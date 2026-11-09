import AppKit
import ApplicationServices
import SystemConfiguration

// MARK: Options

struct Options {
    var port: UInt16 = 8045                // http = port, https = port+2, secure WebSocket = port+3
    var micDevice = "BlackHole"            // output device that receives a modern iPhone's mic
    var lat = 50.94, lon = 6.96            // weather location (default: Köln)
    var place = "Köln"                     // name shown on the weather widget
    var calendars: [String] = []           // only show these calendars (empty = all)
    var theme = ""                         // page look for this account, e.g. "privat"
    var asanaWorkspace = ""                // Asana workspace name (part); empty = the first one
    var mailFlag: String? = nil            // Apple Mail flag colour to show (work theme: orange); "aus" = off
    var reminders: [String] = []           // reminder lists to show (work theme: same names as --calendar)

    init(_ args: [String]) {
        var it = args.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--port": port = UInt16(it.next() ?? "") ?? port
            case "--mic-device": micDevice = it.next() ?? micDevice
            case "--lat": lat = Double(it.next() ?? "") ?? lat
            case "--lon": lon = Double(it.next() ?? "") ?? lon
            case "--place": place = it.next() ?? place
            case "--calendar": if let c = it.next() { calendars.append(c) }
            case "--theme": theme = (it.next() ?? "").lowercased()
            case "--asana-workspace": asanaWorkspace = it.next() ?? ""
            case "--reminders": if let r = it.next() { reminders.append(r) }
            case "--mail-flag": mailFlag = it.next()
            case "-h", "--help":
                print("""
                Nordpult: Bedienpult fürs iPad, gesteuert vom Mac
                  --port N          HTTP port (default 8045; HTTPS uses N+2, WebSocket N+3)
                  --mic-device NAME audio device that receives the phone's mic (default BlackHole)
                  --lat N --lon N   weather location (default Köln: 50.94, 6.96)
                  --place NAME      place name shown on the weather widget (default Köln)
                  --calendar NAME   only show this calendar (repeat for more; default: all)
                  --theme NAME      look of the deck for this account: work or privat (default: standard)
                  --reminders NAME  show this Reminders list (repeat for more; work theme: the --calendar names)
                  --mail-flag FARBE show Apple Mail inbox mails with this flag colour (work theme: orange; "aus" = off)
                """)
                exit(0)
            default: print("Unknown option \(a) (try --help)"); exit(2)
            }
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let opts = Options(CommandLine.arguments)
let configDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".nordpult")
// Umzug vom alten Namen: Einstellungen (App-Tasten, Asana-Token, Zertifikat) einmalig übernehmen.
do {
    let legacy = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".oldphonedeck")
    let fm = FileManager.default
    if !fm.fileExists(atPath: configDir.path), fm.fileExists(atPath: legacy.path) {
        try? fm.copyItem(at: legacy, to: configDir)
        try? fm.removeItem(at: configDir.appendingPathComponent("log.txt"))
        print("Einstellungen aus ~/.oldphonedeck übernommen.")
    }
}

// MARK: Access token (anyone on the Wi-Fi could otherwise open apps on your Mac)

