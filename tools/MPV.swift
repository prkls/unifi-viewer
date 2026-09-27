// Talking to mpv over its JSON IPC socket, and the two things the menu bar
// button draws for the viewer: the right-click menu and the "Loading" panel.
// Free of AppKit so it can be tested on its own.
//
// mpv speaks newline-delimited JSON on a Unix socket (--input-ipc-server in
// view.sh). We send commands and receive two kinds of message: replies to our
// commands, and events. The events that matter:
//
//   property-change   a property we asked to watch has a new value
//   client-message    a key in the viewer ran "script-message <name>", which
//                     mpv broadcasts to every client, us included
//
// This replaces tools/menu.lua. mpv then needs no scripting engine at all,
// which is what lets the app ship an mpv built without LuaJIT — see the notes
// in README.md.

import Foundation

// --- messages from mpv ------------------------------------------------------

enum MPVMessage: Equatable {
    case property(name: String, value: MPVValue)
    case message(args: [String])      // client-message: a key in the viewer
    case reply(id: Int, value: MPVValue, error: String)
    case other(event: String)
}

// The handful of value shapes mpv sends back for the properties we watch.
enum MPVValue: Equatable {
    case none
    case bool(Bool)
    case number(Double)
    case text(String)
    case size(width: Int, height: Int)   // from video-params

    var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var text: String? {
        if case .text(let s) = self { return s }
        return nil
    }
}

func parseMPV(_ line: String) -> MPVMessage? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    if let event = object["event"] as? String {
        switch event {
        case "property-change":
            guard let name = object["name"] as? String else { return nil }
            return .property(name: name, value: mpvValue(object["data"]))
        case "client-message":
            let args = (object["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            return .message(args: args)
        default:
            return .other(event: event)
        }
    }

    if let id = object["request_id"] as? Int {
        return .reply(id: id, value: mpvValue(object["data"]),
                      error: object["error"] as? String ?? "")
    }
    return nil
}

// video-params arrives as a map; dw and dh are the size the window is sized
// for, after aspect correction. Everything else is a plain value.
func mpvValue(_ raw: Any?) -> MPVValue {
    switch raw {
    case let b as Bool: return .bool(b)
    case let n as NSNumber:
        // JSONSerialization hands booleans over as NSNumber too.
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
        return .number(n.doubleValue)
    case let s as String: return .text(s)
    case let map as [String: Any]:
        if let w = map["dw"] as? Int, let h = map["dh"] as? Int, w > 0, h > 0 {
            return .size(width: w, height: h)
        }
        return .none
    default:
        return .none
    }
}

// --- commands to mpv --------------------------------------------------------

// One line of JSON for the socket. Values are Int, Double, String, Bool or the
// arrays and dictionaries a menu is made of.
func mpvRequest(_ command: [Any], id: Int) -> String? {
    let object: [String: Any] = ["command": command, "request_id": id]
    guard JSONSerialization.isValidJSONObject(object),
          // Sorted keys so the line is the same every time, which the tests rely on.
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8)
    else { return nil }
    return line + "\n"
}

// --- the viewer's right-click menu ------------------------------------------

// What a menu item does. The helper runs these itself, so nothing is sent to
// mpv that mpv would have to understand.
enum ViewerAction: Equatable {
    case selectFeed(Int)
    case reload
    case settings
    case quit
}

struct ViewerMenuItem: Equatable {
    var title: String
    var action: ViewerAction?     // nil for a separator
    var shortcut: String
    var checked: Bool

    static let separator = ViewerMenuItem(title: "", action: nil, shortcut: "", checked: false)
}

// The menu for the feeds configured, with the one playing ticked. Same shape
// as the menu menu.lua used to build, so the viewer behaves as before.
func viewerMenu(feeds: [(index: Int, key: String, name: String)], current: Int?) -> [ViewerMenuItem] {
    var items = feeds.map {
        ViewerMenuItem(title: $0.name, action: .selectFeed($0.index),
                       shortcut: $0.key, checked: $0.index == current)
    }
    if !items.isEmpty {
        items.append(.separator)
        items.append(ViewerMenuItem(title: "Reload (back to live)", action: .reload,
                                    shortcut: "r", checked: false))
    }
    items.append(ViewerMenuItem(title: "Camera Settings...", action: .settings,
                                shortcut: ",", checked: false))
    items.append(.separator)
    items.append(ViewerMenuItem(title: "Quit", action: .quit, shortcut: "q", checked: false))
    return items
}

// --- the "Loading" panel ----------------------------------------------------

// Switching feeds means a stream setup of several seconds, during which the
// window would sit on a frozen last frame. This covers it with a dimmed panel
// naming the feed being opened, drawn by mpv's osd-overlay command.
//
// In ASS, alpha 00 is opaque and FF invisible, so 70 leaves the old picture
// faintly visible. The text is sized off the frame height so it reads the same
// on a 360p and a 2160p stream; these feeds are very wide, so height is the
// sane reference.
func loadingOverlay(feed name: String, width: Int, height: Int) -> String {
    let size = max(22, height / 10)
    let dim = "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H000000&\\1a&H70&}"
        + "{\\p1}m 0 0 l \(width) 0 l \(width) \(height) l 0 \(height){\\p0}"
    let label = "{\\an5\\pos(\(width / 2),\(height / 2))\\bord2\\3c&H000000&\\shad0"
        + "\\1c&HFFFFFF&\\fs\(size)}Loading \(name)"
    return dim + "\n" + label
}
