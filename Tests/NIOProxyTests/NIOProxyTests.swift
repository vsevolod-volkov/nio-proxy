import XCTest
@testable import NIOProxy

final class NIOProxyTests: XCTestCase {
    func testProxy() async throws {
        let proxy = NIOProxy()
        
        try await proxy.listen(port: 4321, targetHost: "moz-bi.ru", targetPort: 443)
        try await proxy.listen(port: 1234, targetHost: "esxi", targetPort: 80)
        try await proxy.stopListening(port: 4321)

        await withCheckedContinuation { continuation in
            Thread.sleep(forTimeInterval: 3600)
            continuation.resume(returning: ())
        }
    }
}
