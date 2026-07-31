// Rick-Rubin-inspired 8-bit desktop buddy.
//
// A borderless, transparent, always-on-top window that sits on the desktop,
// reacts to what Claude Code is doing, and occasionally says something. Lives in
// the menu bar; no Dock icon.
//
// Drag him anywhere; click him for a nod and a line; right-click him or use the
// menu bar icon for settings.
//
// Build:  swiftc -O Buddy.swift -o buddy
// Run:    ./buddy [framesDir] [scale]

import AppKit
import Darwin

let PAPER = NSColor(srgbRed: 0.965, green: 0.953, blue: 0.925, alpha: 1)  // beard white
let INK = NSColor(srgbRed: 0.090, green: 0.071, blue: 0.059, alpha: 1)  // outline

// MARK: - Single instance

/// Held for the process lifetime; the flock releases when we exit, however we go.
var instanceLockDescriptor: Int32 = -1

/// Two of him on screen is confusing, and both copies would fight over the same
/// state file and saved position. Cheaper to refuse than to coordinate: an
/// advisory flock that the kernel drops for us on exit, so a crash can't leave a
/// stale lock behind the way a pidfile would.
func acquireInstanceLock(at directory: URL) -> Bool {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(".lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true }  // can't lock: better to run than not to
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        close(fd)
        return false
    }
    instanceLockDescriptor = fd
    return true
}

// MARK: - Geometry

/// One sprite pixel, in points, such that it covers a whole number of *device*
/// pixels. At fractional scales an unsnapped size makes some sprite pixels 4
/// device pixels wide and others 5, which reads as a wobble on straight edges.
func snappedPixelSize(scale: Double, screen: NSScreen?) -> Double {
    let backing = Double(screen?.backingScaleFactor ?? 2.0)
    let devicePixels = max(1.0, (scale * backing).rounded())
    return devicePixels / backing
}

// MARK: - Updates

/// Checks the repo's VERSION file and reinstalls when it's newer.
///
/// Pinned to one repo and one file over HTTPS. The heavy lifting is in
/// install.sh, which builds from source and only replaces the running copy once
/// the build succeeds — so a broken commit upstream can't leave you with a
/// buddy that won't start.
enum Updater {
    static let repo = "otniel-bit/rubin-buddy"
    static let branch = "main"

    /// The contents API, not raw.githubusercontent.com. Raw serves a cached copy
    /// for about five minutes — irrelevant for the periodic check, but it makes a
    /// manual "Check for Updates" report the old version right after a release.
    /// The API is uncached; 60 requests/hour unauthenticated is far more than a
    /// six-hourly poll needs.
    static var versionURL: URL {
        URL(string: "https://api.github.com/repos/\(repo)/contents/VERSION?ref=\(branch)")!
    }
    /// Falls back here if the API is unreachable or rate-limited.
    static var versionFallbackURL: URL {
        URL(string: "https://raw.githubusercontent.com/\(repo)/\(branch)/VERSION")!
    }
    static var installerURL: URL {
        URL(string: "https://raw.githubusercontent.com/\(repo)/\(branch)/install.sh")!
    }

    /// Numeric compare, so 1.10.0 correctly beats 1.9.0 — a plain string
    /// comparison gets that backwards.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let (r, l) = (parts(remote), parts(local))
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func fetch(_ url: URL, api: Bool, _ done: @escaping (String?) -> Void) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        if api {
            // Hands back the file's bytes instead of JSON with base64 in it.
            request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        }
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200,
                let text = data.flatMap({ String(data: $0, encoding: .utf8) })?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty, text.first?.isNumber == true
            else {
                done(nil)
                return
            }
            done(text)
        }.resume()
    }

    static func fetchLatest(_ done: @escaping (String?) -> Void) {
        fetch(versionURL, api: true) { viaAPI in
            if let viaAPI {
                DispatchQueue.main.async { done(viaAPI) }
                return
            }
            fetch(versionFallbackURL, api: false) { viaRaw in
                DispatchQueue.main.async { done(viaRaw) }
            }
        }
    }

    /// Runs the installer detached. It stops the old copy and starts the new
    /// one itself, so this process is expected to die partway through — which
    /// is why it must not be a child that dies with us.
    /// Runs the installer detached. Success normally kills this very process
    /// (the installer replaces and restarts us), so the termination handler
    /// firing with a bad status — or at all, in a process still alive — means
    /// the update failed and someone should hear about it.
    ///
    /// Downloaded to a file first, never `curl | sh`: piping executes the
    /// script as it streams, and a dropped connection mid-transfer would run a
    /// truncated prefix of it. RUBIN_AUTO=1 tells the installer it's running
    /// headless so it must never prompt.
    static var installerTask: Process?

    static func runInstaller(onFailure: @escaping (String) -> Void) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rubin-buddy-install-\(getpid()).sh")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            "curl -fsSL '\(installerURL.absoluteString)' -o '\(tmp.path)' "
                + "&& RUBIN_AUTO=1 sh '\(tmp.path)'; s=$?; rm -f '\(tmp.path)'; exit $s",
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        task.terminationHandler = { finished in
            installerTask = nil
            if finished.terminationStatus != 0 {
                DispatchQueue.main.async {
                    onFailure("Update failed. Run ~/.rubin-buddy/update.sh in Terminal.")
                }
            }
        }
        do {
            try task.run()
            installerTask = task
        } catch {
            onFailure("Couldn't start the update.")
        }
    }
}

// MARK: - Login item

/// The launchd agent that starts him at login. Toggled from the menu bar.
enum LoginItem {
    static let label = "co.desklify.rubinbuddy"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    private static func launchctl(_ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    static func setEnabled(_ on: Bool, executable: String, logPath: String) {
        let domain = "gui/\(getuid())"
        guard on else {
            // Deliberately no `bootout`: disabling "start at login" shouldn't
            // also kill the copy that's running right now. Removing the plist
            // is enough to stop it loading next login.
            try? FileManager.default.removeItem(at: plistURL)
            launchctl(["disable", "\(domain)/\(label)"])
            return
        }

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            // Restart him after a crash; menu Quit exits 0 and stays quit.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardErrorPath": logPath,
        ]
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        {
            try? data.write(to: plistURL)
        }
        launchctl(["enable", "\(domain)/\(label)"])
        // Fails harmlessly if the job is already bootstrapped this session.
        launchctl(["bootstrap", domain, plistURL.path])
    }
}

// MARK: - Frame loading

struct Frame {
    let image: NSImage
    let hold: Int
}

struct Animation {
    let frames: [Frame]
    /// Animation to settle into once this one finishes a cycle; nil loops.
    let next: String?
    /// Where the shades sit when this animation ends: "up" or "down".
    let shades: String
    /// Where they sat when it started. Only differs for transitions.
    let from: String
    let isTransition: Bool
}

struct SpriteSet {
    let pixelWidth: Int
    let pixelHeight: Int
    let animations: [String: Animation]
    let menuIcon: NSImage?

