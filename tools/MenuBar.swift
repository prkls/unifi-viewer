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
let windowEventsFile = cacheDir + "/window"   // written by menu.lua, read here

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
    var tracker: Timer?               // follows the viewer's window while it is open

    // About the window of the viewer now open.
    var calibration: (screen: String, requested: CGPoint, observed: CGPoint?)?
    var sessionScale: Double?         // the scale it is at, nil for mpv's own
    var previousFrame: CGRect?        // where it was at the last look
    var ignoreMovesUntil = Date.distantPast
    var seenEvents = 0                // menu.lua lines already acted on

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

    func applicationWillTerminate(_ notification: Notification) {
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

    @objc func quit() {
        NSApp.terminate(nil)
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

        var placement = Placement()
        if let screen = screen {
            placement = savedPlacement(screen.name)
            // A resolution change or a smaller display can leave a saved corner
            // off the edge; centre instead.
            if let offset = placement.offset,
               !offsetFits(offset, visible: screen.visible, backing: screen.backing) {
                placement.offset = nil
            }
        }
        try? FileManager.default.removeItem(atPath: windowEventsFile)
        seenEvents = 0
        writePlacementFile(screen?.name, placement)
        calibration = screen.flatMap { s in placement.offset.map { (s.name, $0, nil) } }
        sessionScale = placement.scale
        previousFrame = nil
        ignoreMovesUntil = .distantPast

        guard let pid = spawnGroup(launcher) else { return }
        viewer = pid
        if let name = screen?.name { remember(name) }
        // Follows the window while the viewer is open, and only then, so a
        // closed viewer still costs nothing.
        tracker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            self.trackViewer()
        }
        handOver(to: pid)
        watch(pid) {
            self.tracker?.invalidate()
            self.tracker = nil
            self.viewer = nil
            // Nothing left to place; a later run from a terminal gets defaults.
            try? FileManager.default.removeItem(atPath: placementFile)
            try? FileManager.default.removeItem(atPath: windowEventsFile)
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
        trackViewer()
        kill(-pid, SIGTERM)
        // mpv exits within a fraction of a second on SIGTERM. If anything in the
        // group ignores it, do not let a stuck process block the next open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.viewer == pid { kill(-pid, SIGKILL) }
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
        if let scale = placement.scale { text += String(format: "scale=%.4f\n", scale) }
        let geometry = geometryArgument(placement)
        if !geometry.isEmpty { text += "geometry=\(geometry)\n" }
        try? FileManager.default.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        try? text.write(toFile: placementFile, atomically: true, encoding: .utf8)
    }

    func offset(of window: CGRect, on screen: Screen) -> CGPoint {
        var pair: Calibration? = nil
        if let c = calibration, c.screen == screen.name, let observed = c.observed {
            pair = Calibration(requested: c.requested, observed: observed)
        }
        return geometryOffset(window: window, visible: screen.visible, backing: screen.backing,
                              calibration: pair)
    }

    // Every 2 seconds while the viewer is open, and once more as it closes:
    // which screen the window is on, and whether you moved or resized it.
    func trackViewer() {
        guard let frame = viewerWindow() else { return }
        let screens = currentScreens()
        guard let i = screenIndex(forWindow: frame, in: screens.map { $0.bounds }) else { return }
        let screen = screens[i]
        remember(screen.name)

        // The first sight of a window opened at a saved position: where mpv
        // really put it, for measuring every later position against.
        if let c = calibration, c.screen == screen.name, c.observed == nil {
            calibration = (c.screen, c.requested, frame.origin)
        }

        var placement = savedPlacement(screen.name)
        var changed = false

        let text = (try? String(contentsOfFile: windowEventsFile, encoding: .utf8)) ?? ""
        let (events, last) = windowEvents(text, after: seenEvents)
        seenEvents = last
        for event in events {
            switch event {
            case .scale(let value):
                sessionScale = value
                placement.scale = value
                placement.offset = offset(of: frame, on: screen)
                changed = true
            case .reset:
                // view.sh restarts mpv at its defaults. Until the new window
                // has settled, a change of position is that, not a drag: the
                // restart includes connecting to the camera, which occasionally
                // takes over 30 seconds.
                placement = Placement()
                sessionScale = nil
                calibration = nil
                previousFrame = nil
                ignoreMovesUntil = Date().addingTimeInterval(40)
                changed = true
            }
        }

        if Date() >= ignoreMovesUntil, let previous = previousFrame,
           isUserMove(from: previous, to: frame) {
            placement.offset = offset(of: frame, on: screen)
            // Dragged here from another screen, it keeps the size it had.
            placement.scale = sessionScale
            changed = true
        }
        previousFrame = frame

        if changed {
            save(placement, for: screen.name)
            writePlacementFile(screen.name, placement)
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
