import Foundation

enum OrbitError: LocalizedError, Equatable {
    case unauthorized
    case problem(status: Int, code: String?, detail: String)
    case invalidServer
    case externalImageBlocked
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Your session has ended. Sign in again."
        case .problem(_, _, let detail): return detail
        case .invalidServer: return "That doesn't look like an Orbit server address."
        case .externalImageBlocked: return "Images from other sites are not loaded automatically."
        case .unexpected(let message): return message
        }
    }

    var code: String? {
        if case .problem(_, let code, _) = self { return code }
        return nil
    }
}

/// A JSON body where a key can be absent (unchanged) or `null` (cleared): build it as a dictionary.
typealias JSONBody = [String: Any]

/// Talks to one Orbit server. URLSession sends no `Origin` header, so the server treats this app
/// as a native client: sign-in returns the session token in the body and later requests send it
/// as a bearer token, exactly like Orbit's mobile app.
final class OrbitClient: @unchecked Sendable {
    static let contract = "orbit-api-v1"

    /// A file URL from the API, such as `avatar_url`, which Orbit sends as a path relative to the server.
    /// Only `http` and `https` come back: `file:` and other schemes are dropped.
    nonisolated static func resolve(_ string: String?, server: URL?) -> URL? {
        guard let string, !string.isEmpty else { return nil }
        if let absolute = URL(string: string), absolute.scheme != nil { return isWeb(absolute) ? absolute : nil }
        guard let server, let resolved = URL(string: string, relativeTo: server)?.absoluteURL else { return nil }
        return isWeb(resolved) ? resolved : nil
    }

    nonisolated static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// The links a description may open: web pages and mail. Anything else (`file:`, other apps' schemes) is refused.
    nonisolated static func isOpenableLink(_ url: URL) -> Bool {
        isWeb(url) || url.scheme?.lowercased() == "mailto"
    }

