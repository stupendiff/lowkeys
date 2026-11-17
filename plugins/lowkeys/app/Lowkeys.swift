// Lowkeys: a typewriter writing mode that lives in the menu bar.
//
// One file, built by build.sh with swiftc (no Xcode project). This shell
// owns everything macOS is strict about: the menu bar item, the full-screen
// window, every keystroke, the sounds, the global hotkey, the files and the
// PDF. The paper itself is a web page (web/page.html) that only draws; keys
// reach it through window.lk and it answers through one message handler.
//
// There is no text field anywhere, on purpose: with nothing to type into,
// paste and dictation have no target, and the mouse has nothing to click.

import AppKit
import WebKit
import AVFoundation
import Carbon.HIToolbox

let bundleID = "com.stupendiff.lowkeys"
let askOpen = "com.stupendiff.lowkeys.open"
let askReload = "com.stupendiff.lowkeys.reload"
let askQuit = "com.stupendiff.lowkeys.quit"

// MARK: - Where things are

enum Paths {
    static let env = ProcessInfo.processInfo.environment
    static let home: URL = {
        if let h = env["LOWKEYS_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/lowkeys")
    }()
    static let logs: URL = {
        if let h = env["LOWKEYS_LOGS"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/lowkeys")
    }()
    static var config: URL { home.appendingPathComponent("config.json") }
    static var state: URL { home.appendingPathComponent("state.json") }
    /// Present while the page is open, so an update never restarts the app mid-sentence.
    static var lock: URL { home.appendingPathComponent("writing.lock") }
    static var resources: URL { Bundle.main.resourceURL ?? URL(fileURLWithPath: ".") }
}

func expand(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
}

func note(_ s: String) {
    let f = ISO8601DateFormatter()
    let line = "\(f.string(from: Date())) \(s)\n"
    try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
    let url = Paths.logs.appendingPathComponent("lowkeys.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

func readJSON(_ url: URL) -> [String: Any] {
    guard let d = try? Data(contentsOf: url),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

func writeJSON(_ obj: [String: Any], to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
        try? d.write(to: url, options: .atomic)
    }
}

/// A Swift string as a JavaScript literal.
func js(_ s: String) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: [s]),
          let t = String(data: d, encoding: .utf8) else { return "\"\"" }
    return String(t.dropFirst().dropLast())
}

// MARK: - Settings (config.json, written by scripts/lowkeys.py)

struct Config {
    var saveDir = expand("~/Documents/Lowkeys")
    var hotkey = "ctrl+opt+l"
    var goal: [String: Any]? = nil
    var sounds = true
    var soundsDir: URL? = nil
    var volume: Float = 0.8
    var font: String? = nil
    var margin = 62

    static func load() -> Config {
        var c = Config()
        let j = readJSON(Paths.config)
        if let s = j["save_dir"] as? String, !s.isEmpty { c.saveDir = expand(s) }
        if let s = j["hotkey"] as? String { c.hotkey = s }
        if let g = j["goal"] as? [String: Any] { c.goal = g }
        if let b = j["sounds"] as? Bool { c.sounds = b }
        if let s = j["sounds_dir"] as? String, !s.isEmpty { c.soundsDir = expand(s) }
        if let v = j["volume"] as? Double { c.volume = Float(max(0, min(1, v))) }
        if let s = j["font"] as? String, !s.isEmpty { c.font = s }
        if let m = j["margin"] as? Int, m >= 20, m <= 200 { c.margin = m }
        return c
    }

    /// What the page needs to know.
    var forPage: [String: Any] {
        var d: [String: Any] = ["margin": margin]
        if let g = goal { d["goal"] = g }
        if let f = font { d["font"] = f }
        return d
    }
}

// MARK: - Sounds

/// Small pools of players so fast typing overlaps instead of cutting off.
/// A file named key3.wav belongs to the group "key"; one is picked at random.
final class Sounds {
    private var pools: [String: [AVAudioPlayer]] = [:]
    var on = true
    var volume: Float = 0.8
    private static let kinds = ["wav", "aiff", "aif", "m4a", "mp3", "caf"]

    func load(custom: URL?) {
        pools = [:]
        let bundled = Paths.resources.appendingPathComponent("sounds")
        var byGroup: [String: [URL]] = [:]
        // Bundled first, then the user's folder: a group found there replaces ours.
        for dir in [bundled, custom].compactMap({ $0 }) {
            var here: [String: [URL]] = [:]
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where Sounds.kinds.contains(f.pathExtension.lowercased()) {
                let base = f.deletingPathExtension().lastPathComponent.lowercased()
                let group = String(base.reversed().drop(while: { $0.isNumber }).reversed())
                if !group.isEmpty { here[group, default: []].append(f) }
            }
            for (g, urls) in here { byGroup[g] = urls }
        }
        for (g, urls) in byGroup {
            let copies = g == "key" || g == "space" || g == "strike" ? 3 : 2
            var pool: [AVAudioPlayer] = []
            for _ in 0..<copies {
                for u in urls {
                    if let p = try? AVAudioPlayer(contentsOf: u) { p.prepareToPlay(); pool.append(p) }
                }
            }
            pools[g] = pool
        }
    }

