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

// Whether the window is no longer where its placement puts it. The answer is
// the same whenever the question is asked, and nothing depends on having seen
// the window before.
//
// mpv opens a window at its saved corner, or centred if it has none. After
// that it keeps the window's centre when the feed changes (menu.lua clears the
// start position so it does), so a feed of another size moves the corner. That
// counts as a change of position too, and saving it is right: the saved corner
// is then the corner of the feed showing, which is the feed the viewer reopens
// with. Everything else that changes the position is you.
//
// "Changed" means by more than a point. A saved position above the top (see
// geometryArgument) comes back pushed down below the menu bar, and counts as
// changed: the position saved then is where the window really is.
func hasMoved(_ window: CGRect, from placement: Placement, visible: CGRect, backing: CGFloat) -> Bool {
    if let offset = placement.offset {
        let now = geometryOffset(window: window, visible: visible, backing: backing)
        return abs(now.x - offset.x) > backing || abs(now.y - offset.y) > backing
    }
    return abs(window.midX - visible.midX) > 1.5 || abs(window.midY - visible.midY) > 1.5
}

// The size mpv gives a window, in points: the feed's own size at `scale`, and
// if that is larger than the visible area, shrunk to fit it with its shape
// kept (--autofit-larger=100%x100%). Checked against mpv 0.41: a 7680x2160
// feed at scale 1 comes out 3200x900 on the Studio Display and 1800x506 on
// the built-in.
func expectedSize(video: CGSize, scale: Double?, visible: CGRect, backing: CGFloat) -> CGSize {
    let s = CGFloat(scale ?? 1)
    var width = video.width * s / backing
    var height = video.height * s / backing
    if width > visible.width || height > visible.height {
        let fit = min(visible.width / width, visible.height / height)
        width *= fit
        height *= fit
    }
    return CGSize(width: width, height: height)
}

// The scale you resized the window to, or nil if it is the size mpv gave it.
// Like hasMoved, this compares the window with what mpv would have done, so
// the answer does not depend on when it is asked — mpv's own resizing, as a
// feed opens or the window is fitted to a screen, always matches.
func resizedScale(window: CGRect, video: CGSize, scale: Double?, visible: CGRect,
                  backing: CGFloat) -> Double? {
    let expected = expectedSize(video: video, scale: scale, visible: visible, backing: backing)
    guard abs(window.width - expected.width) > 1.5 || abs(window.height - expected.height) > 1.5 else {
        return nil
    }
    return Double(window.width * backing / video.width)
}

// What menu.lua reports, one line per event:
//
//   <seq> video <w> <h>   a feed of this size, in pixels, is now showing, and
//                         mpv has sized the window for it
//   <seq> reset           you pressed the reset shortcut
//   <seq> feed <n>        feed n started opening; only logged, since size is
//                         a scale and the same for every feed
//
// seq counts up from 1 each time the viewer opens, carrying on across the
// restart a reset causes, so the menu bar button can tell which lines it has
// already acted on.
enum WindowEvent: Equatable {
    case video(Int, Int)
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
        case ("video", 4):
            guard let width = Int(parts[2]), let height = Int(parts[3]), width > 0, height > 0 else { continue }
            events.append(.video(width, height))
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
//   moved         whether the window is no longer where it was put (hasMoved)
//   resizedTo     the scale you resized it to, if you did (resizedScale)
//   offset        where its corner is now, as a --geometry offset
//   sessionScale  the scale the window is at, as far as is known so far
//
// A resize keeps the new scale and where the corner is. A move keeps the new
// position with the scale the window is at, so a window dragged here from
// another screen keeps its size. A reset clears the screen back to mpv's
// default, and outranks anything else in the same look: the window then is
// the old one on its way out, or the new one restarting.
struct TrackOutcome: Equatable {
    var placement: Placement
    var sessionScale: Double?
    var changed: Bool
    var wasReset: Bool
}

func track(saved: Placement, events: [WindowEvent], moved: Bool, resizedTo: Double?,
           offset: CGPoint, sessionScale: Double?) -> TrackOutcome {
    var outcome = TrackOutcome(placement: saved, sessionScale: sessionScale, changed: false, wasReset: false)
    if events.contains(.reset) {
        outcome.placement = Placement()
        outcome.sessionScale = nil
        outcome.wasReset = true
        outcome.changed = true
        return outcome
    }
    if let scale = resizedTo {
        outcome.sessionScale = scale
        outcome.placement.scale = scale
        outcome.placement.offset = offset
        outcome.changed = true
    }
    if moved {
        outcome.placement.offset = offset
        outcome.placement.scale = outcome.sessionScale
        outcome.changed = true
    }
    return outcome
}

// The size of the feed showing, from the latest of menu.lua's reports, or nil
// while a feed is still opening. A feed can take many seconds to show its
// first frame, and until then the window keeps the last feed's size: judging
// it against the new feed's size then took the old size for a resize by hand
// (seen in the log, with a feed that took 13 seconds to connect). So a feed
// switch forgets the size until the new feed's own report, which comes once
// its first frame is up and mpv has sized the window for it.
func latestVideo(_ events: [WindowEvent], else current: CGSize?) -> CGSize? {
    var video = current
    for event in events {
        switch event {
        case .video(let width, let height): video = CGSize(width: width, height: height)
        case .feed: video = nil
        case .reset: video = nil
        }
    }
    return video
}

// The last `keep` lines of a log, so it cannot grow without bound.
func trimmedLog(_ text: String, keeping keep: Int) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let body = lines.last == "" ? lines.dropLast() : lines[...]
    guard body.count > keep else { return text }
    return body.suffix(keep).joined(separator: "\n") + "\n"
}
