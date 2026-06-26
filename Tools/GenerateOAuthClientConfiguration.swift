import Foundation

private struct GoogleOAuthClientFile: Decodable {
    let installed: GoogleOAuthInstalledClient?
    let web: GoogleOAuthInstalledClient?
}

private struct GoogleOAuthInstalledClient: Decodable {
    let clientID: String
    let clientSecret: String?
    let redirectURIs: [String]?

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case redirectURIs = "redirect_uris"
    }
}

private struct BuildOAuthConfiguration {
    var googleClientID: String?
    var googleClientSecret: String?
    var googleRedirectURIs: [String]
}

private enum GeneratorError: LocalizedError {
    case missingOutputPath
    case webClientJSON
    case missingClientID(String)
    case invalidClientID(String)

    var errorDescription: String? {
        switch self {
        case .missingOutputPath:
            return "Usage: swift Tools/GenerateOAuthClientConfiguration.swift <output.swift> [google-client-json]"
        case .webClientJSON:
            return "Google OAuth JSON must be a Desktop app client with an installed section, not a Web Application client."
        case .missingClientID(let path):
            return "Google OAuth JSON does not contain installed.client_id: \(path)"
        case .invalidClientID(let clientID):
            return "Google OAuth client ID must end in .apps.googleusercontent.com: \(redactedClientID(clientID))"
        }
    }
}

private func main() throws {
    guard CommandLine.arguments.count >= 2 else {
        throw GeneratorError.missingOutputPath
    }

    let outputPath = CommandLine.arguments[1]
    let argumentJSONPath = CommandLine.arguments.dropFirst(2).first
    let environment = ProcessInfo.processInfo.environment
    let environmentJSONPath = trimmed(environment["GOOGLE_OAUTH_CLIENT_JSON"])
    let jsonPath = environmentJSONPath ?? trimmed(argumentJSONPath)

    var configuration = BuildOAuthConfiguration(
        googleClientID: nil,
        googleClientSecret: nil,
        googleRedirectURIs: []
    )

    if let jsonPath, FileManager.default.fileExists(atPath: jsonPath) {
        configuration = try loadGoogleConfiguration(from: jsonPath)
    }

    if let clientID = trimmed(environment["GOOGLE_OAUTH_CLIENT_ID"] ?? environment["WC_GOOGLE_OAUTH_CLIENT_ID"]) {
        configuration.googleClientID = clientID
    }
    if let clientSecret = trimmed(environment["GOOGLE_OAUTH_CLIENT_SECRET"] ?? environment["WC_GOOGLE_OAUTH_CLIENT_SECRET"]) {
        configuration.googleClientSecret = clientSecret
    }

    if let clientID = configuration.googleClientID,
       !clientID.lowercased().hasSuffix(".apps.googleusercontent.com") {
        throw GeneratorError.invalidClientID(clientID)
    }

    let source = renderSource(configuration)
    let outputURL = URL(fileURLWithPath: outputPath)
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try source.write(to: outputURL, atomically: true, encoding: .utf8)

    if configuration.googleClientID == nil {
        print("Generated OAuth build configuration without Google credentials.")
    } else {
        print("Generated OAuth build configuration with embedded Google desktop credentials.")
    }
}

private func loadGoogleConfiguration(from path: String) throws -> BuildOAuthConfiguration {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let decoded = try JSONDecoder().decode(GoogleOAuthClientFile.self, from: data)
    guard let installed = decoded.installed else {
        if decoded.web != nil {
            throw GeneratorError.webClientJSON
        }
        throw GeneratorError.missingClientID(path)
    }

    guard let clientID = trimmed(installed.clientID) else {
        throw GeneratorError.missingClientID(path)
    }

    return BuildOAuthConfiguration(
        googleClientID: clientID,
        googleClientSecret: trimmed(installed.clientSecret),
        googleRedirectURIs: installed.redirectURIs ?? []
    )
}

private func renderSource(_ configuration: BuildOAuthConfiguration) -> String {
    """
    import Foundation

    // Generated at build time by Tools/GenerateOAuthClientConfiguration.swift.
    enum GeneratedOAuthClientConfiguration {
        static let googleClientID: String? = \(optionalStringLiteral(configuration.googleClientID))
        static let googleClientSecret: String? = \(optionalStringLiteral(configuration.googleClientSecret))
        static let googleRedirectURIs: [String] = \(arrayLiteral(configuration.googleRedirectURIs))
    }

    """
}

private func optionalStringLiteral(_ value: String?) -> String {
    guard let value else { return "nil" }
    return swiftStringLiteral(value)
}

private func arrayLiteral(_ values: [String]) -> String {
    "[" + values.map(swiftStringLiteral).joined(separator: ", ") + "]"
}

private func swiftStringLiteral(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22:
            result += "\\\""
        case 0x5c:
            result += "\\\\"
        case 0x0a:
            result += "\\n"
        case 0x0d:
            result += "\\r"
        case 0x09:
            result += "\\t"
        default:
            if scalar.value < 0x20 {
                result += "\\u{\(String(scalar.value, radix: 16))}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
    }
    result += "\""
    return result
}

private func trimmed(_ value: String?) -> String? {
    let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmedValue.isEmpty ? nil : trimmedValue
}

private func redactedClientID(_ value: String) -> String {
    guard value.count > 16 else { return "<redacted>" }
    return "\(value.prefix(6))...\(value.suffix(10))"
}

do {
    try main()
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    fputs("OAuth configuration generation failed: \(message)\n", stderr)
    exit(1)
}