    init(framesDir: URL) throws {
        func fail(_ message: String) -> NSError {
            NSError(domain: "buddy", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }

        let data = try Data(contentsOf: framesDir.appendingPathComponent("manifest.json"))
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let width = root["width"] as? Int,
            let height = root["height"] as? Int,
            let anims = root["animations"] as? [String: [String: Any]]
        else { throw fail("malformed manifest.json") }

        var loaded: [String: Animation] = [:]
        for (name, spec) in anims {
            guard let frames = spec["frames"] as? [[String: Any]] else {
                throw fail("\(name): no frames")
            }
            let parsed = try frames.map { entry -> Frame in
                guard
                    let file = entry["file"] as? String,
                    let hold = entry["hold"] as? Int,
                    let image = NSImage(contentsOf: framesDir.appendingPathComponent(file))
                else { throw fail("\(name): bad frame") }
                return Frame(image: image, hold: hold)
            }
            let shades = spec["shades"] as? String ?? "down"
            loaded[name] = Animation(
                frames: parsed,
                next: spec["next"] as? String,
                shades: shades,
                from: spec["from"] as? String ?? shades,
                isTransition: spec["transition"] as? Bool ?? false)
        }

        self.pixelWidth = width
        self.pixelHeight = height
        self.animations = loaded

        if let icon = NSImage(contentsOf: framesDir.appendingPathComponent("menubar.png")) {
            icon.size = NSSize(width: 16, height: 16)
            icon.isTemplate = true  // macOS recolours it per menu bar appearance
            self.menuIcon = icon
        } else {
            self.menuIcon = nil
        }
    }

    /// The gesture that moves the shades between two positions, if there is one.
    func transition(from: String, to: String) -> String? {
        animations.first { $0.value.isTransition && $0.value.from == from && $0.value.shades == to }?
            .key
    }
}

// MARK: - Sprite view

final class SpriteView: NSView {
    var image: NSImage?
    var onClick: (() -> Void)?
    var onGrab: (() -> Void)?
    var onDragEnd: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    private var grabOffset: NSPoint = .zero
    private var didDrag = false

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        // Nearest-neighbour, or the pixel art turns to mush when scaled up.
        image.draw(
            in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0,
            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
    }

    override func mouseDown(with event: NSEvent) {
        grabOffset = event.locationInWindow
        didDrag = false
        onGrab?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        didDrag = true
        let cursor = NSEvent.mouseLocation
        let proposed = NSPoint(x: cursor.x - grabOffset.x, y: cursor.y - grabOffset.y)
        // Refuse a move that would put him entirely off every display. Crossing
        // between monitors still works; vanishing doesn't.
        let frame = NSRect(origin: proposed, size: window.frame.size)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { return }
        window.setFrameOrigin(proposed)
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag { onDragEnd?() } else { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

// MARK: - Speech bubble

final class BubbleView: NSView {
    var text = ""
    var pixel: Double = 3
    var tailX: Double = 20
    var tailDown = true
    var font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .medium)
    /// The wrap width the window was sized against. Laying the text out at any
    /// other width here can pull a word onto the previous line, and then the
    /// height the window was built for no longer matches what's drawn.
    var wrapWidth: Double = 190

    static let tailDepth: Double = 3  // in sprite pixels

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        let p = pixel
        let tail = p * Self.tailDepth
        let cut = p  // one-pixel corner bevel

        let body = NSRect(
            x: 0, y: tailDown ? tail : 0, width: bounds.width, height: bounds.height - tail)

        // One path for bubble + tail, so the border comes out uniform on both.
        let path = NSBezierPath()
        let tipY = tailDown ? 0 : bounds.height
        let baseY = tailDown ? body.minY : body.maxY
        let tx = min(max(tailX, body.minX + cut + p * 2), body.maxX - cut - p * 2)

        path.move(to: NSPoint(x: body.minX + cut, y: baseY))
        path.line(to: NSPoint(x: tx - p * 2, y: baseY))
        path.line(to: NSPoint(x: tx, y: tipY))
        path.line(to: NSPoint(x: tx + p * 2, y: baseY))
        path.line(to: NSPoint(x: body.maxX - cut, y: baseY))
        let farY = tailDown ? body.maxY : body.minY
        let step = tailDown ? -cut : cut
        path.line(to: NSPoint(x: body.maxX, y: baseY - step))
        path.line(to: NSPoint(x: body.maxX, y: farY + step))
        path.line(to: NSPoint(x: body.maxX - cut, y: farY))
        path.line(to: NSPoint(x: body.minX + cut, y: farY))
        path.line(to: NSPoint(x: body.minX, y: farY + step))
        path.line(to: NSPoint(x: body.minX, y: baseY - step))
        path.close()

        // Hard edges on the bevels and the tail — this is meant to look drawn
        // on a grid, not vector-smooth.
        ctx.saveGraphicsState()
        ctx.shouldAntialias = false
        PAPER.setFill()
        path.fill()
        // Stroking at 2x width against the path's own clip leaves a border
        // exactly `pixel` thick, all the way around the tail included.
        path.addClip()
        INK.setStroke()
        path.lineWidth = p * 2
        path.stroke()
        ctx.restoreGraphicsState()

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: INK]
        let size = (text as NSString).boundingRect(
            with: NSSize(width: wrapWidth, height: body.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs
        ).size
        (text as NSString).draw(
            in: NSRect(
                x: body.minX + (body.width - size.width) / 2,
                y: body.minY + (body.height - size.height) / 2,
                width: size.width, height: size.height),
            withAttributes: attrs)
    }
}

final class Bubble {
    private let window: NSWindow
    private let view = BubbleView()
    private var hideWork: DispatchWorkItem?

    private static let maxTextWidth: Double = 190

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.ignoresMouseEvents = true  // never in the way of a click
        window.contentView = view
    }

    var isVisible: Bool { window.isVisible }

    func show(
        _ text: String, over buddy: NSRect, pixel: Double, screen: NSScreen?,
        duration: Double? = nil
    ) {
        let fontSize = max(10.0, (pixel * 4).rounded())
        let font = NSFont(name: "Monaco", size: fontSize)
            ?? .monospacedSystemFont(ofSize: fontSize, weight: .medium)

        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).boundingRect(
            with: NSSize(width: Self.maxTextWidth, height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs
        ).size

        let padX = pixel * 3
        let padY = pixel * 2
        let tail = pixel * BubbleView.tailDepth
        let w = (textSize.width + padX * 2 + pixel * 2).rounded(.up)
        let h = (textSize.height + padY * 2 + pixel * 2).rounded(.up) + tail

        let area = (screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap = pixel

        // Prefer above him; flip below if there isn't room.
        var tailDown = true
        var y = buddy.maxY + gap
        if y + h > area.maxY {
            tailDown = false
            y = buddy.minY - h - gap
        }
        var x = buddy.midX - w / 2
        x = min(max(x, area.minX + 4), area.maxX - w - 4)

        view.text = text
        view.pixel = pixel
        view.font = font
        view.wrapWidth = Self.maxTextWidth
        view.tailDown = tailDown
        view.tailX = buddy.midX - x
        view.needsDisplay = true

        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        window.orderFrontRegardless()

        hideWork?.cancel()
        let seconds = duration ?? min(9.0, max(3.0, 2.0 + Double(text.count) * 0.07))
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        window.orderOut(nil)
    }
}

// MARK: - Controller

final class Buddy: NSObject, NSMenuDelegate {
    private let sprites: SpriteSet
    private let window: NSWindow
    private let view: SpriteView
    private let stateFile: URL
    private let linesFile: URL

