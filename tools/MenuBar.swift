// Menu bar button for unifi-viewer. When the app is built with swiftc this is
// its main program; it stays running with nothing but a button in the menu bar,
// and starts and stops the viewer on demand.
//
//   click          open the viewer on the screen whose menu bar was clicked,
//                  close it if it is already open there, or move it there if
//                  it is open on another screen
//   right-click    Camera Settings... and Quit
//   ⌃⌥⌘U           open the viewer on the screen it was last on, or close it
//                  (the shortcut is changed in Camera Settings)
//
// Closing means stopping mpv, not hiding its window, so a closed viewer costs no
// network and no CPU. Moving means closing and reopening: mpv chooses a screen
// only when its window is created (see view.sh), so a restart is the only
// reliable way to put it on another one.
//
// The viewer runs in its own process group — view.sh, mpv, and the settings
// window when view.sh opens it — so one signal to the group stops all of it,
// whatever it happens to be doing at the time.
//
// Each screen remembers where you last put the window on it and how large you
// made it (see Placement.swift). The viewer opens with that, through a small
// file view.sh reads each time it starts mpv; a screen you have not changed
// anything on gets mpv's default, each feed at its own size, centred.
//
// The decisions live in MenuBarLogic.swift, Shortcut.swift and Placement.swift,
// which are tested on their own. Build:
//
//   swiftc -O -parse-as-library tools/MenuBarLogic.swift tools/Shortcut.swift \
//       tools/Placement.swift tools/MenuBar.swift

import AppKit
import Carbon.HIToolbox

// Where the viewer was last seen, by display name, so the shortcut can open it
// there again — also after the app has been quit and reopened.
let lastScreenDefaultsKey = "lastScreen"
// Screen name -> Placement.encoded, for every screen you have changed.
let placementsDefaultsKey = "placements"

// Shared with view.sh and menu.lua, which find them the same way.
let cacheDir = (ProcessInfo.processInfo.environment["XDG_CACHE_HOME"] ?? NSHomeDirectory() + "/.cache")
    + "/unifi-viewer"
let placementFile = cacheDir + "/placement"   // written here, read by view.sh
let mpvSocket = cacheDir + "/mpv.sock"        // mpv listens here; view.sh opens it
let placementLog = cacheDir + "/placement.log"

// A record of every open, look, report and save, for working out afterwards
// why a window came back where it did. Trimmed to the last 500 lines each time
// the viewer opens, so it stays small.
let logTime: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

func record(_ line: String) {
    let text = logTime.string(from: Date()) + " " + line + "\n"
    if let handle = FileHandle(forWritingAtPath: placementLog) {
        handle.seekToEndOfFile()
        handle.write(text.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        try? text.write(toFile: placementLog, atomically: true, encoding: .utf8)
    }
}

func trimLog() {
    guard let text = try? String(contentsOfFile: placementLog, encoding: .utf8) else { return }
    let trimmed = trimmedLog(text, keeping: 500)
    if trimmed != text {
        try? trimmed.write(toFile: placementLog, atomically: true, encoding: .utf8)
    }
}

func describe(_ rect: CGRect) -> String {
    return "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
}

// The feed now selected, as "3 Garage", from the files view.sh keeps.
func currentFeed() -> String {
    let index = (try? String(contentsOfFile: cacheDir + "/feed", encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    let feeds = (try? String(contentsOfFile: cacheDir + "/feeds", encoding: .utf8)) ?? ""
    for line in feeds.split(separator: "\n") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        if fields.count > 2 && String(fields[0]) == index {
            return index + " " + String(fields[2])
        }
    }
    return index
}

struct Screen {
    let name: String      // what mpv's --screen-name matches
    let frame: CGRect     // Cocoa coordinates, as NSEvent.mouseLocation uses
    let bounds: CGRect    // Quartz coordinates, as CGWindowList uses
    let visible: CGRect   // the part below the menu bar, in Quartz coordinates
    let backing: CGFloat  // pixels per point: 2 on Retina
}

func currentScreens() -> [Screen] {
    let mainHeight = NSScreen.screens.first?.frame.height ?? 0
    return NSScreen.screens.map { screen in
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return Screen(name: screen.localizedName,
                      frame: screen.frame,
                      bounds: CGDisplayBounds(number?.uint32Value ?? 0),
                      visible: quartzRect(fromCocoa: screen.visibleFrame, mainHeight: mainHeight),
                      backing: screen.backingScaleFactor)
    }
}

// Start a program as the leader of a new process group, with extra environment
// on top of our own. Returns its pid, which is also the group id.
func spawnGroup(_ path: String, args: [String] = [], env extra: [String: String] = [:]) -> pid_t? {
    var attr: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attr, 0)

    var env = ProcessInfo.processInfo.environment
    extra.forEach { env[$0.key] = $0.value }
    let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, nil, &attr, argv, envp)
    if rc != 0 {
        NSLog("unifi-viewer: cannot start %@: %s", path, strerror(rc))
        return nil
    }
    return pid
}

