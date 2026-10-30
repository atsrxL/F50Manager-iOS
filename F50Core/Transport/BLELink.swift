import Foundation
import CoreBluetooth

enum F50GATT {
    static let service = CBUUID(string: "d3ec2c28-de73-4173-b0e1-06fd4e6b25a0")
    static let info = CBUUID(string: "d3ec2c29-de73-4173-b0e1-06fd4e6b25a0")
    static let rx = CBUUID(string: "d3ec2c2a-de73-4173-b0e1-06fd4e6b25a0")
    static let tx = CBUUID(string: "d3ec2c2b-de73-4173-b0e1-06fd4e6b25a0")
}

/// A new delegate, manager, peripheral discovery, pin check and TLS context for EVERY attempt.
/// Closed delegates ignore late callbacks; no callback can enter a replacement session.
@MainActor
final class BLELink: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private enum Phase { case power, connecting, services, characteristics, subscribing, info, open, tls, ready, closed }
    var onReady: ((String) -> Void)?
    var onPlaintext: ((Data) -> Void)?
    var onFailure: ((Error) -> Void)?
    private let identifier: UUID
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var info: CBCharacteristic?
    private var phase: Phase = .power
    private var deadline = TransportDeadline(now: ProcessInfo.processInfo.systemUptime, timeout: 10)
    private var timer: Timer?
    private var tls: MemoryTLS?
    private var pin: [UInt8]?
    private var deviceID: String?
    private var valueLimit = 20
    private var writes: [Data] = []
    private var queuedBytes = 0
    private var inFlight: Data?
    private var writeDeadline: TransportDeadline?

    init(identifier: UUID) { self.identifier = identifier; super.init() }
    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func enter(_ next: Phase, timeout: TimeInterval = 15) {
        phase = next
        deadline = TransportDeadline(now: ProcessInfo.processInfo.systemUptime, timeout: timeout)
    }
    private func tick() {
        guard phase != .closed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if (phase != .ready && deadline.expired(at: now)) || writeDeadline?.expired(at: now) == true {
            fail(TransportError.timeout); return
        }
        do { try pump() } catch { fail(error) }
    }
    func send(_ data: Data) throws {
        guard phase == .ready, let tls else { throw TransportError.disconnected }
        do { try tls.send(data); try pump() } catch { fail(error); throw error }
    }
    private func pump() throws {
        guard let tls else { return }
        let output = try tls.pump()
        for record in output.encrypted { try enqueue(WireCodec.chunks(record, valueLimit: valueLimit)) }
        if phase == .tls && tls.ready {
            guard let deviceID else { throw TransportError.identity }
            enter(.ready)
            onReady?(deviceID)
        }
        for plaintext in output.plaintext {
            guard phase == .ready else { throw TransportError.tls }
            onPlaintext?(plaintext)
            if phase == .closed { return }
        }
    }
    private func enqueue(_ frames: [Data]) throws {
        guard phase != .closed, frames.allSatisfy({ !$0.isEmpty && $0.count <= valueLimit }),
              frames.count + writes.count <= 8192 else { throw TransportError.size }
        let added = frames.reduce(0) { $0 + $1.count }
        guard added + queuedBytes <= WireCodec.maximumQueue else { throw TransportError.size }
        writes.append(contentsOf: frames); queuedBytes += added
        writeNext()
    }
    private func writeNext() {
        guard phase != .closed, inFlight == nil, !writes.isEmpty else { return }
        guard let peripheral, let rx else { fail(TransportError.disconnected); return }
        let frame = writes.removeFirst()
        inFlight = frame
        writeDeadline = TransportDeadline(now: ProcessInfo.processInfo.systemUptime, timeout: 10)
        peripheral.writeValue(frame, for: rx, type: .withResponse)
    }
    func close() {
        guard phase != .closed else { return }
        phase = .closed
        timer?.invalidate(); timer = nil
        tls?.close(); tls = nil
        pin = nil; deviceID = nil
        writes.removeAll(); inFlight = nil; queuedBytes = 0; writeDeadline = nil
        rx = nil; tx = nil; info = nil
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        central?.delegate = nil
        central = nil
        onReady = nil; onPlaintext = nil; onFailure = nil
    }
    private func fail(_ error: Error) {
        guard phase != .closed else { return }
        let callback = onFailure
        close()
        callback?(error)
    }
    private func current(_ source: CBPeripheral) -> Bool { phase != .closed && source === peripheral }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central, phase != .closed else { return }
        guard central.state == .poweredOn else {
            if phase != .power || (central.state != .unknown && central.state != .resetting) { fail(TransportError.bluetooth) }
            return
        }
        guard phase == .power else { return }
        guard let found = central.retrievePeripherals(withIdentifiers: [identifier]).first else { fail(TransportError.disconnected); return }
        peripheral = found; found.delegate = self
        enter(.connecting, timeout: 20)
        central.connect(found, options: nil)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central, current(peripheral), phase == .connecting else { return }
        enter(.services)
        peripheral.discoverServices([F50GATT.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, current(peripheral) else { return }
        fail(TransportError.bluetooth)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard central === self.central, current(peripheral) else { return }
        fail(TransportError.disconnected)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard current(peripheral), phase == .services else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == F50GATT.service }) else { fail(TransportError.protocolViolation); return }
        enter(.characteristics)
        peripheral.discoverCharacteristics([F50GATT.info, F50GATT.rx, F50GATT.tx], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard current(peripheral), phase == .characteristics, service.uuid == F50GATT.service else { return }
        guard error == nil, let chars = service.characteristics,
              let rx = chars.first(where: { $0.uuid == F50GATT.rx }), rx.properties.contains(.write),
              let tx = chars.first(where: { $0.uuid == F50GATT.tx }), tx.properties.contains(.indicate), !tx.properties.contains(.notify),
              let info = chars.first(where: { $0.uuid == F50GATT.info }), info.properties.contains(.read) else {
            fail(TransportError.protocolViolation); return
        }
        self.rx = rx; self.tx = tx; self.info = info
        // withResponse alone may advertise 512 by using ATT prepared/long writes.
        // The withoutResponse limit estimates one ATT value; use it ONLY as a bound,
        // never as the actual write type (all writes below remain withResponse).
        valueLimit = min(512, peripheral.maximumWriteValueLength(for: .withResponse),
                         peripheral.maximumWriteValueLength(for: .withoutResponse))
        guard valueLimit >= 20 else { fail(TransportError.size); return }
        enter(.subscribing)
        peripheral.setNotifyValue(true, for: tx) // indicate-only characteristic -> CCCD 0x0002
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard current(peripheral), characteristic === tx else { return }
        guard error == nil, characteristic.isNotifying else { fail(TransportError.bluetooth); return }
        guard phase == .subscribing, let info else { fail(TransportError.protocolViolation); return }
        enter(.info)
        peripheral.readValue(for: info) // CoreBluetooth performs long attribute reads.
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard current(peripheral) else { return }
        guard error == nil, let value = characteristic.value else { fail(TransportError.bluetooth); return }
        do {
            if characteristic === info {
                guard phase == .info, value.count <= 160,
                      let object = try JSONSerialization.jsonObject(with: value) as? [String: Any],
                      object["p"] as? String == "f50mgr/1", let hint = object["id"] as? String else { throw TransportError.protocolViolation }
                pin = try ProvisionedDevices.pin(for: hint) // untrusted hint ONLY selects a provisioned pin
                deviceID = hint
                enter(.open, timeout: 5)
                try enqueue([WireCodec.open])
            } else if characteristic === tx {
                guard phase == .open || phase == .tls || phase == .ready else { throw TransportError.protocolViolation }
                let payload = try WireCodec.payload(value, awaitingOpen: phase == .open, valueLimit: valueLimit)
                if let payload {
                    guard let tls else { throw TransportError.tls }
                    try tls.receive(payload)
                } else {
                    guard let pin else { throw TransportError.identity }
                    enter(.tls, timeout: 30)
                    tls = try MemoryTLS(pin: pin)
                    self.pin = nil
                }
                try pump()
            } else { throw TransportError.protocolViolation }
        } catch { fail(error) }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard current(peripheral), characteristic === rx else { return }
        guard error == nil, let frame = inFlight else { fail(TransportError.bluetooth); return }
        queuedBytes -= frame.count; inFlight = nil; writeDeadline = nil
        writeNext()
    }
}