    private let bubble = Bubble()
    private var statusItem: NSStatusItem?
    private var pixel: Double = 4
    private var requestedScale: Double
    /// Guards against re-entering the resize from the notification it posts.
    private var adjustingScale = false

    private var currentAnimation = "idle"
    private var frameIndex = 0
    private var ticksOnFrame = 0
    /// Animation to run once the transition gesture currently playing finishes.
    private var pendingTarget: String?
    private var timer: Timer?

    private var lastStateStamp: Date?
    private var ticksSinceStatePoll = 0
    private var ticksUntilSpeaking = 0
    /// Shuffled deck, so every line plays before any repeats.
    private var lineBag: [String] = []
    private var bagSource: [String] = []

    // Contextual speech: the moment picks the theme, the theme picks the line.
    private var lastContextual = Date.distantPast
    /// Start of the current unbroken stretch of Claude Code activity.
    private var activeSince = Date()
    private var lastStateEvent = Date()
    /// Set while he's in the shades-up "your turn" state.
    private var waitingSince: Date?
    private var saidWaitingLine = false

    // Idle fidgets. Only ever started FROM idle, so returning to idle when one
    // ends is always right; a real state event cancels the return outright.
    private var fidgetUntil: Date?
    private var nextFidgetAt = Date.distantFuture

    /// Seconds you've spent actively at the machine since your last real break.
    private var activeSeconds: TimeInterval = 0
    private var ticksSincePresencePoll = 0

    /// The seated states. Entering meditate goes through sitdown; leaving any of
    /// them goes through standup — request() enforces both.
    private static let sittingStates: Set<String> = ["sitdown", "meditate"]

    /// Pending steps of a guided breath; empty means not breathing.
    private var breathWork: [DispatchWorkItem] = []
    private var isBreathing: Bool { !breathWork.isEmpty }

    /// Why he's seated, when he is — each reason has its own "stand up" rule.
    /// "away": you left; your return ends it. "night": it's late; morning (or
    /// an event) ends it. "long": Claude's been at one task a while; the Stop
    /// ends it. nil: you asked for the sit, so it's yours to end.
    private var sitReason: String?

    /// When the current unbroken run of think/stroke began; nil when not busy.
    private var busySince: Date?

    /// The last thing he said, surfaced in the menu for anyone who caught the
    /// bubble vanishing and wondered.
    private var lastSaid = ""

    private let localVersion: String
    /// True when running from the installed location, where update.sh applies.
    /// A developer checkout updates with git, not by being overwritten.
    private let isManagedInstall: Bool
    private var updateTimer: Timer?

    private static let originKey = "buddyOrigin"
    private static let scaleKey = "buddyScale"
    private static let chatterKey = "buddyChatter"
    private static let autoUpdateKey = "buddyAutoUpdate"
    private static let updateCheckInterval: TimeInterval = 6 * 60 * 60
    private static let tickInterval = 1.0 / 30.0
    private static let ticksPerSecond = 30
    private static let statePollTicks = 6  // ~200ms

    /// Seconds of quiet between unprompted lines; nil means he stays silent.
    static var quietSecondsRange: ClosedRange<Int>? = 150...420
    /// RUBIN_DEBUG=1 logs every animation change to stderr.
    static var debug = false
    /// True when RUBIN_SCALE / a scale argument was given at launch — an
    /// explicit ask that outranks the remembered menu choice for this run.
    static var scaleFromLaunch = false
    /// Likewise for RUBIN_CHATTER.
    static var chatterFromLaunch = false

    // Contextual-speech timing. Vars, not lets, so RUBIN_CTX_FAST can shrink
    // them for testing — the triggers are otherwise hours apart by design.
    /// Minimum gap between contextual lines, shared across all three triggers.
    static var ctxCooldown: TimeInterval = 15 * 60
    /// How long Claude must be waiting on you before he says something.
    static var ctxWait: TimeInterval = 3 * 60
    /// Unbroken activity before he suggests stepping away.
    static var ctxStretch: TimeInterval = 2 * 60 * 60
    /// A pause longer than this ends the stretch.
    static var ctxGap: TimeInterval = 15 * 60
    /// Quiet time between idle fidgets, and how long one runs. Between turns he
    /// used to be a two-frame bob for minutes on end — most of what anyone ever
    /// saw of him. Now idleness has a life of its own.
    static var fidgetEvery: ClosedRange<Double> = 25...75
    static var fidgetLength: ClosedRange<Double> = 3.5...7
    /// Break nudge: after this long actively at the machine — keyboard or mouse
    /// input within the last minute, YOUR presence, not Claude's activity — he
    /// suggests going to live a little.
    static var breakEvery: TimeInterval = 90 * 60
    /// Being away from the machine this long counts as a break taken.
    static var breakReset: TimeInterval = 15 * 60
    /// When you've been away this long, he sits down and meditates.
    static var meditateAfter: TimeInterval = 8 * 60
    /// A busy pose (think/stroke) with no state event for this long means the
    /// session died without a Stop; he drifts back to idle.
    static var busyStaleAfter: TimeInterval = 30 * 60
    /// Claude working one task longer than this: he sits down and keeps watch —
    /// patience reads better than ten more minutes of beard-stroking.
    static var longTaskAfter: TimeInterval = 10 * 60
    /// Local hours (start, end) between which idle becomes the seated pose.
    static var nightWindow = (start: 23, end: 5)

    private static let sizeChoices: [(String, Double)] = [
        ("Tiny", 2.0), ("Small", 2.5), ("Medium", 3.5), ("Large", 5.0),
    ]
    private static let chatterChoices: [(String, ClosedRange<Int>?)] = [
        ("Silent", nil), ("Quiet", 300...900), ("Normal", 150...420), ("Talkative", 45...120),
    ]

    private static let fallbackLines = ["Let it breathe.", "Slower.", "Less."]

