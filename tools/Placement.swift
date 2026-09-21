// Where the viewer window goes on each screen, once you have moved or resized
// it there. Free of AppKit so it can be tested on its own.
//
// Size is kept as a scale, not a width and height. The feeds differ in shape —
// a 32:9 panorama, a portrait doorbell — and mpv given a fixed size squeezes
// every feed into that one shape. Given a scale, it opens each feed at that
// fraction of its own size, and keeps it across feed switches.
//
// Position is kept the way mpv's --geometry takes it: pixels from the top-left
// of the screen's visible area, the part below the menu bar (tested on 0.41,
// with the default --macos-geometry-calculation=visible).

import CoreGraphics
import Foundation

struct Placement: Equatable {
    var offset: CGPoint? = nil   // nil: centred, as mpv does by default
    var scale: Double? = nil     // nil: 1, each feed at its own size

    var isDefault: Bool { return offset == nil && scale == nil }

    // "<x> <y> <scale>", with "-" for anything not set: "200 150 0.75".
    var encoded: String {
        let x = offset.map { String(Int($0.x)) } ?? "-"
        let y = offset.map { String(Int($0.y)) } ?? "-"
        let s = scale.map { String($0) } ?? "-"
        return "\(x) \(y) \(s)"
    }

    init(offset: CGPoint? = nil, scale: Double? = nil) {
        self.offset = offset
        self.scale = scale
    }

    // nil for anything unreadable, so a damaged preference means "default"
    // rather than a window somewhere odd.
    init?(encoded: String) {
        let parts = encoded.split(separator: " ").map(String.init)
        guard parts.count == 3 else { return nil }
        if parts[0] == "-" && parts[1] == "-" {
            offset = nil
        } else if let x = Int(parts[0]), let y = Int(parts[1]) {
            offset = CGPoint(x: x, y: y)
        } else {
            return nil
        }
        if parts[2] == "-" {
            scale = nil
        } else if let s = Double(parts[2]), s > 0 {
            scale = s
        } else {
            return nil
        }
    }
}

// A Cocoa rectangle (origin bottom-left of the main display, y up) in Quartz
// coordinates (origin top-left, y down), which is what CGWindowList reports.
func quartzRect(fromCocoa rect: CGRect, mainHeight: CGFloat) -> CGRect {
    return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
}

// Where a window sits, as mpv's --geometry offset: pixels from the top-left of
// the visible area. Window and visible area are in Quartz points; mpv counts
// pixels, so a Retina screen doubles the numbers.
//
// The visible area must be the one an app sees. On a MacBook display with a
// notch, apps get a menu bar 2 points taller than a command-line process does
// (40 against 38, measured), and mpv, being an app, places windows by the
// app's figure. The menu bar button, also an app, sees the same one, so the
// conversion is exact both ways (tested on mpv 0.41).
func geometryOffset(window: CGRect, visible: CGRect, backing: CGFloat) -> CGPoint {
    return CGPoint(x: ((window.minX - visible.minX) * backing).rounded(),
                   y: ((window.minY - visible.minY) * backing).rounded())
}

// Whether a saved offset still makes sense on this screen. A resolution change
// or a smaller display can leave it past the far edge; the window then opens
// centred instead.
//
// The corner may be off the left or top: a window as wide as the screen is
// easily dragged part-way off it. How far is limited to half the visible area,
// since the window's size is not known until its feed opens, and a corner far
// off the edge could leave a small window out of sight.
func offsetFits(_ offset: CGPoint, visible: CGRect, backing: CGFloat) -> Bool {
    let width = visible.width * backing
    let height = visible.height * backing
    return offset.x > -width / 2 && offset.x < width &&
        offset.y > -height / 2 && offset.y < height
}

// The --geometry value for a placement, or "" for mpv's own choice. A corner
// off the left or top is written "+-380", which mpv reads as 380 pixels past
// that edge; plain "-380" would mean 380 pixels from the right (tested on
// 0.41). macOS keeps the top below the menu bar whatever mpv asks.
func geometryArgument(_ placement: Placement) -> String {
    guard let offset = placement.offset else { return "" }
    return "+\(Int(offset.x))+\(Int(offset.y))"
}

