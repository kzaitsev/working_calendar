import CryptoKit
import Foundation
import Network
import Security

enum OAuthServiceKind: String, Codable, Hashable {
    case googleCalendar
    case microsoft365

    var scopes: String {
        requestedScopes.joined(separator: " ")
    }

    var requestedScopes: [String] {
        switch self {
        case .googleCalendar:
            return ["https://www.googleapis.com/auth/calendar"]
        case .microsoft365:
            return ["offline_access", "User.Read", "Calendars.ReadWrite", "Calendars.ReadWrite.Shared"]
        }
    }

    var requiredGrantedScopes: [String] {
        switch self {
        case .googleCalendar:
            return ["https://www.googleapis.com/auth/calendar"]
        case .microsoft365:
            return ["User.Read", "Calendars.ReadWrite"]
        }
    }

    var title: String {
        switch self {
        case .googleCalendar:
            return "Google Calendar"
        case .microsoft365:
            return "Microsoft 365"
        }
    }

    var defaultTenant: String {
        switch self {
        case .googleCalendar:
            return ""
        case .microsoft365:
            return "common"
        }
    }

    var clientIDPlaceholder: String {
        switch self {
        case .googleCalendar:
            return defaultClientID ?? "1234567890-abc.apps.googleusercontent.com"
        case .microsoft365:
            return "00000000-0000-0000-0000-000000000000"
        }
    }

    var defaultClientID: String? {
        switch self {
        case .googleCalendar:
            return "728926875401-u5ou0oi0d0bklrd3qbl328nv58j8jj4t.apps.googleusercontent.com"
        case .microsoft365:
            return nil
        }
    }

    var clientIDLabel: String {
        switch self {
        case .googleCalendar:
            return "Google OAuth desktop client ID"
        case .microsoft365:
            return "Microsoft public-client app ID"
        }
    }

    var usesClientSecret: Bool {
        switch self {
        case .googleCalendar:
            return true
        case .microsoft365:
            return false
        }
    }

    var clientSecretPlaceholder: String {
        switch self {
        case .googleCalendar:
            return "Optional client_secret from Desktop OAuth JSON"
        case .microsoft365:
            return ""
        }
    }

    var clientSecretGuidanceText: String {
        switch self {
        case .googleCalendar:
            return "Optional: Google Desktop OAuth may include a client_secret in the downloaded JSON. It is not a user password or a confidential desktop secret; enter it only if Google rejects token exchange with client_secret is missing."
        case .microsoft365:
            return ""
        }
    }

    var tenantPlaceholder: String {
        switch self {
        case .googleCalendar:
            return ""
        case .microsoft365:
            return "common, organizations, consumers, or tenant ID"
        }
    }

    var onboardingGuidanceText: String {
        switch self {
        case .googleCalendar:
            return "Use a Google OAuth desktop client ID ending in .apps.googleusercontent.com. Working Calendar opens browser sign-in with a local loopback redirect, requests calendar read/write scope, and stores the refresh token in Keychain for background sync."
        case .microsoft365:
            return "Use a Microsoft public-client app ID with device-code flow enabled. Working Calendar requests calendar read/write plus profile scopes and stores the refresh token in Keychain."
        }
    }

    var tenantGuidanceText: String {
        switch self {
        case .googleCalendar:
            return ""
        case .microsoft365:
            return "Use common for work or personal accounts, organizations for work/school accounts, consumers for personal Microsoft accounts, or a tenant ID for a single organization."
        }
    }

    var usesTenant: Bool {
        switch self {
        case .googleCalendar:
            return false
        case .microsoft365:
            return true
        }
    }

    func normalizedTenant(_ tenant: String?) -> String {
        guard usesTenant else { return defaultTenant }
        return tenant?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? defaultTenant
    }

    func clientIDValidationMessage(for clientID: String) -> String? {
        let normalizedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedClientID.isEmpty else { return nil }

        switch self {
        case .googleCalendar:
            guard normalizedClientID.lowercased().hasSuffix(".apps.googleusercontent.com") else {
                return "Enter a Google OAuth desktop client ID ending in .apps.googleusercontent.com."
            }
        case .microsoft365:
            guard UUID(uuidString: normalizedClientID) != nil else {
                return "Enter the Microsoft application client ID as a UUID."
            }
        }

        return nil
    }
}