    init(sprites: SpriteSet, scale: Double, stateFile: URL, linesFile: URL) {
        self.sprites = sprites
        self.stateFile = stateFile
        self.linesFile = linesFile
        // Precedence: an explicit env/argument beats the remembered menu choice
        // (you typed it, you meant it); the menu choice beats the default.
        let stored = UserDefaults.standard.double(forKey: Self.scaleKey)
        self.requestedScale = Buddy.scaleFromLaunch ? scale : (stored > 0 ? stored : scale)

        let here = Bundle.main.bundleURL
        self.localVersion =
            (try? String(contentsOf: here.appendingPathComponent("VERSION"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"
        let installDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".rubin-buddy")
        self.isManagedInstall =
            here.standardizedFileURL.path == installDir.standardizedFileURL.path

        view = SpriteView(frame: .zero)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: .borderless, backing: .buffered, defer: false)

        super.init()

        if !Buddy.chatterFromLaunch,
            let stored = UserDefaults.standard.string(forKey: Self.chatterKey),
            let match = Self.chatterChoices.first(where: { $0.0 == stored })
        {
            Self.quietSecondsRange = match.1
        }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.contentView = view

        // Pick the scale from the display his saved position sits on, before the
        // window exists. Using NSScreen.main here would bring him up at the
        // laptop's scale even when he's parked on a monitor with a different one,
        // and nothing would correct it until some screen notification fired.
        pixel = snappedPixelSize(
            scale: requestedScale,
            screen: Self.screen(containing: Self.storedOriginPoint()) ?? NSScreen.main)
        let size = spriteSize()
        window.setFrame(NSRect(origin: savedOrigin(size: size), size: size), display: false)

        view.onGrab = { [weak self] in self?.bubble.hide() }
        view.onClick = { [weak self] in
            guard let self else { return }
            // Mid-breath, a click means "enough" — he stands, nothing more.
            if self.isBreathing {
                self.cancelBreath(standUp: true)
                return
            }
            // Waiting on you, eyes on you: a nod would drop the shades and lose
            // the waiting posture. He's already giving you his attention.
            if self.currentAnimation == "look" {
                self.speakLine()
                return
            }
            self.request("nod")
            self.speakLine()
        }
        view.onDragEnd = { [weak self] in self?.saveOrigin() }
        view.onRightClick = { [weak self] event in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.buildMenu(), with: event, for: self.view)
        }

        try? FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Whatever state the previous session left on disk is history, not news —
        // without this he'd replay a stale "stroke" from last week at every launch.
        lastStateStamp =
            (try? FileManager.default.attributesOfItem(atPath: stateFile.path))?[
                .modificationDate] as? Date

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensRearranged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        installStatusItem()
        scheduleNextLine()
        scheduleNextFidget()

        // First run ever: say something soon, so a new user learns he talks
        // without waiting the usual several minutes for the first line.
        let firstRunKey = "buddyHasRun"
        if !UserDefaults.standard.bool(forKey: firstRunKey) {
            UserDefaults.standard.set(true, forKey: firstRunKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, !self.isBreathing, !self.bubble.isVisible else { return }
                self.speakLine()
            }
        }

        renderCurrentFrame()
        window.orderFrontRegardless()

        // .common, not .default: a timer in the default mode stops while any
        // menu is open, which froze him mid-frame whenever you used the menu bar.
        let tickTimer = Timer(timeInterval: Self.tickInterval, repeats: true) {
            [weak self] _ in self?.tick()
        }
        RunLoop.main.add(tickTimer, forMode: .common)
        timer = tickTimer

        log("bundle=\(Bundle.main.bundleURL.path) managed=\(isManagedInstall) v=\(localVersion)")
        if isManagedInstall {
            // Not at the instant of launch — logging in is busy enough already.
            let delay =
                Double(ProcessInfo.processInfo.environment["RUBIN_UPDATE_DELAY"] ?? "") ?? 45
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.checkForUpdates(userAsked: false)
            }
            updateTimer = Timer.scheduledTimer(
                withTimeInterval: Self.updateCheckInterval, repeats: true
            ) { [weak self] _ in self?.checkForUpdates(userAsked: false) }
        }
    }

    private func spriteSize() -> NSSize {
        NSSize(
            width: Double(sprites.pixelWidth) * pixel,
            height: Double(sprites.pixelHeight) * pixel)
    }

    // MARK: scale and displays

    /// Anchor the scale decision to the display under his origin, not to
    /// `window.screen`. `window.screen` is whichever display he *most overlaps*,
    /// and resizing changes the overlap — which on a mixed-DPI setup makes the
    /// choice flip back and forth forever.
    private static func screen(containing point: NSPoint?) -> NSScreen? {
        guard let point else { return nil }
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func anchorScreen() -> NSScreen? {
        Self.screen(containing: window.frame.origin) ?? window.screen ?? NSScreen.main
    }

    @objc private func screenChanged() {
        // setFrame below posts didChangeScreenNotification, which lands here
        // again. Without this guard that recursion is unbounded and the stack
        // gives out — a real crash when dragged between mixed-DPI displays.
        guard !adjustingScale else { return }
        let snapped = snappedPixelSize(scale: requestedScale, screen: anchorScreen())
        guard snapped != pixel else { return }

        adjustingScale = true
        defer { adjustingScale = false }
        pixel = snapped
        // Keep his feet where they are while the box around him changes.
        let old = window.frame
        let size = spriteSize()
        window.setFrame(
            NSRect(x: old.minX, y: old.minY, width: size.width, height: size.height), display: true)
    }

    /// A display being unplugged can leave him stranded off-screen. This rescue
    /// is temporary, so it deliberately does NOT overwrite the saved position —
    /// plug the display back in, relaunch, and he's where you left him.
    @objc private func screensRearranged() {
        screenChanged()
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
            return
        }
        bringBack(persist: false)
    }

    private func applyScale(_ scale: Double) {
        requestedScale = scale
        UserDefaults.standard.set(scale, forKey: Self.scaleKey)
        let snapped = snappedPixelSize(scale: scale, screen: anchorScreen())
        adjustingScale = true
        defer { adjustingScale = false }
        pixel = snapped
        let old = window.frame
        let size = spriteSize()
        window.setFrame(
            NSRect(x: old.minX, y: old.minY, width: size.width, height: size.height), display: true)
        bubble.hide()
    }

    // MARK: position

    /// Bottom-right of the main screen, clear of the Dock.
    private func defaultOrigin(size: NSSize) -> NSPoint {
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.maxX - size.width - 24, y: area.minY + 24)
    }

