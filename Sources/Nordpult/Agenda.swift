import AppKit
import EventKit

/// Upcoming events from the Mac's Calendar (every calendar it syncs, iCloud included), for the deck.
/// Needs Calendar permission; macOS asks once ("Nordpult" would like to access your calendars).
final class Agenda {
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "agenda")
    private var events: [[String: Any]] = []
    private var status = "pending"            // pending | ok | denied | nocal
    private var onlyTitle = ""
    private var timer: DispatchSourceTimer?
    private let only: [String]                // calendar names to show; empty = all

    init(only: [String] = []) { self.only = only.map { $0.lowercased() } }

    func start() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            guard let self else { return }
            self.queue.async {
                self.status = granted ? "ok" : "denied"
                if !granted {
                    print("⚠️  No Calendar access: System Settings → Privacy & Security → Calendars → turn on Nordpult.")
                }
                self.refresh()
            }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: nil) { [weak self] _ in
            self?.queue.async { self?.refresh() }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 60, repeating: 5 * 60)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func snapshot() -> [String: Any] {
        queue.sync { ["status": status, "events": events, "only": only.isEmpty ? "" : onlyTitle] }
    }

    /// Runs on `queue`.
    private func refresh() {
        guard status == "ok" || status == "nocal" else { return }
        status = "ok"
        let cal = Foundation.Calendar.current
        let now = Date()
        guard let end = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: now)) else { return }
        var calendars: [EKCalendar]? = nil
        if !only.isEmpty {
            let all = store.calendars(for: .event)
            let match = all.filter { only.contains($0.title.lowercased()) }
            onlyTitle = match.map { $0.title }.joined(separator: ", ")
            if match.isEmpty {
                status = "nocal"
                print("⚠️  No calendar named \(only.joined(separator: ", ")). Available: \(all.map { $0.title }.sorted().joined(separator: ", "))")
                events = []
                return
            }
            calendars = match
        }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: calendars)
        let found = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .sorted { $0.startDate < $1.startDate }
        events = found.prefix(8).map { ev in
            [
                "title": ev.title ?? "",
                "start": ev.startDate.timeIntervalSince1970 * 1000,
                "end": ev.endDate.timeIntervalSince1970 * 1000,
                "allDay": ev.isAllDay,
                "color": Agenda.hex(ev.calendar?.color),
            ]
        }
    }

    static func hex(_ color: NSColor?) -> String {
        guard let c = color?.usingColorSpace(.sRGB) else { return "#8e8e93" }
        return String(format: "#%02x%02x%02x",
                      Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
