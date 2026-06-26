import Foundation

@main
struct VerifyOAuthDeviceFlow {
    static func main() async throws {
        try verifyOAuthOnboardingMetadata()
        try await verifyOAuthClientIDValidation()
        try await verifyDeviceAuthorizationRequest()
        try await verifyGoogleDoesNotUseDeviceAuthorization()
        try await verifyGoogleLoopbackAuthorizationURL()
        try await verifyGoogleLoopbackTokenExchange()
        try await verifyPollingSlowDownAndTokenSuccess()
        try await verifyInitialTokenRequiresRefreshToken()
        try await verifyGrantedScopesAreRequired()
        try await verifyMicrosoftRefreshPreservesRefreshToken()
        try await verifyGoogleRefreshUsesNewRefreshTokenWithoutScope()
        try await verifyRefreshInvalidGrantRequiresReconnect()
        print("OAuth device flow invariant passed.")
    }

    private static func verifyOAuthOnboardingMetadata() throws {
        try expect(OAuthServiceKind.googleCalendar.clientIDLabel.localizedCaseInsensitiveContains("desktop client ID"),
                   "Google onboarding should ask for a desktop OAuth client ID")
        try expect(OAuthServiceKind.googleCalendar.defaultClientID == "728926875401-u5ou0oi0d0bklrd3qbl328nv58j8jj4t.apps.googleusercontent.com",
                   "Google onboarding should ship the configured desktop OAuth client ID")
        try expect(OAuthServiceKind.googleCalendar.clientIDPlaceholder == OAuthServiceKind.googleCalendar.defaultClientID ?? "",
                   "Google onboarding should show the shipped desktop client ID as the placeholder")
        try expect(OAuthServiceKind.googleCalendar.clientIDPlaceholder.hasSuffix(".apps.googleusercontent.com"),
                   "Google onboarding should show the expected desktop client ID shape")
        try expect(OAuthServiceKind.googleCalendar.onboardingGuidanceText.contains("Keychain"),
                   "Google onboarding should explain refresh-token storage")
        try expect(OAuthServiceKind.googleCalendar.onboardingGuidanceText.contains("calendar read/write"),
                   "Google onboarding should explain calendar write scope")
        try expect(OAuthServiceKind.googleCalendar.onboardingGuidanceText.contains(".apps.googleusercontent.com"),
                   "Google onboarding should explain client ID shape")
        try expect(OAuthServiceKind.googleCalendar.onboardingGuidanceText.localizedCaseInsensitiveContains("loopback"),
                   "Google onboarding should explain loopback desktop sign-in")
        try expect(OAuthServiceKind.googleCalendar.onboardingGuidanceText.localizedCaseInsensitiveContains("browser"),
                   "Google onboarding should explain browser sign-in")
        try expect(!OAuthServiceKind.googleCalendar.usesTenant,
                   "Google onboarding should not ask for a tenant")

        try expect(OAuthServiceKind.microsoft365.clientIDLabel.localizedCaseInsensitiveContains("public-client app ID"),
                   "Microsoft onboarding should ask for a public-client app ID")
        try expect(OAuthServiceKind.microsoft365.defaultClientID == nil,
                   "Microsoft onboarding should not ship a default app ID")
        try expect(UUID(uuidString: OAuthServiceKind.microsoft365.clientIDPlaceholder) != nil,
                   "Microsoft onboarding should show the expected app ID UUID shape")
        try expect(OAuthServiceKind.microsoft365.tenantPlaceholder.contains("common"),
                   "Microsoft onboarding should document the common tenant")
        try expect(OAuthServiceKind.microsoft365.tenantGuidanceText.contains("organizations"),
                   "Microsoft tenant guidance should cover work/school accounts")
        try expect(OAuthServiceKind.microsoft365.onboardingGuidanceText.contains("device-code flow"),
                   "Microsoft onboarding should explain device-code flow requirements")
        try expect(OAuthServiceKind.microsoft365.onboardingGuidanceText.contains("Keychain"),
                   "Microsoft onboarding should explain refresh-token storage")
    }

