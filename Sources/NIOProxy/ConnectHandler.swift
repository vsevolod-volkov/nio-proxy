import Foundation
@_spi(AsyncChannel) import NIOCore
@_spi(AsyncChannel) import NIOPosix
import Logging

final class ConnectHandler {
    private var state: State

    private var logger: Logger
    private let targetHost: String
    private let targetPort: Int

    init(targetHost: String, targetPort: Int, logger: Logger) {
        self.state = .connecting(pandingBytes: [])
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.logger = logger
    }
}


extension ConnectHandler {
    fileprivate enum State {
        case connecting(pandingBytes: [NIOAny])
        case connected(connectResult: Channel)
        case failure(error: Error)
    }
}


extension ConnectHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    typealias OutboundOut = NIOAny

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch self.state {
        case .connecting(let pendingBytes):
            self.state = .connecting(pandingBytes: pendingBytes + [data])

        case .connected(let peerChannel):
            peerChannel.write(data, promise: nil)
            peerChannel.flush()

        case .failure:
            break
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // Add logger metadata.
        if let localAddress = context.channel.localAddress,
           let remoteAddress = context.channel.remoteAddress {
            self.logger.info("Handler added for remote peer \(String(describing: remoteAddress)) connection to local address \(String(describing: localAddress))")
        }

        self.connectTo(host: self.targetHost, port: self.targetPort, context: context)
    }
}


extension ConnectHandler: RemovableChannelHandler {
    func removeHandler(context: ChannelHandlerContext, removalToken: ChannelHandlerContext.RemovalToken) {
        self.logger.debug("Removing \(self) from pipeline")
        context.leavePipeline(removalToken: removalToken)
    }
}

extension ConnectHandler {
    private func connectTo(host: String, port: Int, context: ChannelHandlerContext) {
        self.logger.info("Connecting to \(host):\(port)")

        let channelFuture = ClientBootstrap(group: context.eventLoop)
            .connect(host: String(host), port: port)

        channelFuture.whenSuccess { channel in
            self.connectSucceeded(channel: channel, context: context)
        }
        channelFuture.whenFailure { error in
            self.connectFailed(error: error, context: context)
        }
    }

    private func connectSucceeded(channel: Channel, context: ChannelHandlerContext) {
        if let remoteAddress = channel.remoteAddress {
            self.logger.info("Connected to \(String(describing: remoteAddress))")
        } else {
            self.logger.info("Connected to remote")
        }

        switch self.state {
        case .connecting(let pendingBytes):
            self.state = .connected(connectResult: channel)
            self.glue(channel, context: context)
            pendingBytes.forEach { channel.write($0, promise: nil) }
            channel.flush()

        case .connected(let peerChannel):
            // This case is a logic error, close already connected peer channel.
            peerChannel.close(mode: .all, promise: nil)
            context.close(promise: nil)

        case .failure:
            // These cases are logic errors, but let's be careful and just shut the connection.
            context.close(promise: nil)
        }
    }

    private func connectFailed(error: Error, context: ChannelHandlerContext) {
        self.logger.error("Connect failed: \(error)")

        switch self.state {
        case .connected(let peerChannel):
            // This case is a logic error, close already connected peer channel.
            peerChannel.close(mode: .all, promise: nil)
            context.close(promise: nil)

        case .connecting, .failure:
            // Most of these cases are logic errors, but let's be careful and just shut the connection.
            context.close(promise: nil)
        }
        
        self.state = .failure(error: error)

        context.fireErrorCaught(error)
    }

    private func glue(_ peerChannel: Channel, context: ChannelHandlerContext) {
        self.logger.debug("Gluing together \(ObjectIdentifier(context.channel)) and \(ObjectIdentifier(peerChannel))")

        // Now we need to glue our channel and the peer channel together.
        let (localGlue, peerGlue) = GlueHandler.matchedPair()
        context.channel.pipeline.addHandler(localGlue)
            .and(peerChannel.pipeline.addHandler(peerGlue))
            .whenComplete { result in
                switch result {
                case .success(_):
                    context.pipeline.removeHandler(self, promise: nil)
                case .failure(_):
                    peerChannel.close(mode: .all, promise: nil)
                    context.close(promise: nil)
                }
            }
    }
}
