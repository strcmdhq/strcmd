import XCTest
@testable import StarCommand

final class KubeDiscoveryTests: XCTestCase {
    func testParsesResourcesAndPorts() {
        let item: [String: Any] = [
            "kind": "Service",
            "metadata": ["name": "web"],
            "spec": ["ports": [["port": 80], ["port": 443]]],
        ]
        let resource = KubeResource(item: item)
        XCTAssertEqual(resource?.reference, "svc/web")
        XCTAssertEqual(resource?.ports, [80, 443])

        let deploy: [String: Any] = [
            "kind": "Deployment",
            "metadata": ["name": "api"],
            "spec": ["template": ["spec": ["containers": [["ports": [["containerPort": 8080]]]]]]],
        ]
        XCTAssertEqual(KubeResource(item: deploy)?.reference, "deploy/api")
        XCTAssertEqual(KubeResource(item: deploy)?.ports, [8080])
    }

    func testLiveDiscoveryAgainstDevCluster() async throws {
        guard let context = ProcessInfo.processInfo.environment["KUBE_TEST_CONTEXT"] else {
            throw XCTSkip("set KUBE_TEST_CONTEXT to run against a cluster")
        }
        let namespaces = await ExternalConfig.kubeNamespaces(context: context)
        XCTAssertTrue(namespaces.contains("kube-system"), "namespaces: \(namespaces)")
        let resources = await ExternalConfig.kubeResources(context: context, namespace: "kube-system")
        let services = resources.filter { $0.kind == .service }
        XCTAssertTrue(services.contains { $0.name == "kube-dns" && $0.ports.contains(53) }, "services: \(services.map(\.reference))")
        print("namespaces:", namespaces.count, "| services:", services.map { "\($0.name)\($0.ports)" }, "| deployments:", resources.filter { $0.kind == .deployment }.count, "| pods:", resources.filter { $0.kind == .pod }.count)
    }
}
