import AppKit

/// Flagged mails (one flag colour, e.g. orange) from Apple Mail's inboxes, for page 2.
/// Reads via AppleScript only while Mail is open (never launches it). macOS asks once:
/// "Nordpult wants to control Mail".
final class FlaggedMail {
    static let colours = ["rot": 0, "red": 0, "orange": 1, "gelb": 2, "yellow": 2, "grün": 3, "green": 3,
                          "blau": 4, "blue": 4, "lila": 5, "purple": 5, "grau": 6, "gray": 6, "grey": 6]
    private let queue = DispatchQueue(label: "mail")
    private var state: [String: Any] = ["status": "off"]     // off | loading | ok | closed | denied
    private let flag: Int?
    private var timer: DispatchSourceTimer?

    init(colour: String?) {
        flag = colour.flatMap { FlaggedMail.colours[$0.lowercased()] }
        if flag != nil { state = ["status": "loading"] }
    }

    func start() {
        guard flag != nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 60)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func snapshot() -> [String: Any] { queue.sync { state } }
    func poke() { queue.async { [weak self] in self?.refresh() } }

    private static let us = "character id 31", rs = "character id 30"

    /// Runs on `queue`.
    private func refresh() {
        guard let flag else { return }
        let script = """
        if application "Mail" is not running then return "CLOSED"
        tell application "Mail"
          set out to ""
          set n to 0
          repeat with m in (messages of inbox whose flagged status is true and flag index is \(flag) and deleted status is false)
            set n to n + 1
            if n > 40 then exit repeat
            set out to out & (id of m) & \(FlaggedMail.us) & (sender of m) & \(FlaggedMail.us) & (subject of m) & \(FlaggedMail.us) & ((date received of m) as «class isot» as string) & \(FlaggedMail.us) & (read status of m) & \(FlaggedMail.rs)
          end repeat
          return "OK" & \(FlaggedMail.rs) & out
        end tell
        """
        guard let data = Stats.run("/usr/bin/osascript", ["-e", script], timeout: 25),
              let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            // Most likely the "control Mail" permission was refused (or the first prompt is still open).
            if (state["status"] as? String) != "ok" { state = ["status": "denied"] }
            print("⚠️  Mail: could not read flagged mails. System Settings → Privacy & Security → Automation → Nordpult → Mail.")
            return
        }
        if raw == "CLOSED" { state = ["status": "closed"]; return }
        var recs = raw.components(separatedBy: "\u{1e}")
        guard recs.first == "OK" else { return }
        recs.removeFirst()
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let items: [[String: Any]] = recs.compactMap { r in
            let f = r.components(separatedBy: "\u{1f}")
            guard f.count >= 5, let id = Int(f[0].trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            var who = f[1]
            if let lt = who.firstIndex(of: "<") {                     // "Name <mail@x>" → Name
                let name = who[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                who = name.isEmpty ? String(who[who.index(after: lt)...]).replacingOccurrences(of: ">", with: "") : name
            }
            let subject = f[2].replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            let at = iso.date(from: f[3])?.timeIntervalSince1970 ?? 0
            return ["id": id, "who": who, "subject": subject.isEmpty ? "(kein Betreff)" : subject,
                    "at": at * 1000, "read": f[4].contains("true")]
        }.sorted { (($0["at"] as? Double) ?? 0) > (($1["at"] as? Double) ?? 0) }
        state = ["status": "ok", "items": items]
    }

    /// Opens the mail in Apple Mail on the Mac.
    func open(_ id: Int) {
        let script = """
        tell application "Mail"
          set ms to (messages of inbox whose id is \(id))
          if (count of ms) > 0 then open (item 1 of ms)
          activate
        end tell
        """
        queue.async { _ = Stats.run("/usr/bin/osascript", ["-e", script], timeout: 20) }
    }
}