    func play(_ group: String) {
        guard on, let pool = pools[group], !pool.isEmpty else { return }
        var i = Int.random(in: 0..<pool.count)
        for _ in 0..<pool.count where pool[i].isPlaying { i = (i + 1) % pool.count }
        let p = pool[i]
        p.currentTime = 0
        // No two keys are hit equally hard.
        p.volume = volume * (group == "key" || group == "space" ? Float.random(in: 0.78...1) : 1)
        p.play()
    }
}

// MARK: - Global hotkey ("ctrl+opt+l")

struct Hotkey {
    var code: UInt32
    var mods: UInt32

    private static let keys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "space": kVK_Space,
    ]

    /// nil for "off", or for anything that doesn't parse.
    static func parse(_ text: String) -> Hotkey? {
        var mods: UInt32 = 0
        var code: Int? = nil
        for raw in text.lowercased().split(separator: "+") {
            switch raw.trimmingCharacters(in: .whitespaces) {
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            case let k: if let c = keys[k] { code = c } else { return nil }
            }
        }
        guard let c = code, mods != 0 else { return nil }
        return Hotkey(code: UInt32(c), mods: mods)
    }

    var shown: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        let name = Hotkey.keys.first(where: { UInt32($0.value) == code })?.key ?? "?"
        return s + (name == "space" ? "Space" : name.uppercased())
    }
}

// MARK: - PDF

/// The page as an ordinary document: readable serif, A4, real pages, text you
/// can select. No print panel: it goes straight to a file beside the .md.
func writePDF(_ text: String, to url: URL) -> Bool {
    let info = NSPrintInfo()
    info.paperSize = NSSize(width: 595, height: 842)
    info.topMargin = 80; info.bottomMargin = 80; info.leftMargin = 80; info.rightMargin = 80
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    info.isHorizontallyCentered = false
    info.isVerticallyCentered = false
    info.jobDisposition = .save
    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

    let para = NSMutableParagraphStyle()
    para.lineSpacing = 4
    para.paragraphSpacing = 9
    let font = NSFont(name: "Charter-Roman", size: 12) ?? NSFont(name: "Georgia", size: 12)
        ?? NSFont.systemFont(ofSize: 12)
    let width = info.paperSize.width - info.leftMargin - info.rightMargin
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    view.textContainerInset = .zero
    view.textContainer?.lineFragmentPadding = 0
    view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
        .font: font, .paragraphStyle: para, .foregroundColor: NSColor.black,
    ]))
    view.sizeToFit()

    let op = NSPrintOperation(view: view, printInfo: info)
    op.showsPrintPanel = false
    op.showsProgressPanel = false
    return op.run()
}

// MARK: - Windows

final class PageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// WKUserContentController holds its handler strongly; this breaks the loop.
final class Relay: NSObject, WKScriptMessageHandler {
    weak var app: Lowkeys?
    init(_ app: Lowkeys) { self.app = app }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        app?.fromPage(m.body)
    }
}

// MARK: - The app

final class Lowkeys: NSObject, NSApplicationDelegate {
    let paper = NSColor(red: 0xf3 / 255.0, green: 0xee / 255.0, blue: 0xe3 / 255.0, alpha: 1)
    let nightPaper = NSColor(red: 0x1b / 255.0, green: 0x19 / 255.0, blue: 0x17 / 255.0, alpha: 1)
    var statusItem: NSStatusItem!
    var cfg = Config.load()
    let sounds = Sounds()

    // The open page, if any.
    var win: PageWindow?
    var blanks: [NSWindow] = []
    var web: WKWebView?
    var monitor: Any?
    var cursorHidden = false
    var gen = 0                     // which page the web view is showing
    var pagePath: URL?
    var lastText = ""               // newest text heard from the page
    var written: String?            // what is on disk for this page
    var closing = false
    var cameFrom: NSRunningApplication?
    var onReady: (() -> Void)?

    var hotKeyRef: EventHotKeyRef?
    var hotKeyHandler: EventHandlerRef?
    var peekTimer: Timer?
    var peeking = false

    // The shelf (⌘O): the list of pages, then one of them to read.
    enum Mode { case writing, list, reading }
    var mode = Mode.writing
    var shelfAll: [Shelved] = []
    var shelf: [Shelved] = []       // the ones that match what has been typed
    var shelfQuery = ""
    var shelfAt = 0
    var shelfText = ""              // the page being read
    var keysShown = false
    var board = NSPasteboard.general