    private static func verifyOAuthClientIDValidation() async throws {
        try expect(OAuthServiceKind.googleCalendar.clientIDValidationMessage(for: "  1234567890-abc.apps.googleusercontent.com  ") == nil,
                   "Google desktop OAuth client IDs should pass local validation")
        try expect(OAuthServiceKind.googleCalendar.clientIDValidationMessage(for: "server-client-id")?.contains(".apps.googleusercontent.com") == true,
                   "Google non-desktop-looking client IDs should be rejected locally")

        try expect(OAuthServiceKind.microsoft365.clientIDValidationMessage(for: "00000000-0000-4000-8000-000000000001") == nil,
                   "Microsoft app IDs should pass local UUID validation")
        try expect(OAuthServiceKind.microsoft365.clientIDValidationMessage(for: "not-a-guid")?.contains("UUID") == true,
                   "Microsoft non-UUID app IDs should be rejected locally")

        let googleTransport = OAuthFixtureTransport(responses: [])
        let googleClient = OAuthDeviceFlowClient(transport: googleTransport)
        do {
            _ = try await googleClient.requestAuthorization(
                service: .googleCalendar,
                clientID: "web-client-id",
                tenant: "ignored"
            )
            throw OAuthDeviceFlowInvariantError("Invalid Google client IDs should fail before OAuth network requests")
        } catch OAuthDeviceFlowError.invalidClientID(let service, let message) {
            try expect(service == .googleCalendar, "Invalid Google client ID errors should preserve service context")
            try expect(message.contains(".apps.googleusercontent.com"), "Invalid Google client ID errors should explain the required suffix")
            try expect(googleTransport.requests.isEmpty, "Invalid Google client IDs should not send device-code requests")
        }

        let microsoftTransport = OAuthFixtureTransport(responses: [])
        let microsoftClient = OAuthDeviceFlowClient(transport: microsoftTransport)
        do {
            _ = try await microsoftClient.requestAuthorization(
                service: .microsoft365,
                clientID: "microsoft-client",
                tenant: "common"
            )
            throw OAuthDeviceFlowInvariantError("Invalid Microsoft client IDs should fail before OAuth network requests")
        } catch OAuthDeviceFlowError.invalidClientID(let service, let message) {
            try expect(service == .microsoft365, "Invalid Microsoft client ID errors should preserve service context")
            try expect(message.contains("UUID"), "Invalid Microsoft client ID errors should explain the UUID requirement")
            try expect(microsoftTransport.requests.isEmpty, "Invalid Microsoft client IDs should not send device-code requests")
        }
    }

    private static func verifyDeviceAuthorizationRequest() async throws {
        let now = try date("2026-07-01T09:00:00Z")
        let transport = OAuthFixtureTransport(responses: [
            .json("""
            {
              "device_code": "device-code-1",
              "user_code": "ABCD-EFGH",
              "verification_uri": "https://microsoft.com/devicelogin",
              "verification_uri_complete": "https://microsoft.com/devicelogin?code=ABCD-EFGH",
              "expires_in": 30,
              "interval": 1,
              "message": " "
            }
            """)
        ])
        let client = OAuthDeviceFlowClient(transport: transport, now: { now })

        let authorization = try await client.requestAuthorization(
            service: .microsoft365,
            clientID: "  00000000-0000-4000-8000-000000000001  ",
            tenant: "  organizations  "
        )

        let request = try requireOnlyRequest(transport.requests, context: "device authorization")
        try expect(request.url?.absoluteString == "https://login.microsoftonline.com/organizations/oauth2/v2.0/devicecode",
                   "Microsoft device authorization should target the trimmed tenant endpoint")
        let fields = try formFields(request)
        try expect(fields["client_id"] == "00000000-0000-4000-8000-000000000001", "Device authorization should trim the OAuth client ID")
        try expect(fields["scope"] == OAuthServiceKind.microsoft365.scopes,
                   "Microsoft device authorization should request offline calendar scopes")
        try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded",
                   "OAuth form requests should use application/x-www-form-urlencoded")
        try expect(request.value(forHTTPHeaderField: "Accept") == "application/json",
                   "OAuth form requests should accept JSON")

