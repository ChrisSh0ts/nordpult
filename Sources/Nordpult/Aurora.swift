import AppKit

/// Northern-lights outlook from NOAA's Space Weather Prediction Center (free, no key):
///  - OVATION: short-term (≈30–90 min) aurora probability on a 1° grid
///  - Planetary Kp forecast in 3-hour steps for the next days
/// The page combines this with the cloud cover from MET and the time of sunset/sunrise.
final class Aurora {
    private let queue = DispatchQueue(label: "aurora")
    private var current: [String: Any] = [:]
    private var timer: DispatchSourceTimer?
    let lat: Double, lon: Double

    init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 15 * 60)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 20) { [weak self] in self?.refresh() }
        }
    }

    func snapshot() -> [String: Any] { queue.sync { current } }

    private func get(_ url: String, _ done: @escaping (Any?) -> Void) {
        guard let u = URL(string: url) else { return done(nil) }
        var req = URLRequest(url: u, timeoutInterval: 30)
        req.setValue("Nordpult/1.0 (home dashboard)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200 else { return done(nil) }
            done(try? JSONSerialization.jsonObject(with: data))
        }.resume()
    }

    private func refresh() {
        get("https://services.swpc.noaa.gov/json/ovation_aurora_latest.json") { [weak self] json in
            guard let self else { return }
            let prob = self.ovation(json)
            self.get("https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json") { [weak self] json in
                guard let self else { return }
                let kp = Aurora.kp(json)
                self.queue.async {
                    var out: [String: Any] = ["at": Date().timeIntervalSince1970 * 1000]
                    if let prob { out["prob"] = prob }
                    if let now = kp.now { out["kpNow"] = now }
                    if let max = kp.max12 { out["kpMax"] = max }
                    if !kp.blocks.isEmpty { out["kp"] = kp.blocks }
                    if out.count > 1 { self.current = out } else { print("⚠️  Aurora update failed; retrying in 15 min") }
                }
            }
        }
    }

    /// Highest probability from our grid cell up to 3° further north: aurora low on the
    /// northern horizon is still visible from here.
    private func ovation(_ json: Any?) -> Int? {
        guard let root = json as? [String: Any], let coords = root["coordinates"] as? [[Any]] else { return nil }
        var lonI = Int(lon.rounded()) % 360
        if lonI < 0 { lonI += 360 }
        let latI = Int(lat.rounded())
        var best: Int?
        for c in coords where c.count >= 3 {
            guard let x = (c[0] as? NSNumber)?.intValue, let y = (c[1] as? NSNumber)?.intValue,
                  let p = (c[2] as? NSNumber)?.intValue else { continue }
            if abs(x - lonI) <= 1, y >= latI, y <= latI + 3 { best = max(best ?? 0, p) }
        }
        return best
    }

    /// Kp for the current 3-hour block and the highest Kp in the next 12 hours.
    /// Accepts both the older table format ([[header…], [row…]]) and a list of objects.
    static func kp(_ json: Any?) -> (now: Double?, max12: Double?, blocks: [[Double]]) {
        var rows: [(Date, Double)] = []
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        func date(_ s: String) -> Date? {
            for f in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
                fmt.dateFormat = f
                if let d = fmt.date(from: String(s.prefix(19))) { return d }
            }
            return nil
        }
        func number(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }
        if let table = json as? [[Any]], let header = table.first as? [String],
           let ti = header.firstIndex(of: "time_tag"), let ki = header.firstIndex(of: "kp") {
            for r in table.dropFirst() where r.count > max(ti, ki) {
                if let s = r[ti] as? String, let d = date(s), let k = number(r[ki]) { rows.append((d, k)) }
            }
        } else if let list = json as? [[String: Any]] {
            for r in list {
                if let s = r["time_tag"] as? String, let d = date(s), let k = number(r["kp"] ?? r["Kp"]) { rows.append((d, k)) }
            }
        }
        guard !rows.isEmpty else { return (nil, nil, []) }
        let now = Date()
        let current = rows.last { $0.0 <= now }?.1
        let soon = rows.filter { $0.0 > now.addingTimeInterval(-3 * 3600) && $0.0 <= now.addingTimeInterval(12 * 3600) }.map { $0.1 }
        // 3-hour blocks from the current one up to 48 h ahead, as [start ms, Kp], for "best time tonight".
        let blocks = rows.filter { $0.0 > now.addingTimeInterval(-3 * 3600) && $0.0 <= now.addingTimeInterval(48 * 3600) }
            .map { [$0.0.timeIntervalSince1970 * 1000, $0.1] }
        return (current, soon.max(), blocks)
    }
}