    private static func storedOriginPoint() -> NSPoint? {
        guard
            let saved = UserDefaults.standard.dictionary(forKey: originKey) as? [String: Double],
            let x = saved["x"], let y = saved["y"]
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    private func savedOrigin(size: NSSize) -> NSPoint {
        if let point = Self.storedOriginPoint(),
            // Only reuse it if that spot is still on a connected display.
            NSScreen.screens.contains(where: {
                $0.visibleFrame.intersects(NSRect(origin: point, size: size))
            })
        { return point }
        return defaultOrigin(size: size)
    }

    private func saveOrigin() {
        let origin = window.frame.origin
        UserDefaults.standard.set(
            ["x": Double(origin.x), "y": Double(origin.y)], forKey: Self.originKey)
    }

    // MARK: animation

    private var animation: Animation? {
        sprites.animations[currentAnimation] ?? sprites.animations["idle"]
    }

    /// Ask for an animation. Inserts a shades-up/shades-down gesture first when
    /// the target's shade position doesn't match where they currently are, and
    /// routes into and out of sitting through sitdown/standup.
    private func request(_ name: String) {
        guard let target = sprites.animations[name] else { return }

        // Leaving the floor: anything that isn't sitting goes through standup.
        if Self.sittingStates.contains(currentAnimation), !Self.sittingStates.contains(name),
            name != "standup"
        {
            sitReason = nil
            pendingTarget = name == "idle" ? nil : name  // standup resolves to idle itself
            play("standup")
            return
        }
        let here = sprites.animations[currentAnimation]?.shades ?? "down"

        // Taking the floor: meditate always begins by sitting down — and if the
        // shades are up, they come down first rather than teleporting.
        if name == "meditate", !Self.sittingStates.contains(currentAnimation) {
            if here == "up", let bridge = sprites.transition(from: "up", to: "down") {
                pendingTarget = "meditate"
                play(bridge)
            } else {
                pendingTarget = nil  // a stale target must not hijack the sit
                play("sitdown")
            }
            return
        }

        if target.isTransition {
            // Asked to move the shades somewhere they already are — skip the
            // gesture and go straight to where it would have landed.
            if target.shades == here {
                if let next = target.next { play(next) }
                return
            }
        } else if target.shades != here,
            let bridge = sprites.transition(from: here, to: target.shades)
        {
            pendingTarget = name
            play(bridge)
            return
        }

        pendingTarget = nil
        play(name)
    }

    private func play(_ name: String) {
        guard sprites.animations[name] != nil else { return }
        if Buddy.debug {
            FileHandle.standardError.write("play \(currentAnimation) -> \(name)\n".data(using: .utf8)!)
        }
        currentAnimation = name
        frameIndex = 0
        ticksOnFrame = 0
        renderCurrentFrame()
    }

    private func tick() {
        ticksSinceStatePoll += 1
        if ticksSinceStatePoll >= Self.statePollTicks {
            ticksSinceStatePoll = 0
            pollState()
        }

        if Buddy.quietSecondsRange != nil {
            ticksUntilSpeaking -= 1
            if ticksUntilSpeaking <= 0 {
                if !bubble.isVisible && window.isVisible && !isBreathing { speakLine() }
                scheduleNextLine()
            }
        }

        // Claude has been waiting on you a while: shades up, and after ctxWait
        // he says so — you're the decision now. Once per wait.
        if let since = waitingSince, !saidWaitingLine {
            let now = Date()
            if now.timeIntervalSince(since) >= Self.ctxWait, canSpeakContextual(now) {
                saidWaitingLine = true
                speakContextual(["noticing", "taste over technique"], at: now)
            }
        }

        ticksSincePresencePoll += 1
        if ticksSincePresencePoll >= Self.ticksPerSecond {
            ticksSincePresencePoll = 0
            pollPresence()
        }

        // Idle fidgets. A gesture ends by returning to idle; a state event that
        // arrives mid-fidget takes over immediately (pollState clears the timer).
        if let until = fidgetUntil {
            if Date() >= until {
                fidgetUntil = nil
                // Only reel him back in if he's still doing the fidget. If a
                // breath, a Pose pick, or anything else took over meanwhile,
                // this timer has no business standing him back up.
                if ["stroke", "think", "glasses", "look"].contains(currentAnimation) {
                    request("idle")
                }
                scheduleNextFidget()
            }
        } else if currentAnimation == "idle", Date() >= nextFidgetAt {
            if let gesture = ["stroke", "think", "glasses"].randomElement() {
                fidgetUntil = Date().addingTimeInterval(.random(in: Self.fidgetLength))
                request(gesture)
            }
        }

        guard let animation, !animation.frames.isEmpty else { return }
        ticksOnFrame += 1
        guard ticksOnFrame >= max(1, animation.frames[frameIndex].hold) else { return }

        ticksOnFrame = 0
        frameIndex += 1
        if frameIndex >= animation.frames.count {
            frameIndex = 0
            if let pending = pendingTarget {
                pendingTarget = nil
                // Through request(), not play(): the pending step may itself
                // need a bridge (standup into "look" must raise the shades).
                request(pending)
                return
            }
            if let next = animation.next {
                play(next)
                return
            }
        }
        renderCurrentFrame()
    }

    private func renderCurrentFrame() {
        guard let animation, frameIndex < animation.frames.count else { return }
        view.image = animation.frames[frameIndex].image
        view.needsDisplay = true
    }

    // MARK: Claude Code state

    private func pollState() {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: stateFile.path),
            let stamp = attrs[.modificationDate] as? Date
        else { return }
        guard stamp != lastStateStamp else { return }
        lastStateStamp = stamp

        guard let raw = try? String(contentsOf: stateFile, encoding: .utf8) else { return }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Not an animation: "breathe" in the state file starts a guided breath,
        // so hooks and scripts can offer one ("state.sh breathe").
        if name == "breathe" {
            if !isBreathing {
                cancelFidget()
                takeABreath()
            }
            return
        }
        // Also not an animation: "say <text>" borrows his voice — the quietest
        // notification endpoint on the machine. Local input from the user's own
        // scripts; capped so a runaway payload can't wallpaper the screen, and
        // never over a guided breath.
        if name.hasPrefix("say ") {
            let text = String(name.dropFirst(4))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(140)
            guard !text.isEmpty, !isBreathing else { return }
            lastSaid = String(text)
            if Buddy.debug {
                FileHandle.standardError.write("say: \(text)\n".data(using: .utf8)!)
            }
            window.orderFrontRegardless()
            bubble.show(String(text), over: window.frame, pixel: pixel, screen: window.screen)
            return
        }
        guard !name.isEmpty, sprites.animations[name] != nil else { return }
        noteStateEvent(name)
        // Seated for a long run: more of the same work is not a reason to stand.
        // Anything that ISN'T the same work (nod, glasses, idle) still is.
        if sitReason == "long", ["think", "stroke"].contains(name) { return }
        // Re-triggering what's already playing would just make it stutter — and
        // a repeat that matches the pending target would hard-cut the bridge
        // that's currently carrying him there.
        guard name != currentAnimation, name != pendingTarget else { return }
        request(name)
    }

    /// Contextual bookkeeping, run on every state-file event (even repeats).
    private func noteStateEvent(_ name: String) {
        let now = Date()
        if now.timeIntervalSince(lastStateEvent) > Self.ctxGap { activeSince = now }
        lastStateEvent = now

        // Real activity trumps fidgeting: cancel any gesture in flight and push
        // the next one out, so fidgets only happen after genuine quiet.
        fidgetUntil = nil
        scheduleNextFidget()
        // And it trumps a guided breath — the incoming state change re-poses him.
        cancelBreath(standUp: false)

        if name == "glasses" || name == "look" {
            if waitingSince == nil {
                waitingSince = now
                saidWaitingLine = false
            }
        } else {
            waitingSince = nil
        }

        // Track how long one unbroken run of work has been going. Waiting
        // states (glasses/look) pause nothing — a permission prompt mid-task
        // is still the same task.
        let longRun = busySince.map { now.timeIntervalSince($0) >= Self.longTaskAfter } ?? false
        switch name {
        case "think", "stroke":
            if busySince == nil { busySince = now }
        case "nod", "idle":
            busySince = nil
        default:
            break
        }

        // A finished turn sometimes earns a Finishing line — but only sometimes,
        // and never twice inside the cooldown. Every Claude turn ends with a
        // Stop, and a buddy that comments on all of them stops being listened to.
        // The exception: a LONG run ending always deserves the word, cooldown or
        // not — if you waited half an hour for it, he has something to say.
        if name == "nod", longRun, canSpeakIgnoringCooldown() {
            speakContextual(["finishing"], at: now)
        } else if name == "nod", canSpeakContextual(now), Int.random(in: 0..<3) == 0 {
            speakContextual(["finishing"], at: now)
        } else if now.timeIntervalSince(activeSince) >= Self.ctxStretch, canSpeakContextual(now) {
            speakContextual(["stepping away"], at: now)
            activeSince = now  // the two-hour clock restarts after he says it
        }
    }

