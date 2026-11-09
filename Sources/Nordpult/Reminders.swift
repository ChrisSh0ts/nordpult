import AppKit
import EventKit

/// Open reminders from chosen lists (e.g. "Arbeit"), shown in the calendar card and on page 2,
/// and completing them from the deck. Needs Reminders permission; macOS asks once.
final class Reminders {
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "reminders")
    private var items: [[String: Any]] = []
    private var status = "off"                // off | pending | ok | denied | nolist
    private var listTitle = ""
    private let lists: [String]               // list names (lowercased); empty = feature off
    private var timer: DispatchSourceTimer?

    init(lists: [String]) {
        self.lists = lists.map { $0.lowercased() }
        if !lists.isEmpty { status = "pending" }
    }

    func start() {
        guard !lists.isEmpty else { return }
        store.requestFullAccessToReminders { [weak self] granted, _ in
            guard let self else { return }
            self.queue.async {
                self.status = granted ? "ok" : "denied"
                if !granted {
                    print("⚠️  No Reminders access: System Settings → Privacy & Security → Reminders → turn on Nordpult.")
                }
                self.refresh()
            }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { [weak self] _ in
            self?.queue.async { self?.refresh() }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 2 * 60)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func snapshot() -> [String: Any] {
        queue.sync { ["status": status, "items": items, "list": listTitle] }
    }

    private func matchingLists() -> [EKCalendar] {
        store.calendars(for: .reminder).filter { lists.contains($0.title.lowercased()) }
    }

    /// Runs on `queue`.
    private func refresh() {
        guard status == "ok" || status == "nolist" else { return }
        let cals = matchingLists()
        if cals.isEmpty {
            status = "nolist"
            items = []
            print("⚠️  No reminders list named \(lists.joined(separator: ", ")). Available: \(store.calendars(for: .reminder).map { $0.title }.sorted().joined(separator: ", "))")
            return
        }
        status = "ok"
        listTitle = cals.map { $0.title }.joined(separator: ", ")
        let pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        let sem = DispatchSemaphore(value: 0)
        var found: [EKReminder] = []
        store.fetchReminders(matching: pred) { r in found = r ?? []; sem.signal() }
        _ = sem.wait(timeout: .now() + 20)
        let cal = Foundation.Calendar.current
        items = found.compactMap { r -> [String: Any]? in
            let title = (r.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            var o: [String: Any] = ["id": r.calendarItemIdentifier, "title": title, "color": Agenda.hex(r.calendar?.color)]
            if let dc = r.dueDateComponents, let d = cal.date(from: dc) {
                o["due"] = d.timeIntervalSince1970 * 1000
                o["allDay"] = dc.hour == nil
            }
            if r.priority > 0 && r.priority <= 4 { o["prio"] = true }
            return o
        }.sorted { a, b in
            let x = a["due"] as? Double ?? .greatestFiniteMagnitude, y = b["due"] as? Double ?? .greatestFiniteMagnitude
            return x == y ? (a["title"] as! String) < (b["title"] as! String) : x < y
        }
    }

    /// Marks a reminder done (syncs to iPhone etc. via iCloud).
    func complete(_ id: String, _ done: @escaping (Bool) -> Void) {
        queue.async {
            guard self.status == "ok", let r = self.store.calendarItem(withIdentifier: id) as? EKReminder,
                  let cal = r.calendar, self.lists.contains(cal.title.lowercased()) else { return done(false) }
            r.isCompleted = true
            do {
                try self.store.save(r, commit: true)
                self.items.removeAll { ($0["id"] as? String) == id }
                done(true)
            } catch {
                print("⚠️  Could not complete reminder: \(error.localizedDescription)")
                done(false)
            }
        }
    }

    func openApp() {
        DispatchQueue.main.async {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
        }
    }
}