// The app icon's lens, drawn as a template image so macOS colours it to suit
// the menu bar: white on a dark one, black on a light one. The proportions are
// make-icon.py's — ring 0.300 to 0.238, pupil 0.105 — without the plate, which
// would only read as a blob at this size.
func lensIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
        let scale: CGFloat = 8 / 0.300    // outer ring radius of 8pt
        func circle(_ r: CGFloat) -> NSRect {
            return NSRect(x: rect.midX - r * scale, y: rect.midY - r * scale,
                          width: 2 * r * scale, height: 2 * r * scale)
        }
        let lens = NSBezierPath(ovalIn: circle(0.300))
        lens.append(NSBezierPath(ovalIn: circle(0.238)))
        lens.append(NSBezierPath(ovalIn: circle(0.105)))
        lens.windingRule = .evenOdd       // ring, empty glass, filled pupil
        NSColor.black.setFill()
        lens.fill()
        return true
    }
    image.isTemplate = true
    return image
}

final class MenuBar: NSObject, NSApplicationDelegate {
    let launcher = Bundle.main.executableURL!
        .deletingLastPathComponent().appendingPathComponent("launch-viewer").path

    var statusItem: NSStatusItem!
    var viewer: pid_t?           // process group of the running viewer
    var settings: pid_t?         // process group of a settings window we opened
    var afterViewerExit: (() -> Void)?
    var watchers: [ObjectIdentifier: DispatchSourceProcess] = [:]

    var shortcut = Shortcut.standard
    var hotKey: EventHotKeyRef?
    var shortcutWorks = false
    var pausedBy: Set<pid_t> = []     // settings windows recording a shortcut
    var viewerActions: [ViewerAction] = []   // what the viewer menu's items do

    // About the viewer now open.
    var mpv: MPVClient?               // the socket mpv listens on
    var feeds: [Feed] = []            // what view.sh wrote for this session
    var playing: Int?                 // the feed showing, by its number
    var sessionScale: Double?         // the scale the window is at, nil for mpv's own
    var sessionVideo: CGSize?         // the size of the feed showing; nil while one opens
    var pendingVideo: CGSize?         // its size as mpv announced it, before the window changed
    var lastSeen: (frame: CGRect, screen: Screen)?  // for the final save, once it has gone
    var mouseUpMonitor: Any?          // a look at the end of every drag or resize
    var rightClickMonitor: Any?       // the viewer's own menu
    var loadingShown = false
    var placedOnce = false            // mpv's start position has done its job

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "unifi-viewer"
        if let button = statusItem.button {
            button.image = lensIcon()
            button.toolTip = "UniFi Viewer"
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        installShortcutHandler()
        registerShortcut()
        listenToSettings()
        // Whether macOS trusts this app for Accessibility. Nothing here needs
        // it; logged so the log shows the mouse watching works without it.
        record("started, accessibility trusted: \(AXIsProcessTrusted())")
        // Opening the app is asking to see the cameras, where you last had them.
        openViewer(on: lastScreen() ?? pointerScreen())
    }

