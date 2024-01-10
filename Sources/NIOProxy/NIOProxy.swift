import Foundation
@_spi(AsyncChannel) import NIOCore
@_spi(AsyncChannel) import NIOPosix
import Logging

public actor NIOProxy {
    private let configuration: ServerConfiguration
    private let group: MultiThreadedEventLoopGroup
    private let bootstrap: ServerBootstrap
    
    private var listeners: [String: [Int: Listener]] = [:]
    
    public static let defaultIPAddress = "0.0.0.0"
    
    public init(configuration: ServerConfiguration = .default) {
        self.configuration = configuration
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: self.configuration.numberOfThreads)
        self.bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: self.configuration.backlog)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
    }
}

extension NIOProxy {
    public struct ServerConfiguration {
        public var backlog: ChannelOptions.Types.BacklogOption.Value
        public var numberOfThreads: Int
        public var logger: Logger
        
        public static let `default` = ServerConfiguration()
        
        public init(backlog: ChannelOptions.Types.BacklogOption.Value = 256, numberOfThreads: Int = System.coreCount, logger: Logger = Logger(label: "NIOProxy.Server")) {
            self.backlog = backlog
            self.numberOfThreads = numberOfThreads
            self.logger = logger
        }
    }
    
    public struct ClientConfiguration {
        public var maxMessagesPerRead: ChannelOptions.Types.MaxMessagesPerReadOption.Value
        public var logger: Logger

        public static let `default` = ClientConfiguration()
        
        public init(maxMessagesPerRead: ChannelOptions.Types.MaxMessagesPerReadOption.Value = 16, logger: Logger = Logger(label: "NIOProxy.Client")) {
            self.maxMessagesPerRead = maxMessagesPerRead
            self.logger = logger
        }
    }

    public func listen(on ipAddress: String = defaultIPAddress, port: Int, targetHost: String, targetPort: Int, configuration: ClientConfiguration = .default) async throws {
        do {
            guard self.listeners[ipAddress]?[port] == nil else {
                throw "NIOProxy is already listening on \(ipAddress):\(port)."
            }
            let channel = try await self.bootstrap.bind(to: try SocketAddress(ipAddress: ipAddress, port: port)) { channel in
                channel.pipeline.addHandler(BackPressureHandler())
                    .flatMap { channel.setOption(ChannelOptions.maxMessagesPerRead, value: configuration.maxMessagesPerRead) }
                    .flatMap { channel.pipeline.addHandler(ConnectHandler(
                        targetHost: targetHost,
                        targetPort: targetPort,
                        logger: configuration.logger
                    )) }
            }
            self.listeners[ipAddress, default: [:]][port] = .init(
                nioChannel: channel,
                configuration: configuration,
                targetHost: targetHost,
                targetPort: targetPort
            )
            self.configuration.logger.info("Listening on \(String(describing: channel.channel.localAddress!))")
        } catch {
            self.configuration.logger.error("Failed to bind \(ipAddress):\(port), \(error)")
            throw error
        }
    }
    
    @discardableResult
    public func stopListening(on ipAddress: String = defaultIPAddress, port: Int) async throws -> Bool {
        if let listener = self.listeners[ipAddress]?[port] {
            self.listeners[ipAddress]?.removeValue(forKey: port)
            if self.listeners[ipAddress]?.isEmpty == true {
                self.listeners.removeValue(forKey: ipAddress)
            }
            
            try await listener.nioChannel.channel.close()
            return true
        } else {
            return false
        }
    }
}

extension NIOProxy {
    public enum UpdateResult {
        case new
        case replaced
        case unchanged
    }
    
    @discardableResult
    public func update(on ipAddress: String = defaultIPAddress, port: Int, targetHost: String, targetPort: Int, configuration: ClientConfiguration = .default) async throws -> UpdateResult {
        let listener = self.listeners[ipAddress]?[port]
        
        if let listener, listener.targetHost == targetHost,
           listener.targetPort == targetPort,
           listener.configuration == configuration {
            return .unchanged
        }
        
        try await self.stopListening(on: ipAddress, port: port)
        try await self.listen(on: ipAddress, port: port, targetHost: targetHost, targetPort: targetPort, configuration: configuration)
        
        return listener == nil ? .new : .replaced
    }
    
    public func update<P>(on ipAddress: String = defaultIPAddress, ports: P, producingTargetWith target: (Int) throws -> (host: String, port: Int), configuration: ClientConfiguration = .default, mapConfigurationWith mapper: ((Int, ClientConfiguration) throws -> ClientConfiguration)? = nil) async throws where P: Sequence, P.Element == Int {
        for port in ports {
            let (targetHost, targetPort) = try target(port)
            try await self.update(
                on: ipAddress,
                port: port,
                targetHost: targetHost,
                targetPort: targetPort,
                configuration: mapper?(port, configuration) ?? configuration
            )
        }
    }
    
    public func stopListening<P>(on ipAddress: String = defaultIPAddress, ports: P) async throws where P: Sequence, P.Element == Int {
        for port in ports {
            try await self.stopListening(on: ipAddress, port: port)
        }
    }
    
    @discardableResult
    public func set<P>(on ipAddress: String = defaultIPAddress, proxyPortsTo ports: P, producingTargetWith target: (Int) throws -> (host: String, port: Int), configuration: ClientConfiguration = .default, mapConfigurationWith mapper: ((Int, ClientConfiguration) throws -> ClientConfiguration)? = nil) async throws -> (new: [Int], removed: [Int], replaced: [Int], unchanged: [Int]) where P: Sequence, P.Element == Int {
        var result: (new: [Int], removed: [Int], replaced: [Int], unchanged: [Int]) = (new: [], removed: [], replaced: [], unchanged: [])

        for port in ports {
            let (targetHost, targetPort) = try target(port)
            switch try await self.update(
                on: ipAddress,
                port: port,
                targetHost: targetHost,
                targetPort: targetPort,
                configuration: mapper?(port, configuration) ?? configuration
            ) {
            case .new:
                result.new.append(port)
            case .replaced:
                result.replaced.append(port)
            case .unchanged:
                result.unchanged.append(port)
            }
        }
        
        if let used = self.listeners[ipAddress]?.keys {
            for port in used {
                if !ports.contains(port) {
                    try await self.stopListening(on: ipAddress, port: port)
                    result.removed.append(port)
                }
            }
        }

        return result
    }
}

extension NIOProxy {
    fileprivate struct Listener {
        let nioChannel: NIOAsyncChannel<Void, Never>
        let configuration: ClientConfiguration
        let targetHost: String
        let targetPort: Int
    }
}

extension NIOProxy.ServerConfiguration: Equatable {
    public static func == (lhs: NIOProxy.ServerConfiguration, rhs: NIOProxy.ServerConfiguration) -> Bool {
        (lhs.backlog, lhs.numberOfThreads, lhs.logger.label) == (rhs.backlog, rhs.numberOfThreads, rhs.logger.label)
    }
}

extension NIOProxy.ClientConfiguration: Equatable {
    public static func == (lhs: NIOProxy.ClientConfiguration, rhs: NIOProxy.ClientConfiguration) -> Bool {
        (lhs.maxMessagesPerRead, lhs.logger.label) == (rhs.maxMessagesPerRead, rhs.logger.label)
    }
}

extension String: Error {}