    /// Scheme, host and port (with the default port filled in) match.
    nonisolated static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : url.scheme?.lowercased() == "http" ? 80 : nil) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }

    /// Plain `http` to a host that is not this Mac or a local network name: passwords and tokens travel unencrypted.
    nonisolated static func isInsecure(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host == "::1" { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return false
            case (172, 16...31): return false
            default: return true
            }
        }
        return true
    }

    /// Optional image proxy (`worker/image-proxy`), set as `OrbitBarImageProxy` in Info.plist. Images from other
    /// sites go through it, so their hosts never see this Mac's address and can't reach its local network.
    nonisolated static let imageProxy: URL? = {
        guard let string = Bundle.main.object(forInfoDictionaryKey: "OrbitBarImageProxy") as? String,
              let url = URL(string: string.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }()

    nonisolated static let imageProxyKey: String? = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "OrbitBarImageProxyKey") as? String, !key.isEmpty else { return nil }
        return key
    }()

    let server: URL
    let token: String?
    private let session: URLSession

    init(server: URL, token: String?) {
        self.server = server
        self.token = token
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: config, delegate: RedirectGuard(), delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// `orbit.example.com` → `https://orbit.example.com`; keeps an explicit `http://` for local servers.
    static func normalize(_ input: String) -> URL? {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        if trimmed.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    func withToken(_ token: String?) -> OrbitClient { OrbitClient(server: server, token: token) }

    // MARK: - Transport

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func request(_ method: String, _ path: String, query: [String: String?] = [:], body: JSONBody? = nil) async throws -> (Data, Int) {
        var components = URLComponents(url: server.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { components.queryItems = items.sorted { $0.name < $1.name } }
        guard let url = components.url else { throw OrbitError.invalidServer }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.contract, forHTTPHeaderField: "X-Orbit-Contract")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw OrbitError.unexpected("Could not reach \(server.host ?? "the server"): \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else { throw OrbitError.unexpected("No HTTP response.") }
        if (200..<300).contains(http.statusCode) { return (data, http.statusCode) }

        let problem = try? Self.decoder.decode(Problem.self, from: data)
        // With a token, any 401 means the session is gone. Without one (sign-in), only this code does: wrong
        // passwords also answer 401.
        if http.statusCode == 401, token != nil || problem?.code == "authentication_required" {
            throw OrbitError.unauthorized
        }
        let detail = problem?.detail ?? problem?.title ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized
        throw OrbitError.problem(status: http.statusCode, code: problem?.code, detail: detail)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw OrbitError.unexpected("The server sent an answer this app does not understand (\(T.self)). Is this an Orbit server?")
        }
    }

    private func get<T: Decodable>(_ path: String, query: [String: String?] = [:]) async throws -> T {
        try decode(T.self, try await request("GET", path, query: query).0)
    }

    /// Follows `next_cursor` until the server has no more, or `maxPages` is reached.
    private func all<T: Decodable & Sendable>(_ path: String, query: [String: String?] = [:], maxPages: Int = 20) async throws -> [T] {
        var items: [T] = []
        var cursor: String?
        var pages = 0
        repeat {
            var q = query
            q["limit"] = "100"
            q["cursor"] = cursor
            let page: PageOf<T> = try await get(path, query: q)
            items += page.items
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < maxPages
        return items
    }

    private func ws(_ workspaceID: String) -> String { "api/v1/workspaces/\(workspaceID)" }

    // MARK: - Auth

    func authOptions() async throws -> AuthOptions { try await get("api/v1/auth/options") }

    func login(email: String, password: String) async throws -> SignInAnswer {
        try decode(SignInAnswer.self, try await request("POST", "api/v1/auth/login", body: ["email": email, "password": password]).0)
    }

    func loginSecondFactor(token: String, code: String) async throws -> SignInAnswer {
        try decode(SignInAnswer.self, try await request("POST", "api/v1/auth/login/two-factor", body: ["two_factor_token": token, "code": code]).0)
    }

    func startProvider(_ provider: String, codeChallenge: String, redirect: String) async throws -> ProviderStart {
        let body: JSONBody = ["intent": "sign_in", "code_challenge": codeChallenge, "redirect": redirect]
        return try decode(ProviderStart.self, try await request("POST", "api/v1/auth/providers/\(provider)/start", body: body).0)
    }

    func exchangeProvider(handoff: String, verifier: String) async throws -> SignInAnswer {
        try decode(SignInAnswer.self, try await request("POST", "api/v1/auth/providers/exchange", body: ["handoff": handoff, "code_verifier": verifier]).0)
    }

    func linkProvider(passwordToken: String, password: String) async throws -> SignInAnswer {
        try decode(SignInAnswer.self, try await request("POST", "api/v1/auth/providers/link", body: ["password_token": passwordToken, "password": password]).0)
    }

    func me() async throws -> User { try await get("api/v1/auth/me") }

    func logout() async throws { _ = try await request("POST", "api/v1/auth/logout") }

    // MARK: - Workspace data

    func workspaces() async throws -> [Workspace] {
        let list: [Workspace] = try await get("api/v1/workspaces")
        return list.filter { $0.deletedAt == nil }
    }

    func projects(_ workspaceID: String) async throws -> [Project] {
        let list: [Project] = try await all("\(ws(workspaceID))/projects")
        return list.filter { $0.deletedAt == nil }
    }

    func statuses(_ workspaceID: String, projectID: String) async throws -> [TaskStatus] {
        try await all("\(ws(workspaceID))/projects/\(projectID)/statuses")
    }

    func members(_ workspaceID: String) async throws -> [Member] {
        let list: [Member] = try await all("\(ws(workspaceID))/members")
        return list.filter { $0.suspendedAt == nil }
    }

    /// `view: "mine"` keeps the tasks assigned to the signed-in user.
    func tasks(_ workspaceID: String, projectID: String?, view: String?) async throws -> [OrbitTask] {
        try await all("\(ws(workspaceID))/tasks", query: ["project_id": projectID, "view": view], maxPages: 10)
    }

    func createTask(_ workspaceID: String, body: JSONBody) async throws -> OrbitTask {
        try decode(OrbitTask.self, try await request("POST", "\(ws(workspaceID))/tasks", body: body).0)
    }

    /// `body` needs `expected_version`; absent keys stay unchanged, `NSNull()` clears.
    func updateTask(_ workspaceID: String, taskID: String, body: JSONBody) async throws -> OrbitTask {
        try decode(OrbitTask.self, try await request("PATCH", "\(ws(workspaceID))/tasks/\(taskID)", body: body).0)
    }

    func task(_ workspaceID: String, taskID: String) async throws -> OrbitTask {
        try await get("\(ws(workspaceID))/tasks/\(taskID)")
    }

    /// Bytes of a file such as a description image or an avatar. Files on this server are fetched with the token.
    /// Files on other sites go through the image proxy when one is set, and are refused otherwise
    /// (`externalImageBlocked`) unless `direct` is true, which the person chooses.
    func fileData(_ url: URL, direct: Bool = false) async throws -> Data {
        guard Self.isWeb(url) else { throw OrbitError.unexpected("Could not load \(url.lastPathComponent).") }
        var request: URLRequest
        if Self.sameOrigin(url, server) {
            request = URLRequest(url: url)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        } else if !direct, let proxy = Self.imageProxy {
            var components = URLComponents(url: proxy, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
            guard let proxied = components.url else { throw OrbitError.unexpected("Could not load \(url.lastPathComponent).") }
            request = URLRequest(url: proxied)
            if let key = Self.imageProxyKey { request.setValue(key, forHTTPHeaderField: "X-Proxy-Key") }
        } else if direct {
            request = URLRequest(url: url)
        } else {
            throw OrbitError.externalImageBlocked
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OrbitError.unexpected("Could not load \(url.lastPathComponent).")
        }
        return data
    }

    /// Moves the task to the trash, as the web's Delete.
    func trashTask(_ workspaceID: String, taskID: String, version: Int) async throws {
        _ = try await request("DELETE", "\(ws(workspaceID))/tasks/\(taskID)", query: ["expected_version": String(version)])
    }
}

/// URLSession keeps headers set by hand across redirects. This drops `Authorization` when a redirect leaves the
/// original origin or goes from https to http, and refuses redirects to anything but http(s).
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, OrbitClient.isWeb(target) else { completionHandler(nil); return }
        var next = request
        if let origin = task.originalRequest?.url, !OrbitClient.sameOrigin(origin, target) {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}
