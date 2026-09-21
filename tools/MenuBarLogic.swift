// Decisions for the menu bar button, kept free of AppKit so they can be tested
// on their own. MenuBar.swift gathers the facts (where the pointer is, which
// screens exist, where the viewer window sits) and asks these what to do.
//
// Screens are passed as arrays of rectangles and answered with an index into
// that array, so the caller keeps whatever else it knows about each screen.

import CoreGraphics

enum ToggleAction: Equatable {
    case open(screen: Int)   // nothing running: start the viewer there
    case close               // stop the viewer, and with it the stream
    case move(screen: Int)   // running elsewhere: close, then open there
}

// What a click on the menu bar button should do.
//
// viewerScreen is nil when the viewer is running but has no window on any
// screen — still connecting, or showing the settings window. A click then means
// "make it go away", the same as clicking on the screen it is on.
func toggleAction(viewerRunning: Bool, viewerScreen: Int?, clickedScreen: Int) -> ToggleAction {
    guard viewerRunning else { return .open(screen: clickedScreen) }
    guard let viewerScreen = viewerScreen, viewerScreen != clickedScreen else { return .close }
    return .move(screen: clickedScreen)
}

// What the keyboard shortcut should do. Unlike a click it names no screen, so
// it opens where the viewer was last seen, or failing that where the pointer is.
func shortcutAction(viewerRunning: Bool, lastScreen: Int?, pointerScreen: Int) -> ToggleAction {
    guard viewerRunning else { return .open(screen: lastScreen ?? pointerScreen) }
    return .close
}

// A remembered screen, found again by name. nil if nothing was remembered or
// that display is no longer connected.
func screenIndex(named name: String?, in names: [String]) -> Int? {
    guard let name = name else { return nil }
    return names.firstIndex(of: name)
}

// The screen containing a point, or nil if it is on none.
//
// The pointer sits on the very top row of a screen when it clicks the menu bar,
// which is the frame's maxY — exactly the edge CGRect.contains leaves out. And
// where one display sits directly below another, that same line is also the
// upper display's bottom edge. So a screen owns its top edge but not its
// bottom one, and a click in the lower display's menu bar goes to the lower
// display. Only if that finds nothing — a point on an outer bottom or right
// edge — are all edges allowed.
func screenIndex(containing point: CGPoint, in frames: [CGRect]) -> Int? {
    let owned = frames.firstIndex { frame in
        point.x >= frame.minX && point.x < frame.maxX &&
        point.y > frame.minY && point.y <= frame.maxY
    }
    return owned ?? frames.firstIndex { frame in
        point.x >= frame.minX && point.x <= frame.maxX &&
        point.y >= frame.minY && point.y <= frame.maxY
    }
}

// The screen holding the largest share of a window, or nil if it is on none.
// A window straddling two displays belongs to the one showing more of it, which
// is also how macOS decides where it lives.
func screenIndex(forWindow window: CGRect, in frames: [CGRect]) -> Int? {
    var best: Int? = nil
    var bestArea: CGFloat = 0
    for (i, frame) in frames.enumerated() {
        let overlap = frame.intersection(window)
        guard !overlap.isNull else { continue }
        let area = overlap.width * overlap.height
        if area > bestArea {
            best = i
            bestArea = area
        }
    }
    return best
}