struct OAuthDeviceAuthorization: Hashable {
    let service: OAuthServiceKind
    let clientID: String
    let tenant: String
    let deviceCode: String
    let userCode: String
    let verificationURL: URL
    let verificationURLComplete: URL?
    let expiresAt: Date
    let intervalSeconds: Int
    let message: String
}

struct OAuthLoopbackAuthorization {
    let service: OAuthServiceKind
    let clientID: String
    let redirectURI: URL
    let authorizationURL: URL
    let state: String
    let codeVerifier: String
    private let listener: OAuthLoopbackRedirectListener

    init(
        service: OAuthServiceKind,
        clientID: String,
        redirectURI: URL,
        authorizationURL: URL,
        state: String,
        codeVerifier: String,
        listener: OAuthLoopbackRedirectListener
    ) {
        self.service = service
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.authorizationURL = authorizationURL
        self.state = state
        self.codeVerifier = codeVerifier
        self.listener = listener
    }

    func waitForCallback() async throws -> OAuthLoopbackCallback {
        try await listener.waitForCallback()
    }

    func cancel() {
        listener.cancel()
    }
}

struct OAuthLoopbackCallback: Hashable {
    let code: String?
    let state: String?
    let error: String?
    let errorDescription: String?
}

struct OAuthCredential: Codable, Hashable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var tokenType: String
    var scope: String
    var clientID: String
    var clientSecret: String? = nil
    var tenant: String?
    var service: OAuthServiceKind

    var shouldRefresh: Bool {
        expiresAt <= Date().addingTimeInterval(90)
    }

    func missingRequiredScopes() -> [String] {
        let grantedScopes = Set(scope.oauthScopeTokens.map { $0.lowercased() })
        return service.requiredGrantedScopes.filter { !grantedScopes.contains($0.lowercased()) }
    }
}

struct GoogleOAuthClientConfiguration: Hashable {
    let clientID: String
    let clientSecret: String?
    let redirectURIs: [String]

    static func load(from url: URL) throws -> GoogleOAuthClientConfiguration {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> GoogleOAuthClientConfiguration {
        let decoded = try JSONDecoder().decode(GoogleOAuthClientConfigurationFile.self, from: data)
        guard let installed = decoded.installed else {
            throw GoogleOAuthClientConfigurationError.missingInstalledClient
        }

        let clientID = installed.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw GoogleOAuthClientConfigurationError.missingClientID
        }
        if let validationMessage = OAuthServiceKind.googleCalendar.clientIDValidationMessage(for: clientID) {
            throw GoogleOAuthClientConfigurationError.invalidClientID(validationMessage)
        }

        let clientSecret = installed.clientSecret?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank

        return GoogleOAuthClientConfiguration(
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURIs: installed.redirectURIs ?? []
        )
    }
}

enum GoogleOAuthClientConfigurationError: LocalizedError {
    case missingInstalledClient
    case missingClientID
    case invalidClientID(String)

    var errorDescription: String? {
        switch self {
        case .missingInstalledClient:
            return "Choose the downloaded JSON for a Google Desktop OAuth client. The file should contain an installed client section, not a web client section."
        case .missingClientID:
            return "The Google OAuth JSON does not contain an installed.client_id."
        case .invalidClientID(let message):
            return message
        }
    }
}

private struct GoogleOAuthClientConfigurationFile: Decodable {
    let installed: GoogleOAuthClientConfigurationPayload?

    private enum CodingKeys: String, CodingKey {
        case installed
    }
}

private struct GoogleOAuthClientConfigurationPayload: Decodable {
    let clientID: String
    let clientSecret: String?
    let redirectURIs: [String]?

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case redirectURIs = "redirect_uris"
    }
}

