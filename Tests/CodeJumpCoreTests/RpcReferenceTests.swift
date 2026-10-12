import Foundation
import Testing
@testable import CodeJumpCore

struct RpcReferenceTests {
    @Test
    func traceAndLogCallNamesAreRecognized() {
        let service = ReferenceParser.parse("udp-default/PackageOperateService.callShippingLabel")
        #expect(service.map(\.symbol) == ["PackageOperateService.callShippingLabel"])
        #expect(service.first?.preferImplementation == true)

        let defender = ReferenceParser.parse("bg-pasta-api->udp-default/UserAddressCheckService:deliveryCheckUpdateAddressLock(DeliveryCheckUpdateAddressRequest)")
        #expect(defender.map(\.symbol) == ["UserAddressCheckService.deliveryCheckUpdateAddressLock"])
        #expect(defender.first?.parameterSignature == "DeliveryCheckUpdateAddressRequest")

        let text = "XrpcCall udp-default/FopenBgApiService.queryAfter 11.25 ms"
        let hit = ReferenceSelection.select(text: text, utf16Offset: (text as NSString).range(of: "queryAfter").location)
        #expect(hit.map(\.symbol) == ["FopenBgApiService.queryAfter"])
        #expect(hit.first?.isFallback == false)
    }

    @Test
    func filePathsAndOrdinaryClassMethodsAreNotRpcCalls() {
        #expect(ReferenceParser.parse("service/Foo.java").allSatisfy { !$0.preferImplementation })
        #expect(ReferenceParser.parse("src/main/java/com/demo/Foo.java:12").first?.path == "src/main/java/com/demo/Foo.java")
        #expect(ReferenceParser.parse("OrderService.query").allSatisfy { !$0.preferImplementation })
    }

    @Test
    func implementationIsPreferredAndInterfaceIsTheFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codejump-rpc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ content: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("contract/OrderService.java", "public interface OrderService {\n  Result query(Request request);\n  Result cancel(Request request);\n}\n")
        try write("api/OrderServiceImpl.java", "public class OrderServiceImpl implements OrderService {\n  public Result query(Request request) {\n    return null;\n  }\n}\n")
        let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "demo", path: root.path)]))

        let query = resolver.resolve(ReferenceParser.parse("udp-default/OrderService.query")[0])
        #expect(query.map(\.relativePath) == ["api/OrderServiceImpl.java"])
        #expect(query.first?.line == 2)
        #expect(query.first?.requiresConfirmation == false)

        let cancel = resolver.resolve(ReferenceParser.parse("udp-default/OrderService:cancel(Request)")[0])
        #expect(cancel.map(\.relativePath) == ["contract/OrderService.java"])
        #expect(cancel.first?.line == 3)
    }
}
