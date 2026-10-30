import Foundation
import Combine
import CoreBluetooth

@MainActor
final class F50Session: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate {
    @Published private(set) var devices: [NearbyDevice] = []
    @Published private(set) var status = "未连接"
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var connectedDeviceID: String?
    var onDisconnect: ((String) -> Void)?
    var onEvent: ((String, JSONValue) -> Void)?

    private var scanner: CBCentralManager?
    // Retain recently discovered handles across stop/disconnect; the fresh link manager
    // retrieves its own handle by UUID rather than reusing an old session's delegate.
    private var discovered: [UUID: CBPeripheral] = [:]
    private var scanTimer: Timer?
    private var link: BLELink?
    private var generation = UUID()
    private var connecting: CheckedContinuation<Void, Error>?
    private var pending: CheckedContinuation<JSONValue, Error>?
    private var pendingToken: UUID?
    private var pendingID: Int?
    private var nextID = 1
    private var requestTimer: Timer?
    private var decoder = FrameDecoder()

    func startScan() {
        stopScan()
        guard link == nil else { status = "请先断开当前连接再扫描"; return }
        devices = []; discovered = [:]; isScanning = true; status = "正在扫描附近 F50"
        if let scanner { beginScan(scanner) }
        else { scanner = CBCentralManager(delegate: self, queue: .main) }
        let timer = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopScan() }
        }
        scanTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func beginScan(_ scanner: CBCentralManager) {
        guard isScanning else { return }
        if scanner.state == .poweredOn {
            scanner.scanForPeripherals(withServices: [F50GATT.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        } else if scanner.state != .unknown && scanner.state != .resetting {
            status = TransportError.bluetooth.localizedDescription; stopScan()
        }
    }
    func stopScan() {
        scanTimer?.invalidate(); scanTimer = nil
        scanner?.stopScan(); isScanning = false
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === scanner else { return }
        beginScan(central)
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === scanner, isScanning else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "F50"
        let device = NearbyDevice(id: peripheral.identifier, name: String(name.prefix(64)), rssi: RSSI.intValue)
        devices.removeAll { $0.id == device.id }
        devices.append(device); devices.sort { $0.rssi > $1.rssi }
        devices = Array(devices.prefix(32))
        discovered[device.id] = peripheral
        let retained = Set(devices.map(\.id))
        discovered = discovered.filter { retained.contains($0.key) }
    }

    func connect(id: UUID) async throws {
        try Task.checkCancellation()
        close(TransportError.disconnected, notify: false)
        stopScan()
        let epoch = UUID(); generation = epoch
        status = "正在建立并验证 TLS 1.3 安全连接"
        let transport = BLELink(identifier: id)
        link = transport
        transport.onReady = { [weak self] identity in
            guard let self, self.generation == epoch, self.link != nil else { return }
            self.isConnected = true; self.connectedDeviceID = identity; self.status = "安全连接已就绪"
            let continuation = self.connecting; self.connecting = nil
            continuation?.resume()
        }
        transport.onPlaintext = { [weak self] bytes in
            guard let self, self.generation == epoch else { return }
            do { try self.receive(bytes) } catch { self.close(error) }
        }
        transport.onFailure = { [weak self] error in
            guard let self, self.generation == epoch else { return }
            self.close(error)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connecting = continuation
                if Task.isCancelled { close(TransportError.cancelled) }
                else { transport.start() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == epoch, self.connecting != nil else { return }
                self.close(TransportError.cancelled)
            }
        }
    }

    func request(method: String, params: [String: JSONValue] = [:], timeout: TimeInterval = 20) async throws -> JSONValue {
        try Task.checkCancellation()
        guard isConnected, let link else { throw TransportError.disconnected }
        guard pending == nil else { throw TransportError.busy }
        guard timeout.isFinite, timeout > 0, timeout <= 300, !method.isEmpty else { throw TransportError.protocolViolation }
        let id = nextID; nextID = nextID == Int(Int32.max) ? 1 : nextID + 1
        let envelope: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": .object(params)])
        let bytes = try WireCodec.frame(JSONEncoder().encode(envelope))
        let token = UUID(), epoch = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation; pendingID = id; pendingToken = token
                let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == epoch, self.pendingToken == token else { return }
                        self.close(TransportError.timeout)
                    }
                }
                requestTimer = timer; RunLoop.main.add(timer, forMode: .common)
                if Task.isCancelled { close(TransportError.cancelled); return }
                do { try link.send(bytes) } catch { close(error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == epoch, self.pendingToken == token else { return }
                self.close(TransportError.cancelled)
            }
        }
    }
    private func receive(_ bytes: Data) throws {
        for frame in try decoder.feed(bytes) {
            switch try RPCMessage.decode(frame, pendingID: pendingID) {
            case .event(let method, let params):
                onEvent?(method, params)
                guard isConnected else { return }
            case .result(let result):
                guard let continuation = pending else { throw TransportError.protocolViolation }
                clearPending(); continuation.resume(returning: result)
            case .failure(let error):
                guard let continuation = pending else { throw TransportError.protocolViolation }
                clearPending(); continuation.resume(throwing: error)
            }
        }
    }
    private func clearPending() {
        pending = nil; pendingID = nil; pendingToken = nil
        requestTimer?.invalidate(); requestTimer = nil
    }
    // AppModel is the sole poll/keepalive scheduler, so hidden pings cannot race user actions.
    func disconnect() { stopScan(); close(TransportError.disconnected) }
    private func close(_ error: Error, notify: Bool = true) {
        let hadSession = link != nil || connecting != nil || pending != nil || isConnected
        generation = UUID() // invalidate callbacks/cancellation BEFORE destroying old resources
        let old = link; link = nil; old?.close()
        let connectContinuation = connecting; connecting = nil
        let requestContinuation = pending; clearPending()
        decoder = FrameDecoder(); nextID = 1
        isConnected = false; connectedDeviceID = nil
        // Never expose arbitrary NIO/CoreBluetooth/JSON errors (may embed payloads).
        let safe = (error as? TransportError) ?? .tls
        status = safe.localizedDescription
        connectContinuation?.resume(throwing: safe)
        requestContinuation?.resume(throwing: safe)
        if notify && hadSession { onDisconnect?(status) }
    }
}
