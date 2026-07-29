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
    static func runInstaller() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "curl -fsSL '\(installerURL.absoluteString)' | sh"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
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

    func show(_ text: String, over buddy: NSRect, pixel: Double, screen: NSScreen?) {
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
        let seconds = min(9.0, max(3.0, 2.0 + Double(text.count) * 0.07))
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
        // A size chosen from the menu bar outlives the launch argument.
        let stored = UserDefaults.standard.double(forKey: Self.scaleKey)
        self.requestedScale = stored > 0 ? stored : scale

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

        if let stored = UserDefaults.standard.string(forKey: Self.chatterKey),
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
            self?.request("nod")
            self?.speakLine()
        }
        view.onDragEnd = { [weak self] in self?.saveOrigin() }
        view.onRightClick = { [weak self] event in
            guard let self else { return }
            NSMenu.popUpContextMenu(self.buildMenu(), with: event, for: self.view)
        }

        try? FileManager.default.createDirectory(
            at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensRearranged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        installStatusItem()
        scheduleNextLine()
        renderCurrentFrame()
        window.orderFrontRegardless()

        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) {
            [weak self] _ in self?.tick()
        }

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

    /// A display being unplugged can leave him stranded off-screen.
    @objc private func screensRearranged() {
        screenChanged()
        guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else {
            return
        }
        bringBack()
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
    /// the target's shade position doesn't match where they currently are.
    private func request(_ name: String) {
        guard let target = sprites.animations[name] else { return }
        let here = sprites.animations[currentAnimation]?.shades ?? "down"

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
                if !bubble.isVisible && window.isVisible { speakLine() }
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

        guard let animation, !animation.frames.isEmpty else { return }
        ticksOnFrame += 1
        guard ticksOnFrame >= max(1, animation.frames[frameIndex].hold) else { return }

        ticksOnFrame = 0
        frameIndex += 1
        if frameIndex >= animation.frames.count {
            frameIndex = 0
            if let pending = pendingTarget {
                pendingTarget = nil
                play(pending)
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
        guard !name.isEmpty, sprites.animations[name] != nil else { return }
        noteStateEvent(name)
        // Re-triggering what's already playing would just make it stutter.
        guard name != currentAnimation else { return }
        request(name)
    }

    /// Contextual bookkeeping, run on every state-file event (even repeats).
    private func noteStateEvent(_ name: String) {
        let now = Date()
        if now.timeIntervalSince(lastStateEvent) > Self.ctxGap { activeSince = now }
        lastStateEvent = now

        if name == "glasses" || name == "look" {
            if waitingSince == nil {
                waitingSince = now
                saidWaitingLine = false
            }
        } else {
            waitingSince = nil
        }

        // A finished turn sometimes earns a Finishing line — but only sometimes,
        // and never twice inside the cooldown. Every Claude turn ends with a
        // Stop, and a buddy that comments on all of them stops being listened to.
        if name == "nod", canSpeakContextual(now), Int.random(in: 0..<3) == 0 {
            speakContextual(["finishing"], at: now)
        } else if now.timeIntervalSince(activeSince) >= Self.ctxStretch, canSpeakContextual(now) {
            speakContextual(["stepping away"], at: now)
            activeSince = now  // the two-hour clock restarts after he says it
        }
    }

    // MARK: speech

    private func scheduleNextLine() {
        guard let range = Buddy.quietSecondsRange else { return }
        ticksUntilSpeaking = Int.random(in: range) * Self.ticksPerSecond
    }

    /// Re-read on every line so edits to lines.txt land without a restart.
    private func lines() -> [String] {
        guard let raw = try? String(contentsOf: linesFile, encoding: .utf8) else {
            return Self.fallbackLines
        }
        let parsed = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
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
        bubble.show(line, over: window.frame, pixel: pixel, screen: window.screen)
    }

    /// lines.txt grouped by its `# ── Theme ──` headers, keyed lowercase.
    /// Re-parsed on use, same as lines(), so edits land live.
    private func lineGroups() -> [String: [String]] {
        guard let raw = try? String(contentsOf: linesFile, encoding: .utf8) else { return [:] }
        var groups: [String: [String]] = [:]
        var current = ""
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                if line.contains("──") {
                    let name = line
                        .replacingOccurrences(of: "#", with: "")
                        .replacingOccurrences(of: "─", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { current = name.lowercased() }
                }
                continue
            }
            if !line.isEmpty { groups[current, default: []].append(line) }
        }
        return groups
    }

    private func canSpeakContextual(_ now: Date) -> Bool {
        Buddy.quietSecondsRange != nil && window.isVisible && !bubble.isVisible
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

    private func checkForUpdates(userAsked: Bool) {
        log(
            "update check: asked=\(userAsked) auto=\(autoUpdateEnabled) "
                + "managed=\(isManagedInstall) local=\(localVersion)")
        guard userAsked || (autoUpdateEnabled && isManagedInstall) else {
            log("update check: skipped")
            return
        }
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
            self.say("New version, \(remote). Updating.")
            // Let the bubble land before the installer stops us.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Updater.runInstaller() }
        }
    }

    /// Say something specific, rather than a line from the deck.
    private func say(_ text: String) {
        window.orderFrontRegardless()
        bubble.show(text, over: window.frame, pixel: pixel, screen: window.screen)
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

        menu.addItem(item("Say Something", #selector(saySomething)))
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

    private func bringBack() {
        bubble.hide()
        window.setFrameOrigin(defaultOrigin(size: spriteSize()))
        saveOrigin()
    }

    @objc private func bringBackAndShow() {
        bringBack()
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
        request(name)
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
}

if let spec = env["RUBIN_CHATTER"] {
    let parts = spec.split(separator: "-").compactMap { Int($0) }
    if parts.count == 2, parts[0] > 0, parts[1] >= parts[0] {
        Buddy.quietSecondsRange = parts[0]...parts[1]
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
