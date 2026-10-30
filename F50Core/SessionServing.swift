import Combine
import Foundation

/// Injection boundary for offline policy tests. Production has only F50Session,
/// never a cleartext, HTTP or permissive TLS implementation.
@MainActor
protocol SessionServing: AnyObject {
    var devicePublisher: AnyPublisher<[NearbyDevice], Never> { get }
    var statusPublisher: AnyPublisher<String, Never> { get }
    var scanPublisher: AnyPublisher<Bool, Never> { get }
    var connectedDeviceID: String? { get }
    var onDisconnect: ((String) -> Void)? { get set }
    var onEvent: ((String, JSONValue) -> Void)? { get set }
    func startScan()
    func stopScan()
    func disconnect()
    func connect(id: UUID) async throws
    func request(method: String, params: [String: JSONValue], timeout: TimeInterval) async throws -> JSONValue
}

extension F50Session: SessionServing {
    var devicePublisher: AnyPublisher<[NearbyDevice], Never> { $devices.eraseToAnyPublisher() }
    var statusPublisher: AnyPublisher<String, Never> { $status.eraseToAnyPublisher() }
    var scanPublisher: AnyPublisher<Bool, Never> { $isScanning.eraseToAnyPublisher() }
}
