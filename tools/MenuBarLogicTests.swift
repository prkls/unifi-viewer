// Unit tests for MenuBarLogic.swift and Shortcut.swift. Run by test.sh:
//
//   swiftc -parse-as-library tools/MenuBarLogic.swift tools/Shortcut.swift tools/MenuBarLogicTests.swift
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

        // --- shortcutAction --------------------------------------------------

        assertEq("shortcut, closed: opens on the last screen",
                 ToggleAction.open(screen: 1),
                 shortcutAction(viewerRunning: false, lastScreen: 1, pointerScreen: 0))
        assertEq("shortcut, closed, no last screen: opens where the pointer is",
                 ToggleAction.open(screen: 0),
                 shortcutAction(viewerRunning: false, lastScreen: nil, pointerScreen: 0))
        assertEq("shortcut, open: closes, wherever it is",
                 ToggleAction.close,
                 shortcutAction(viewerRunning: true, lastScreen: 1, pointerScreen: 0))

        // --- screenIndex(named:) --------------------------------------------

        let names = ["Studio Display", "Built-in Retina Display"]
        assertEq("remembered screen found", 1, screenIndex(named: "Built-in Retina Display", in: names))
        assertEq("remembered screen disconnected", nil, screenIndex(named: "LG UltraFine", in: names))
        assertEq("nothing remembered", nil, screenIndex(named: nil, in: names))

        // --- Shortcut --------------------------------------------------------

        let standard = Shortcut.standard
        assertEq("default is Control-Option-Command-U", "⌃⌥⌘U", standard.label)
        assertEq("default is key code 32", UInt32(32), standard.keyCode)
        assertEq("modifiers in Apple's order",
                 "⌃⌥⇧⌘K", Shortcut(keyCode: 40, modifiers: cmdMask | shiftMask | optionMask | controlMask, key: "K").label)
        assertEq("default is allowed", true, standard.isAllowed)
        assertEq("Command alone is allowed", true, Shortcut(keyCode: 32, modifiers: cmdMask, key: "U").isAllowed)
        assertEq("Control alone is allowed", true, Shortcut(keyCode: 32, modifiers: controlMask, key: "U").isAllowed)
        assertEq("Option-Shift only is refused", false,
                 Shortcut(keyCode: 32, modifiers: optionMask | shiftMask, key: "U").isAllowed)
        assertEq("no modifiers is refused", false, Shortcut(keyCode: 32, modifiers: 0, key: "U").isAllowed)
        assertEq("stray bits are dropped", controlMask,
                 Shortcut(keyCode: 32, modifiers: controlMask | 0x20000, key: "U").modifiers)

        assertEq("default encodes", "32 6400 U", standard.encoded)
        assertEq("encoding round-trips", standard, Shortcut(encoded: standard.encoded))
        let spaced = Shortcut(keyCode: 116, modifiers: cmdMask, key: "Page Up")
        assertEq("a key name with a space round-trips", spaced, Shortcut(encoded: spaced.encoded))
        assertEq("junk does not decode", nil, Shortcut(encoded: "hello"))
        assertEq("missing key does not decode", nil, Shortcut(encoded: "32 6400"))
        assertEq("a refused shortcut does not decode", nil, Shortcut(encoded: "32 2560 U"))
        assertEq("nothing saved: default", standard, Shortcut.from(saved: nil))
        assertEq("junk saved: default", standard, Shortcut.from(saved: "32 x U"))
        assertEq("saved shortcut is used", spaced, Shortcut.from(saved: "116 256 Page Up"))

        // --- keyLabel --------------------------------------------------------

        assertEq("letter shown in capitals", "U", keyLabel(keyCode: 32, characters: "u"))
        assertEq("digit shown as is", "5", keyLabel(keyCode: 23, characters: "5"))
        assertEq("space is named", "Space", keyLabel(keyCode: 49, characters: " "))
        assertEq("function key is named", "F5", keyLabel(keyCode: 96, characters: "\u{F708}"))
        assertEq("arrow is a symbol", "↑", keyLabel(keyCode: 126, characters: "\u{F700}"))

        // --- clashesWithSystem -----------------------------------------------

        // As CopySymbolicHotKeys reports them: Spotlight is Command-Space,
        // screenshots Shift-Command-3; the 0x20000 bit is the function key flag.
        let system = [
            SystemShortcut(keyCode: 49, modifiers: cmdMask, enabled: true),
            SystemShortcut(keyCode: 20, modifiers: cmdMask | shiftMask, enabled: true),
            SystemShortcut(keyCode: 122, modifiers: 0x20000 | cmdMask, enabled: true),
            SystemShortcut(keyCode: 40, modifiers: cmdMask | controlMask, enabled: false),
        ]
        assertEq("default does not clash", false, clashesWithSystem(standard, system))
        assertEq("Command-Space clashes with Spotlight", true,
                 clashesWithSystem(Shortcut(keyCode: 49, modifiers: cmdMask, key: "Space"), system))
        assertEq("same key, different modifiers: no clash", false,
                 clashesWithSystem(Shortcut(keyCode: 49, modifiers: cmdMask | optionMask, key: "Space"), system))
        assertEq("function key flag ignored when comparing", true,
                 clashesWithSystem(Shortcut(keyCode: 122, modifiers: cmdMask, key: "F1"), system))
        assertEq("a disabled system shortcut does not clash", false,
                 clashesWithSystem(Shortcut(keyCode: 40, modifiers: cmdMask | controlMask, key: "K"), system))

        print("\(pass) passed, \(fail) failed")
        if fail > 0 { exit(1) }
    }
}
