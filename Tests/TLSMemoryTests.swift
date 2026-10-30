import XCTest
import CryptoKit
import NIOCore
import NIOEmbedded
import NIOSSL
@testable import F50Manager

/// Entirely offline BoringSSL client/server interoperability. This deliberately PUBLIC synthetic
/// key/certificate belongs only to these tests; it is never provisioned into the application.
final class TLSMemoryTests: XCTestCase {
    private static let certificatePEM = """
    -----BEGIN CERTIFICATE-----
    MIIBbDCCARKgAwIBAgIUZUNBCFLKkTrAacrJVcgiHfQLx20wCgYIKoZIzj0EAwIw
    HDEaMBgGA1UEAwwRb2ZmbGluZS10ZXN0LW9ubHkwHhcNMjYxMDMwMDE0MTE0WhcN
    MjYxMTI5MDE0MTE0WjAcMRowGAYDVQQDDBFvZmZsaW5lLXRlc3Qtb25seTBZMBMG
    ByqGSM49AgEGCCqGSM49AwEHA0IABBsxHr68f4RlHP00plHEyLHKnJzBiXMAsnck
    QDLSSIxZOaefSyAkKVko2Cvz1uiBWwL13IqentCP87QInxxYiFWjMjAwMB0GA1Ud
    DgQWBBTpwyAZfWAMac7zcx9x6GqOq1kX9TAPBgNVHRMBAf8EBTADAQH/MAoGCCqG
    SM49BAMCA0gAMEUCICsaYel9W+R4MOGqTZC5TMpsduj0GlYm6pm1Ja+AJCZHAiEA
    zcwg2ZhWQjkPWQInHrl6L33Mc2uqwRRo8BTkis0OPV4=
    -----END CERTIFICATE-----
    """
    private static let privateKeyPEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgPZoa78wMmvIjyo/Y
    UxZ0I1STFYHLB5e3zVeu5YOC946hRANCAAQbMR6+vH+EZRz9NKZRxMixypycwYlz
    ALJ3JEAy0kiMWTmnn0sgJClZKNgr89bogVsC9dyKnp7Qj/O0CJ8cWIhV
    -----END PRIVATE KEY-----
    """
    private func certificate() throws -> NIOSSLCertificate {
        try NIOSSLCertificate(bytes: Array(Self.certificatePEM.utf8), format: .pem)
    }
    private func pin() throws -> [UInt8] { Array(SHA256.hash(data: Data(try certificate().toDERBytes()))) }
    private func server(alpn: [String] = ["f50mgr/1"], version: TLSVersion = .tlsv13) throws -> EmbeddedChannel {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try certificate())],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(Self.privateKeyPEM.utf8), format: .pem)))
        configuration.minimumTLSVersion = version; configuration.maximumTLSVersion = version
        configuration.applicationProtocols = alpn
        let handler = NIOSSLServerHandler(context: try NIOSSLContext(configuration: configuration))
        let channel = EmbeddedChannel(handler: handler)
        channel.connect(to: try SocketAddress(unixDomainSocketPath: "/offline-f50-test"), promise: nil)
        return channel
    }
    private func closeServer(_ server: EmbeddedChannel) {
        if let context = try? server.pipeline.syncOperations.context(handlerType: NIOSSLServerHandler.self) {
            context.close(promise: nil)
        }
        server.embeddedEventLoop.run()
        _ = try? server.finish(acceptAlreadyClosed: true)
    }
    /// Exchange records with deliberate minimum-MTU and one-byte fragmentation. No wall-clock sleeps.
    @discardableResult private func exchange(_ client: MemoryTLS, _ server: EmbeddedChannel, fragment: Int = 19) throws -> [Data] {
        var received: [Data] = []
        for _ in 0..<40 {
            var progress = false
            let output = try client.pump()
            received += output.plaintext
            for record in output.encrypted {
                progress = true
                var buffer = server.allocator.buffer(capacity: record.count)
                buffer.writeBytes(record)
                _ = try server.writeInbound(buffer)
            }
            server.embeddedEventLoop.run()
            while let buffer = try server.readOutbound(as: ByteBuffer.self) {
                progress = true
                let bytes = Array(buffer.readableBytesView)
                for offset in stride(from: 0, to: bytes.count, by: fragment) {
                    try client.receive(Data(bytes[offset..<min(offset + fragment, bytes.count)]))
                }
            }
            if !progress { return received }
        }
        throw TransportError.timeout
    }
    @MainActor func testRealTLS13MemoryRoundTripAndFreshConnections() throws {
        for _ in 0..<2 { // new handler/context; never reuse prior TLS/auth state
            let client = try MemoryTLS(pin: pin()), server = try server()
            defer { client.close(); closeServer(server) }
            XCTAssertFalse(client.ready)
            _ = try exchange(client, server, fragment: 1)
            XCTAssertTrue(client.ready)
            let request = try WireCodec.frame(Data(#"{"jsonrpc":"2.0","id":1,"method":"sys.hello","params":{}}"#.utf8))
            try client.send(request)
            _ = try exchange(client, server)
            var received = Data()
            while let buffer = try server.readInbound(as: ByteBuffer.self) { received.append(contentsOf: buffer.readableBytesView) }
            XCTAssertEqual(received, request)
            let reply = try WireCodec.frame(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
            var buffer = server.allocator.buffer(capacity: reply.count); buffer.writeBytes(reply)
            _ = try server.writeOutbound(buffer)
            XCTAssertEqual(try exchange(client, server).reduce(Data(), +), reply)
            client.close()
            XCTAssertFalse(client.ready)
            XCTAssertThrowsError(try client.send(request))
        }
    }
    @MainActor func testWrongPinRejectsBeforeReadyOrApplicationData() throws {
        let client = try MemoryTLS(pin: Array(repeating: 0, count: 32)), server = try server()
        defer { client.close(); closeServer(server) }
        XCTAssertThrowsError(try exchange(client, server))
        XCTAssertFalse(client.ready)
        XCTAssertThrowsError(try client.send(Data([1])))
    }
    @MainActor func testMissingAndWrongALPNReject() throws {
        for protocols in [[], ["not-f50/1"]] as [[String]] {
            let client = try MemoryTLS(pin: pin()), server = try server(alpn: protocols)
            defer { client.close(); closeServer(server) }
            XCTAssertThrowsError(try exchange(client, server))
            XCTAssertFalse(client.ready)
        }
    }
    @MainActor func testTLS12ServerRejected() throws {
        let client = try MemoryTLS(pin: pin()), server = try server(version: .tlsv12)
        defer { client.close(); closeServer(server) }
        XCTAssertThrowsError(try exchange(client, server))
        XCTAssertFalse(client.ready)
    }
    @MainActor func testOversizeInputAndInvalidPinRejected() throws {
        XCTAssertThrowsError(try MemoryTLS(pin: []))
        let client = try MemoryTLS(pin: pin())
        defer { client.close() }
        XCTAssertThrowsError(try client.receive(Data(repeating: 0, count: 513)))
        XCTAssertFalse(client.ready)
    }
}
