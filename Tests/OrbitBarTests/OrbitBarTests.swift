import XCTest
@testable import OrbitBar

final class OrbitBarTests: XCTestCase {
    private let taskJSON = """
    {"id":"t1","workspace_id":"w1","project_id":"p1","status_id":"s1","number":42,"title":"Ship it",
     "description":"","description_json":null,"collab_epoch":"x","priority":"high","position":3,
     "assignee_ids":["u1"],"label_ids":[],"recurrence":null,"milestone_id":null,"cycle_id":null,
     "estimate":null,"version":7,"created_at":"2026-11-01T10:00:00Z","updated_at":"2026-11-02T10:00:00.123Z",
     "duplicate_of":null,"blocked":false,"parent_task_id":null,"parent":null,"sub_issue_count":0,
     "sub_issue_closed_count":0,"due_at":"2026-11-20T22:59:00.000Z"}
    """

    private func decodeTask() throws -> OrbitTask {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(OrbitTask.self, from: Data(taskJSON.utf8))
    }

    func testDecodesTaskRecord() throws {
        let task = try decodeTask()
        XCTAssertEqual(task.number, 42)
        XCTAssertEqual(task.assigneeIds, ["u1"])
        XCTAssertNotNil(OrbitDate.parse(task.dueAt))
        XCTAssertNotNil(OrbitDate.parse(task.createdAt))
    }

    func testNormalizesServer() {
        XCTAssertEqual(OrbitClient.normalize("orbit.example.com/")?.absoluteString, "https://orbit.example.com")
        XCTAssertEqual(OrbitClient.normalize(" http://localhost:18080 ")?.absoluteString, "http://localhost:18080")
        XCTAssertNil(OrbitClient.normalize("   "))
    }

    func testEditBodyHasOnlyChangedFields() throws {
        var draft = TaskDraft(task: try decodeTask())
        XCTAssertNil(draft.body())
        draft.title = "Ship it now"
        draft.hasDue = false
        let body = try XCTUnwrap(draft.body())
        XCTAssertEqual(body["title"] as? String, "Ship it now")
        XCTAssertEqual(body["expected_version"] as? Int, 7)
        XCTAssertTrue(body["due_at"] is NSNull)
        XCTAssertNil(body["priority"])
        XCTAssertNil(body["status_id"])
    }

    func testMovingProjectSendsStatus() throws {
        var draft = TaskDraft(task: try decodeTask())
        draft.projectID = "p2"
        draft.statusID = "s9"
        let body = try XCTUnwrap(draft.body())
        XCTAssertEqual(body["project_id"] as? String, "p2")
        XCTAssertEqual(body["status_id"] as? String, "s9")
    }

    func testCreateBody() throws {
        var draft = TaskDraft(newIn: "p1", statusID: "s1", assignee: "u1")
        draft.title = "  New  "
        let body = try XCTUnwrap(draft.body())
        XCTAssertEqual(body["title"] as? String, "New")
        XCTAssertEqual(body["assignee_ids"] as? [String], ["u1"])
        XCTAssertNil(body["due_at"])
        XCTAssertNil(body["expected_version"])
    }

