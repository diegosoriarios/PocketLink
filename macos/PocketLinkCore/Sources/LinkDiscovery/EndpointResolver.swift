import Foundation
import dnssd

public struct ResolvedEndpoint: Equatable, Sendable {
    public let ip: String
    public let port: UInt16

    public init(ip: String, port: UInt16) {
        self.ip = ip
        self.port = port
    }
}

/// Resolves an mDNS service to its IP address and port without opening a TCP
/// connection. Uses dnssd directly because connecting with NWConnection would
/// actually dial the remote peer, which on PocketLink would replace any active
/// accepted session on the phone.
public actor EndpointResolver {
    private let queue = DispatchQueue(label: "link.endpoint-resolver", qos: .utility)

    public init() {}

    public func resolve(
        name: String,
        type: String,
        domain: String,
        interfaceIndex: UInt32 = 0,
        timeout: TimeInterval = 4
    ) async -> ResolvedEndpoint? {
        await withCheckedContinuation { continuation in
            let session = EndpointResolutionSession(continuation: continuation, queue: queue)
            if session.start(name: name, type: type, domain: domain, interfaceIndex: interfaceIndex) {
                session.scheduleTimeout(seconds: timeout)
            } else {
                session.finish(nil)
            }
        }
    }
}

final class EndpointResolutionSession: @unchecked Sendable {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var continuation: CheckedContinuation<ResolvedEndpoint?, Never>?
    private var resolveRef: DNSServiceRef?
    private var addrRef: DNSServiceRef?
    private var timeoutItem: DispatchWorkItem?
    private var servicePort: UInt16?
    private var interfaceIndex: UInt32 = 0
    private var finished = false
    private var selfContext: UnsafeMutableRawPointer?

    fileprivate init(continuation: CheckedContinuation<ResolvedEndpoint?, Never>, queue: DispatchQueue) {
        self.continuation = continuation
        self.queue = queue
    }
    fileprivate func start(name: String, type: String, domain: String, interfaceIndex: UInt32) -> Bool {
        self.interfaceIndex = interfaceIndex
        let context = Unmanaged.passRetained(self).toOpaque()
        selfContext = context
        let error = name.withCString { nameC in
            type.withCString { typeC in
                domain.withCString { domainC in
                    DNSServiceResolve(
                        &resolveRef,
                        0,
                        interfaceIndex,
                        nameC,
                        typeC,
                        domainC,
                        resolveReply,
                        context
                    )
                }
            }
        }
        guard error == kDNSServiceErr_NoError, let resolveRef else {
            return false
        }
        DNSServiceSetDispatchQueue(resolveRef, queue)
        return true
    }

    fileprivate func scheduleTimeout(seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            self?.finish(nil)
        }
        lock.lock()
        timeoutItem = item
        lock.unlock()
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    fileprivate func finish(_ result: ResolvedEndpoint?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        timeoutItem?.cancel()
        timeoutItem = nil
        let continuation = self.continuation
        self.continuation = nil
        if let resolveRef {
            DNSServiceRefDeallocate(resolveRef)
        }
        if let addrRef {
            DNSServiceRefDeallocate(addrRef)
        }
        resolveRef = nil
        addrRef = nil
        lock.unlock()
        if let context = selfContext {
            selfContext = nil
            Unmanaged<EndpointResolutionSession>.fromOpaque(context).release()
        }
        continuation?.resume(returning: result)
    }

    private func isFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    fileprivate func handleResolve(errorCode: DNSServiceErrorType, hostTarget: String?, port: UInt16) {
        guard !isFinished() else { return }
        guard errorCode == kDNSServiceErr_NoError, let hostTarget else {
            finish(nil)
            return
        }
        lock.lock()
        servicePort = UInt16(bigEndian: port)
        lock.unlock()
        startAddrInfo(host: hostTarget)
    }

    private func startAddrInfo(host: String) {
        guard !isFinished() else {
            finish(nil)
            return
        }
        var child: DNSServiceRef?
        let context = selfContext ?? Unmanaged.passRetained(self).toOpaque()
        if selfContext == nil {
            selfContext = context
        }
        let error = host.withCString { hostC in
            DNSServiceGetAddrInfo(
                &child,
                0,
                interfaceIndex,
                DNSServiceProtocol(kDNSServiceProtocol_IPv4),
                hostC,
                addrInfoReply,
                context
            )
        }
        guard error == kDNSServiceErr_NoError, let child else {
            finish(nil)
            return
        }
        addrRef = child
        DNSServiceSetDispatchQueue(child, queue)
    }

    fileprivate func handleAddrInfo(errorCode: DNSServiceErrorType, address: UnsafePointer<sockaddr>?) {
        guard !isFinished() else { return }
        guard errorCode == kDNSServiceErr_NoError, let address else {
            finish(nil)
            return
        }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address,
            socklen_t(address.pointee.sa_len),
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else {
            finish(nil)
            return
        }
        let ip = String(decoding: host.prefix(while: { $0 != 0 }).map(UInt8.init), as: UTF8.self)
        lock.lock()
        let port = servicePort ?? 0
        lock.unlock()
        finish(ResolvedEndpoint(ip: ip, port: port))
    }
}

private func resolveReply(
    sdRef: DNSServiceRef?,
    flags: DNSServiceFlags,
    interfaceIndex: UInt32,
    errorCode: DNSServiceErrorType,
    fullName: UnsafePointer<CChar>?,
    hostTarget: UnsafePointer<CChar>?,
    port: UInt16,
    txtLen: UInt16,
    txtRecord: UnsafePointer<UInt8>?,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let session = Unmanaged<EndpointResolutionSession>.fromOpaque(context).takeUnretainedValue()
    session.handleResolve(
        errorCode: errorCode,
        hostTarget: hostTarget.map { String(cString: $0) },
        port: port
    )
}

private func addrInfoReply(
    sdRef: DNSServiceRef?,
    flags: DNSServiceFlags,
    interfaceIndex: UInt32,
    errorCode: DNSServiceErrorType,
    hostname: UnsafePointer<CChar>?,
    address: UnsafePointer<sockaddr>?,
    ttl: UInt32,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let session = Unmanaged<EndpointResolutionSession>.fromOpaque(context).takeUnretainedValue()
    session.handleAddrInfo(errorCode: errorCode, address: address)
}
