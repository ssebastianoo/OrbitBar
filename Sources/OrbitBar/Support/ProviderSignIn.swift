import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// Google / GitHub / OpenID Connect sign-in: the server's start → provider → handoff → exchange
/// flow with PKCE, in the system's web authentication session. Orbit accepts the fixed redirect
/// `orbit://auth/callback` from native apps.
@MainActor
final class ProviderSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    nonisolated static let redirect = "orbit://auth/callback"

    private var session: ASWebAuthenticationSession?

    nonisolated static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    nonisolated static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// The `handoff` query value of the callback URL, or nil when it is not our redirect.
    nonisolated static func handoff(from url: URL) -> String? {
        guard url.scheme == "orbit", url.host == "auth", url.path == "/callback" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "handoff" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Returns nil when the person cancels.
    func run(client: OrbitClient, provider: String) async throws -> SignInAnswer? {
        let verifier = Self.verifier()
        let start = try await client.startProvider(provider, codeChallenge: Self.challenge(for: verifier), redirect: Self.redirect)
        guard let url = URL(string: start.authorizeUrl) else { throw OrbitError.unexpected("The server sent an invalid sign-in address.") }

        let callback: URL? = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "orbit") { url, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(returning: nil)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: url)
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(throwing: OrbitError.unexpected("Could not open the sign-in window."))
            }
        }
        session = nil
        guard let callback else { return nil }
        guard let handoff = Self.handoff(from: callback) else {
            throw OrbitError.unexpected("The provider did not finish the sign-in. Try again.")
        }
        return try await client.exchangeProvider(handoff: handoff, verifier: verifier)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? NSWindow()
        }
    }
}
