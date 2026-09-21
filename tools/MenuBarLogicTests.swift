// Unit tests for MenuBarLogic.swift. Run by test.sh:
//
//   swiftc -parse-as-library tools/MenuBarLogic.swift tools/MenuBarLogicTests.swift
//
// Plain assertions, no XCTest, to match test.sh. Prints one line per failure
// and a final "N passed, M failed" line that test.sh adds to its own totals.

import CoreGraphics

@main
enum MenuBarLogicTests {
    static var pass = 0
    static var fail = 0

    static func assertEq<T: Equatable>(_ desc: String, _ expected: T, _ actual: T) {
        if expected == actual {
            pass += 1
        } else {
            fail += 1
            print("FAIL: \(desc)\n  expected: \(expected)\n  actual:   \(actual)")
        }
    }

    // The two displays this was developed on, as the system reports them.
    // Cocoa frames: origin bottom-left of the main display, y up. The built-in
    // sits below the Studio Display and a little to the right.
    static let studio = CGRect(x: 0, y: 0, width: 3200, height: 1800)
    static let builtin = CGRect(x: 699, y: -1169, width: 1800, height: 1169)
    static let cocoa = [studio, builtin]

    // The same displays as CGDisplayBounds gives them: origin top-left, y down.
    // Window positions from CGWindowList use this system.
    static let cgStudio = CGRect(x: 0, y: 0, width: 3200, height: 1800)
    static let cgBuiltin = CGRect(x: 699, y: 1800, width: 1800, height: 1169)
    static let cg = [cgStudio, cgBuiltin]

    static func main() {
        // --- toggleAction ---------------------------------------------------

        assertEq("closed: click opens on the clicked screen",
                 ToggleAction.open(screen: 1),
                 toggleAction(viewerRunning: false, viewerScreen: nil, clickedScreen: 1))
        assertEq("closed: a stale screen is ignored",
                 ToggleAction.open(screen: 0),
                 toggleAction(viewerRunning: false, viewerScreen: 1, clickedScreen: 0))
        assertEq("open here: click closes",
                 ToggleAction.close,
                 toggleAction(viewerRunning: true, viewerScreen: 0, clickedScreen: 0))
        assertEq("open elsewhere: click moves it here",
                 ToggleAction.move(screen: 1),
                 toggleAction(viewerRunning: true, viewerScreen: 0, clickedScreen: 1))
        assertEq("running with no window yet: click closes",
                 ToggleAction.close,
                 toggleAction(viewerRunning: true, viewerScreen: nil, clickedScreen: 1))

        // --- screenIndex(containing:) ---------------------------------------

        assertEq("point in the middle of the main display",
                 0, screenIndex(containing: CGPoint(x: 1600, y: 900), in: cocoa))
        assertEq("menu bar click: top edge of the main display",
                 0, screenIndex(containing: CGPoint(x: 2000, y: 1800), in: cocoa))
        // y = 0 is both the built-in's top edge and the main display's bottom.
        assertEq("menu bar click: top edge of the built-in, shared with the main",
                 1, screenIndex(containing: CGPoint(x: 1000, y: 0), in: cocoa))
        assertEq("bottom edge of the main with nothing below it",
                 0, screenIndex(containing: CGPoint(x: 100, y: 0), in: cocoa))
        assertEq("far right edge of the main display",
                 0, screenIndex(containing: CGPoint(x: 3200, y: 900), in: cocoa))
        assertEq("left of the built-in, below the main: on neither",
                 nil, screenIndex(containing: CGPoint(x: 100, y: -500), in: cocoa))
        assertEq("no screens at all",
                 nil, screenIndex(containing: CGPoint(x: 0, y: 0), in: []))

        // --- screenIndex(forWindow:) ----------------------------------------

        // Measured: the viewer opened with --screen-name on the built-in.
        assertEq("window measured on the built-in",
                 1, screenIndex(forWindow: CGRect(x: 1439, y: 2315, width: 320, height: 180), in: cg))
        assertEq("window on the main display",
                 0, screenIndex(forWindow: CGRect(x: 100, y: 100, width: 2560, height: 720), in: cg))
        assertEq("straddling: mostly on the main display",
                 0, screenIndex(forWindow: CGRect(x: 1000, y: 1500, width: 1000, height: 400), in: cg))
        assertEq("straddling: mostly on the built-in",
                 1, screenIndex(forWindow: CGRect(x: 1000, y: 1700, width: 1000, height: 400), in: cg))
        assertEq("off every screen",
                 nil, screenIndex(forWindow: CGRect(x: -5000, y: -5000, width: 100, height: 100), in: cg))
        assertEq("touching an edge is not being on it",
                 nil, screenIndex(forWindow: CGRect(x: 3200, y: 0, width: 100, height: 100), in: [cgStudio]))

        print("\(pass) passed, \(fail) failed")
        if fail > 0 { exit(1) }
    }
}
