// Settings window for unifi-viewer.
//
//   settings <streams.conf path>
//
// Ten rows of name + RTSP URL, prefilled from the existing file. Row order is
// the hotkey order: row 1 is key 1, row 9 is key 9, row 10 is key 0. Rows with
// an empty URL are skipped on save.
//
// Exits 0 after writing, 1 if cancelled, so view.sh can tell the difference.
//
// Deliberately does no URL validation: lib.sh already validates, and a second
// implementation here would be one more thing to keep in step. view.sh reopens
// this window when what was saved yields no usable feeds.

import AppKit

let maxFeeds = 10

struct Feed {
    var name: String
    var url: String
}

func hotkey(forRow row: Int) -> String {
    return row == 9 ? "0" : String(row + 1)
}

func readConf(_ path: String) -> [Feed] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var feeds: [Feed] = []
    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        guard let eq = trimmed.firstIndex(of: "=") else { continue }
        let name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
        let url = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if name.isEmpty || url.isEmpty { continue }
        feeds.append(Feed(name: name, url: url))
        if feeds.count == maxFeeds { break }
    }
    return feeds
}

func writeConf(_ path: String, _ feeds: [Feed]) throws {
    var text = """
    # Written by the UniFi Viewer settings window.
    #
    # One feed per line, "Name = URL". Order decides the hotkey: first line is 1,
    # ninth is 9, tenth is 0.

    """
    for feed in feeds {
        text += "\(feed.name) = \(feed.url)\n"
    }
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let path: String
    var nameFields: [NSTextField] = []
    var urlFields: [NSTextField] = []
    var window: NSWindow!

    init(path: String) {
        self.path = path
    }

    // Cmd+V and friends only reach a text field if the app has a menu bar
    // carrying the standard editing items — AppKit routes those shortcuts
    // through menu key equivalents, not to the first responder directly.
    // Without this, right-click Paste worked but Cmd+V did nothing.
    private func buildMenuBar() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // Both close and quit are a cancel here, not a save.
        appMenu.addItem(withTitle: "Close", action: #selector(cancel), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit", action: #selector(cancel), keyEquivalent: "q")
        appMenu.items.forEach { $0.target = self }
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_: Notification) {
        buildMenuBar()
        let existing = readConf(path)

        let pad: CGFloat = 20
        let rowH: CGFloat = 30
        let width: CGFloat = 700
        let innerW = width - pad * 2
        // Tall enough for every row, so the list never needs scrolling.
        let listH = CGFloat(maxFeeds) * rowH

        let list = NSView(frame: NSRect(x: 0, y: 0, width: innerW, height: listH))

        for row in 0..<maxFeeds {
            let y = listH - CGFloat(row + 1) * rowH + 3

            let key = NSTextField(labelWithString: hotkey(forRow: row))
            key.alignment = .center
            key.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            key.textColor = .secondaryLabelColor
            key.frame = NSRect(x: 0, y: y + 3, width: 20, height: 18)
            list.addSubview(key)

            let name = NSTextField(frame: NSRect(x: 26, y: y, width: 150, height: 24))
            name.placeholderString = "Name"
            name.stringValue = row < existing.count ? existing[row].name : ""
            list.addSubview(name)
            nameFields.append(name)

            let url = NSTextField(frame: NSRect(x: 184, y: y, width: width - 232, height: 24))
            url.placeholderString = "rtsps://192.168.0.1:7441/…?enableSrtp"
            url.stringValue = row < existing.count ? existing[row].url : ""
            url.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            url.lineBreakMode = .byTruncatingMiddle
            list.addSubview(url)
            urlFields.append(url)
        }

        let heading = NSTextField(labelWithString: "Camera Feeds")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let headingH = ceil(heading.fittingSize.height)

        let blurb = NSTextField(wrappingLabelWithString:
            "In Protect: click the camera → Settings → Share Livestream → enable Secure RTSPS "
            + "Output. A link then appears under each resolution.\n"
            + "The number on the left is the key that selects that feed, and the name is what "
            + "appears in the right-click menu. Leave a row blank to skip it.")
        blurb.font = .systemFont(ofSize: 11)
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = innerW
        // Measured rather than assumed: a fixed height clipped the last line as
        // soon as the wording grew.
        let blurbH = ceil(blurb.sizeThatFits(
            NSSize(width: innerW, height: .greatestFiniteMagnitude)).height)

        let buttonH: CGFloat = 30
        let gap: CGFloat = 12
        let totalH = pad + buttonH + gap + listH + gap + blurbH + 6 + headingH + pad

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: totalH))

        var y = totalH - pad - headingH
        heading.frame = NSRect(x: pad, y: y, width: innerW, height: headingH)
        content.addSubview(heading)

        y -= 6 + blurbH
        blurb.frame = NSRect(x: pad, y: y, width: innerW, height: blurbH)
        content.addSubview(blurb)

        y -= gap + listH
        let scroll = NSScrollView(frame: NSRect(x: pad, y: y, width: innerW, height: listH))
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.documentView = list
        content.addSubview(scroll)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: width - pad - 180, y: pad, width: 85, height: buttonH)
        content.addSubview(cancel)

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: width - pad - 85, y: pad, width: 85, height: buttonH)
        content.addSubview(save)

        window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Camera Settings"
        window.contentView = content
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func alert(_ message: String, _ detail: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.beginSheetModal(for: window, completionHandler: nil)
    }

    @objc func save() {
        var feeds: [Feed] = []
        for row in 0..<maxFeeds {
            let url = urlFields[row].stringValue.trimmingCharacters(in: .whitespaces)
            if url.isEmpty { continue }
            var name = nameFields[row].stringValue.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "Camera \(row + 1)" }
            // The name is everything before the first "=", so one inside it would
            // split in the wrong place when the file is read back.
            if name.contains("=") {
                alert("Name cannot contain \"=\"",
                      "Row \(row + 1): the equals sign separates the name from the URL.")
                return
            }
            feeds.append(Feed(name: name, url: url))
        }

        if feeds.isEmpty {
            alert("No feeds entered", "Paste at least one RTSP URL from Protect, or press Cancel.")
            return
        }

        do {
            try writeConf(path, feeds)
        } catch {
            alert("Could not save", "\(path)\n\n\(error.localizedDescription)")
            return
        }
        exit(0)
    }

    @objc func cancel() {
        exit(1)
    }

    // Closing the window is a cancel, not a save.
    func windowWillClose(_: Notification) {
        exit(1)
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: settings <streams.conf path>\n".data(using: .utf8)!)
    exit(2)
}

let app = NSApplication.shared
let controller = Controller(path: args[1])
app.delegate = controller
app.run()