// The placement a screen really opens with: its saved one, less a position
// that no longer fits (see offsetFits), which mpv would otherwise be asked for.
func usable(_ placement: Placement, visible: CGRect, backing: CGFloat) -> Placement {
    var result = placement
    if let offset = placement.offset, !offsetFits(offset, visible: visible, backing: backing) {
        result.offset = nil
    }
    return result
}

// Whether the window is no longer where its placement puts it — which only
// you can have done. mpv never moves a window's corner away from a saved
// position, even when a feed of another size opens; and a window with no
// saved position it keeps centred, feed switches included. So the answer is
// the same whenever the question is asked, and nothing depends on having
// seen the window before.
//
// "Moved" means by more than a point. A saved position above the top (see
// geometryArgument) comes back pushed down below the menu bar, and counts as
// moved: the position saved then is where the window really is.
func hasMoved(_ window: CGRect, from placement: Placement, visible: CGRect, backing: CGFloat) -> Bool {
    if let offset = placement.offset {
        let now = geometryOffset(window: window, visible: visible, backing: backing)
        return abs(now.x - offset.x) > backing || abs(now.y - offset.y) > backing
    }
    return abs(window.midX - visible.midX) > 1.5 || abs(window.midY - visible.midY) > 1.5
}

// What menu.lua reports, one line per event:
//
//   <seq> scale <value>   you resized the window to this scale
//   <seq> reset           you pressed the reset shortcut
//   <seq> feed <n>        feed n started opening; only logged, since size is
//                         a scale and the same for every feed
//
// seq counts up from 1 each time the viewer opens, carrying on across the
// restart a reset causes, so the menu bar button can tell which lines it has
// already acted on.
enum WindowEvent: Equatable {
    case scale(Double)
    case reset
    case feed(Int)
}

func windowEvents(_ text: String, after seen: Int) -> (events: [WindowEvent], last: Int) {
    var events: [WindowEvent] = []
    var last = seen
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let seq = Int(parts[0]), seq > last else { continue }
        switch (parts[1], parts.count) {
        case ("scale", 3):
            guard let value = Double(parts[2]), value > 0 else { continue }
            events.append(.scale(value))
        case ("reset", 2):
            events.append(.reset)
        case ("feed", 3):
            guard let index = Int(parts[2]) else { continue }
            events.append(.feed(index))
        default:
            continue
        }
        last = seq
    }
    return (events, last)
}

// What one look at the window changes about a screen's saved placement.
//
//   saved         what the screen had saved before this look
//   events        menu.lua's reports not yet acted on, oldest first
//   moved         whether the window was dragged since the last look
//   offset        where its corner is now, as a --geometry offset
//   sessionScale  the scale the window is at, as far as is known so far
//
// A resize keeps the new scale and where the corner is. A reset clears the
// screen back to mpv's default, and a move reported in the same look is
// ignored: it is the restart putting the window back, not a drag. A move keeps
// the new position with the scale the window is at, so a window dragged here
// from another screen keeps its size.
struct TrackOutcome: Equatable {
    var placement: Placement
    var sessionScale: Double?
    var changed: Bool
    var wasReset: Bool
}

func track(saved: Placement, events: [WindowEvent], moved: Bool, offset: CGPoint,
           sessionScale: Double?) -> TrackOutcome {
    var outcome = TrackOutcome(placement: saved, sessionScale: sessionScale, changed: false, wasReset: false)
    for event in events {
        switch event {
        case .scale(let value):
            outcome.sessionScale = value
            outcome.placement.scale = value
            outcome.placement.offset = offset
        case .reset:
            outcome.placement = Placement()
            outcome.sessionScale = nil
            outcome.wasReset = true
        case .feed:
            continue
        }
        outcome.changed = true
    }
    if moved && !outcome.wasReset {
        outcome.placement.offset = offset
        outcome.placement.scale = outcome.sessionScale
        outcome.changed = true
    }
    return outcome
}

// The last `keep` lines of a log, so it cannot grow without bound.
func trimmedLog(_ text: String, keeping keep: Int) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let body = lines.last == "" ? lines.dropLast() : lines[...]
    guard body.count > keep else { return text }
    return body.suffix(keep).joined(separator: "\n") + "\n"
}