    var selfTest: SelfTest?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            b.image = Lowkeys.glyph()
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = "Lowkeys"
        }
        sounds.load(custom: cfg.soundsDir)
        registerHotkey()
        try? FileManager.default.removeItem(at: Paths.lock)

        NotificationCenter.default.addObserver(self, selector: #selector(wentInactive),
            name: NSApplication.didResignActiveNotification, object: nil)

        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            selfTest = SelfTest(app: self, out: URL(fileURLWithPath: args[i + 1]))
            selfTest?.run()
            return
        }
        let far = DistributedNotificationCenter.default()
        far.addObserver(self, selector: #selector(askedOpen), name: .init(askOpen), object: nil)
        far.addObserver(self, selector: #selector(askedReload), name: .init(askReload), object: nil)
        far.addObserver(self, selector: #selector(askedQuit), name: .init(askQuit), object: nil)
        if args.contains("--open") { DispatchQueue.main.async { self.openPage() } }
        note("started \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?")")
    }

    @objc func askedOpen() { openPage() }
    @objc func askedReload() { reload() }
    @objc func askedQuit() { quit() }

    func reload() {
        cfg = Config.load()
        sounds.load(custom: cfg.soundsDir)
        registerHotkey()
    }

    // MARK: Menu bar

    /// A round typewriter key with a k on it. Template image: the menu bar tints it.
    static func glyph() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 2.2, y: 2.2, width: 13.6, height: 13.6))
            ring.lineWidth = 1.3
            ring.stroke()
            let font = NSFont(name: "Courier-Bold", size: 10.5) ?? NSFont.boldSystemFont(ofSize: 10)
            let s = NSAttributedString(string: "k", attributes: [.font: font, .foregroundColor: NSColor.black])
            let z = s.size()
            s.draw(at: NSPoint(x: (18 - z.width) / 2, y: (18 - z.height) / 2 + 0.6))
            return true
        }
        img.isTemplate = true
        return img
    }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu() } else { openPage() }
    }

    func showMenu() {
        cfg = Config.load()
        let m = NSMenu()
        let hk = Hotkey.parse(cfg.hotkey).map { "   \($0.shown)" } ?? ""
        m.addItem(withTitle: "Open Lowkeys\(hk)", action: #selector(menuOpen), keyEquivalent: "").target = self
        m.addItem(withTitle: "New page", action: #selector(menuNew), keyEquivalent: "").target = self
        m.addItem(withTitle: "Show writing folder", action: #selector(menuFolder), keyEquivalent: "").target = self
        m.addItem(.separator())
        let s = m.addItem(withTitle: "Sounds", action: #selector(menuSounds), keyEquivalent: "")
        s.target = self
        s.state = cfg.sounds ? .on : .off
        m.addItem(.separator())
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        m.addItem(withTitle: "Lowkeys \(v)", action: nil, keyEquivalent: "").isEnabled = false
        m.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "").target = self
        // Attach, click, detach: a left click must keep opening the page.
        statusItem.menu = m
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func menuOpen() { openPage() }
    @objc func menuNew() { setOpenPage(nil); openPage() }
    @objc func menuFolder() {
        try? FileManager.default.createDirectory(at: cfg.saveDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(cfg.saveDir)
    }
    @objc func menuSounds() { setSounds(!cfg.sounds) }

    func setSounds(_ on: Bool) {
        var j = readJSON(Paths.config)
        j["sounds"] = on
        writeJSON(j, to: Paths.config)
        cfg = Config.load()
        sounds.on = cfg.sounds
    }

    /// ⌘D: light paper or dark. Kept between sittings.
    var dark: Bool { (readJSON(Paths.state)["theme"] as? String) == "dark" }

    func toggleTheme() {
        var j = readJSON(Paths.state)
        j["theme"] = dark ? "light" : "dark"
        writeJSON(j, to: Paths.state)
        win?.backgroundColor = dark ? nightPaper : paper
        web?.underPageBackgroundColor = dark ? nightPaper : paper
        call("lk.theme(\(js(dark ? "dark" : "light")))")
    }

    /// How big the type is, as a multiple of the usual size. Kept between sittings.
    var typeSize: Double {
        max(0.7, min(1.6, readJSON(Paths.state)["zoom"] as? Double ?? 1))
    }

    func setTypeSize(_ z: Double) {
        let to = (max(0.7, min(1.6, z)) * 10).rounded() / 10
        var j = readJSON(Paths.state)
        j["zoom"] = to
        writeJSON(j, to: Paths.state)
        call("lk.zoom(\(to))")
        call("lk.note(\(js("type \(Int((to * 100).rounded()))%")))")
    }
    @objc func quit() {
        if win != nil { closePage { NSApp.terminate(nil) } } else { NSApp.terminate(nil) }
    }

    // MARK: Hotkey

    func registerHotkey() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        guard let hk = Hotkey.parse(cfg.hotkey) else { return }
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, user in
                guard let user = user else { return noErr }
                let me = Unmanaged<Lowkeys>.fromOpaque(user).takeUnretainedValue()
                DispatchQueue.main.async { me.openPage() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        }
        let id = EventHotKeyID(signature: OSType(0x4C4B4559), id: 1)   // 'LKEY'
        let err = RegisterEventHotKey(hk.code, hk.mods, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if err != noErr { note("hotkey \(cfg.hotkey) not registered (\(err)): another app may hold it") }
    }

    // MARK: Opening the page

    func openPagePath() -> URL? {
        guard let p = readJSON(Paths.state)["open_page"] as? String, !p.isEmpty else { return nil }
        let u = URL(fileURLWithPath: p)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func setOpenPage(_ url: URL?) {
        var j = readJSON(Paths.state)
        j["open_page"] = url?.path ?? ""
        writeJSON(j, to: Paths.state)
    }

    func openPage() {
        guard win == nil, !closing else { return }
        cfg = Config.load()
        sounds.on = cfg.sounds
        sounds.volume = cfg.volume

        // Pick the page back up if one is open; otherwise start clean.
        var text = ""
        pagePath = openPagePath()
        if let p = pagePath, var t = try? String(contentsOf: p, encoding: .utf8) {
            if t.hasSuffix("\n") { t.removeLast() }   // the one we add on save
            text = t
        } else {
            pagePath = nil
        }
        lastText = text
        written = pagePath == nil ? nil : text
        gen += 1

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

        let w = PageWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.level = level
        w.isReleasedWhenClosed = false
        w.backgroundColor = dark ? nightPaper : paper
        w.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        w.acceptsMouseMovedEvents = false

        let wc = WKWebViewConfiguration()
        wc.userContentController.add(Relay(self), name: "lk")
        var forPage = cfg.forPage
        forPage["zoom"] = typeSize
        forPage["theme"] = dark ? "dark" : "light"
        let payload: [String: Any] = ["config": forPage, "text": text, "gen": gen]
        let json = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        wc.userContentController.addUserScript(WKUserScript(
            source: "window.__LK = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let v = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: wc)
        v.underPageBackgroundColor = dark ? nightPaper : paper
        v.autoresizingMask = [.width, .height]
        v.loadFileURL(Paths.resources.appendingPathComponent("web/page.html"), allowingReadAccessTo: Paths.resources)
        w.contentView = v

        // Every other display goes dark.
        for other in NSScreen.screens where other != screen {
            let b = NSWindow(contentRect: other.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            b.level = level
            b.isReleasedWhenClosed = false
            b.backgroundColor = .black
            b.ignoresMouseEvents = false
            b.orderFrontRegardless()
            blanks.append(b)
        }

        let front = NSWorkspace.shared.frontmostApplication
        cameFrom = front?.processIdentifier == getpid() ? nil : front
        win = w; web = v
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        NSCursor.hide(); cursorHidden = true
        FileManager.default.createFile(atPath: Paths.lock.path, contents: nil)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .scrollWheel,
        ]) { [weak self] ev in
            guard let self = self, self.win != nil else { return ev }
            switch ev.type {
            case .keyDown: self.keyDown(ev); return nil
            case .keyUp:
                if Int(ev.keyCode) == kVK_ANSI_Slash { self.showKeys(false) }
                return nil
            case .flagsChanged: self.flagsChanged(ev); return ev
            default: return nil          // the mouse does nothing here
            }
        }

        // If macOS wouldn't let us come forward, the keyboard isn't ours and
        // the page would just sit on top of everything. Try again, then give up.
        let opened = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, self.win != nil, self.gen == opened, !NSApp.isActive else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.win?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self = self, self.win != nil, self.gen == opened, !NSApp.isActive else { return }
                note("could not take the keyboard; closing the page")
                self.closePage(nil)
            }
        }
    }

    // MARK: Keys

    func call(_ script: String) { web?.evaluateJavaScript(script, completionHandler: nil) }

    func keyDown(_ ev: NSEvent) {
        stopPeek()
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            let k = (ev.charactersIgnoringModifiers ?? "").lowercased()
            if k != "/" && k != "?" { showKeys(false) }
            switch k {
            case "q", "w": closePage(nil)
            case "o": if mode == .writing { openShelf() } else { closeShelf() }
            case "n": if mode == .writing { newPage() } else { newFromShelf() }
            case "s" where mode == .writing: saveNow()
            case "p": if mode == .writing { printPDF() } else { printChosen() }
            case "c": copyPage()
            case "m": toggleSounds()
            case "d": toggleTheme()
            case "=", "+": setTypeSize(typeSize + 0.1)
            case "-", "_": setTypeSize(typeSize - 0.1)
            case "0": setTypeSize(1)
            case "/", "?": showKeys(true)
            default: break
            }
            return
        }
        showKeys(false)
        if mode != .writing { shelfKey(ev); return }
        switch Int(ev.keyCode) {
        case kVK_Escape: closePage(nil); return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            call("lk.ret()"); return      // the page asks for the return sound
        case kVK_Delete:
            call(mods.contains(.option) ? "lk.backWord()" : "lk.back()"); return
        case kVK_Tab:
            sounds.play("space"); call("lk.type('    ')"); return
        default: break
        }
        let typed = printable(ev)
        guard !typed.isEmpty else { return }
        sounds.play(typed == " " ? "space" : "key")
        call("lk.type(\(js(typed)))")
    }

    /// Letters only: no control codes, no arrow or function keys.
    func printable(_ ev: NSEvent) -> String {
        if ev.modifierFlags.contains(.control) { return "" }
        return String(String.UnicodeScalarView((ev.characters ?? "").unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
        }))
    }

    /// ⌘/ shows every key on the page for as long as it is held.
    func showKeys(_ on: Bool) {
        guard on != keysShown else { return }
        keysShown = on
        call("lk.keys(\(on))")
    }

    func toggleSounds() {
        setSounds(!cfg.sounds)
        sounds.play("key")
        call("lk.note(\(js(cfg.sounds ? "sounds on" : "sounds off")))")
    }

    /// ⌘C: the clean text of the page on the paper, or of the one chosen on the shelf.
    func copyPage() {
        let put: (String) -> Void = { [weak self] text in
            guard let self = self else { return }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.call("lk.note('nothing to copy yet')")
                return
            }
            self.board.clearContents()
            self.board.setString(text, forType: .string)
            self.call("lk.note('copied')")
        }
        if mode == .writing {
            pullText { [weak self] text in self?.lastText = text; put(text) }
        } else if let page = chosen() {
            put(page.text)
        }
    }

    /// Holding Option by itself for a moment shows the count; letting go hides it.
    func flagsChanged(_ ev: NSEvent) {
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !mods.contains(.command) { showKeys(false) }
        if mods == .option && mode == .writing {
            peekTimer?.invalidate()
            peekTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                self?.peeking = true
                self?.call("lk.peek(true)")
            }
        } else {
            stopPeek()
        }
    }

    func stopPeek() {
        peekTimer?.invalidate(); peekTimer = nil
        if peeking { peeking = false; call("lk.peek(false)") }
    }

    // MARK: Page → app

    func fromPage(_ body: Any) {
        guard let m = body as? [String: Any], let t = m["t"] as? String else { return }
        // A page that has since been put away may still have a message in flight.
        guard (m["gen"] as? Int) == gen else { return }
        switch t {
        case "save":
            if let text = m["text"] as? String { lastText = text; _ = save(text) }
        case "sound":
            if let n = m["n"] as? String { sounds.play(n) }
        case "ready":
            onReady?(); onReady = nil
        default: break
        }
    }

    // MARK: Saving

    func newPagePath() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let base = f.string(from: Date())
        var url = cfg.saveDir.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = cfg.saveDir.appendingPathComponent("\(base)-\(n).md"); n += 1
        }
        return url
    }

    /// Writes the page. A page with nothing on it never becomes a file.
    @discardableResult
    func save(_ text: String) -> Bool {
        if pagePath == nil {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
            pagePath = newPagePath()
            setOpenPage(pagePath)
        }
        guard let url = pagePath else { return false }
        if written == text { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
            written = text
            return true
        } catch {
            note("save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Asks the page for its text. Falls back to the last text it sent if the
    /// page doesn't answer, so closing can never lose words or hang.
    func pullText(_ script: String = "lk.text()", _ done: @escaping (String) -> Void) {
        guard let web = web else { done(lastText); return }
        var answered = false
        let finish: (String) -> Void = { text in
            if answered { return }
            answered = true
            done(text)
        }
        web.evaluateJavaScript(script) { [weak self] r, _ in
            finish((r as? String) ?? self?.lastText ?? "")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in finish(self?.lastText ?? "") }
    }

    func saveNow() {
        pullText { [weak self] text in
            guard let self = self else { return }
            self.lastText = text
            let ok = self.save(text)
            self.call("lk.note(\(js(ok ? "saved" : (self.pagePath == nil ? "nothing to save yet" : "could not save"))))")
        }
    }

    func printPDF() {
        pullText { [weak self] text in
            guard let self = self else { return }
            self.lastText = text
            guard self.save(text), let md = self.pagePath else {
                self.call("lk.note(\(js(self.pagePath == nil ? "nothing to print yet" : "could not save")))")
                return
            }
            let pdf = md.deletingPathExtension().appendingPathExtension("pdf")
            let ok = writePDF(text, to: pdf)
            self.call("lk.note(\(js(ok ? "pdf saved" : "could not make the pdf")))")
        }
    }

    func newPage() {
        let old = gen
        gen += 1
        // fresh() hands back the old page's text and clears the paper in one
        // step, so nothing typed in between can land in the wrong file.
        pullText("lk.fresh(\(gen))") { [weak self] text in
            guard let self = self else { return }
            _ = old
            self.save(text)
            self.pagePath = nil
            self.written = nil
            self.lastText = ""
            self.setOpenPage(nil)
        }
    }

    // MARK: The shelf

    struct Shelved {
        let url: URL
        let when: String
        let text: String            // as saved, without the final newline
        let lower: String
        let first: String
        let words: Int
    }

    /// Every page in the writing folder, most recently written first.
    func pages() -> [Shelved] {
        let files = (try? FileManager.default.contentsOfDirectory(at: cfg.saveDir,
            includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var found: [(url: URL, when: Date, text: String)] = []
        for f in files where f.pathExtension.lowercased() == "md" {
            guard var t = try? String(contentsOf: f, encoding: .utf8) else { continue }
            if t.hasSuffix("\n") { t.removeLast() }
            let when = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            found.append((f, when ?? .distantPast, t))
        }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("dMMMyyyyjmm")
        return found.sorted { $0.when > $1.when }.prefix(300).map { p in
            let words = p.text.split(whereSeparator: { $0.isWhitespace })
            return Shelved(url: p.url, when: f.string(from: p.when), text: p.text, lower: p.text.lowercased(),
                first: String(words.prefix(14).joined(separator: " ").prefix(60)), words: words.count)
        }
    }

    func chosen() -> Shelved? { shelf.indices.contains(shelfAt) ? shelf[shelfAt] : nil }

    func forgetShelf() { shelfAll = []; shelf = []; shelfQuery = "" }

    func openShelf() {
        // Save first, so the page on the paper is in the list as it stands.
        pullText { [weak self] text in
            guard let self = self, self.win != nil, !self.closing, self.mode == .writing else { return }
            self.lastText = text
            self.save(text)
            let found = self.pages()
            guard !found.isEmpty else { self.call("lk.note('nothing written yet')"); return }
            self.shelfAll = found
            self.shelf = found
            self.shelfQuery = ""
            let here = self.pagePath?.standardizedFileURL.path
            self.shelfAt = found.firstIndex(where: { $0.url.standardizedFileURL.path == here }) ?? 0
            self.mode = .list
            self.drawShelf()
        }
    }

    func drawShelf() {
        let rows: [[String: Any]] = shelf.map { ["when": $0.when, "first": $0.first, "words": $0.words] }
        let json = (try? JSONSerialization.data(withJSONObject: rows))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        call("lk.shelf(\(json), \(shelfAt), \(js(shelfQuery)))")
    }

    /// Typing on the shelf keeps only the pages that hold every word typed.
    func refilter() {
        let was = chosen()?.url
        let terms = shelfQuery.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        shelf = terms.isEmpty ? shelfAll : shelfAll.filter { p in terms.allSatisfy { p.lower.contains($0) } }
        shelfAt = shelf.firstIndex(where: { $0.url == was }) ?? 0
        drawShelf()
    }

    func closeShelf() {
        mode = .writing
        forgetShelf()
        call("lk.shelfClose()")
    }

    /// ⌘N from the shelf. The page on the paper was saved when the shelf opened.
    func newFromShelf() {
        mode = .writing
        forgetShelf()
        newPage()
    }

    func moveShelf(to i: Int) {
        guard !shelf.isEmpty else { return }
        let to = max(0, min(shelf.count - 1, i))
        guard to != shelfAt else { return }
        shelfAt = to
        sounds.play("space")
        call("lk.shelfSelect(\(to))")
    }

    func shelfKey(_ ev: NSEvent) {
        let code = Int(ev.keyCode)
        if mode == .reading {
            switch code {
            case kVK_UpArrow: call("lk.readScroll('up')")
            case kVK_DownArrow: call("lk.readScroll('down')")
            case kVK_PageUp: call("lk.readScroll('pgup')")
            case kVK_PageDown, kVK_Space: call("lk.readScroll('pgdn')")
            case kVK_Home: call("lk.readScroll('home')")
            case kVK_End: call("lk.readScroll('end')")
            case kVK_Return, kVK_ANSI_KeypadEnter: writeOnChosen()
            case kVK_Escape, kVK_LeftArrow: mode = .list; call("lk.readClose()")
            default: break
            }
            return
        }
        switch code {
        case kVK_UpArrow: moveShelf(to: shelfAt - 1)
        case kVK_DownArrow: moveShelf(to: shelfAt + 1)
        case kVK_PageUp: moveShelf(to: shelfAt - 6)
        case kVK_PageDown: moveShelf(to: shelfAt + 6)
        case kVK_Home: moveShelf(to: 0)
        case kVK_End: moveShelf(to: shelf.count - 1)
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_RightArrow: readChosen()
        case kVK_Escape:
            // First Esc clears what was typed; the next one leaves the shelf.
            if shelfQuery.isEmpty { closeShelf() } else { shelfQuery = ""; refilter() }
        case kVK_Delete:
            if !shelfQuery.isEmpty { shelfQuery.removeLast(); sounds.play("strike"); refilter() }
        default:
            let typed = printable(ev)
            guard !typed.isEmpty, shelfQuery.count < 40 else { return }
            shelfQuery += typed
            sounds.play(typed == " " ? "space" : "key")
            refilter()
        }
    }

    func readChosen() {
        guard let page = chosen() else { return }
        shelfText = page.text
        mode = .reading
        sounds.play("key")
        call("lk.read(\(js(page.when)), \(js(page.text)))")
    }

    /// ⌘P on the shelf: a PDF of the chosen page, beside its text file.
    func printChosen() {
        guard let page = chosen() else { return }
        let pdf = page.url.deletingPathExtension().appendingPathExtension("pdf")
        let ok = writePDF(page.text, to: pdf)
        call("lk.note(\(js(ok ? "pdf saved" : "could not make the pdf")))")
    }

    /// Return while reading: that page goes on the paper, to carry on writing.
    func writeOnChosen() {
        guard let page = chosen() else { return }
        if page.url.standardizedFileURL.path == pagePath?.standardizedFileURL.path { closeShelf(); return }
        // The page on the paper was saved when the shelf opened and no key has
        // reached it since; this is a no-op unless that save failed.
        save(lastText)
        gen += 1
        pagePath = page.url
        written = page.text
        lastText = page.text
        setOpenPage(page.url)
        mode = .writing
        forgetShelf()
        sounds.play("return")
        call("lk.open(\(js(page.text)), \(gen))")
    }

    // MARK: Closing

    @objc func wentInactive() {
        if win != nil && selfTest == nil { closePage(nil) }
    }

    func closePage(_ then: (() -> Void)?) {
        guard win != nil, !closing else { then?(); return }
        closing = true
        stopPeek()
        pullText { [weak self] text in
            guard let self = self else { return }
            self.lastText = text
            self.save(text)
            self.tearDown()
            then?()
        }
    }

    func tearDown() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        web?.configuration.userContentController.removeAllScriptMessageHandlers()
        win?.orderOut(nil)
        win?.contentView = nil
        blanks.forEach { $0.orderOut(nil) }
        blanks = []
        win = nil; web = nil
        mode = .writing; forgetShelf(); keysShown = false
        try? FileManager.default.removeItem(at: Paths.lock)
        closing = false
        // Hand the keyboard back to whatever was in front before.
        if NSApp.isActive, let app = cameFrom, !app.isTerminated { app.activate(options: []) }
        cameFrom = nil
    }

    func applicationWillTerminate(_ n: Notification) {
        if win != nil { save(lastText); tearDown() }
    }
}

// MARK: - Self-test (--selftest <folder>)

/// Drives the real app with real key events, the way a person would, and
/// writes what happened to <folder>/report.json plus three pictures of the
/// page. Used while building; nothing in normal use reaches it.
final class SelfTest {
    unowned let app: Lowkeys
    let out: URL
    var report: [String: Any] = [:]

    init(app: Lowkeys, out: URL) { self.app = app; self.out = out }

    func after(_ s: Double, _ f: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f)
    }

    func key(_ chars: String, code: Int = 0, flags: NSEvent.ModifierFlags = []) {
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.win?.windowNumber ?? 0,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
            keyCode: UInt16(code)) else { return }
        NSApp.postEvent(ev, atStart: false)
    }

    /// Types a string a key at a time. "\u{8}" is backspace, "\n" is Return.
    func typeOut(_ s: String, gap: Double = 0.012, _ done: @escaping () -> Void) {
        let chars = Array(s)
        var i = 0
        func next() {
            if i >= chars.count { after(0.45, done); return }
            let c = chars[i]; i += 1
            if c == "\u{8}" { key("\u{7F}", code: kVK_Delete) }
            else if c == "\n" { key("\r", code: kVK_Return) }
            else { key(String(c)) }
            after(gap, next)
        }
        next()
    }

    func shot(_ name: String, _ done: @escaping () -> Void) {
        guard let web = app.web else { done(); return }
        web.takeSnapshot(with: nil) { img, _ in
            if let tiff = img?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: self.out.appendingPathComponent(name))
            }
            done()
        }
    }

    func run() {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        report["hotkey_parsed"] = Hotkey.parse(app.cfg.hotkey)?.shown ?? "none"
        report["hotkey_registered"] = app.hotKeyRef != nil
        app.onReady = { [weak self] in self?.after(0.5) { self?.typed() } }
        after(0.3) { self.app.openPage() }
        after(45) { self.finish("timed out") }
    }

    func typed() {
        report["active"] = NSApp.isActive
        report["key_window"] = app.win?.isKeyWindow ?? false
        report["screens_blanked"] = app.blanks.count
        report["lock_while_open"] = FileManager.default.fileExists(atPath: Paths.lock.path)
        let a = "It was a quiet morning and the keyz\u{8}s felt goood\u{8}\u{8}\u{8}od under"
        typeOut(a) {
            self.shot("1-midline.png") {
                let b = " my hands, so I kept going until the bell rang and the carriage came back by itself.\nA second paragraph, short."
                self.typeOut(b) {
                    self.shot("2-returned.png") { self.saveAndPrint() }
                }
            }
        }
    }

    func saveAndPrint() {
        key("s", code: kVK_ANSI_S, flags: .command)
        after(0.5) {
            self.report["file"] = self.app.pagePath?.path ?? ""
            self.report["file_text"] = (self.app.pagePath.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""
            self.key("p", code: kVK_ANSI_P, flags: .command)
            self.after(1.0) {
                if let md = self.app.pagePath {
                    let pdf = md.deletingPathExtension().appendingPathExtension("pdf")
                    let doc = CGPDFDocument(pdf as CFURL)
                    self.report["pdf"] = pdf.path
                    self.report["pdf_pages"] = doc?.numberOfPages ?? 0
                }
                self.app.call("lk.peek(true)")
                self.after(0.4) {
                    self.shot("3-peek.png") {
                        self.app.call("lk.peek(false)")
                        self.newPageThenClose()
                    }
                }
            }
        }
    }

    func newPageThenClose() {
        let first = app.pagePath
        key("n", code: kVK_ANSI_N, flags: .command)
        after(0.5) {
            self.report["after_new_no_file"] = self.app.pagePath == nil
            self.typeOut("Fresh page.") {
                self.key("\u{1B}", code: kVK_Escape)
                self.after(0.6) {
                    self.report["closed"] = self.app.win == nil
                    self.report["lock_after_close"] = FileManager.default.fileExists(atPath: Paths.lock.path)
                    let second = self.app.pagePath
                    self.report["second_file"] = second?.path ?? ""
                    self.report["second_text"] = (second.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""
                    self.report["first_untouched"] = (first.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) == (self.report["file_text"] as? String)
                    self.resume()
                }
            }
        }
    }

    /// Reopen: the page that was open should come back, and carry on cleanly.
    func resume() {
        app.onReady = { [weak self] in
            guard let self = self else { return }
            self.after(0.4) {
                self.typeOut("Back again.") { self.shelf() }
            }
        }
        app.openPage()
    }

    func textOf(_ url: URL?) -> String {
        (url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? ""
    }

    /// ⌘O: the list, find a page by its words, read it, PDF and copy it, write on.
    func shelf() {
        let second = app.pagePath
        let first = URL(fileURLWithPath: report["file"] as? String ?? "")
        app.board = NSPasteboard(name: NSPasteboard.Name("com.stupendiff.lowkeys.selftest"))
        key("o", code: kVK_ANSI_O, flags: .command)
        after(0.7) {
            self.report["shelf_rows"] = self.app.shelf.count
            self.report["shelf_starts_on_open_page"] = self.app.chosen()?.url.path == second?.path
            self.report["second_saved_before_shelf"] = self.textOf(second)
            self.typeOut("zzz") {
                self.report["find_no_match"] = self.app.shelf.isEmpty
                self.key("\u{1B}", code: kVK_Escape)        // clears the search, stays on the shelf
                self.typeOut("Quiet bell") {
                    self.report["find_one"] = self.app.mode == .list && self.app.shelf.count == 1
                        && self.app.chosen()?.url.path == first.path
                    self.shot("4-shelf.png") {
                        self.key("\r", code: kVK_Return)
                        self.after(0.5) { self.reading(first, second) }
                    }
                }
            }
        }
    }

    func reading(_ first: URL, _ second: URL?) {
        report["reading"] = app.mode == .reading
        let pdf = first.deletingPathExtension().appendingPathExtension("pdf")
        try? FileManager.default.removeItem(at: pdf)
        key("p", code: kVK_ANSI_P, flags: .command)
        key("c", code: kVK_ANSI_C, flags: .command)
        after(1.0) {
            self.report["pdf_from_reading"] = FileManager.default.fileExists(atPath: pdf.path)
            self.report["copied_from_reading"] = self.app.board.string(forType: .string) == self.app.shelfText
            self.shot("5-read.png") {
                self.key("\r", code: kVK_Return)
                self.after(0.5) { self.afterShelf(first, second) }
            }
        }
    }

    func afterShelf(_ first: URL, _ second: URL?) {
        report["writing_first_again"] = app.mode == .writing && app.pagePath?.path == first.path
        typeOut("And more. cat \u{8}s wrold\u{8}\u{8}\u{8}\u{8}\u{8}\u{8}") {
            self.key("c", code: kVK_ANSI_C, flags: .command)
            self.key("=", code: kVK_ANSI_Equal, flags: .command)
            self.key("m", code: kVK_ANSI_M, flags: .command)
            self.key("d", code: kVK_ANSI_D, flags: .command)
            self.after(0.7) {
                self.report["copied_from_writing"] = self.app.board.string(forType: .string) ?? ""
                self.report["size_after_plus"] = self.app.typeSize
                self.report["sounds_after_m"] = self.app.cfg.sounds
                self.report["dark_after_d"] = self.app.dark
                self.shot("6-bigger.png") {
                    self.key("0", code: kVK_ANSI_0, flags: .command)
                    self.key("m", code: kVK_ANSI_M, flags: .command)
                    self.key("/", code: kVK_ANSI_Slash, flags: .command)
                    self.after(0.7) {
                        self.report["dark_at_keys"] = self.app.dark
                        self.report["size_after_zero"] = self.app.typeSize
                        self.report["sounds_after_m_again"] = self.app.cfg.sounds
                        self.report["keys_shown"] = self.app.keysShown
                        self.shot("7-keys.png") { self.newFromShelf(first, second) }
                    }
                }
            }
        }
    }

    func newFromShelf(_ first: URL, _ second: URL?) {
        app.showKeys(false)
        key("o", code: kVK_ANSI_O, flags: .command)
        after(0.6) {
            self.shot("8-shelf-dark.png") {}
            self.key("d", code: kVK_ANSI_D, flags: .command)
            self.key("n", code: kVK_ANSI_N, flags: .command)
            self.after(0.6) {
                self.report["new_from_shelf"] = self.app.mode == .writing && self.app.pagePath == nil
                self.report["dark_at_end"] = self.app.dark
                self.key("\u{1B}", code: kVK_Escape)
                self.after(0.6) {
                    self.report["first_after_shelf"] = self.textOf(first)
                    self.report["resumed_text"] = self.textOf(second)
                    self.finish("ok")
                }
            }
        }
    }

    var done = false
    func finish(_ how: String) {
        if done { return }
        done = true
        report["result"] = how
        writeJSON(report, to: out.appendingPathComponent("report.json"))
        if app.win != nil { app.tearDown() }
        NSApp.terminate(nil)
    }
}

// MARK: - Start

let args = CommandLine.arguments
if !args.contains("--selftest") {
    // One Lowkeys at a time. A second launch passes its request on and leaves.
    let me = getpid()
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != me }
    let ask = args.contains("--quit") ? askQuit : args.contains("--reload") ? askReload : askOpen
    if !others.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(
            .init(ask), object: nil, userInfo: nil, deliverImmediately: true)
        exit(0)
    }
    if ask != askOpen { exit(0) }      // nothing running to reload or quit
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let lowkeys = Lowkeys()
app.delegate = lowkeys
app.run()
