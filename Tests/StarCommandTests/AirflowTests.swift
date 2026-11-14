import XCTest
@testable import StarCommand

final class AirflowTests: XCTestCase {
    func testLoginURL() throws {
        let json = #"{"WebServerHostname": "abc.c1.airflow.us-east-1.on.aws", "WebToken": "tok123"}"#
        let login = try JSONDecoder().decode(AirflowLogin.self, from: Data(json.utf8))
        XCTAssertEqual(login.url?.absoluteString, "https://abc.c1.airflow.us-east-1.on.aws/aws_mwaa/aws-console-sso?login=true#tok123")
    }

    func testExpiredSSOMessage() {
        XCTAssertEqual(AWSCLI.explain("Error when retrieving token from sso: Token has expired and refresh failed", profile: "acme-dev"),
                       "SSO expired. Run: aws sso login --profile acme-dev")
        XCTAssertEqual(AWSCLI.explain("An error occurred (AccessDeniedException)", profile: "p"), "Access denied for p")
    }
}

final class AirflowGatewayTests: XCTestCase {
    func testParseAndHostCheck() {
        let request = AirflowGateway.parse(Data("GET / HTTP/1.1\r\nHost: localhost:8081\r\nAccept: */*\r\n\r\n".utf8))
        XCTAssertEqual(request, AirflowGateway.Request(method: "GET", path: "/", host: "localhost:8081"))
        XCTAssertTrue(AirflowGateway.isAllowedHost("localhost:8081", port: 8081))
        XCTAssertTrue(AirflowGateway.isAllowedHost("127.0.0.1:8081", port: 8081))
        XCTAssertFalse(AirflowGateway.isAllowedHost("evil.example:8081", port: 8081))
        XCTAssertFalse(AirflowGateway.isAllowedHost("localhost:8082", port: 8081))
        XCTAssertFalse(AirflowGateway.isAllowedHost(nil, port: 8081))
        XCTAssertNil(AirflowGateway.parse(Data()))
    }

    func testRedirectAndErrorEscaping() {
        let redirect = AirflowGateway.redirect(URL(string: "https://h.example/aws_mwaa/aws-console-sso?login=true#t")!)
        XCTAssertTrue(redirect.hasPrefix("HTTP/1.1 302 Found\r\nLocation: https://h.example/aws_mwaa/aws-console-sso?login=true#t\r\n"))
        XCTAssertTrue(AirflowGateway.response(502, "<b>x</b>").contains("&lt;b>x&lt;/b>"))
    }
}
