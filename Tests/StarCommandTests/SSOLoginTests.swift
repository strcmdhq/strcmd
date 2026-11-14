import XCTest
@testable import StarCommand

final class SSOLoginTests: XCTestCase {
    func testDetectsExpiredSSOMessages() {
        XCTAssertTrue(AWSCLI.isSSOExpired("Error when retrieving token from sso: Token has expired and refresh failed"))
        XCTAssertTrue(AWSCLI.isSSOExpired("SSO expired. Run: aws sso login --profile dev"))
        XCTAssertFalse(AWSCLI.isSSOExpired("An error occurred (AccessDenied) when calling the GetCallerIdentity operation"))
        XCTAssertFalse(AWSCLI.isSSOExpired("No SSM-online instance matching Name *-system-node"))
    }

    func testOlderConfigsDefaultToAutoSignIn() throws {
        let json = Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"awsSSM"}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(Connection.self, from: json).autoSSOLogin)
    }
}