    /// The gate for lines important enough to skip the cooldown — still never
    /// in Silent mode, over another bubble, mid-breath, or while hidden.
    private func canSpeakIgnoringCooldown() -> Bool {
        Buddy.quietSecondsRange != nil && window.isVisible && !bubble.isVisible && !isBreathing
    }

    // MARK: speech

    private func scheduleNextLine() {
        guard let range = Buddy.quietSecondsRange else { return }
        ticksUntilSpeaking = Int.random(in: range) * Self.ticksPerSecond
    }

    private func scheduleNextFidget() {
        nextFidgetAt = Date().addingTimeInterval(.random(in: Self.fidgetEvery))
    }

    /// For anything that takes over the body deliberately: forget the fidget in
    /// flight so its return-to-idle timer can't yank the new pose away.
    private func cancelFidget() {
        fidgetUntil = nil
        scheduleNextFidget()
    }

    /// Re-read on every line so edits to lines.txt land without a restart.
    private func lines() -> [String] {
        guard let raw = try? String(contentsOf: linesFile, encoding: .utf8) else {
            return Self.fallbackLines
        }
        let parsed = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return parsed.isEmpty ? Self.fallbackLines : parsed
    }

    /// Deals from a shuffled deck rather than picking independently, so all of
    /// them play before any repeats. Reshuffles when lines.txt changes.
    private func speakLine() {
        let all = lines()
        if lineBag.isEmpty || all != bagSource {
            bagSource = all
            lineBag = all.shuffled()
        }
        guard let line = lineBag.popLast() else { return }
        lastSaid = line
        bubble.show(line, over: window.frame, pixel: pixel, screen: window.screen)
    }