        try expect(authorization.clientID == "00000000-0000-4000-8000-000000000001", "Authorization should keep the trimmed client ID")
        try expect(authorization.tenant == "organizations", "Authorization should keep the trimmed tenant")
        try expect(authorization.deviceCode == "device-code-1", "Authorization should preserve the device code")
        try expect(authorization.userCode == "ABCD-EFGH", "Authorization should preserve the user code")
        try expect(authorization.verificationURL.absoluteString == "https://microsoft.com/devicelogin",
                   "Authorization should preserve the verification URL")
        try expect(authorization.verificationURLComplete?.absoluteString == "https://microsoft.com/devicelogin?code=ABCD-EFGH",
                   "Authorization should preserve the complete verification URL")
        try expect(authorization.expiresAt == now.addingTimeInterval(60),
                   "Device authorization should clamp short expirations to at least 60 seconds")
        try expect(authorization.intervalSeconds == 2,
                   "Device authorization should clamp short poll intervals to at least 2 seconds")
        try expect(authorization.message == "Open https://microsoft.com/devicelogin and enter the code.",
                   "Blank provider messages should fall back to a useful instruction")
    }

    private static func verifyGoogleDoesNotUseDeviceAuthorization() async throws {
        let transport = OAuthFixtureTransport(responses: [])
        let client = OAuthDeviceFlowClient(transport: transport)

        do {
            _ = try await client.requestAuthorization(
                service: .googleCalendar,
                clientID: " 1234567890-abc.apps.googleusercontent.com ",
                tenant: "ignored-by-google"
            )
            throw OAuthDeviceFlowInvariantError("Google Calendar should not use device-code OAuth")
        } catch OAuthDeviceFlowError.unsupportedDeviceFlow(let service) {
            try expect(service == .googleCalendar, "Unsupported device flow errors should preserve the Google service")
            try expect(transport.requests.isEmpty, "Google device-code OAuth should fail before network requests")
        }
    }

    private static func verifyGoogleLoopbackAuthorizationURL() async throws {
        let client = OAuthDeviceFlowClient(transport: OAuthFixtureTransport(responses: []))
        let authorization = try await client.requestLoopbackAuthorization(
            service: .googleCalendar,
            clientID: " 1234567890-abc.apps.googleusercontent.com "
        )
        defer { authorization.cancel() }

        try expect(authorization.clientID == "1234567890-abc.apps.googleusercontent.com",
                   "Google loopback authorization should trim the OAuth client ID")
        try expect(authorization.redirectURI.scheme == "http",
                   "Google loopback authorization should use an HTTP loopback redirect")
        try expect(authorization.redirectURI.host == "127.0.0.1",
                   "Google loopback authorization should bind to 127.0.0.1")
        try expect(authorization.redirectURI.port != nil && authorization.redirectURI.port! > 0,
                   "Google loopback authorization should reserve an ephemeral port")
        try expect(authorization.redirectURI.path.isEmpty,
                   "Google loopback authorization should use the bare loopback redirect URI")
        try expect(authorization.state.count >= 24,
                   "Google loopback authorization should include a CSRF state token")
        try expect(authorization.codeVerifier.count >= 43,
                   "Google loopback authorization should include a PKCE code verifier")

        guard let components = URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false) else {
            throw OAuthDeviceFlowInvariantError("Google authorization URL should parse as URL components")
        }
        let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        try expect(authorization.authorizationURL.scheme == "https", "Google authorization URL should use HTTPS")
        try expect(authorization.authorizationURL.host == "accounts.google.com", "Google authorization URL should target Google accounts")
        try expect(components.path == "/o/oauth2/v2/auth", "Google authorization URL should use the OAuth v2 auth endpoint")
        try expect(fields["client_id"] == authorization.clientID, "Google authorization URL should carry the client ID")
        try expect(fields["redirect_uri"] == authorization.redirectURI.absoluteString,
                   "Google authorization URL should carry the loopback redirect URI")
        try expect(fields["response_type"] == "code", "Google authorization URL should request an authorization code")
        try expect(fields["scope"] == OAuthServiceKind.googleCalendar.scopes,
                   "Google authorization URL should request full calendar read/write scope")
        try expect(fields["state"] == authorization.state, "Google authorization URL should carry the CSRF state")
        try expect(fields["code_challenge_method"] == "S256", "Google authorization URL should use PKCE S256")
        try expect(fields["code_challenge"]?.count ?? 0 >= 43, "Google authorization URL should include a PKCE challenge")
        try expect(fields["access_type"] == "offline", "Google authorization URL should request a refresh token")
        try expect(fields["prompt"] == "consent", "Google authorization URL should force consent for reconnect refresh tokens")
    }

    private static func verifyGoogleLoopbackTokenExchange() async throws {
        let now = try date("2026-07-01T09:00:00Z")
        let transport = OAuthFixtureTransport(responses: [
            .json("""
            {
              "access_token": "loopback-google-access",
              "refresh_token": "loopback-google-refresh",
              "expires_in": 3600,
              "token_type": "Bearer",
              "scope": "https://www.googleapis.com/auth/calendar"
            }
            """)
        ])
        let client = OAuthDeviceFlowClient(transport: transport, now: { now })
        let authorization = try await client.requestLoopbackAuthorization(
            service: .googleCalendar,
            clientID: "1234567890-abc.apps.googleusercontent.com"
        )

        let tokenTask = Task {
            try await client.token(authorization: authorization)
        }

        var callbackComponents = URLComponents(url: authorization.redirectURI, resolvingAgainstBaseURL: false)!
        callbackComponents.queryItems = [
            URLQueryItem(name: "code", value: "authorization-code-1"),
            URLQueryItem(name: "state", value: authorization.state)
        ]
        let (_, response) = try await loopbackData(from: callbackComponents.url!)
        try expect((response as? HTTPURLResponse)?.statusCode == 200,
                   "Google loopback callback should return a browser success response")

        let credential = try await tokenTask.value
        let request = try requireOnlyRequest(transport.requests, context: "Google loopback token exchange")
        try expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token",
                   "Google loopback token exchange should target Google's token endpoint")
        let fields = try formFields(request)
        try expect(fields["grant_type"] == "authorization_code", "Google loopback token exchange should use authorization_code grant")
        try expect(fields["code"] == "authorization-code-1", "Google loopback token exchange should submit the callback code")
        try expect(fields["client_id"] == authorization.clientID, "Google loopback token exchange should submit the client ID")
        try expect(fields["redirect_uri"] == authorization.redirectURI.absoluteString,
                   "Google loopback token exchange should submit the exact redirect URI")
        try expect(fields["code_verifier"] == authorization.codeVerifier,
                   "Google loopback token exchange should submit the PKCE verifier")
        try expect(credential.accessToken == "loopback-google-access", "Google loopback token exchange should return the access token")
        try expect(credential.refreshToken == "loopback-google-refresh", "Google loopback token exchange should return the refresh token")
        try expect(credential.expiresAt == now.addingTimeInterval(3600), "Google loopback token exchange should compute expiration from now")
        try expect(credential.service == .googleCalendar, "Google loopback token exchange should preserve the OAuth service")
    }

    private static func verifyPollingSlowDownAndTokenSuccess() async throws {
        let now = try date("2026-07-01T09:00:00Z")
        let transport = OAuthFixtureTransport(responses: [
            .json(#"{ "error": "authorization_pending" }"#),
            .json(#"{ "error": "slow_down" }"#),
            .json("""
            {
              "access_token": "access-token-1",
              "refresh_token": "refresh-token-1",
              "expires_in": 120,
              "token_type": "Bearer",
              "scope": "https://www.googleapis.com/auth/calendar"
            }
            """)
        ])
        var sleptNanoseconds: [UInt64] = []
        let client = OAuthDeviceFlowClient(
            transport: transport,
            now: { now },
            sleep: { nanoseconds in
                sleptNanoseconds.append(nanoseconds)
            }
        )
        let authorization = OAuthDeviceAuthorization(
            service: .googleCalendar,
            clientID: "google-client",
            tenant: "",
            deviceCode: "device-code-2",
            userCode: "WXYZ",
            verificationURL: URL(string: "https://google.com/device")!,
            verificationURLComplete: nil,
            expiresAt: now.addingTimeInterval(300),
            intervalSeconds: 2,
            message: "Authorize"
        )

        let credential = try await client.pollForToken(authorization: authorization)
        try expect(sleptNanoseconds == [2_000_000_000, 2_000_000_000, 7_000_000_000],
                   "Polling should wait the base interval and increase by 5 seconds after slow_down")
        try expect(transport.requests.count == 3, "Polling should retry pending/slow_down responses until success")
        let finalRequestFields = try formFields(transport.requests[2])
        try expect(finalRequestFields["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code",
                   "Polling should use the OAuth device-code grant")
        try expect(finalRequestFields["device_code"] == "device-code-2",
                   "Polling should submit the device code")
        try expect(finalRequestFields["client_id"] == "google-client",
                   "Polling should submit the client ID")
        try expect(credential.accessToken == "access-token-1", "Polling should return the issued access token")
        try expect(credential.refreshToken == "refresh-token-1", "Polling should return the issued refresh token")
        try expect(credential.expiresAt == now.addingTimeInterval(120), "Polling should compute token expiration from now")
        try expect(credential.scope == "https://www.googleapis.com/auth/calendar", "Polling should preserve provider token scopes")
        try expect(credential.service == .googleCalendar, "Polling should preserve the OAuth service")
        try expect(credential.missingRequiredScopes().isEmpty,
                   "Polling should only accept credentials with the required provider scopes")
    }

    private static func verifyInitialTokenRequiresRefreshToken() async throws {
        let now = try date("2026-07-01T09:00:00Z")
        let transport = OAuthFixtureTransport(responses: [
            .json("""
            {
              "access_token": "access-token-no-refresh",
              "expires_in": 3600,
              "token_type": "Bearer",
              "scope": "https://www.googleapis.com/auth/calendar"
            }
            """)
        ])
        let client = OAuthDeviceFlowClient(
            transport: transport,
            now: { now },
            sleep: { _ in }
        )
        let authorization = OAuthDeviceAuthorization(
            service: .googleCalendar,
            clientID: "google-client",
            tenant: "",
            deviceCode: "device-code-no-refresh",
            userCode: "REFR",
            verificationURL: URL(string: "https://google.com/device")!,
            verificationURLComplete: nil,
            expiresAt: now.addingTimeInterval(300),
            intervalSeconds: 2,
            message: "Authorize"
        )

        do {
            _ = try await client.pollForToken(authorization: authorization)
            throw OAuthDeviceFlowInvariantError("Initial device-code credentials without refresh tokens should be rejected")
        } catch OAuthDeviceFlowError.missingRefreshToken {
            try expect(OAuthDeviceFlowError.missingRefreshToken.localizedDescription.localizedCaseInsensitiveContains("background sync"),
                       "Missing refresh token errors should explain why reconnect is required")
        }
    }

    private static func verifyGrantedScopesAreRequired() async throws {
        let now = try date("2026-07-01T09:00:00Z")
        let googleTransport = OAuthFixtureTransport(responses: [
            .json("""
            {
              "access_token": "readonly-google-access",
              "refresh_token": "readonly-google-refresh",
              "expires_in": 3600,
              "token_type": "Bearer",
              "scope": "https://www.googleapis.com/auth/calendar.readonly"
            }
            """)
        ])
        let googleClient = OAuthDeviceFlowClient(transport: googleTransport, now: { now })
        let googleCredential = OAuthCredential(
            accessToken: "old-google-access",
            refreshToken: "old-google-refresh",
            expiresAt: now.addingTimeInterval(-60),
            tokenType: "Bearer",
            scope: OAuthServiceKind.googleCalendar.scopes,
            clientID: "google-client",
            tenant: nil,
            service: .googleCalendar
        )

        do {
            _ = try await googleClient.refresh(googleCredential)
            throw OAuthDeviceFlowInvariantError("Google credentials with read-only scopes should be rejected")
        } catch OAuthDeviceFlowError.missingGrantedScopes(let service, let scopes) {
            try expect(service == .googleCalendar, "Missing scope errors should preserve the Google service")
            try expect(scopes == OAuthServiceKind.googleCalendar.requiredGrantedScopes,
                       "Google missing scope errors should list the full calendar scope")
        }

        let microsoftTransport = OAuthFixtureTransport(responses: [
            .json("""
            {
              "access_token": "calendar-only-microsoft-access",
              "expires_in": 3600,
              "token_type": "Bearer",
              "scope": "Calendars.ReadWrite"
            }
            """)
        ])
        let microsoftClient = OAuthDeviceFlowClient(transport: microsoftTransport, now: { now })
        let microsoftCredential = OAuthCredential(
            accessToken: "old-microsoft-access",
            refreshToken: "old-microsoft-refresh",
            expiresAt: now.addingTimeInterval(-60),
            tokenType: "Bearer",
            scope: OAuthServiceKind.microsoft365.scopes,
            clientID: "microsoft-client",
            tenant: "common",
            service: .microsoft365
        )

        do {
            _ = try await microsoftClient.refresh(microsoftCredential)
            throw OAuthDeviceFlowInvariantError("Microsoft credentials without User.Read should be rejected")
        } catch OAuthDeviceFlowError.missingGrantedScopes(let service, let scopes) {
            try expect(service == .microsoft365, "Missing scope errors should preserve the Microsoft service")
            try expect(scopes == ["User.Read"], "Microsoft missing scope errors should name the profile scope")
        }
    }

    private static func verifyMicrosoftRefreshPreservesRefreshToken() async throws {
        let now = try date("2026-07-01T09:00:00Z")
        let transport = OAuthFixtureTransport(responses: [
            .json("""
            {
              "access_token": "new-microsoft-access",
              "expires_in": 10,
              "token_type": "Bearer",
              "scope": "User.Read Calendars.ReadWrite Calendars.ReadWrite.Shared"
            }
            """)
        ])
        let client = OAuthDeviceFlowClient(transport: transport, now: { now })
        let credential = OAuthCredential(
            accessToken: "old-microsoft-access",
            refreshToken: "old-microsoft-refresh",
            expiresAt: now.addingTimeInterval(-60),
            tokenType: "Bearer",
            scope: OAuthServiceKind.microsoft365.scopes,
            clientID: "microsoft-client",
            tenant: "contoso",
            service: .microsoft365
        )

        let refreshed = try await client.refresh(credential)
        let request = try requireOnlyRequest(transport.requests, context: "Microsoft refresh")
        try expect(request.url?.absoluteString == "https://login.microsoftonline.com/contoso/oauth2/v2.0/token",
                   "Microsoft refresh should target the credential tenant endpoint")
        let fields = try formFields(request)
        try expect(fields["grant_type"] == "refresh_token", "Refresh should use refresh_token grant")
        try expect(fields["refresh_token"] == "old-microsoft-refresh", "Refresh should submit the stored refresh token")
        try expect(fields["client_id"] == "microsoft-client", "Refresh should submit the client ID")
        try expect(fields["scope"] == OAuthServiceKind.microsoft365.scopes,
                   "Microsoft refresh should preserve requested shared-calendar scopes")
        try expect(refreshed.accessToken == "new-microsoft-access", "Refresh should return the new Microsoft access token")
        try expect(refreshed.refreshToken == "old-microsoft-refresh",
                   "Microsoft refresh should preserve the old refresh token when the provider omits a new one")
        try expect(refreshed.expiresAt == now.addingTimeInterval(60),
                   "Refresh should clamp short token expirations to at least 60 seconds")
        try expect(refreshed.tenant == "contoso", "Refresh should preserve the tenant")
        try expect(refreshed.service == .microsoft365, "Refresh should preserve the service")
        try expect(refreshed.missingRequiredScopes().isEmpty,
                   "Microsoft refresh should only accept credentials with the required access scopes")
    }

    private static func verifyGoogleRefreshUsesNewRefreshTokenWithoutScope() async throws {
        let now = try date("2026-07-01T09:00:00Z")
        let transport = OAuthFixtureTransport(responses: [
            .json("""
            {
              "access_token": "new-google-access",
              "refresh_token": "new-google-refresh",
              "expires_in": 3600,
              "token_type": "Bearer"
            }
            """)
        ])
        let client = OAuthDeviceFlowClient(transport: transport, now: { now })
        let credential = OAuthCredential(
            accessToken: "old-google-access",
            refreshToken: "old-google-refresh",
            expiresAt: now.addingTimeInterval(-60),
            tokenType: "Bearer",
            scope: OAuthServiceKind.googleCalendar.scopes,
            clientID: "google-client",
            tenant: nil,
            service: .googleCalendar
        )

        let refreshed = try await client.refresh(credential)
        let request = try requireOnlyRequest(transport.requests, context: "Google refresh")
        try expect(request.url?.absoluteString == "https://oauth2.googleapis.com/token",
                   "Google refresh should target Google's token endpoint")
        let fields = try formFields(request)
        try expect(fields["grant_type"] == "refresh_token", "Google refresh should use refresh_token grant")
        try expect(fields["refresh_token"] == "old-google-refresh", "Google refresh should submit the stored refresh token")
        try expect(fields["client_id"] == "google-client", "Google refresh should submit the client ID")
        try expect(fields["scope"] == nil, "Google refresh should not send an extra scope field")
        try expect(refreshed.accessToken == "new-google-access", "Google refresh should return the new access token")
        try expect(refreshed.refreshToken == "new-google-refresh", "Google refresh should prefer a rotated refresh token")
        try expect(refreshed.scope == OAuthServiceKind.googleCalendar.scopes,
                   "Google refresh should fall back to calendar scopes when token response omits scope")
        try expect(refreshed.tenant == nil, "Google refresh should not invent a tenant")
    }

    private static func verifyRefreshInvalidGrantRequiresReconnect() async throws {
        let now = try date("2026-07-01T09:00:00Z")
        let transport = OAuthFixtureTransport(responses: [
            .json("""
            {
              "error": "invalid_grant",
              "error_description": "Refresh token has expired or been revoked."
            }
            """, statusCode: 400)
        ])
        let client = OAuthDeviceFlowClient(transport: transport, now: { now })
        let credential = OAuthCredential(
            accessToken: "expired-access",
            refreshToken: "revoked-refresh",
            expiresAt: now.addingTimeInterval(-60),
            tokenType: "Bearer",
            scope: OAuthServiceKind.googleCalendar.scopes,
            clientID: "google-client",
            tenant: nil,
            service: .googleCalendar
        )

        do {
            _ = try await client.refresh(credential)
            throw OAuthDeviceFlowInvariantError("Invalid refresh grants should require reconnect")
        } catch OAuthDeviceFlowError.refreshTokenRejected(let message) {
            try expect(message == "Refresh token has expired or been revoked.",
                       "Refresh invalid_grant should preserve the provider rejection reason")
            try expect(OAuthDeviceFlowError.refreshTokenRejected(message).localizedDescription.localizedCaseInsensitiveContains("reconnect"),
                       "Refresh invalid_grant should be presented as a reconnect-required error")
        }

        let request = try requireOnlyRequest(transport.requests, context: "invalid grant refresh")
        let fields = try formFields(request)
        try expect(fields["grant_type"] == "refresh_token",
                   "Invalid grant fixture should still exercise the refresh grant path")
    }

    private static func requireOnlyRequest(_ requests: [URLRequest], context: String) throws -> URLRequest {
        guard requests.count == 1, let request = requests.first else {
            throw OAuthDeviceFlowInvariantError("\(context) should make exactly one request, got \(requests.count)")
        }
        return request
    }

    private static func loopbackData(from url: URL) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<10 {
            do {
                return try await URLSession.shared.data(from: url)
            } catch {
                lastError = error
                if attempt < 9 {
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            }
        }
        throw lastError ?? OAuthDeviceFlowInvariantError("Loopback callback failed")
    }

    private static func formFields(_ request: URLRequest) throws -> [String: String] {
        guard let body = request.httpBody,
              let text = String(data: body, encoding: .utf8)
        else {
            throw OAuthDeviceFlowInvariantError("OAuth request is missing a form body")
        }

        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let pieces = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let key = try decodeFormComponent(pieces[0])
            let value = try decodeFormComponent(pieces[1])
            fields[key] = value
        }
        return fields
    }

    private static func decodeFormComponent(_ value: String) throws -> String {
        let normalized = value.replacingOccurrences(of: "+", with: " ")
        guard let decoded = normalized.removingPercentEncoding else {
            throw OAuthDeviceFlowInvariantError("Could not decode form component \(value)")
        }
        return decoded
    }

    private static func date(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw OAuthDeviceFlowInvariantError("Could not parse date fixture \(value)")
        }
        return date
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw OAuthDeviceFlowInvariantError(message)
        }
    }
}

private final class OAuthFixtureTransport: OAuthDeviceFlowTransport {
    struct FixtureResponse {
        var statusCode: Int
        var body: String

        static func json(_ body: String, statusCode: Int = 200) -> FixtureResponse {
            FixtureResponse(statusCode: statusCode, body: body)
        }
    }

    private var responses: [FixtureResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [FixtureResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw OAuthDeviceFlowInvariantError("Unexpected OAuth request to \(request.url?.absoluteString ?? "<nil>")")
        }
        let response = responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (Data(response.body.utf8), httpResponse)
    }
}

private struct OAuthDeviceFlowInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
