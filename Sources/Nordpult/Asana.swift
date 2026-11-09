import AppKit

/// "My tasks" from Asana for the second page of the deck, plus completing a task.
/// Uses a Personal Access Token stored per macOS account in ~/.nordpult/asana-token (no token = feature off).
final class AsanaTasks {
    private let queue = DispatchQueue(label: "asana")
    private var state: [String: Any] = ["status": "off"]     // off | loading | ok | error | badtoken
    private var token: String?
    private var workspace: String?                          // workspace gid
    private var meGid: String?
    private var timer: DispatchSourceTimer?
    private let tokenFile: URL
    private let preferredWorkspace: String                   // name (part) of the workspace to use; empty = first

    init(configDir: URL, workspace: String) {
        tokenFile = configDir.appendingPathComponent("asana-token")
        preferredWorkspace = workspace.lowercased()
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 120)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.refresh() }
        }
    }

    func snapshot() -> [String: Any] { queue.sync { state } }

    /// Ask for fresh data soon (e.g. when the page is opened).
    func poke() { queue.async { [weak self] in self?.refresh() } }

    // MARK: API

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                         _ done: @escaping (Int, [String: Any]?) -> Void) {
        guard let token, let u = URL(string: "https://app.asana.com/api/1.0" + path) else { return done(0, nil) }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            done(code, json)
        }.resume()
    }

    /// Runs on `queue`.
    private func refresh() {
        let t = (try? String(contentsOf: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let t, !t.isEmpty else { token = nil; state = ["status": "off"]; return }
        if t != token { token = t; workspace = nil; inboxOff = false }
        if (state["status"] as? String) == "off" { state = ["status": "loading"] }

        guard let ws = workspace else {
            request("GET", "/users/me?opt_fields=gid,workspaces.name") { [weak self] code, json in
                guard let self else { return }
                self.queue.async {
                    guard code == 200, let me = json?["data"] as? [String: Any],
                          let list = me["workspaces"] as? [[String: Any]], !list.isEmpty else {
                        self.fail(code); return
                    }
                    self.meGid = me["gid"] as? String
                    let pick = list.first { self.preferredWorkspace.isEmpty ? false :
                        ((($0["name"] as? String) ?? "").lowercased().contains(self.preferredWorkspace)) } ?? list[0]
                    self.workspace = pick["gid"] as? String
                    if self.workspace != nil { self.refresh() }
                }
            }
            return
        }

        let fields = "name,due_on,due_at,projects.name,modified_at"
        request("GET", "/tasks?assignee=me&workspace=\(ws)&completed_since=now&limit=100&opt_fields=\(fields)") { [weak self] code, json in
            guard let self else { return }
            self.queue.async {
                guard code == 200, let data = json?["data"] as? [[String: Any]] else { self.fail(code); return }
                let tasks: [[String: Any]] = data.compactMap { t in
                    guard let gid = t["gid"] as? String else { return nil }
                    var o: [String: Any] = ["gid": gid, "name": (t["name"] as? String) ?? ""]
                    if let d = t["due_at"] as? String { o["due_at"] = d }
                    if let d = t["due_on"] as? String { o["due_on"] = d }
                    if let p = (t["projects"] as? [[String: Any]])?.first?["name"] as? String { o["project"] = p }
                    return o
                }.filter { !(($0["name"] as? String) ?? "").isEmpty }       // skip blank placeholder tasks
                var s: [String: Any] = ["status": "ok", "tasks": tasks, "at": Date().timeIntervalSince1970 * 1000]
                s["inbox"] = self.state["inbox"]
                self.state = s
                self.refreshInbox(ws)
            }
        }
    }

    // MARK: Inbox (Asana's Notifications API, new in autumn 2026)

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// GET /users/me/notifications (needs workspace). If the full field list is refused, fall back to the basic one.
    private var inboxFields = "created_at,created_by.name,is_read,story_resource_subtype,work_objects.name,work_objects.resource_type,story.text"
    private var inboxOff = false

    /// Runs on `queue`.
    private func refreshInbox(_ ws: String) {
        if inboxOff { return }
        request("GET", "/users/me/notifications?workspace=\(ws)&limit=50&opt_fields=\(inboxFields)") { [weak self] code, json in
            guard let self else { return }
            self.queue.async {
                if code == 200 { self.publishInbox(json); return }
                if code == 400, self.inboxFields.contains("story.text") {
                    self.inboxFields = "created_at,created_by.name,is_read,story_resource_subtype,work_objects,work_objects.name"
                    self.refreshInbox(ws); return
                }
                if code == 404 || code == 400 || code == 403 {
                    self.inboxOff = true
                    self.state["inbox"] = ["status": "unavailable"]
                }
                print("⚠️  Asana inbox: HTTP \(code)")
            }
        }
    }

    /// Marks an inbox notification as read in Asana (it then disappears from the deck).
    func markRead(_ nid: String, _ done: @escaping (Bool) -> Void) {
        guard !nid.isEmpty, nid.allSatisfy({ $0.isNumber }) else { return done(false) }
        queue.async {
            guard let ws = self.workspace else { return done(false) }
            self.request("POST", "/users/me/notifications/markRead",
                         body: ["data": ["workspace": ws, "notification_gids": [nid]]]) { [weak self] code, json in
                guard let self else { return }
                self.queue.async {
                    let failed = ((json?["data"] as? [String: Any])?["failed_gids"] as? [String]) ?? []
                    let ok = code == 200 && !failed.contains(nid)
                    if ok, var inbox = self.state["inbox"] as? [String: Any], var items = inbox["items"] as? [[String: Any]] {
                        items.removeAll { ($0["nid"] as? String) == nid }
                        inbox["items"] = items
                        self.state["inbox"] = inbox
                    }
                    if !ok { print("⚠️  Asana inbox: mark read failed (HTTP \(code))") }
                    done(ok)
                }
            }
        }
    }

    /// Runs on `queue`.
    private func publishInbox(_ json: [String: Any]?) {
        let data = (json?["data"] as? [[String: Any]]) ?? []
        let items: [[String: Any]] = data.compactMap { n in
            guard (n["is_read"] as? Bool) != true, let nid = n["gid"] as? String,
                  let at = AsanaTasks.date(n["created_at"] as? String) else { return nil }
            let obj = (n["work_objects"] as? [[String: Any]])?.first
            var text = (((n["story"] as? [String: Any])?["text"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ")
            if text.count > 160 { text = String(text.prefix(157)) + "…" }
            var o: [String: Any] = [
                "kind": (n["story_resource_subtype"] as? String) ?? "",
                "who": ((n["created_by"] as? [String: Any])?["name"] as? String) ?? "",
                "task": (obj?["name"] as? String) ?? "",
                "text": text,
                "read": false,
                "nid": nid,
                "at": at.timeIntervalSince1970 * 1000,
            ]
            if (obj?["resource_type"] as? String) == "task", let g = obj?["gid"] as? String { o["gid"] = g }
            return o
        }
        state["inbox"] = ["status": "ok", "items": items]
    }

    private func fail(_ code: Int) {
        if code == 401 || code == 403 {
            state = ["status": "badtoken"]
            print("⚠️  Asana: token rejected (HTTP \(code)). Create a new Personal Access Token.")
        } else {
            var s = state
            s["status"] = (s["tasks"] != nil) ? "ok" : "error"        // keep showing the last list on hiccups
            s["stale"] = true
            state = s
            print("⚠️  Asana update failed (HTTP \(code)); retrying in 2 min")
        }
    }

    /// Marks a task complete in Asana.
    func complete(_ gid: String, _ done: @escaping (Bool) -> Void) {
        guard gid.allSatisfy({ $0.isNumber }) else { return done(false) }
        queue.async {
            self.request("PUT", "/tasks/\(gid)", body: ["data": ["completed": true]]) { [weak self] code, _ in
                guard let self else { return }
                self.queue.async {
                    if code == 200, var tasks = self.state["tasks"] as? [[String: Any]] {
                        tasks.removeAll { ($0["gid"] as? String) == gid }
                        self.state["tasks"] = tasks
                    }
                    done(code == 200)
                }
            }
        }
    }

    /// Opens the task in the browser / Asana app on the Mac.
    func open(_ gid: String) {
        guard gid.allSatisfy({ $0.isNumber }), let u = URL(string: "https://app.asana.com/0/0/\(gid)/f") else { return }
        // The Asana desktop app ignores links handed to it directly, so use the browser. With Asana's
        // "Open links in desktop app" setting on, the browser forwards the task to the app.
        DispatchQueue.main.async { NSWorkspace.shared.open(u) }
    }
}
