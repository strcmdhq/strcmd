import Foundation

struct AirflowLogin: Decodable {
    let WebServerHostname: String
    let WebToken: String

    var url: URL? {
        URL(string: "https://\(WebServerHostname)/aws_mwaa/aws-console-sso?login=true#\(WebToken)")
    }
}

enum MWAA {
    // The login token is a credential, so it goes straight to the browser and is never logged.
    static func loginURL(base: [String], profile: String, environment: String) async -> Result<URL, ToolError> {
        guard let aws = Tools.find("aws") else { return .failure(ToolError(message: "aws CLI not found")) }
        let result = await Tools.capture(aws, base + ["mwaa", "create-web-login-token", "--name", environment, "--output", "json"], timeout: 30)
        if result.status == 0, let url = (try? JSONDecoder().decode(AirflowLogin.self, from: result.stdout))?.url {
            return .success(url)
        }
        return .failure(ToolError(message: AWSCLI.explain(result.stderr, profile: profile, fallback: "Couldn't create a login link")))
    }
}