    func testSignInAnswers() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let twoFactor = try decoder.decode(SignInAnswer.self, from: Data(#"{"two_factor_token":"abc"}"#.utf8))
        XCTAssertEqual(twoFactor.twoFactorToken, "abc")
        let session = try decoder.decode(SignInAnswer.self, from: Data(#"{"session_id":"s","session_token":"tok","user":{"id":"u","email":"a@b.c","display_name":"A","installation_admin":false,"root":false,"has_password":true,"status":{}}}"#.utf8))
        XCTAssertEqual(session.sessionToken, "tok")
        XCTAssertEqual(session.user?.displayName, "A")
    }

    func testPKCEAndHandoff() {
        let verifier = ProviderSignIn.verifier()
        XCTAssertEqual(verifier.count, 43)
        // base64url(sha256(verifier)), checked with Python
        XCTAssertEqual(ProviderSignIn.challenge(for: "dBjftJeZ4CVP-mJ92IrSqTJm2spLEPI3jOZ7HlUskWA"), "wODWunCMlqVpMVSWWdn7fz2N3AQoNB-pyqx0xXbKjoE")
        XCTAssertEqual(ProviderSignIn.handoff(from: URL(string: "orbit://auth/callback?handoff=h1")!), "h1")
        XCTAssertNil(ProviderSignIn.handoff(from: URL(string: "orbit://other?handoff=h1")!))
    }

    func testResolvesAvatarURL() {
        let server = URL(string: "https://orbit.example.com")!
        XCTAssertEqual(OrbitClient.resolve("/api/v1/users/u1/avatar?v=3", server: server)?.absoluteString, "https://orbit.example.com/api/v1/users/u1/avatar?v=3")
        XCTAssertEqual(OrbitClient.resolve("https://cdn.example.com/a.png", server: server)?.absoluteString, "https://cdn.example.com/a.png")
        XCTAssertNil(OrbitClient.resolve(nil, server: server))
        XCTAssertNil(OrbitClient.resolve("", server: server))
        XCTAssertNil(OrbitClient.resolve("/api/a", server: nil))
    }

    func testPriorityCycle() {
        XCTAssertEqual(Priority.none.next, .low)
        XCTAssertEqual(Priority.urgent.next, .none)
    }

    func testLinkAndImagePolicy() {
        let server = URL(string: "https://orbit.example.com")!
        XCTAssertTrue(OrbitClient.isOpenableLink(URL(string: "https://example.com/a")!))
        XCTAssertTrue(OrbitClient.isOpenableLink(URL(string: "mailto:a@example.com")!))
        XCTAssertFalse(OrbitClient.isOpenableLink(URL(string: "file:///Applications/Calculator.app")!))
        XCTAssertFalse(OrbitClient.isOpenableLink(URL(string: "smb://host/share")!))
        XCTAssertFalse(OrbitClient.isOpenableLink(URL(string: "x-apple.systempreferences:com.apple.preference")!))
        XCTAssertNil(OrbitClient.resolve("file:///etc/hosts", server: server))
        XCTAssertNil(OrbitClient.resolve("javascript:alert(1)", server: server))

        XCTAssertTrue(OrbitClient.sameOrigin(server, URL(string: "https://ORBIT.example.com:443/api/x")!))
        XCTAssertFalse(OrbitClient.sameOrigin(server, URL(string: "http://orbit.example.com/api/x")!))
        XCTAssertFalse(OrbitClient.sameOrigin(server, URL(string: "https://orbit.example.com:8443/x")!))
        XCTAssertFalse(OrbitClient.sameOrigin(server, URL(string: "https://evil.example.com/x")!))
    }

    func testInsecureServerWarning() {
        XCTAssertTrue(OrbitClient.isInsecure(URL(string: "http://orbit.example.com")!))
        XCTAssertTrue(OrbitClient.isInsecure(URL(string: "http://8.8.8.8")!))
        XCTAssertFalse(OrbitClient.isInsecure(URL(string: "https://orbit.example.com")!))
        XCTAssertFalse(OrbitClient.isInsecure(URL(string: "http://localhost:18080")!))
        XCTAssertFalse(OrbitClient.isInsecure(URL(string: "http://192.168.1.20")!))
        XCTAssertFalse(OrbitClient.isInsecure(URL(string: "http://nas.local")!))
    }

    func testProxiedURLEncodesReservedCharacters() {
        let proxy = URL(string: "https://proxy.example.dev")!
        let image = URL(string: "https://cdn.example.com/a+b.png?x=1&y=2#frag")!
        let proxied = OrbitClient.proxied(image, through: proxy)!
        XCTAssertEqual(proxied.absoluteString,
                       "https://proxy.example.dev?url=https%3A%2F%2Fcdn.example.com%2Fa%2Bb.png%3Fx%3D1%26y%3D2%23frag")
        let decoded = URLComponents(url: proxied, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
        XCTAssertEqual(decoded, image.absoluteString)
    }

    private func status(_ id: String, _ name: String, _ category: String, _ position: Int, project: String = "p1") -> TaskStatus {
        TaskStatus(id: id, projectId: project, name: name, color: "#000000", category: category, position: position)
    }

    func testStatusFilterDefaultsAndChoices() {
        let backlog = status("b", "Backlog", "unstarted", 0), todo = status("t", "Todo", "unstarted", 1)
        let doing = status("s", "In Progress", "started", 2), done = status("d", "Done", "completed", 3)
        let cancelled = status("c", "Cancelled", "cancelled", 4)
        XCTAssertEqual([backlog, todo, doing, done, cancelled].map { StatusOption.isVisible($0, choices: [:]) },
                       [false, true, true, false, false])
        XCTAssertTrue(StatusOption.isVisible(done, choices: ["done": true]))
        XCTAssertFalse(StatusOption.isVisible(todo, choices: ["todo": false]))
    }

    func testStatusOptionsMergeByNameInSectionOrder() {
        let options = StatusOption.merge([
            status("d1", "Done", "completed", 3),
            status("t1", "Todo", "unstarted", 1),
            status("t2", "todo", "unstarted", 0, project: "p2"),
            status("s1", "In Progress", "started", 2),
            status("b1", "Backlog", "unstarted", 0),
        ])
        XCTAssertEqual(options.map(\.id), ["in progress", "backlog", "todo", "done"])
    }

    func testTaskSortOrders() throws {
        var a = try decodeTask(), b = a, c = a
        a.id = "a"; a.createdAt = "2026-11-01T10:00:00Z"; a.updatedAt = "2026-11-05T10:00:00Z"; a.priority = "low"; a.dueAt = nil
        b.id = "b"; b.createdAt = "2026-11-03T10:00:00.500Z"; b.updatedAt = "2026-11-03T10:00:00Z"; b.priority = "urgent"; b.dueAt = "2026-12-01T10:00:00Z"
        c.id = "c"; c.createdAt = "2026-11-02T10:00:00Z"; c.updatedAt = "2026-11-04T10:00:00Z"; c.priority = "urgent"; c.dueAt = "2026-11-25T10:00:00Z"
        func order(_ sort: TaskSort) -> [String] { [a, b, c].sorted(by: sort.inOrder).map(\.id) }
        XCTAssertEqual(order(.newest), ["b", "c", "a"])
        XCTAssertEqual(order(.oldest), ["a", "c", "b"])
        XCTAssertEqual(order(.updated), ["a", "c", "b"])
        XCTAssertEqual(order(.priority), ["c", "b", "a"])
        XCTAssertEqual(order(.due), ["c", "b", "a"])
    }
}
