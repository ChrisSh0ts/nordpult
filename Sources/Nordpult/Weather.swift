import AppKit

/// Weather for the deck, from MET Norway (the data behind yr.no). Free and keyless, but MET asks every
/// client to send an identifying User-Agent and not to poll more often than needed; every 30 min is plenty.
final class Weather {
    private let queue = DispatchQueue(label: "weather")
    private var current: [String: Any] = [:]
    private var sun: [String: Any] = [:]        // "rise"/"set" as "HH:mm", from MET's sunrise API
    private var moon: [String: Any] = [:]       // "moonPhase" (0–360°, 180 = full), "moonrise"/"moonset" as "HH:mm"
    private var timer: DispatchSourceTimer?
    let lat: Double, lon: Double, place: String

    init(lat: Double, lon: Double, place: String) {
        self.lat = lat; self.lon = lon; self.place = place
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3, repeating: 30 * 60)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
        // After the Mac wakes up, fetch fresh data instead of showing last night's.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 15) { [weak self] in self?.refresh() }
        }
    }

    func snapshot() -> [String: Any] {
        queue.sync { current.isEmpty ? [:] : current.merging(sun) { a, _ in a }.merging(moon) { a, _ in a } }
    }

    private func refresh() {
        let s = String(format: "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=%.4f&lon=%.4f", lat, lon)
        guard let u = URL(string: s) else { return }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("Nordpult/1.0 github.com/GLAUCOMA82/oldphonedeck", forHTTPHeaderField: "User-Agent")
        refreshSun()
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let parsed = Weather.parse(data, place: self.place) else {
                print("⚠️  Weather update failed: \(err?.localizedDescription ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"); retrying in 1 min")
                // Don't wait half an hour after a failure (e.g. Wi-Fi not up yet after a restart).
                self.queue.asyncAfter(deadline: .now() + 60) { [weak self] in self?.refresh() }
                return
            }
            self.queue.async { self.current = parsed }
            print("Weather updated.")
        }.resume()
    }

    /// Sunrise and sunset for today (MET sunrise 3.0). Times come back in our own UTC offset.
    private func refreshSun() {
        refreshMoon()
        let secs = TimeZone.current.secondsFromGMT()
        let offset = String(format: "%@%02d:%02d", secs < 0 ? "-" : "+", abs(secs) / 3600, abs(secs) % 3600 / 60)
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        var comps = URLComponents(string: "https://api.met.no/weatherapi/sunrise/3.0/sun")!
        comps.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", lat)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", lon)),
            URLQueryItem(name: "date", value: day.string(from: Date())),
            URLQueryItem(name: "offset", value: offset),
        ]
        guard let u = comps.url else { return }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("Nordpult/1.0 github.com/GLAUCOMA82/oldphonedeck", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let props = root["properties"] as? [String: Any] else { return }
            func hhmm(_ key: String) -> String? {
                // "2026-11-04T08:21+01:00" → "08:21"
                guard let t = (props[key] as? [String: Any])?["time"] as? String,
                      let r = t.range(of: "T") else { return nil }
                return String(t[r.upperBound...].prefix(5))
            }
            var s: [String: Any] = [:]
            if let r = hhmm("sunrise") { s["rise"] = r }
            if let st = hhmm("sunset") { s["set"] = st }
            self.queue.async { self.sun = s }
        }.resume()
    }

    /// Moon phase, moonrise and moonset for today (MET sunrise 3.0, /moon). A bright moon washes out faint aurora.
    private func refreshMoon() {
        let secs = TimeZone.current.secondsFromGMT()
        let offset = String(format: "%@%02d:%02d", secs < 0 ? "-" : "+", abs(secs) / 3600, abs(secs) % 3600 / 60)
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        var comps = URLComponents(string: "https://api.met.no/weatherapi/sunrise/3.0/moon")!
        comps.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", lat)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", lon)),
            URLQueryItem(name: "date", value: day.string(from: Date())),
            URLQueryItem(name: "offset", value: offset),
        ]
        guard let u = comps.url else { return }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("Nordpult/1.0 github.com/GLAUCOMA82/oldphonedeck", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let props = root["properties"] as? [String: Any] else { return }
            func hhmm(_ key: String) -> String? {
                guard let t = (props[key] as? [String: Any])?["time"] as? String,
                      let r = t.range(of: "T") else { return nil }
                return String(t[r.upperBound...].prefix(5))
            }
            var m: [String: Any] = [:]
            if let p = props["moonphase"] as? Double { m["moonPhase"] = p }
            if let r = hhmm("moonrise") { m["moonrise"] = r }
            if let st = hhmm("moonset") { m["moonset"] = st }
            self.queue.async { self.moon = m }
        }.resume()
    }

    static func compass(_ deg: Double) -> String {
        let names = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        return names[Int((deg.truncatingRemainder(dividingBy: 360) + 382.5) / 45) % 8]
    }

    /// Wind chill (felt temperature) for cold, windy weather; otherwise the air temperature.
    static func feelsLike(_ t: Double, wind ms: Double) -> Double {
        let v = ms * 3.6
        guard t <= 10, v > 4.8 else { return t }
        let p = pow(v, 0.16)
        return 13.12 + 0.6215 * t - 11.37 * p + 0.3965 * t * p
    }

    /// Parses MET's JSON. If the response arrived cut off (seen in the wild: HTTP 200 but truncated body),
    /// keep every complete hour: cut before the last `,{"time":` and close the array and objects.
    static func decode(_ json: Data) -> [String: Any]? {
        if let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] { return root }
        guard let text = String(data: json, encoding: .utf8),
              let cut = text.range(of: ",{\"time\":", options: .backwards) else { return nil }
        let repaired = String(text[..<cut.lowerBound]) + "]}}"
        guard let root = try? JSONSerialization.jsonObject(with: Data(repaired.utf8)) as? [String: Any] else { return nil }
        print("Weather: response was cut off after \(json.count) bytes; using the complete hours.")
        return root
    }

    static func parse(_ json: Data, place: String) -> [String: Any]? {
        guard let root = decode(json),
              let props = root["properties"] as? [String: Any],
              let series = props["timeseries"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        let hourFmt = DateFormatter()
        hourFmt.dateFormat = "HH"
        let cutoff = Date().addingTimeInterval(-3600)

        // Forecast steps from the current hour onwards.
        let upcoming: [(Date, [String: Any])] = series.compactMap { entry -> (Date, [String: Any])? in
            guard let ts = entry["time"] as? String, let date = iso.date(from: ts),
                  let d = entry["data"] as? [String: Any], date > cutoff else { return nil }
            return (date, d)
        }
        guard let first = upcoming.first else { return nil }

        func instant(_ d: [String: Any]) -> [String: Any] {
            ((d["instant"] as? [String: Any])?["details"] as? [String: Any]) ?? [:]
        }
        func symbol(_ d: [String: Any]) -> String {
            for k in ["next_1_hours", "next_6_hours", "next_12_hours"] {
                if let s = ((d[k] as? [String: Any])?["summary"] as? [String: Any])?["symbol_code"] as? String { return s }
            }
            return ""
        }

        let now = instant(first.1)
        var out: [String: Any] = [
            "place": place,
            "temp": (now["air_temperature"] as? Double) ?? 0,
            "wind": (now["wind_speed"] as? Double) ?? 0,
            "symbol": symbol(first.1),
            "at": Date().timeIntervalSince1970 * 1000,
        ]
        let temp = (now["air_temperature"] as? Double) ?? 0
        let wind = (now["wind_speed"] as? Double) ?? 0
        out["feels"] = Weather.feelsLike(temp, wind: wind)
        if let c = now["cloud_area_fraction"] as? Double { out["clouds"] = c }
        if let dir = now["wind_from_direction"] as? Double { out["windDir"] = Weather.compass(dir) }
        if let next6 = first.1["next_6_hours"] as? [String: Any],
           let det = next6["details"] as? [String: Any],
           let mm = det["precipitation_amount"] as? Double {
            out["precip6"] = mm
        }
        // Lowest/highest temperature for the rest of today.
        let cal = Foundation.Calendar.current
        let todays = upcoming.filter { cal.isDateInToday($0.0) }.compactMap { instant($0.1)["air_temperature"] as? Double }
        if let lo = todays.min(), let hi = todays.max() { out["min"] = lo; out["max"] = hi }
        if let next1 = first.1["next_1_hours"] as? [String: Any],
           let det = next1["details"] as? [String: Any],
           let mm = det["precipitation_amount"] as? Double {
            out["precip"] = mm
        }

        // Three small columns: in 3, 6 and 9 hours.
        var forecast: [[String: Any]] = []
        for step in [3.0, 6.0, 9.0] {
            let target = first.0.addingTimeInterval(step * 3600)
            if let e = upcoming.first(where: { $0.0 >= target }) {
                forecast.append([
                    "h": hourFmt.string(from: e.0),
                    "t": (instant(e.1)["air_temperature"] as? Double) ?? 0,
                    "s": symbol(e.1),
                ])
            }
        }
        out["forecast"] = forecast

        // Detail page: humidity/pressure now, the next 24 hours, and day summaries.
        if let h = now["relative_humidity"] as? Double { out["humidity"] = h }
        if let p = now["air_pressure_at_sea_level"] as? Double { out["pressure"] = p }
        func rain1(_ d: [String: Any]) -> Double? {
            ((d["next_1_hours"] as? [String: Any])?["details"] as? [String: Any])?["precipitation_amount"] as? Double
        }
        func rain6(_ d: [String: Any]) -> Double? {
            ((d["next_6_hours"] as? [String: Any])?["details"] as? [String: Any])?["precipitation_amount"] as? Double
        }
        var hourly: [[String: Any]] = []
        for e in upcoming.prefix(25) {
            let d = instant(e.1)
            var h: [String: Any] = ["t": e.0.timeIntervalSince1970 * 1000,
                                    "temp": (d["air_temperature"] as? Double) ?? 0, "s": symbol(e.1)]
            if let w = d["wind_speed"] as? Double { h["wind"] = w }
            if let c = d["cloud_area_fraction"] as? Double { h["clouds"] = c }
            if let r = rain1(e.1) { h["rain"] = r }
            hourly.append(h)
        }
        out["hourly"] = hourly

        var order: [Date] = []
        var agg: [Date: [String: Any]] = [:]
        for (date, d) in upcoming {
            guard let t = instant(d)["air_temperature"] as? Double else { continue }
            let day = cal.startOfDay(for: date)
            var a = agg[day] ?? ["lo": t, "hi": t, "rain": 0.0, "t": day.timeIntervalSince1970 * 1000, "dist": 99]
            if agg[day] == nil { order.append(day) }
            a["lo"] = min((a["lo"] as? Double) ?? t, t)
            a["hi"] = max((a["hi"] as? Double) ?? t, t)
            // Hourly steps carry 1-hour rain; further out MET only has 6-hour steps.
            if let r = rain1(d) { a["rain"] = ((a["rain"] as? Double) ?? 0) + r }
            else if let r = rain6(d) { a["rain"] = ((a["rain"] as? Double) ?? 0) + r }
            let dist = abs(cal.component(.hour, from: date) - 13)          // symbol around midday
            if dist < ((a["dist"] as? Int) ?? 99) { a["s"] = symbol(d); a["dist"] = dist }
            agg[day] = a
        }
        out["daily"] = order.prefix(7).compactMap { day -> [String: Any]? in
            guard var a = agg[day] else { return nil }
            a.removeValue(forKey: "dist")
            return a
        }
        return out
    }
}
