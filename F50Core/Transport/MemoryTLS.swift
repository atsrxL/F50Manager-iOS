import Foundation
import NIOCore
import NIOEmbedded
import NIOSSL
import NIOTLS

/// All calls, including construction/destruction and callbacks, stay on the main thread.
/// EmbeddedChannel is only a memory BIO adapter: its connect address opens NO socket.
/// A fresh context/handler per connection means no TLS session cache or ticket reuse.
final class MemoryTLS {
    private final class Verification {
        var accepted = false
        var rejected = false
    }
    private final class Observer: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        var negotiated: String?
        var handshakeComplete = false
        var failure: Error?
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if case let TLSUserEvent.handshakeCompleted(negotiatedProtocol: proto) = event {
                negotiated = proto
                handshakeComplete = true
            }
            context.fireUserInboundEventTriggered(event)
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { failure = error }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.fireChannelRead(data) }
    }
    private let verification = Verification()
    private let observer = Observer()
    private let channel: EmbeddedChannel
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private(set) var ready = false
    private var closed = false
    private var handshakeBytes = 0

    init(pin: [UInt8]) throws {
        precondition(Thread.isMainThread)
        guard pin.count == 32 else { throw TransportError.identity }
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        configuration.applicationProtocols = ["f50mgr/1"]
        // Custom verification replaces PKI/date/hostname validation, not verification itself.
        configuration.certificateVerification = .noHostnameVerification
        let context = try NIOSSLContext(configuration: configuration)
        let state = verification
        let handler = try NIOSSLClientHandler(context: context, serverHostname: nil, customVerificationCallback: { certificates, promise in
            precondition(Thread.isMainThread)
            let valid = certificates.first.flatMap { try? $0.toDERBytes() }.map { ProvisionedDevices.verify(der: $0, pin: pin) } ?? false
            state.accepted = valid
            state.rejected = !valid
            promise.succeed(valid ? .certificateVerified : .failed)
        })
        channel = EmbeddedChannel(handlers: [handler, observer])
        channel.connect(to: try SocketAddress(unixDomainSocketPath: "/f50-memory-only"), promise: nil)
        channel.embeddedEventLoop.run()
    }

    func receive(_ bytes: Data) throws {
        precondition(Thread.isMainThread)
        guard !closed, bytes.count <= 512 else { throw TransportError.size }
        if !ready {
            handshakeBytes += bytes.count
            guard handshakeBytes <= WireCodec.maximumQueue else { throw TransportError.size }
        }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        do { _ = try channel.writeInbound(buffer) }
        catch { throw verification.rejected ? TransportError.identity : TransportError.tls }
    }
    func send(_ bytes: Data) throws {
        precondition(Thread.isMainThread)
        guard ready, !closed else { throw TransportError.tls }
        guard bytes.count <= WireCodec.maximumFrame + 4 else { throw TransportError.size }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        _ = try channel.writeOutbound(buffer)
    }
    /// Run ready tasks and advance embedded time by real monotonic elapsed time, never run all future timers.
    func pump() throws -> (encrypted: [Data], plaintext: [Data]) {
        precondition(Thread.isMainThread)
        guard !closed else { throw TransportError.disconnected }
        let now = ProcessInfo.processInfo.systemUptime
        channel.embeddedEventLoop.advanceTime(by: .nanoseconds(Int64(max(0, now - lastTick) * 1_000_000_000)))
        lastTick = now
        channel.embeddedEventLoop.run()
        if verification.rejected { throw TransportError.identity }
        if observer.failure != nil { throw TransportError.tls }
        if observer.handshakeComplete {
            guard verification.accepted, observer.negotiated == "f50mgr/1" else { throw TransportError.tls }
            ready = true
        }
        guard channel.isActive else { throw TransportError.disconnected }
        var encrypted: [Data] = [], plaintext: [Data] = []
        var size = 0
        while let buffer = try channel.readOutbound(as: ByteBuffer.self) {
            size += buffer.readableBytes
            guard size <= WireCodec.maximumQueue else { throw TransportError.size }
            encrypted.append(Data(buffer.readableBytesView))
        }
        size = 0
        while let buffer = try channel.readInbound(as: ByteBuffer.self) {
            guard ready else { throw TransportError.tls }
            size += buffer.readableBytes
            guard size <= WireCodec.maximumQueue else { throw TransportError.size }
            plaintext.append(Data(buffer.readableBytesView))
        }
        return (encrypted, plaintext)
    }
    func close() {
        precondition(Thread.isMainThread)
        guard !closed else { return }
        closed = true; ready = false
        // Abort below SSL, rather than waiting for a peer close_notify on an embedded loop.
        // finish() alone would synchronously wait for NIOSSL's graceful shutdown timeout.
        if let context = try? channel.pipeline.syncOperations.context(handlerType: NIOSSLClientHandler.self) {
            context.close(promise: nil)
        }
        channel.embeddedEventLoop.run()
        _ = try? channel.finish(acceptAlreadyClosed: true)
    }
}