enum OAuthDeviceFlowError: LocalizedError {
    case missingClientID
    case invalidClientID(OAuthServiceKind, String)
    case missingDeviceCode
    case missingVerificationURL
    case missingAccessToken
    case missingRefreshToken
    case missingGrantedScopes(OAuthServiceKind, [String])
    case unsupportedDeviceFlow(OAuthServiceKind)
    case loopbackAuthorizationUnsupported(OAuthServiceKind)
    case loopbackListenerFailed(String)
    case missingAuthorizationCode
    case missingClientSecret
    case stateMismatch
    case randomGenerationFailed
    case refreshTokenRejected(String)
    case expiredDeviceCode
    case accessDenied
    case authorizationFailed(String)
    case httpStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Enter an OAuth client ID."
        case .invalidClientID(_, let message):
            return message
        case .missingDeviceCode:
            return "The OAuth provider did not return a device code."
        case .missingVerificationURL:
            return "The OAuth provider did not return a verification URL."
        case .missingAccessToken:
            return "The OAuth provider did not return an access token."
        case .missingRefreshToken:
            return "Reconnect this account; the OAuth provider did not return a refresh token for background sync."
        case .missingGrantedScopes(let service, let scopes):
            let scopeList = scopes.joined(separator: ", ")
            return "Reconnect this \(service.title) account; the OAuth provider did not grant required scopes: \(scopeList)."
        case .unsupportedDeviceFlow(let service):
            return "\(service.title) cannot use device-code OAuth here. Use browser sign-in with the desktop OAuth client ID."
        case .loopbackAuthorizationUnsupported(let service):
            return "\(service.title) does not support the desktop browser sign-in path in Working Calendar."
        case .loopbackListenerFailed(let message):
            return "Could not start local OAuth redirect listener: \(message)"
        case .missingAuthorizationCode:
            return "The OAuth provider did not return an authorization code."
        case .missingClientSecret:
            return "Google requires a client_secret for this OAuth client. If this is a Desktop OAuth client, download its JSON from Google Cloud and enter installed.client_secret. If there is no installed.client_secret, create a Desktop app OAuth client instead of a Web Application client."
        case .stateMismatch:
            return "The OAuth response did not match this sign-in attempt. Start connection again."
        case .randomGenerationFailed:
            return "Could not create secure OAuth request values."
        case .refreshTokenRejected(let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Reconnect this account; the OAuth provider rejected the refresh token."
            }
            return "Reconnect this account; the OAuth provider rejected the refresh token: \(detail)"
        case .expiredDeviceCode:
            return "The sign-in code expired. Start connection again."
        case .accessDenied:
            return "Sign-in was denied."
        case .authorizationFailed(let message):
            return message
        case .httpStatus(let status, let message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "OAuth request returned HTTP \(status)." : "OAuth request returned HTTP \(status): \(detail)"
        }
    }
}

protocol OAuthDeviceFlowTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

protocol CalendarProviderHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

struct URLSessionOAuthDeviceFlowTransport: OAuthDeviceFlowTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

struct URLSessionCalendarProviderHTTPTransport: CalendarProviderHTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }
}

typealias CalendarProviderAccessTokenProvider = (CalendarProviderAccount, OAuthServiceKind, Bool) async throws -> String

final class OAuthDeviceFlowClient {
    private let transport: OAuthDeviceFlowTransport
    private let now: () -> Date
    private let sleep: (UInt64) async throws -> Void

