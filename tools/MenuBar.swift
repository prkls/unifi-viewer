// Menu bar button for unifi-viewer. When the app is built with swiftc this is
// its main program; it stays running with nothing but a button in the menu bar,
// and starts and stops the viewer on demand.
//
//   click          open the viewer on the screen whose menu bar was clicked,
//                  close it if it is already open there, or move it there if
//                  it is open on another screen
//   right-click    Camera Settings... and Quit
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
// The decisions live in MenuBarLogic.swift, which is tested on its own. Build:
//
//   swiftc -O -parse-as-library tools/MenuBarLogic.swift tools/MenuBar.swift

import AppKit

struct Screen {
    let name: String     // what mpv's --screen-name matches
    let frame: CGRect    // Cocoa coordinates, as NSEvent.mouseLocation uses
    let bounds: CGRect   // Quartz coordinates, as CGWindowList uses
}

func currentScreens() -> [Screen] {
    return NSScreen.screens.map { screen in
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return Screen(name: screen.localizedName,
                      frame: screen.frame,
                      bounds: CGDisplayBounds(number?.uint32Value ?? 0))
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
    var watchers: [pid_t: DispatchSourceProcess] = [:]

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
        // Opening the app is asking to see the cameras, as it was before there
        // was a menu bar button.
        openViewer(on: pointerScreen())
    }

    // Double-clicking the app again while it runs in the menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if viewer == nil && settings == nil {
            openViewer(on: pointerScreen())
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

    func openViewer(on screen: Screen?) {
        guard viewer == nil else { return }
        guard let pid = spawnGroup(launcher, env: ["VIEW_SCREEN": screen?.name ?? ""]) else { return }
        viewer = pid
        handOver(to: pid)
        watch(pid) {
            self.viewer = nil
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

    func watch(_ pid: pid_t, onExit: @escaping () -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            source.cancel()
            self.watchers[pid] = nil
            onExit()
        }
        watchers[pid] = source
        source.resume()
    }
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