    // Double-clicking the app again while it runs in the menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if viewer == nil && settings == nil {
            openViewer(on: lastScreen() ?? pointerScreen())
        }
        return false
    }

    // Only reached directly when macOS ends the app, at logout for instance;
    // Quit from the menu closes the viewer first. Save what the last look saw.
    func applicationWillTerminate(_ notification: Notification) {
        look("quitting")
        [viewer, settings].compactMap { $0 }.forEach { kill(-$0, SIGTERM) }
    }

    // --- clicks -------------------------------------------------------------

    @objc func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            toggle()
        }
    }

    func toggle() {
        // The settings window has the config open; starting a viewer under it
        // would read a file that is about to change.
        if settings != nil {
            NSSound.beep()
            return
        }

        let screens = currentScreens()
        guard !screens.isEmpty else { return }
        // The pointer is in the menu bar it just clicked, so it names the
        // screen, including when each display has a menu bar of its own.
        let clicked = screenIndex(containing: NSEvent.mouseLocation, in: screens.map { $0.frame }) ?? 0
        let showing = viewerWindow().flatMap { screenIndex(forWindow: $0, in: screens.map { $0.bounds }) }

        switch toggleAction(viewerRunning: viewer != nil, viewerScreen: showing, clickedScreen: clicked) {
        case .open(let i):
            openViewer(on: screens[i])
        case .close:
            stopViewer()
        case .move(let i):
            stopViewer { self.openViewer(on: screens[i]) }
        }
    }

    func showMenu() {
        let menu = NSMenu()
        let toggleItem = menu.addItem(withTitle: "Open or Close Viewer", action: #selector(shortcutPressed), keyEquivalent: "")
        toggleItem.target = self
        if !shortcutWorks {
            toggleItem.title += " (shortcut unavailable)"
        } else if shortcut.key.count == 1 {
            // Shown the way macOS shows any shortcut, aligned on the right.
            toggleItem.keyEquivalent = shortcut.key.lowercased()
            toggleItem.keyEquivalentModifierMask = modifierFlags(shortcut.modifiers)
        } else {
            toggleItem.title += "  \(shortcut.label)"
        }
        menu.addItem(.separator())
        let settingsItem = menu.addItem(withTitle: "Camera Settings...", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        settingsItem.isEnabled = settings == nil
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit UniFi Viewer", action: #selector(quit), keyEquivalent: "").target = self
        menu.autoenablesItems = false

        // Attaching the menu only for this click keeps a left click free for
        // the toggle; a status item with a menu set opens it on every click.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc func openSettings() {
        guard settings == nil else { return }
        let screens = currentScreens()
        let reopen = viewerWindow()
            .flatMap { screenIndex(forWindow: $0, in: screens.map { $0.bounds }) }
            .map { screens[$0] }

        stopViewer {
            guard let pid = spawnGroup(self.launcher, args: ["--settings"]) else { return }
            self.settings = pid
            self.handOver(to: pid)
            self.watch(pid) {
                self.settings = nil
                // Come back to where things were: open again only if it was open.
                if let screen = reopen { self.openViewer(on: screen) }
            }
        }
    }

    // Closes the viewer first and waits for it, so the final save on its way
    // out (see openViewer) happens before the app is gone.
    @objc func quit() {
        stopViewer { NSApp.terminate(nil) }
    }

    // --- the viewer ---------------------------------------------------------

    func pointerScreen() -> Screen? {
        let screens = currentScreens()
        return screenIndex(containing: NSEvent.mouseLocation, in: screens.map { $0.frame })
            .map { screens[$0] }
    }

    func lastScreen() -> Screen? {
        let screens = currentScreens()
        return screenIndex(named: UserDefaults.standard.string(forKey: lastScreenDefaultsKey),
                           in: screens.map { $0.name }).map { screens[$0] }
    }

    func openViewer(on screen: Screen?) {
        guard viewer == nil else { return }

        // A resolution change or a smaller display can leave a saved corner
        // off the edge; centre instead.
        let placement = screen.map { placementIn(effect: $0) } ?? Placement()
        trimLog()
        record("open on \(screen?.name ?? "the pointer's screen"): \(placement.encoded), feed \(currentFeed())")

        writePlacementFile(screen?.name, placement)
        sessionScale = placement.scale
        sessionVideo = nil
        lastSeen = nil
        feeds = loadFeeds()
        playing = nil
        loadingShown = false
        placedOnce = false

        guard let pid = spawnGroup(launcher) else { return }
        viewer = pid
        if let name = screen?.name { remember(name) }
        // mpv is driven over its socket from here on: the menu, the "Loading"
        // panel, feed switches and the properties mpv's own menu bar would
        // otherwise change. That is what lets the viewer run an mpv with no
        // scripting engine in it.
        connectToViewer()

        // Nothing polls the window. mpv reports a feed's size over the socket
        // as it starts showing; a move has no report without Accessibility
        // permission, but every drag ends with the mouse button coming up, and
        // watching for that anywhere needs no permission — Apple restricts
        // only key events for global monitors. Looks come from those two, and
        // from closing. A look straight after the button comes up catches a
        // drag; another half a second later catches a window that slides into
        // place, such as one tiled against a screen edge. A move made with the
        // keyboard alone is seen at the next click anywhere, or on closing
        // from the menu bar or the shortcut.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.look("mouse up") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.look("mouse up, settled") }
        }
        // The viewer's own menu, which used to be drawn inside the video by
        // menu.lua and is now a plain macOS menu.
        rightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseDown) { _ in
            self.showViewerMenu()
        }
        handOver(to: pid)
        watch(pid) {
            self.mpv?.stop()
            self.mpv = nil
            for monitor in [self.mouseUpMonitor, self.rightClickMonitor].compactMap({ $0 }) {
                NSEvent.removeMonitor(monitor)
            }
            self.mouseUpMonitor = nil
            self.rightClickMonitor = nil
            self.viewer = nil
            record("closed")
            // Nothing left to place; a later run from a terminal gets defaults.
            try? FileManager.default.removeItem(atPath: placementFile)
            let next = self.afterViewerExit
            self.afterViewerExit = nil
            next?()
        }
    }

    // Stop the viewer and everything it started. `then` runs once it has gone,
    // or straight away if nothing was running.
    func stopViewer(then: (() -> Void)? = nil) {
        guard let pid = viewer else {
            then?()
            return
        }
        afterViewerExit = then
        look("closing")
        kill(-pid, SIGTERM)
        // mpv exits within a fraction of a second on SIGTERM — unless it is
        // stuck connecting to a camera, when it was seen to linger for 11
        // seconds. view.sh goes at once either way, so whether it has gone says
        // nothing about mpv: check the whole group, and stop whatever is left.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if kill(-pid, 0) == 0 {
                record("viewer still running 3s after closing; stopping it")
                kill(-pid, SIGKILL)
            }
        }
    }

    // The viewer's window, in Quartz coordinates, or nil if it has none on
    // screen. Found by process group rather than by title: window titles are
    // hidden from apps without screen recording permission, owner pids are not.
    func viewerWindow() -> CGRect? {
        guard let group = viewer,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        return list
            .filter { window in
                guard let owner = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                else { return false }
                return getpgid(owner) == group
            }
            .compactMap { window in
                (window[kCGWindowBounds as String] as? NSDictionary)
                    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
            }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    // A click on a menu bar button does not make its app active, and macOS 14
    // onwards only lets an app take focus if the active app hands it over. So
    // mpv's own attempt to come to the front can fail and leave the window
    // without the keyboard, and 1-9, r and q would go elsewhere. Take the focus
    // first, then give it to whichever app in the group puts up a window.
    func handOver(to group: pid_t) {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }

        var tries = 0
        func attempt() {
            guard viewer == group || settings == group else { return }
            let app = NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier != getpid() && getpgid($0.processIdentifier) == group
            }
            if let app = app, app.isFinishedLaunching {
                if #available(macOS 14, *) {
                    NSApp.yieldActivation(to: app)
                    app.activate()
                } else {
                    app.activate(options: [.activateIgnoringOtherApps])
                }
                return
            }
            tries += 1
            if tries < 50 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: attempt)
            }
        }
        attempt()
    }

    // Keyed by the source rather than the pid: the same process can be watched
    // twice, as a settings window we opened and as one recording a shortcut.
    // waitpid reaps our own children; for anyone else's it does nothing.
    func watch(_ pid: pid_t, onExit: @escaping () -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        let id = ObjectIdentifier(source)
        source.setEventHandler {
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            source.cancel()
            self.watchers[id] = nil
            onExit()
        }
        watchers[id] = source
        source.resume()
    }

    // --- last screen ----------------------------------------------------------

    func remember(_ screenName: String) {
        if UserDefaults.standard.string(forKey: lastScreenDefaultsKey) != screenName {
            UserDefaults.standard.set(screenName, forKey: lastScreenDefaultsKey)
        }
    }

    // --- placement ------------------------------------------------------------

    func savedPlacements() -> [String: String] {
        return UserDefaults.standard.dictionary(forKey: placementsDefaultsKey) as? [String: String] ?? [:]
    }

    func savedPlacement(_ screenName: String) -> Placement {
        return savedPlacements()[screenName].flatMap { Placement(encoded: $0) } ?? Placement()
    }

    // A default placement is removed rather than stored: nothing saved for a
    // screen is what "you have not changed anything here" means.
    func save(_ placement: Placement, for screenName: String) {
        var all = savedPlacements()
        all[screenName] = placement.isDefault ? nil : placement.encoded
        UserDefaults.standard.set(all, forKey: placementsDefaultsKey)
    }

    // What view.sh gives mpv the next time it starts: now, and after a restart
    // for the settings window or a reset. No screen means no file, and mpv's
    // defaults.
    func writePlacementFile(_ screenName: String?, _ placement: Placement) {
        guard let screenName = screenName else {
            try? FileManager.default.removeItem(atPath: placementFile)
            return
        }
        var text = "screen=\(screenName)\n"
        if let scale = placement.scale { text += String(format: "scale=%.6f\n", scale) }
        let geometry = geometryArgument(placement)
        if !geometry.isEmpty { text += "geometry=\(geometry)\n" }
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        try? text.write(toFile: placementFile, atomically: true, encoding: .utf8)
    }

    func offset(of window: CGRect, on screen: Screen) -> CGPoint {
        return geometryOffset(window: window, visible: screen.visible, backing: screen.backing)
    }

    // A saved placement as it takes effect on a screen: without a position
    // that no longer fits there.
    func placementIn(effect screen: Screen) -> Placement {
        return usable(savedPlacement(screen.name), visible: screen.visible, backing: screen.backing)
    }

    // --- the viewer over its socket -------------------------------------------

    func connectToViewer() {
        let client = MPVClient(path: mpvSocket,
                               onConnect: { [weak self] in self?.viewerConnected() },
                               onMessage: { [weak self] in self?.handle($0) })
        mpv = client
        client.start()
    }

    func viewerConnected() {
        record("connected to the viewer")
        // pause, loop-file and speed are watched because mpv's macOS menu bar
        // sends those commands straight to mpv, where no key binding can catch
        // them: pausing a live camera leaves a stale frame with no way back,
        // and turning off loop-file would make the app exit silently on the
        // next dropped stream.
        mpv?.observe(["pause", "loop-file", "speed", "path", "video-params"])
        if let scale = sessionScale {
            mpv?.send(["set_property", "window-scale", scale])
        }
    }

    func handle(_ message: MPVMessage) {
        switch message {
        case .property(let name, let value):
            switch name {
            case "pause":
                if value == .bool(true) { mpv?.send(["set_property", "pause", false]) }
            case "loop-file":
                if value != .text("inf") { mpv?.send(["set_property", "loop-file", "inf"]) }
            case "speed":
                if let speed = value.number, abs(speed - 1) > 0.001 {
                    mpv?.send(["set_property", "speed", 1.0])
                }
            case "path":
                feedStarted(url: value.text)
            case "video-params":
                // Only noted here. mpv knows a feed's size before it has
                // resized the window for it, and judging the old window
                // against the new size called that a resize by hand.
                if case .size(let width, let height) = value {
                    pendingVideo = CGSize(width: width, height: height)
                }
            default:
                break
            }
        case .message(let args):
            record("viewer says: \(args.joined(separator: " "))")
            switch args.first {
            case "unifi-reload": reload()
            case "unifi-reset": resetWindow()
            default: break
            }
        case .other(let event):
            switch event {
            case "playback-restart":
                // Frames are arriving, so the window is now sized for this
                // feed: its size can be judged against again. The panel has
                // done its job, and so has the position mpv was started at —
                // clearing that stops mpv putting a window you have moved back
                // where it opened.
                sessionVideo = pendingVideo
                hideLoading()
                if !placedOnce {
                    placedOnce = true
                    mpv?.send(["set_property", "geometry", ""])
                }
            case "end-file":
                // A dropped stream reconnects in place; say so rather than
                // leaving the last frame looking live.
                if let feed = feeds.first(where: { $0.index == playing }) { showLoading(feed.name) }
            default:
                break
            }
        case .reply:
            break
        }
    }

    // --- feeds ----------------------------------------------------------------

    struct Feed {
        var index: Int
        var key: String
        var name: String
        var url: String
    }

    // The feeds view.sh wrote for this session, as "<index>\t<key>\t<name>\t<url>".
    func loadFeeds() -> [Feed] {
        let text = (try? String(contentsOfFile: cacheDir + "/feeds", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 4, let index = Int(f[0]) else { return nil }
            return Feed(index: index, key: String(f[1]), name: String(f[2]), url: String(f[3]))
        }
    }

    func feedStarted(url: String?) {
        guard let url = url, let feed = feeds.first(where: { $0.url == url }) else { return }
        if playing != feed.index {
            playing = feed.index
            record("feed \(feed.index) \(feed.name)")
            try? "\(feed.index)\n".write(toFile: cacheDir + "/feed", atomically: true, encoding: .utf8)
        }
        // The window keeps the last feed's size until this one shows, so there
        // is nothing to judge a resize against in the meantime.
        sessionVideo = nil
        pendingVideo = nil
        showLoading(feed.name)
    }

    func select(feed index: Int) {
        guard let feed = feeds.first(where: { $0.index == index }), feed.index != playing else { return }
        record("opening feed \(feed.index) \(feed.name)")
        showLoading(feed.name)
        mpv?.send(["loadfile", feed.url])
    }

    // Reopening the stream is the only real "back to live" for RTSP: a live
    // stream cannot be seeked, so a reload is what drops whatever was buffered.
    func reload() {
        guard let feed = feeds.first(where: { $0.index == playing }) else { return }
        record("reloading feed \(feed.index) \(feed.name)")
        showLoading(feed.name)
        mpv?.send(["loadfile", feed.url])
    }

    // --- the "Loading" panel ---------------------------------------------------

    func showLoading(_ name: String) {
        let size = sessionVideo ?? CGSize(width: 1920, height: 1080)
        let ass = loadingOverlay(feed: name, width: Int(size.width), height: Int(size.height))
        mpv?.send(["osd-overlay", 1, "ass-events", ass, Int(size.width), Int(size.height), 0, false, false])
        loadingShown = true
    }

    func hideLoading() {
        guard loadingShown else { return }
        mpv?.send(["osd-overlay", 1, "none", ""])
        loadingShown = false
    }

    // --- the viewer's menu -----------------------------------------------------

    // A right-click anywhere is offered to the viewer: if the pointer is over
    // its window, this is the menu that used to be drawn inside the video.
    func showViewerMenu() {
        guard viewer != nil, let window = viewerWindow() else {
            record("right-click: no viewer window")
            return
        }
        let pointer = NSEvent.mouseLocation
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let inQuartz = CGPoint(x: pointer.x, y: mainHeight - pointer.y)
        guard window.contains(inQuartz) else {
            record("right-click at \(Int(inQuartz.x)),\(Int(inQuartz.y)): outside \(describe(window))")
            return
        }
        record("right-click at \(Int(inQuartz.x)),\(Int(inQuartz.y)): menu")

        let items = viewerMenu(feeds: feeds.map { (index: $0.index, key: $0.key, name: $0.name) },
                               current: playing)
        viewerActions = items.compactMap { $0.action }
        let menu = NSMenu()
        var actionIndex = 0
        for item in items {
            if item.action == nil {
                menu.addItem(.separator())
                continue
            }
            let entry = menu.addItem(withTitle: item.title, action: #selector(viewerMenuPicked(_:)),
                                     keyEquivalent: "")
            entry.target = self
            entry.tag = actionIndex
            entry.state = item.checked ? .on : .off
            // The key that does the same thing, shown as mpv's menu did.
            entry.attributedTitle = nil
            entry.toolTip = item.shortcut.isEmpty ? nil : "Key: \(item.shortcut)"
            actionIndex += 1
        }
        menu.popUp(positioning: nil, at: pointer, in: nil)
    }

    @objc func viewerMenuPicked(_ item: NSMenuItem) {
        guard item.tag >= 0 && item.tag < viewerActions.count else { return }
        switch viewerActions[item.tag] {
        case .selectFeed(let index): select(feed: index)
        case .reload: reload()
        case .settings: mpv?.send(["quit", 20])      // view.sh opens the settings window
        case .quit: mpv?.send(["quit", 5])
        }
    }

    // Back to mpv's own size and position on this screen, forgetting what the
    // screen had saved. Done by restarting the viewer — quit 21 is view.sh's
    // signal — because mpv 0.41 puts a window moved while it runs in the wrong
    // place on any display but the main one.
    func resetWindow() {
        record("reset asked for")
        if let seen = lastSeen {
            record("reset on \(seen.screen.name)")
            apply(frame: seen.frame, on: seen.screen, judge: false, why: "reset", reset: true)
        }
        sessionScale = nil
        mpv?.send(["quit", 21])
    }

    // Which screen the window is on, and whether it has been moved or resized
    // there. Asked at the end of every mouse drag, on closing, and — without
    // judging moves or resizes — on each report from menu.lua.
    func look(_ trigger: String, judge: Bool = true) {
        guard viewer != nil, let frame = viewerWindow() else {
            if viewer != nil { record("look (\(trigger)): no window") }
            return
        }
        let screens = currentScreens()
        guard let i = screenIndex(forWindow: frame, in: screens.map { $0.bounds }) else { return }
        let screen = screens[i]
        remember(screen.name)
        lastSeen = (frame, screen)
        apply(frame: frame, on: screen, judge: judge, why: trigger)
    }

    // Act on menu.lua's new reports, and when judging, on a move or resize,
    // for a window at `frame`.
    func apply(frame: CGRect, on screen: Screen, judge: Bool, why: String, reset: Bool = false) {
        var moved = false
        var resizedTo: Double? = nil
        if judge && !reset {
            moved = hasMoved(frame, from: placementIn(effect: screen),
                             visible: screen.visible, backing: screen.backing)
            // Nothing to judge a size against while a feed is still opening:
            // the window keeps the last feed's size until the new one shows.
            if let video = sessionVideo {
                resizedTo = resizedScale(window: frame, video: video, scale: sessionScale,
                                         visible: screen.visible, backing: screen.backing)
            }
        }
        var seen = "look (\(why)): \(describe(frame)) on \(screen.name)"
        if moved { seen += ", position changed" }
        if let scale = resizedTo { seen += ", resized to \(String(format: "%.6f", scale))" }
        record(seen)

        let before = savedPlacement(screen.name)
        let outcome = track(saved: before, reset: reset, moved: moved, resizedTo: resizedTo,
                            offset: offset(of: frame, on: screen), sessionScale: sessionScale)
        sessionScale = outcome.sessionScale
        if outcome.changed && outcome.placement != before {
            record("save \(screen.name): \(before.encoded) -> \(outcome.placement.encoded) (\(why))")
            save(outcome.placement, for: screen.name)
            writePlacementFile(screen.name, outcome.placement)
        }
        // A resize is the window's new size for the rest of the session: tell
        // mpv, so the next feed opens at it rather than back at full size.
        if let scale = resizedTo {
            mpv?.send(["set_property", "window-scale", scale])
        }
    }

    // --- keyboard shortcut --------------------------------------------------
    //
    // A Carbon hot key: system-wide, and unlike watching the keyboard it needs
    // no Accessibility permission. It is still the supported way to do this.

    @objc func shortcutPressed() {
        if settings != nil {
            NSSound.beep()
            return
        }
        let screens = currentScreens()
        guard !screens.isEmpty else { return }
        let last = screenIndex(named: UserDefaults.standard.string(forKey: lastScreenDefaultsKey),
                               in: screens.map { $0.name })
        let pointer = screenIndex(containing: NSEvent.mouseLocation, in: screens.map { $0.frame }) ?? 0

        switch shortcutAction(viewerRunning: viewer != nil, lastScreen: last, pointerScreen: pointer) {
        case .open(let i):
            openViewer(on: screens[i])
        case .close, .move:
            stopViewer()
        }
    }

    func installShortcutHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            let me = Unmanaged<MenuBar>.fromOpaque(context!).takeUnretainedValue()
            me.shortcutPressed()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    // Reads the saved shortcut afresh each time: the settings window writes it
    // from another process, so what this one has cached may be stale.
    func registerShortcut() {
        unregisterShortcut()
        guard pausedBy.isEmpty else { return }
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        shortcut = Shortcut.from(saved: UserDefaults.standard.string(forKey: shortcutDefaultsKey))
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: OSType(0x554E4656), id: 1),  // "UNFV"
                                         GetApplicationEventTarget(), 0, &hotKey)
        shortcutWorks = status == noErr
        if !shortcutWorks {
            NSLog("unifi-viewer: cannot register %@ (status %d)", shortcut.label, status)
        }
    }

    func unregisterShortcut() {
        if let hotKey = hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
    }

    func listenToSettings() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init(shortcutChangedNotification), object: nil, queue: .main) { _ in
            self.registerShortcut()
        }
        center.addObserver(forName: .init(shortcutPausedNotification), object: nil, queue: .main) { note in
            guard let pid = (note.object as? String).flatMap({ pid_t($0) }) else { return }
            if self.pausedBy.insert(pid).inserted {
                self.watch(pid) {
                    self.pausedBy.remove(pid)
                    self.registerShortcut()
                }
            }
            self.unregisterShortcut()
        }
        center.addObserver(forName: .init(shortcutResumedNotification), object: nil, queue: .main) { note in
            guard let pid = (note.object as? String).flatMap({ pid_t($0) }) else { return }
            self.pausedBy.remove(pid)
            self.registerShortcut()
        }
    }
}

func modifierFlags(_ carbon: UInt32) -> NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if carbon & controlMask != 0 { flags.insert(.control) }
    if carbon & optionMask != 0 { flags.insert(.option) }
    if carbon & shiftMask != 0 { flags.insert(.shift) }
    if carbon & cmdMask != 0 { flags.insert(.command) }
    return flags
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = MenuBar()
        app.delegate = delegate
        // No Dock tile of our own. The viewer's mpv puts up the one you see
        // while it is open; when it is closed, the menu bar is all there is.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