    init(
        transport: OAuthDeviceFlowTransport = URLSessionOAuthDeviceFlowTransport(),
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    func requestAuthorization(service: OAuthServiceKind, clientID: String, tenant: String? = nil) async throws -> OAuthDeviceAuthorization {
        let safeClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeClientID.isEmpty else { throw OAuthDeviceFlowError.missingClientID }
        if let validationMessage = service.clientIDValidationMessage(for: safeClientID) {
            throw OAuthDeviceFlowError.invalidClientID(service, validationMessage)
        }
        guard service == .microsoft365 else {
            throw OAuthDeviceFlowError.unsupportedDeviceFlow(service)
        }

        let safeTenant = service.normalizedTenant(tenant)
        let endpoint = deviceCodeEndpoint(service: service, tenant: safeTenant)
        let body = formEncoded([
            "client_id": safeClientID,
            "scope": service.scopes
        ])

        let response: OAuthDeviceCodeResponse = try await formRequest(url: endpoint, body: body)
        guard let deviceCode = response.deviceCode.nilIfBlank else { throw OAuthDeviceFlowError.missingDeviceCode }
        guard let verificationURLString = response.verificationURI.nilIfBlank ?? response.verificationURL.nilIfBlank,
              let verificationURL = URL(string: verificationURLString)
        else {
            throw OAuthDeviceFlowError.missingVerificationURL
        }

        return OAuthDeviceAuthorization(
            service: service,
            clientID: safeClientID,
            tenant: safeTenant,
            deviceCode: deviceCode,
            userCode: response.userCode.nilIfBlank ?? "",
            verificationURL: verificationURL,
            verificationURLComplete: response.verificationURIComplete.flatMap(URL.init(string:)),
            expiresAt: now().addingTimeInterval(TimeInterval(max(60, response.expiresIn ?? 900))),
            intervalSeconds: max(2, response.interval ?? 5),
            message: response.message.nilIfBlank ?? "Open \(verificationURL.absoluteString) and enter the code."
        )
    }

    func requestLoopbackAuthorization(service: OAuthServiceKind, clientID: String) async throws -> OAuthLoopbackAuthorization {
        let safeClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safeClientID.isEmpty else { throw OAuthDeviceFlowError.missingClientID }
        if let validationMessage = service.clientIDValidationMessage(for: safeClientID) {
            throw OAuthDeviceFlowError.invalidClientID(service, validationMessage)
        }
        guard service == .googleCalendar else {
            throw OAuthDeviceFlowError.loopbackAuthorizationUnsupported(service)
        }

        let listener = OAuthLoopbackRedirectListener()
        let port = try await listener.start()
        let redirectURI = URL(string: "http://127.0.0.1:\(port)")!
        let state = try secureRandomURLSafeString(byteCount: 24)
        let codeVerifier = try secureRandomURLSafeString(byteCount: 32)
        let codeChallenge = pkceChallenge(for: codeVerifier)
        let authorizationURL = try authorizationEndpoint(
            service: service,
            clientID: safeClientID,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: codeChallenge
        )

        return OAuthLoopbackAuthorization(
            service: service,
            clientID: safeClientID,
            redirectURI: redirectURI,
            authorizationURL: authorizationURL,
            state: state,
            codeVerifier: codeVerifier,
            listener: listener
        )
    }

    func token(authorization: OAuthLoopbackAuthorization, clientSecret: String? = nil) async throws -> OAuthCredential {
        defer { authorization.cancel() }
        let callback = try await authorization.waitForCallback()
        if let error = callback.error.nilIfBlank {
            throw OAuthDeviceFlowError.authorizationFailed(callback.errorDescription.nilIfBlank ?? error)
        }
        guard callback.state == authorization.state else {
            throw OAuthDeviceFlowError.stateMismatch
        }
        guard let code = callback.code.nilIfBlank else {
            throw OAuthDeviceFlowError.missingAuthorizationCode
        }

        var fields = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": authorization.clientID,
            "redirect_uri": authorization.redirectURI.absoluteString,
            "code_verifier": authorization.codeVerifier
        ]
        let normalizedClientSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        if let normalizedClientSecret {
            fields["client_secret"] = normalizedClientSecret
        }

        let credential = try await token(
            service: authorization.service,
            clientID: authorization.clientID,
            tenant: nil,
            clientSecret: normalizedClientSecret,
            fields: fields
        )
        guard credential.refreshToken.nilIfBlank != nil else {
            throw OAuthDeviceFlowError.missingRefreshToken
        }
        return credential
    }