func loadToken() -> String {
    // Mehrere Konten: gemeinsamer Code in /Users/Shared/Nordpult (gleicher iPad-Link für alle Konten).
    // Einzelplatz: der Code liegt im eigenen Benutzerordner (~/.nordpult/token).
    for path in ["/Users/Shared/Nordpult/token", "/Users/Shared/oldphonedeck/token"] {
        let shared = URL(fileURLWithPath: path)
        if let t = try? String(contentsOf: shared, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
    }
    let file = configDir.appendingPathComponent("token")
    if let t = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
        return t
    }
    let t = (0..<12).map { _ in String("abcdefghjkmnpqrstuvwxyz23456789".randomElement()!) }.joined()
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try? t.write(to: file, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return t
}

func lanAddress() -> String {
    var addr = "localhost"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return addr }
    defer { freeifaddrs(ifaddr) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let i = p.pointee
        guard i.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: i.ifa_name)
        guard name.hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(i.ifa_addr, socklen_t(i.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        addr = String(cString: host)
        if name == "en0" { break }
    }
    return addr
}

// MARK: Several macOS accounts: only the account at the screen runs the deck

/// True when this process's user is the one currently at the screen (fast user switching aware).
func isActiveUser() -> Bool {
    var uid: uid_t = 0
    guard SCDynamicStoreCopyConsoleUser(nil, &uid, nil) != nil else { return false }
    return uid == getuid()
}

/// Modification date of our own executable; when an update replaces it, we restart to pick it up.
let exePath = Bundle.main.executablePath ?? CommandLine.arguments[0]
func exeDate() -> Date? { (try? FileManager.default.attributesOfItem(atPath: exePath))?[.modificationDate] as? Date }
let startedExeDate = exeDate()

if !isActiveUser() {
    print("Another account is at the screen; waiting until this one is active …")
    while !isActiveUser() {
        if exeDate() != startedExeDate { exit(0) }      // updated meanwhile: restart into the new version
        Thread.sleep(forTimeInterval: 2)
    }
    Thread.sleep(forTimeInterval: 3)                    // let the other account's deck release the ports
}

let token = loadToken()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MARK: Services

let server: HTTPServer
do { server = try HTTPServer(port: opts.port) } catch { print("Cannot listen on \(opts.port): \(error)"); exit(1) }

// Camera + mic from a modern iPhone (browser, over the secure WebSocket).
var cameraViewers: [ObjectIdentifier: HTTPConnection] = [:]   // touched only on server.queue
let phoneMedia = PhoneMediaServer(token: token, audio: AudioOut(deviceMatch: opts.micDevice))
phoneMedia.onFrame = { jpeg in
    server.queue.async { for v in cameraViewers.values { v.pushFrame(jpeg) } }
}

let stats = Stats()
stats.start()
let music = Music()
music.start()
let weather = Weather(lat: opts.lat, lon: opts.lon, place: opts.place)
weather.start()
let aurora = Aurora(lat: opts.lat, lon: opts.lon)
aurora.start()
let asana = AsanaTasks(configDir: configDir, workspace: opts.asanaWorkspace)
asana.start()
let agenda = Agenda(only: opts.calendars)
agenda.start()
let reminders = Reminders(lists: !opts.reminders.isEmpty ? opts.reminders : (opts.theme == "work" ? opts.calendars : []))
reminders.start()
let flaggedMail = FlaggedMail(colour: opts.mailFlag ?? (opts.theme == "work" ? "orange" : nil))
flaggedMail.start()

// MARK: Routes

let webRoot = Bundle.module.url(forResource: "web", withExtension: nil)!

let routes: (HTTPRequest, HTTPConnection) -> Void = { req, conn in
    // Public: the page shell (so a home-screen bookmark loads) and the local CA as an iOS profile.
    if req.path == "/nordpult.mobileconfig" {
        guard let der = try? Data(contentsOf: LocalTLS.caDER) else { return conn.respond(404, text: "no certificate yet") }
        let cert: [String: Any] = [
            "PayloadType": "com.apple.security.root", "PayloadVersion": 1,
            "PayloadIdentifier": "com.nordpult.ca.cert", "PayloadUUID": "6F1C2A4E-2B7D-4C5A-9E1F-50A1C0DEC0A1",
            "PayloadDisplayName": "Nordpult CA", "PayloadCertificateFileName": "nordpult-ca.cer", "PayloadContent": der,
        ]
        let profile: [String: Any] = [
            "PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": "com.nordpult.ca", "PayloadUUID": "3B8E9D10-7C2F-4E61-A5B3-50A1C0DEC0A2",
            "PayloadDisplayName": "Nordpult", "PayloadOrganization": "Nordpult",
            "PayloadDescription": "Lets this iPhone open Nordpult on your Mac over HTTPS (needed for camera, mic and voice).",
            "PayloadContent": [cert],
        ]
        let data = (try? PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)) ?? Data()
        return conn.respond(200, "application/x-apple-aspen-config", data)
    }
    if req.path == "/" || req.path == "/index.html" {
        let html = (try? Data(contentsOf: webRoot.appendingPathComponent("index.html"))) ?? Data()
        return conn.respond(200, "text/html; charset=utf-8", html)
    }
    guard req.query["k"] == token else { return conn.respond(403, text: "bad token") }
    let p = req.params

    switch (req.method, req.path) {
    case ("GET", "/info"):
        conn.respondJSON(["camera": phoneMedia.isLive])
    case ("GET", "/stats"):
        var snap = stats.snapshot()
        snap["music"] = music.snapshot()
        snap["weather"] = weather.snapshot()
        snap["calendar"] = agenda.snapshot()
        snap["reminders"] = reminders.snapshot()
        snap["mail"] = flaggedMail.snapshot()
        snap["theme"] = opts.theme
        snap["aurora"] = aurora.snapshot()
        conn.respondJSON(snap)
    case ("GET", "/asana"):
        if p["fresh"] == "1" { asana.poke() }
        conn.respondJSON(asana.snapshot())
    case ("POST", "/asana/done"):
        asana.complete(p["gid"] ?? "") { ok in
            server.queue.async { conn.respond(ok ? 200 : 500, text: ok ? "ok" : "failed") }
        }
    case ("POST", "/reminders/done"):
        reminders.complete(p["id"] ?? "") { ok in
            server.queue.async { conn.respond(ok ? 200 : 500, text: ok ? "ok" : "failed") }
        }
    case ("POST", "/mail/open"):
        if let id = Int(p["id"] ?? "") { flaggedMail.open(id) }
        conn.respond(text: "ok")
    case ("POST", "/reminders/open"):
        reminders.openApp()
        conn.respond(text: "ok")
    case ("POST", "/asana/read"):
        asana.markRead(p["nid"] ?? "") { ok in
            server.queue.async { conn.respond(ok ? 200 : 500, text: ok ? "ok" : "failed") }
        }
    case ("POST", "/asana/open"):
        asana.open(p["gid"] ?? "")
        conn.respond(text: "ok")
    case ("POST", "/speedtest"):
        stats.runSpeedTest()
        conn.respond(text: "ok")
    case ("POST", "/media"):
        let cmd = p["cmd"] ?? ""
        if cmd == "open" { DispatchQueue.global().async { music.openPlayer() } } else { music.control(cmd) }
        conn.respond(text: "ok")
    case ("GET", "/artwork"):
        guard let art = music.artwork() else { return conn.respond(404, text: "no artwork") }
        conn.respond(200, "image/jpeg", art)
    case ("GET", "/launcher"):
        let selected: Any = Launcher.selected() ?? NSNull()
        conn.respondJSON(["selected": selected, "all": Apps.list()])
    case ("POST", "/launcher"):
        // Body: paths=<path>\n<path>\n… in display order.
        let paths = (p["paths"] ?? "").split(separator: "\n").map(String.init)
        do { conn.respondJSON(["saved": try Launcher.save(paths)]) }
        catch { conn.respond(500, text: error.localizedDescription) }
    case ("GET", "/icon"):
        let path = p["path"] ?? ""
        guard Apps.isKnown(path) else { return conn.respond(404, text: "unknown app") }
        DispatchQueue.main.async {
            let png = Apps.icon(path) ?? Data()
            server.queue.async { conn.respond(200, "image/png", png) }
        }
    case ("POST", "/launch"):
        let path = p["path"] ?? ""
        guard Apps.isKnown(path) else { return conn.respond(404, text: "unknown app") }
        DispatchQueue.main.async { Apps.launch(path) }
        conn.respond(text: "ok")
    case ("POST", "/claude"):
        let text = (p["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            if text.isEmpty { Claude.focus() } else { Claude.ask(text, autoSend: p["send"] == "1") }
        }
        conn.respond(text: "ok")
    case ("GET", "/camera.mjpg"):
        let id = ObjectIdentifier(conn)
        conn.onClose = { server.queue.async { cameraViewers[id] = nil } }
        cameraViewers[id] = conn
        conn.beginMJPEG()
        if let last = phoneMedia.latestFrame { conn.pushFrame(last) }
    case ("GET", "/camera.jpg"):
        conn.respond(200, "image/jpeg", phoneMedia.latestFrame ?? Data())
    default:
        conn.respond(404, text: "not found")
    }
}
server.start(routes)

// HTTPS + secure WebSocket for modern iPhones (Safari needs a secure page for camera, mic and speech).
let lanIP = lanAddress()
var httpsServer: HTTPServer?
if let identity = LocalTLS.identity(for: lanIP) {
    do {
        let s = try HTTPServer(port: opts.port + 2, parameters: LocalTLS.parameters(identity), queue: server.queue)
        s.start(routes)
        httpsServer = s
        try phoneMedia.startWebSocket(port: opts.port + 3, identity: identity)
    } catch { print("⚠️  HTTPS failed to start: \(error)") }
}

// MARK: Permissions + start

// Take note was removed, so no Accessibility permission is needed any more.

print("""

Nordpult is running. On the phone (same Wi-Fi), open Safari and go to:

    http://\(lanIP):\(opts.port)/#k=\(token)

Then tap Share → Add to Home Screen. Hold any key to choose your apps.

Modern iPhone (voice, camera, mic): once, open http://\(lanIP):\(opts.port)/nordpult.mobileconfig,
install it, enable it in Settings → General → About → Certificate Trust Settings,
then use https://\(lanIP):\(opts.port + 2)/#k=\(token)
Camera for OBS (Media Source): http://localhost:\(opts.port)/camera.mjpg?k=\(token)
Ctrl-C to quit.

""")

// Hand the deck over when someone else switches in (launchd restarts us, and we wait above).
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    if !isActiveUser() { print("Another account switched in; handing over the deck."); exit(0) }
    if exeDate() != startedExeDate { print("Updated; restarting."); exit(0) }
}

signal(SIGINT) { _ in exit(0) }
app.run()