    /// lines.txt grouped by its `# ── Theme ──` headers, keyed lowercase.
    /// Re-parsed on use, same as lines(), so edits land live.
    private func lineGroups() -> [String: [String]] {
        guard let raw = try? String(contentsOf: linesFile, encoding: .utf8) else { return [:] }
        var groups: [String: [String]] = [:]
        var current = ""
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") {
                if line.contains("──") {
                    let name = line
                        .replacingOccurrences(of: "#", with: "")
                        .replacingOccurrences(of: "─", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { current = name.lowercased() }
                }
                continue
            }
            if !line.isEmpty { groups[current, default: []].append(line) }
        }
        return groups
    }

    /// The break nudge. CGEventSource's idle clock is public API and needs no
    /// permissions — it reports time since input, never what was typed.
    private static let inputTypes: [CGEventType] = [
        .keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel,
    ]

    static func isNight(_ now: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: now)
        return hour >= Self.nightWindow.start || hour < Self.nightWindow.end
    }

    private static let greetDayKey = "buddyGreetDay"
    /// A gap in your activity this long makes the next activity an "arrival" —
    /// the thing a morning greeting is actually about.
    static var arrivalGap: TimeInterval = 4 * 60 * 60

    /// Wall clock of the last poll that saw you active; nil until the first.
    private var lastActiveAt: Date?
    /// Wall clock of the previous poll, whatever it saw. A large gap here means
    /// the Mac was asleep — polls don't run while it sleeps.
    private var lastPollAt = Date()

    private func pollPresence() {
        let now = Date()
        // The machine sleeping IS a break, but the idle clock can't see it:
        // wake the Mac after eight hours and the very first poll reports
        // idle≈0 (you just touched the keyboard), so the away-branch below
        // never runs and yesterday's activeSeconds would still be on the books.
        if now.timeIntervalSince(lastPollAt) >= Self.breakReset {
            activeSeconds = 0
        }
        lastPollAt = now

        let idle = Self.inputTypes
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .infinity

        if idle < 60 {
            activeSeconds += 1

            // You're back from being away: he finishes nothing, he just gets
            // up. Only for away-sits — a night sit means he's sitting WITH
            // you, and any other sit is yours (or a task's) to end.
            if sitReason == "away", Self.sittingStates.contains(currentAnimation), !isBreathing {
                sitReason = nil
                request("idle")
            }

            // An arrival is activity after a real gap (or the first since
            // launch) — NOT the date flipping at midnight under your hands.
            let isArrival = lastActiveAt.map { now.timeIntervalSince($0) >= Self.arrivalGap } ?? true
            if isArrival { greetTheMorning() }
            lastActiveAt = now

            // The break nudge belongs here, while you're present — firing it
            // into an empty room both wasted the line and reset the clock.
            if activeSeconds >= Self.breakEvery, canSpeakContextual(now) {
                speakContextual(["the world"], at: now)
                activeSeconds = 0
            }
        } else {
            if idle >= Self.breakReset {
                activeSeconds = 0  // you took a real break; the clock restarts
            }
            // Nobody's here. He has his own practice.
            if idle >= Self.meditateAfter, currentAnimation == "idle" {
                sitReason = "away"
                request("meditate")
            }
        }

        // Late: idle becomes the seated pose — he sits with you, not at you.
        // Events still stand him up (the sit-exit bridge handles it), and he
        // settles back down when things go quiet again.
        if Self.isNight(now), currentAnimation == "idle", fidgetUntil == nil, !isBreathing {
            sitReason = "night"
            request("meditate")
        } else if !Self.isNight(now), sitReason == "night",
            Self.sittingStates.contains(currentAnimation), !isBreathing
        {
            sitReason = nil
            request("idle")  // morning: back on his feet
        }

        // Claude has been at ONE task a long time: stroking on loop for forty
        // minutes reads as manic. He sits down and keeps watch instead.
        if let since = busySince, ["think", "stroke"].contains(currentAnimation),
            now.timeIntervalSince(since) >= Self.longTaskAfter
        {
            sitReason = "long"
            request("meditate")
        }

        // A busy pose with no state event for this long is a dead session —
        // Claude Code crashed or the terminal was killed, so no Stop ever came.
        // He shouldn't work the beard (or keep a seated vigil) for a ghost.
        if now.timeIntervalSince(lastStateEvent) >= Self.busyStaleAfter {
            if ["think", "stroke"].contains(currentAnimation) {
                busySince = nil
                request("idle")
            } else if sitReason == "long" {
                busySince = nil
                sitReason = nil
                request("idle")
            }
        }
    }

    /// One line for your first arrival of the day, leaning toward beginnings.
    /// The day is only marked once he actually says it, so a blocked attempt
    /// (bubble up, cooldown) retries on a later poll instead of skipping a day.
    private func greetTheMorning() {
        let day = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current,
            formatOptions: [.withFullDate])
        guard UserDefaults.standard.string(forKey: Self.greetDayKey) != day else { return }
        let now = Date()
        guard canSpeakContextual(now) else { return }
        UserDefaults.standard.set(day, forKey: Self.greetDayKey)
        speakContextual(["beginnings and endings", "practice"], at: now)
    }

    private func canSpeakContextual(_ now: Date) -> Bool {
        Buddy.quietSecondsRange != nil && window.isVisible && !bubble.isVisible
            && !isBreathing  // never interject between "Hold…" and "Out…"
            && now.timeIntervalSince(lastContextual) >= Self.ctxCooldown
    }

    /// A line from the named theme groups — the moment picks the theme. Falls
    /// back to the whole deck if the groups aren't in the file any more.
    private func speakContextual(_ groupNames: [String], at now: Date) {
        let groups = lineGroups()
        let pool = groupNames.flatMap { groups[$0] ?? [] }
        guard let line = (pool.isEmpty ? lines() : pool).randomElement() else { return }
        if Buddy.debug {
            FileHandle.standardError.write("ctx \(groupNames): \(line)\n".data(using: .utf8)!)
        }
        lastSaid = line
        bubble.show(line, over: window.frame, pixel: pixel, screen: window.screen)
        lastContextual = now
        // He just spoke; push the random line back out so they don't stack.
        scheduleNextLine()
    }

    // MARK: updates

    private var autoUpdateEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool ?? true
    }

    private func log(_ message: String) {
        guard Buddy.debug else { return }
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
    }

    /// True from announcing an update until its installer reports failure.
    /// (Success kills this process, so there is no "success" transition.)
    private var updateInFlight = false
    /// A version whose install already failed once — retried silently on later
    /// checks, never re-announced. "New version. Updating." every six hours
    /// while nothing changes is worse than no updater at all.
    private var announcedFailedVersion: String?

    private func checkForUpdates(userAsked: Bool) {
        log(
            "update check: asked=\(userAsked) auto=\(autoUpdateEnabled) "
                + "managed=\(isManagedInstall) local=\(localVersion)")
        guard userAsked || (autoUpdateEnabled && isManagedInstall) else {
            log("update check: skipped")
            return
        }
        guard !updateInFlight else { return }
        // Never yank him out from under a guided breath; the next check gets it.
        if isBreathing, !userAsked { return }
        Updater.fetchLatest { [weak self] remote in
            guard let self else { return }
            self.log("update check: remote=\(remote ?? "nil")")
            guard let remote else {
                if userAsked { self.say("Couldn't reach the update server.") }
                return
            }
            guard Updater.isNewer(remote, than: self.localVersion) else {
                if userAsked { self.say("You're on the latest. \(self.localVersion)") }
                return
            }
            guard self.isManagedInstall else {
                if userAsked { self.say("\(remote) is out. Developer build — git pull.") }
                return
            }
            guard !self.updateInFlight else { return }
            self.updateInFlight = true
            if userAsked || self.announcedFailedVersion != remote {
                self.say("New version, \(remote). Updating.")
            }
            // Let the bubble land before the installer stops us.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                Updater.runInstaller { message in
                    guard let self else { return }
                    self.updateInFlight = false
                    // Tell the user once per broken version; retries stay silent.
                    let alreadyAnnounced = self.announcedFailedVersion == remote
                    self.announcedFailedVersion = remote
                    self.log("update failed for \(remote)")
                    if userAsked || !alreadyAnnounced { self.say(message) }
                }
            }
        }
    }

    /// Say something specific, rather than a line from the deck.
    private func say(_ text: String) {
        window.orderFrontRegardless()
        bubble.show(text, over: window.frame, pixel: pixel, screen: window.screen)
    }

    // MARK: guided breath

    /// A slow minute together: he sits, and the bubble paces four rounds of
    /// 4-4-6. No streaks, no history, no reminder to do it again.
    @objc func takeABreath() {
        if isBreathing {
            cancelBreath(standUp: true)
            return
        }
        cancelFidget()
        window.orderFrontRegardless()  // a hidden Rick pacing breaths is just noise
        request("meditate")
        var at = 1.6  // let him get seated first
        var steps: [(String, Double)] = []
        for _ in 0..<4 { steps += [("In…", 4), ("Hold…", 4), ("Out…", 6)] }
        for (text, length) in steps {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.bubble.show(
                    text, over: self.window.frame, pixel: self.pixel,
                    screen: self.window.screen, duration: length - 0.4)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + at, execute: work)
            breathWork.append(work)
            at += length
        }
        let done = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.breathWork.removeAll()
            self.request("idle")  // he stands; no line — the silence is part of it
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + at + 0.5, execute: done)
        breathWork.append(done)
    }

    private func cancelBreath(standUp: Bool) {
        guard isBreathing else { return }
        breathWork.forEach { $0.cancel() }
        breathWork.removeAll()
        bubble.hide()
        if standUp { request("idle") }
    }

    // MARK: menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let icon = sprites.menuIcon {
            item.button?.image = icon
        } else {
            item.button?.title = "R"
        }
        item.button?.toolTip = "Rick"
        let menu = NSMenu()
        menu.delegate = self  // rebuilt on open so the check marks are current
        item.menu = menu
        statusItem = item
    }

    /// NSMenuDelegate — rebuild just before it's shown.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        for item in buildMenu().items.map({ $0.copy() as! NSMenuItem }) {
            menu.addItem(item)
        }
    }

    private func item(_ title: String, _ action: Selector, on: Bool = false, tag: Int = 0)
        -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        item.tag = tag
        return item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(
            item(window.isVisible ? "Hide Rick" : "Show Rick", #selector(toggleVisible)))
        menu.addItem(item("Bring Him Back", #selector(bringBackAndShow)))
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for (i, choice) in Self.sizeChoices.enumerated() {
            sizeMenu.addItem(
                item(
                    choice.0, #selector(setSize(_:)),
                    on: abs(choice.1 - requestedScale) < 0.01, tag: i))
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let chatterMenu = NSMenu()
        for (i, choice) in Self.chatterChoices.enumerated() {
            chatterMenu.addItem(
                item(
                    choice.0, #selector(setChatter(_:)),
                    on: choice.1 == Buddy.quietSecondsRange, tag: i))
        }
        let chatterItem = NSMenuItem(title: "Chatter", action: nil, keyEquivalent: "")
        chatterItem.submenu = chatterMenu
        menu.addItem(chatterItem)

        let poseMenu = NSMenu()
        for name in sprites.animations.keys.sorted() {
            let entry = item(
                name.capitalized, #selector(selectAnimation(_:)), on: name == currentAnimation)
            entry.representedObject = name
            poseMenu.addItem(entry)
        }
        let poseItem = NSMenuItem(title: "Pose", action: nil, keyEquivalent: "")
        poseItem.submenu = poseMenu
        menu.addItem(poseItem)

        if !lastSaid.isEmpty {
            // Clickable: copies the full line. People share these — make it easy.
            let shown = lastSaid.count > 58 ? lastSaid.prefix(57) + "…" : Substring(lastSaid)
            let said = item(
                "He said: \u{201C}\(shown)\u{201D} — copy", #selector(copyLastSaid))
            menu.addItem(said)
        }
        menu.addItem(item("Say Something", #selector(saySomething)))
        menu.addItem(item("Take a Breath", #selector(takeABreath), on: isBreathing))
        menu.addItem(.separator())
        menu.addItem(
            item("Follow Claude Code", #selector(toggleFollowClaude), on: hooksWired))
        menu.addItem(item("Start at Login", #selector(toggleLoginItem), on: LoginItem.isEnabled))

        let versionLabel = NSMenuItem(
            title: isManagedInstall
                ? "Version \(localVersion)" : "Version \(localVersion) (dev build)",
            action: nil, keyEquivalent: "")
        versionLabel.isEnabled = false
        menu.addItem(versionLabel)
        menu.addItem(item("Check for Updates", #selector(checkNow)))
        if isManagedInstall {
            menu.addItem(item("Auto-Update", #selector(toggleAutoUpdate), on: autoUpdateEnabled))
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Rick", #selector(quit)))
        return menu
    }

    @objc private func checkNow() {
        say("Checking...")
        checkForUpdates(userAsked: true)
    }

    @objc private func toggleAutoUpdate() {
        UserDefaults.standard.set(!autoUpdateEnabled, forKey: Self.autoUpdateKey)
    }

    @objc private func toggleVisible() {
        if window.isVisible {
            bubble.hide()
            window.orderOut(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    private func bringBack(persist: Bool) {
        bubble.hide()
        window.setFrameOrigin(defaultOrigin(size: spriteSize()))
        if persist { saveOrigin() }
    }

    @objc private func bringBackAndShow() {
        bringBack(persist: true)  // the menu click is intentional; remember it
        window.orderFrontRegardless()
        request("glasses")  // shades up — he's looking right at you
    }

    @objc private func setSize(_ sender: NSMenuItem) {
        guard Self.sizeChoices.indices.contains(sender.tag) else { return }
        applyScale(Self.sizeChoices[sender.tag].1)
    }

    @objc private func setChatter(_ sender: NSMenuItem) {
        guard Self.chatterChoices.indices.contains(sender.tag) else { return }
        let choice = Self.chatterChoices[sender.tag]
        Buddy.quietSecondsRange = choice.1
        UserDefaults.standard.set(choice.0, forKey: Self.chatterKey)
        scheduleNextLine()
    }

    @objc private func selectAnimation(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        cancelFidget()
        request(name)
    }

    @objc private func copyLastSaid() {
        guard !lastSaid.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastSaid, forType: .string)
    }

    @objc private func saySomething() {
        window.orderFrontRegardless()
        speakLine()
        scheduleNextLine()
    }

    // MARK: Claude Code hooks

    private var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// The hooks script tags every entry it writes with "rubin-buddy", which is
    /// also how it recognises its own entries to remove — so presence of the
    /// marker is exactly "wired".
    private var hooksWired: Bool {
        (try? String(contentsOf: claudeSettingsURL, encoding: .utf8))?
            .contains("rubin-buddy") ?? false
    }

    /// One click instead of a trip to the terminal. Shells out to the same
    /// hooks.sh the terminal path uses, so there is exactly one implementation
    /// of the settings merge.
    @objc private func toggleFollowClaude() {
        let script = Bundle.main.bundleURL.appendingPathComponent("hooks.sh").path
        guard FileManager.default.fileExists(atPath: script) else {
            say("Can't find hooks.sh. Reinstall me.")
            return
        }
        let wasWired = hooksWired
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = wasWired ? [script, "--remove"] : [script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            say("Couldn't run it. Try ~/.rubin-buddy/hooks.sh")
            return
        }
        // Believe the file, not the exit code.
        switch (wasWired, hooksWired) {
        case (false, true): say("Following. Open a fresh session.")
        case (true, false): say("Not following.")
        default: say("That didn't take. Try ~/.rubin-buddy/hooks.sh")
        }
    }

    @objc private func toggleLoginItem() {
        LoginItem.setEnabled(
            !LoginItem.isEnabled,
            executable: Bundle.main.bundleURL.appendingPathComponent("buddy").path,
            logPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/rubin-buddy.log").path)
    }

    @objc private func quit() {
        saveOrigin()
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment
let home = FileManager.default.homeDirectoryForCurrentUser
let here = Bundle.main.bundleURL

let version =
    (try? String(contentsOf: here.appendingPathComponent("VERSION"), encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"

if args.contains("--version") || args.contains("-v") {
    print("rubin-buddy \(version)")
    exit(0)
}
if args.contains("--help") || args.contains("-h") {
    print(
        """
        rubin-buddy \(version) — an 8-bit desktop buddy.

          buddy [framesDir] [scale]

          --version   print the version
          --help      this

        Environment: RUBIN_SCALE, RUBIN_CHATTER (e.g. 150-420), RUBIN_LINES,
        RUBIN_STATE, RUBIN_FRAMES, RUBIN_DEBUG=1, RUBIN_UPDATE_DELAY.

        Settings live in the menu bar. https://github.com/otniel-bit/rubin-buddy
        """)
    exit(0)
}

// Flags are handled above; anything left that starts with '-' isn't a path, and
// treating it as one produced a baffling "manifest.json not found" error.
let positional = args.filter { !$0.hasPrefix("-") }

let framesDir: URL = {
    if let arg = positional.first { return URL(fileURLWithPath: arg) }
    if let fromEnv = env["RUBIN_FRAMES"] { return URL(fileURLWithPath: fromEnv) }
    return here.appendingPathComponent("frames")
}()

// 2.5 lands on exactly 5 device pixels per sprite pixel on a 2x display.
Buddy.scaleFromLaunch = positional.count > 1 || env["RUBIN_SCALE"] != nil
let scale = max(
    1.0, Double(positional.count > 1 ? positional[1] : env["RUBIN_SCALE"] ?? "") ?? 2.5)

let stateFile: URL = {
    if let fromEnv = env["RUBIN_STATE"] { return URL(fileURLWithPath: fromEnv) }
    return home.appendingPathComponent(".rubin-buddy/state")
}()

let linesFile: URL = {
    if let fromEnv = env["RUBIN_LINES"] { return URL(fileURLWithPath: fromEnv) }
    return here.appendingPathComponent("lines.txt")
}()

Buddy.debug = env["RUBIN_DEBUG"] == "1"

// Testing only: contextual triggers are minutes-to-hours apart by design, which
// makes them unverifiable in a sitting. This compresses them to seconds.
if env["RUBIN_CTX_FAST"] == "1" {
    Buddy.ctxCooldown = 12
    Buddy.ctxWait = 8
    Buddy.ctxStretch = 40
    Buddy.ctxGap = 20
    Buddy.fidgetEvery = 5...9
    Buddy.fidgetLength = 3...5
    Buddy.breakEvery = 30
    Buddy.breakReset = 10
    Buddy.meditateAfter = 15
    Buddy.busyStaleAfter = 60
    Buddy.arrivalGap = 40
    Buddy.longTaskAfter = 18
}
// Testing only: pretend it's the middle of the night.
if env["RUBIN_FORCE_NIGHT"] == "1" {
    Buddy.nightWindow = (start: 0, end: 24)
}

if let spec = env["RUBIN_CHATTER"] {
    let parts = spec.split(separator: "-").compactMap { Int($0) }
    if parts.count == 2, parts[0] > 0, parts[1] >= parts[0] {
        Buddy.quietSecondsRange = parts[0]...parts[1]
        Buddy.chatterFromLaunch = true
    }
}

guard acquireInstanceLock(at: stateFile.deletingLastPathComponent()) else {
    FileHandle.standardError.write("buddy: already running\n".data(using: .utf8)!)
    exit(0)
}

let sprites: SpriteSet
do {
    sprites = try SpriteSet(framesDir: framesDir)
} catch {
    FileHandle.standardError.write(
        "buddy: could not load frames from \(framesDir.path): \(error.localizedDescription)\n"
            .data(using: .utf8)!)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
let buddy = Buddy(sprites: sprites, scale: scale, stateFile: stateFile, linesFile: linesFile)
app.run()