    func pollForToken(authorization: OAuthDeviceAuthorization) async throws -> OAuthCredential {
        var interval = authorization.intervalSeconds

        while now() < authorization.expiresAt {
            try await sleep(UInt64(interval) * 1_000_000_000)

            do {
                let credential = try await token(
                    service: authorization.service,
                    clientID: authorization.clientID,
                    tenant: authorization.tenant,
                    clientSecret: nil,
                    fields: [
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                        "device_code": authorization.deviceCode,
                        "client_id": authorization.clientID
                    ]
                )
                guard credential.refreshToken.nilIfBlank != nil else {
                    throw OAuthDeviceFlowError.missingRefreshToken
                }
                return credential
            } catch OAuthDeviceFlowError.authorizationFailed(let message) {
                switch message {
                case "authorization_pending":
                    continue
                case "slow_down":
                    interval += 5
                    continue
                case "expired_token":
                    throw OAuthDeviceFlowError.expiredDeviceCode
                case "access_denied", "authorization_declined":
                    throw OAuthDeviceFlowError.accessDenied
                default:
                    throw OAuthDeviceFlowError.authorizationFailed(message)
                }
            }
        }

        throw OAuthDeviceFlowError.expiredDeviceCode
    }

    func refresh(_ credential: OAuthCredential) async throws -> OAuthCredential {
        guard let refreshToken = credential.refreshToken.nilIfBlank else {
            throw OAuthDeviceFlowError.missingRefreshToken
        }

        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": credential.clientID
        ]

        let normalizedClientSecret = credential.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        if let normalizedClientSecret {
            fields["client_secret"] = normalizedClientSecret
        }

        if credential.service == .microsoft365 {
            fields["scope"] = credential.scope.nilIfBlank ?? credential.service.scopes
        }

        var refreshed = try await token(
            service: credential.service,
            clientID: credential.clientID,
            tenant: credential.tenant,
            clientSecret: normalizedClientSecret,
            fields: fields
        )
        if refreshed.refreshToken.nilIfBlank == nil {
            refreshed.refreshToken = refreshToken
        }
        return refreshed
    }

    private func token(
        service: OAuthServiceKind,
        clientID: String,
        tenant: String?,
        clientSecret: String?,
        fields: [String: String]
    ) async throws -> OAuthCredential {
        let endpoint = tokenEndpoint(service: service, tenant: tenant?.nilIfBlank ?? service.defaultTenant)
        let response: OAuthTokenResponse = try await formRequest(
            url: endpoint,
            body: formEncoded(fields),
            isRefreshGrant: fields["grant_type"] == "refresh_token"
        )
        guard let accessToken = response.accessToken.nilIfBlank else { throw OAuthDeviceFlowError.missingAccessToken }

        let credential = OAuthCredential(
            accessToken: accessToken,
            refreshToken: response.refreshToken.nilIfBlank,
            expiresAt: now().addingTimeInterval(TimeInterval(max(60, response.expiresIn ?? 3600))),
            tokenType: response.tokenType.nilIfBlank ?? "Bearer",
            scope: response.scope.nilIfBlank ?? service.scopes,
            clientID: clientID,
            clientSecret: clientSecret?.nilIfBlank,
            tenant: service.usesTenant ? tenant?.nilIfBlank : nil,
            service: service
        )
        let missingScopes = credential.missingRequiredScopes()
        guard missingScopes.isEmpty else {
            throw OAuthDeviceFlowError.missingGrantedScopes(service, missingScopes)
        }
        return credential
    }

    private func formRequest<Response: Decodable>(
        url: URL,
        body: Data,
        isRefreshGrant: Bool = false
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response) = try await transport.data(for: request)
        if let errorResponse = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data),
           let error = errorResponse.error.nilIfBlank {
            let message = errorResponse.errorDescription.nilIfBlank ?? error
            if message.localizedCaseInsensitiveContains("client_secret"),
               message.localizedCaseInsensitiveContains("missing") {
                throw OAuthDeviceFlowError.missingClientSecret
            }
            if isRefreshGrant,
               ["invalid_grant", "invalid_client", "unauthorized_client"].contains(error) {
                throw OAuthDeviceFlowError.refreshTokenRejected(message)
            }
            if error == "authorization_pending" || error == "slow_down" || error == "expired_token" || error == "access_denied" || error == "authorization_declined" {
                throw OAuthDeviceFlowError.authorizationFailed(error)
            }
            throw OAuthDeviceFlowError.authorizationFailed(message)
        }

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw OAuthDeviceFlowError.httpStatus(httpResponse.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func deviceCodeEndpoint(service: OAuthServiceKind, tenant: String) -> URL {
        switch service {
        case .googleCalendar:
            return URL(string: "https://oauth2.googleapis.com/device/code")!
        case .microsoft365:
            return URL(string: "https://login.microsoftonline.com/\(tenant.nilIfBlank ?? "common")/oauth2/v2.0/devicecode")!
        }
    }

    private func tokenEndpoint(service: OAuthServiceKind, tenant: String) -> URL {
        switch service {
        case .googleCalendar:
            return URL(string: "https://oauth2.googleapis.com/token")!
        case .microsoft365:
            return URL(string: "https://login.microsoftonline.com/\(tenant.nilIfBlank ?? "common")/oauth2/v2.0/token")!
        }
    }

    private func authorizationEndpoint(
        service: OAuthServiceKind,
        clientID: String,
        redirectURI: URL,
        state: String,
        codeChallenge: String
    ) throws -> URL {
        switch service {
        case .googleCalendar:
            var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: service.scopes),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: codeChallenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent")
            ]
            return components.url!
        case .microsoft365:
            throw OAuthDeviceFlowError.loopbackAuthorizationUnsupported(service)
        }
    }

    private func formEncoded(_ fields: [String: String]) -> Data {
        fields
            .map { key, value in "\(urlFormEscape(key))=\(urlFormEscape(value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private func urlFormEscape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        allowed.remove(charactersIn: " ")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: " ", with: "+") ?? value
    }

    private func secureRandomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw OAuthDeviceFlowError.randomGenerationFailed
        }
        return Data(bytes).base64URLEncodedString()
    }

    private func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

final class OAuthLoopbackRedirectListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.codex.WorkingCalendar.oauth-loopback")
    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<OAuthLoopbackCallback, Error>?
    private var pendingCallback: Result<OAuthLoopbackCallback, Error>?

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let readyState = OAuthLoopbackReadyState()
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    readyState.resumeOnce {
                        if let port = listener?.port?.rawValue {
                            continuation.resume(returning: port)
                        } else {
                            continuation.resume(throwing: OAuthDeviceFlowError.loopbackListenerFailed("listener did not publish a port"))
                        }
                    }
                case .failed(let error):
                    readyState.resumeOnce {
                        self?.finish(.failure(OAuthDeviceFlowError.loopbackListenerFailed(error.localizedDescription)))
                        continuation.resume(throwing: OAuthDeviceFlowError.loopbackListenerFailed(error.localizedDescription))
                    }
                case .cancelled:
                    readyState.resumeOnce {
                        continuation.resume(throwing: OAuthDeviceFlowError.accessDenied)
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback() async throws -> OAuthLoopbackCallback {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pendingCallback = self.pendingCallback {
                    self.pendingCallback = nil
                    continuation.resume(with: pendingCallback)
                    return
                }
                self.callbackContinuation = continuation
            }
        }
    }

    func cancel() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            if let callbackContinuation = self.callbackContinuation {
                self.callbackContinuation = nil
                callbackContinuation.resume(throwing: OAuthDeviceFlowError.accessDenied)
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                self.finish(.failure(OAuthDeviceFlowError.loopbackListenerFailed(error.localizedDescription)))
                connection.cancel()
                return
            }

            let callback = self.callback(from: data)
            self.sendResponse(for: callback, on: connection) {
                self.finish(.success(callback))
            }
        }
    }

    private func callback(from data: Data?) -> OAuthLoopbackCallback {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\r\n").first
        else {
            return OAuthLoopbackCallback(
                code: nil,
                state: nil,
                error: "invalid_request",
                errorDescription: "The local OAuth redirect request was not readable."
            )
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])")
        else {
            return OAuthLoopbackCallback(
                code: nil,
                state: nil,
                error: "invalid_request",
                errorDescription: "The local OAuth redirect request was malformed."
            )
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if query[item.name] == nil {
                query[item.name] = item.value ?? ""
            }
        }
        return OAuthLoopbackCallback(
            code: query["code"],
            state: query["state"],
            error: query["error"],
            errorDescription: query["error_description"]
        )
    }

    private func sendResponse(for callback: OAuthLoopbackCallback, on connection: NWConnection, completion: @escaping () -> Void) {
        let isSuccess = callback.code.nilIfBlank != nil && callback.error.nilIfBlank == nil
        let title = isSuccess ? "Working Calendar is connected" : "Working Calendar sign-in failed"
        let detail = isSuccess
            ? "You can close this browser tab and return to Working Calendar."
            : (callback.errorDescription.nilIfBlank ?? callback.error.nilIfBlank ?? "Return to Working Calendar and try again.")
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(htmlEscaped(title))</title></head>
        <body style="font: -apple-system-body; margin: 42px; color: #1d1d1f;">
        <h1 style="font-size: 24px;">\(htmlEscaped(title))</h1>
        <p>\(htmlEscaped(detail))</p>
        </body></html>
        """
        let bodyData = Data(body.utf8)
        let responseHeader = "HTTP/1.1 \(isSuccess ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(responseHeader.utf8)
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
            completion()
        })
    }

    private func finish(_ result: Result<OAuthLoopbackCallback, Error>) {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            if let callbackContinuation = self.callbackContinuation {
                self.callbackContinuation = nil
                callbackContinuation.resume(with: result)
            } else {
                self.pendingCallback = result
            }
        }
    }

    private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private final class OAuthLoopbackReadyState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resumeOnce(_ block: () -> Void) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()
        block()
    }
}

enum OAuthCredentialStore {
    static func saveCredential(_ credential: OAuthCredential, key: String) -> Bool {
        guard let data = try? JSONEncoder().encode(credential),
              let text = String(data: data, encoding: .utf8)
        else {
            return false
        }
        return CalendarCredentialStore.savePassword(text, key: key)
    }

    static func credential(key: String, fallbackService: OAuthServiceKind) -> OAuthCredential? {
        guard let stored = CalendarCredentialStore.password(key: key)?.nilIfBlank else {
            return nil
        }

        if let data = stored.data(using: .utf8),
           let credential = try? JSONDecoder().decode(OAuthCredential.self, from: data) {
            return credential
        }

        return OAuthCredential(
            accessToken: stored,
            refreshToken: nil,
            expiresAt: .distantFuture,
            tokenType: "Bearer",
            scope: fallbackService.scopes,
            clientID: "",
            tenant: fallbackService.defaultTenant.nilIfBlank,
            service: fallbackService
        )
    }

    static func validAccessToken(
        for account: CalendarProviderAccount,
        service: OAuthServiceKind,
        forceRefresh: Bool = false
    ) async throws -> String {
        guard let credentialKey = account.credentialKey,
              var credential = credential(key: credentialKey, fallbackService: service)
        else {
            throw OAuthDeviceFlowError.missingAccessToken
        }

        guard forceRefresh || credential.shouldRefresh else {
            return credential.accessToken
        }

        credential = try await OAuthDeviceFlowClient().refresh(credential)
        guard saveCredential(credential, key: credentialKey) else {
            throw CalendarProviderStoreError.keychainSaveFailed
        }
        return credential.accessToken
    }
}

private struct OAuthDeviceCodeResponse: Decodable {
    let deviceCode: String?
    let userCode: String?
    let verificationURI: String?
    let verificationURL: String?
    let verificationURIComplete: String?
    let expiresIn: Int?
    let interval: Int?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURL = "verification_url"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
        case message
    }
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?
    let scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }
}

private struct OAuthErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var oauthScopeTokens: [String] {
        split { character in
            character == " " || character == "\n" || character == "\t" || character == ","
        }
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        self?.nilIfBlank
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
