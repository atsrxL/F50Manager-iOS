import Foundation
import CryptoKit

enum TransportError: LocalizedError, Equatable {
    case protocolViolation, size, identity, unprovisioned, tls, disconnected, timeout, cancelled, busy, bluetooth, remote(Int)
    var errorDescription: String? {
        switch self {
        case .protocolViolation: return "设备协议异常，安全连接已关闭"
        case .size: return "设备消息或队列超过安全上限，连接已关闭"
        case .identity: return "设备身份已改变；不会自动更新证书，请人工核对"
        case .unprovisioned: return "此设备的证书未预置，无法验证身份"
        case .tls: return "TLS 1.3 安全验证失败，连接已关闭"
        case .disconnected: return "蓝牙连接已断开"
        case .timeout: return "操作超时，连接已关闭；结果可能未知，请重新读取状态，勿重复执行"
        case .cancelled: return "操作已取消，连接已关闭；已发送操作的结果可能未知"
        case .busy: return "正在处理另一请求，请稍后再试"
        case .bluetooth: return "蓝牙不可用，请检查蓝牙权限、开关和系统配对提示"
        case .remote(let reason):
            switch reason {
            case 4: return "连接空闲超时，请重新连接"
            case 5: return "设备正被其他客户端使用"
            case 7: return "设备正在重启或关闭"
            case 9: return "设备暂时锁定，请稍后再试"
            default: return "设备已关闭安全连接"
            }
        }
    }
}

/// Never retain or display the server's private response/message/data.
struct RPCError: LocalizedError {
    let code: Int
    var errorDescription: String? {
        switch code {
        case -32001: return "此操作需要本次连接授权"
        case -32002: return "授权失败"
        case -32003: return "授权尝试过多，请稍后重试"
        case -32601, -32010: return "设备不支持此功能"
        case -32602: return "操作参数无效，请检查输入"
        case -32011, -32012: return "设备所需服务或硬件暂不可用"
        case -32020: return "设备忙，请稍后重试"
        case -32021, -32022: return "操作确认已失效，请重新准备"
        case -32023, -32024: return "Wi-Fi 事务冲突或已结束，请刷新状态"
        case -32031: return "操作结果不确定，请读取实际状态，勿自动重试"
        default: return "设备未能完成请求，请刷新状态后检查"
        }
    }
}

enum WireCodec {
    static let maximumFrame = 65_536
    static let maximumQueue = 131_072
    static let open = Data([2, 1])

    static func frame(_ body: Data) throws -> Data {
        guard (1...maximumFrame).contains(body.count) else { throw TransportError.size }
        let n = UInt32(body.count)
        return Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) + body
    }
    static func chunks(_ stream: Data, valueLimit: Int) throws -> [Data] {
        guard (20...512).contains(valueLimit), stream.count <= maximumQueue else { throw TransportError.size }
        let bytes = [UInt8](stream), room = valueLimit - 1
        return stride(from: 0, to: bytes.count, by: room).map { Data([1]) + Data(bytes[$0..<min($0 + room, bytes.count)]) }
    }
    static func payload(_ value: Data, awaitingOpen: Bool, valueLimit: Int) throws -> Data? {
        guard value.count >= 2, value.count <= min(valueLimit, 512) else { throw TransportError.size }
        let bytes = [UInt8](value)
        if bytes[0] == 3, bytes.count == 2 { throw TransportError.remote(Int(bytes[1])) }
        if awaitingOpen {
            guard value == open else { throw TransportError.protocolViolation }
            return nil
        }
        guard bytes[0] == 1 else { throw TransportError.protocolViolation }
        return Data(bytes.dropFirst())
    }
}

/// Incremental decoder; invalid input permanently poisons this connection's decoder.
struct FrameDecoder {
    private var buffer = Data()
    private var failed = false
    mutating func feed(_ input: Data) throws -> [Data] {
        guard !failed else { throw TransportError.protocolViolation }
        do {
            guard input.count <= WireCodec.maximumQueue, buffer.count + input.count <= WireCodec.maximumQueue else { throw TransportError.size }
            buffer.append(input)
            var messages: [Data] = []
            while buffer.count >= 4 {
                let n = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard n > 0, n <= WireCodec.maximumFrame else { throw TransportError.size }
                guard buffer.count >= Int(n) + 4 else { break }
                let body = Data(buffer.dropFirst(4).prefix(Int(n)))
                guard String(data: body, encoding: .utf8) != nil else { throw TransportError.protocolViolation }
                messages.append(body)
                buffer.removeFirst(Int(n) + 4)
            }
            return messages
        } catch { failed = true; buffer.removeAll(); throw error }
    }
}

enum ProvisionedDevices {
    // Public certificate fingerprint only, identical to Android's explicitly provisioned identity.
    static func pin(for hint: String) throws -> [UInt8] {
        guard hint == "W3MJZCCR" else { throw TransportError.unprovisioned }
        let hex = "e0e92fb198c427b86cb391b62d3004380af8dc78f895af677dbe02501edd0d4f"
        return stride(from: 0, to: hex.count, by: 2).map { offset in
            let i = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[i..<hex.index(i, offsetBy: 2)], radix: 16)!
        }
    }
    static func verify(der: [UInt8], pin: [UInt8]) -> Bool {
        let digest = Array(SHA256.hash(data: Data(der)))
        guard pin.count == 32 else { return false }
        return zip(digest, pin).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

enum RPCMessage {
    case event(String, JSONValue)
    case result(JSONValue)
    case failure(RPCError)

    static func decode(_ frame: Data, pendingID: Int?) throws -> RPCMessage {
        let json: JSONValue
        do { json = try JSONDecoder().decode(JSONValue.self, from: frame) }
        catch { throw TransportError.protocolViolation }
        guard let object = json.object, json["jsonrpc"].string == "2.0" else { throw TransportError.protocolViolation }
        if object["id"] == nil {
            guard let method = json["method"].string, method.hasPrefix("event."), method.count <= 128,
                  json["params"].object != nil, object["result"] == nil, object["error"] == nil else { throw TransportError.protocolViolation }
            return .event(method, json["params"])
        }
        guard let id = pendingID, json["id"].number == Double(id), object["method"] == nil,
              (object["result"] != nil) != (object["error"] != nil) else { throw TransportError.protocolViolation }
        if object["error"] != nil {
            guard let code = json["error"]["code"].number, code.rounded() == code,
                  code >= Double(Int32.min), code <= Double(Int32.max), json["error"]["message"].string != nil else { throw TransportError.protocolViolation }
            return .failure(RPCError(code: Int(code)))
        }
        guard json["result"].object != nil else { throw TransportError.protocolViolation }
        return .result(json["result"])
    }
}

/// Monotonic deadlines are not extended by partial/malicious input.
struct TransportDeadline {
    let end: TimeInterval
    init(now: TimeInterval, timeout: TimeInterval) { end = now + timeout }
    func expired(at now: TimeInterval) -> Bool { now >= end }
}
