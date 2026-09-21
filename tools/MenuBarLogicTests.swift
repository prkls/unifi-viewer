// Unit tests for MenuBarLogic.swift, Shortcut.swift and Placement.swift. Run by test.sh:
//
//   swiftc -parse-as-library tools/MenuBarLogic.swift tools/Shortcut.swift tools/Placement.swift tools/MenuBarLogicTests.swift
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

        // --- Placement ---------------------------------------------------------

        let placed = Placement(offset: CGPoint(x: 200, y: 150), scale: 0.75)
        assertEq("placement encodes", "200 150 0.75", placed.encoded)
        assertEq("placement round-trips", placed, Placement(encoded: placed.encoded))
        assertEq("scale only round-trips", Placement(scale: 0.5), Placement(encoded: "- - 0.5"))
        assertEq("position only round-trips", Placement(offset: CGPoint(x: 0, y: 12)), Placement(encoded: "0 12 -"))
        assertEq("default encodes as dashes", "- - -", Placement().encoded)
        assertEq("default is default", true, Placement().isDefault)
        assertEq("scale alone is not default", false, Placement(scale: 0.5).isDefault)
        assertEq("junk does not decode", nil, Placement(encoded: "left top big"))
        assertEq("half a position does not decode", nil, Placement(encoded: "200 - 0.5"))
        assertEq("zero scale does not decode", nil, Placement(encoded: "- - 0"))
        assertEq("too few fields do not decode", nil, Placement(encoded: "200 150"))

        assertEq("no position: mpv's own choice", "", geometryArgument(Placement(scale: 0.5)))
        assertEq("position as --geometry", "+200+150", geometryArgument(placed))
        // Measured: dragged part-way off the left, then reopened exactly there.
        assertEq("off the left edge as --geometry", "+-380+570",
                 geometryArgument(Placement(offset: CGPoint(x: -380, y: 570))))
        assertEq("off-left position round-trips", Placement(offset: CGPoint(x: -380, y: 570), scale: 0.625),
                 Placement(encoded: "-380 570 0.625"))

        // --- quartzRect ---------------------------------------------------------

        // visibleFrame as NSScreen reports it to an app, below each menu bar.
        // The built-in's menu bar is 40 points, since it has a notch.
        let studioVisible = quartzRect(fromCocoa: CGRect(x: 0, y: 0, width: 3200, height: 1769), mainHeight: 1800)
        let builtinVisible = quartzRect(fromCocoa: CGRect(x: 699, y: -1169, width: 1800, height: 1129), mainHeight: 1800)
        assertEq("main display's visible area starts below its menu bar",
                 CGRect(x: 0, y: 31, width: 3200, height: 1769), studioVisible)
        assertEq("built-in's visible area, below the main display",
                 CGRect(x: 699, y: 1840, width: 1800, height: 1129), builtinVisible)

        // --- geometryOffset -----------------------------------------------------

        // Measured: +200+150 on the main display put the corner at 100,106.
        assertEq("main display: offset from the visible area, in pixels",
                 CGPoint(x: 200, y: 150),
                 geometryOffset(window: CGRect(x: 100, y: 106, width: 320, height: 180),
                                visible: studioVisible, backing: 2))
        // Measured: +200+150 on the built-in put the corner at 799,1915.
        assertEq("built-in: exact, so it cannot creep",
                 CGPoint(x: 200, y: 150),
                 geometryOffset(window: CGRect(x: 799, y: 1915, width: 320, height: 180),
                                visible: builtinVisible, backing: 2))
        // Measured: +1590+240 on the built-in put the corner at 1494,1960.
        assertEq("built-in: a second measured position",
                 CGPoint(x: 1590, y: 240),
                 geometryOffset(window: CGRect(x: 1494, y: 1960, width: 922, height: 259),
                                visible: builtinVisible, backing: 2))
        assertEq("at the very top: offset 0",
                 CGPoint(x: 1350, y: 0),
                 geometryOffset(window: CGRect(x: 1374, y: 1840, width: 922, height: 259),
                                visible: builtinVisible, backing: 2))

        // --- offsetFits ---------------------------------------------------------

        assertEq("corner on the screen fits", true,
                 offsetFits(CGPoint(x: 200, y: 150), visible: studioVisible, backing: 2))
        assertEq("top-left corner itself fits", true,
                 offsetFits(CGPoint(x: 0, y: 0), visible: studioVisible, backing: 2))
        assertEq("past the right edge does not fit", false,
                 offsetFits(CGPoint(x: 6400, y: 150), visible: studioVisible, backing: 2))
        assertEq("past the bottom of a smaller screen does not fit", false,
                 offsetFits(CGPoint(x: 200, y: 3000), visible: builtinVisible, backing: 2))
        assertEq("part-way off the left fits", true,
                 offsetFits(CGPoint(x: -380, y: 570), visible: studioVisible, backing: 2))
        assertEq("part-way off the top fits", true,
                 offsetFits(CGPoint(x: 200, y: -40), visible: studioVisible, backing: 2))
        assertEq("more than half off the left does not fit", false,
                 offsetFits(CGPoint(x: -3300, y: 570), visible: studioVisible, backing: 2))

        // --- usable -------------------------------------------------------------

        assertEq("a position that fits is kept", placed, usable(placed, visible: studioVisible, backing: 2))
        assertEq("a position past the edge is dropped, the scale kept", Placement(scale: 0.5),
                 usable(Placement(offset: CGPoint(x: 9000, y: 150), scale: 0.5), visible: studioVisible, backing: 2))

        // --- hasMoved ---------------------------------------------------------------

        let anchored = Placement(offset: CGPoint(x: 1590, y: 240), scale: 0.24)
        // Measured: +1590+240 on the built-in puts the corner at 1494,1960.
        assertEq("where it was put: not moved", false,
                 hasMoved(CGRect(x: 1494, y: 1960, width: 922, height: 259), from: anchored,
                          visible: builtinVisible, backing: 2))
        assertEq("a feed of another size keeps the corner: not moved", false,
                 hasMoved(CGRect(x: 1494, y: 1960, width: 240, height: 320), from: anchored,
                          visible: builtinVisible, backing: 2))
        assertEq("dragged: moved", true,
                 hasMoved(CGRect(x: 1394, y: 2060, width: 922, height: 259), from: anchored,
                          visible: builtinVisible, backing: 2))
        assertEq("half a point is not a move", false,
                 hasMoved(CGRect(x: 1494.5, y: 1960, width: 922, height: 259), from: anchored,
                          visible: builtinVisible, backing: 2))
        // Measured: the opening animation passes through 1501,1960 on the way.
        assertEq("mid-animation it looks moved; the next look puts it right", true,
                 hasMoved(CGRect(x: 1501, y: 1960, width: 908, height: 255), from: anchored,
                          visible: builtinVisible, backing: 2))
        assertEq("pushed below the menu bar from above the top: moved, so saved as it is", true,
                 hasMoved(CGRect(x: 1374, y: 1840, width: 922, height: 259),
                          from: Placement(offset: CGPoint(x: 1350, y: -4)),
                          visible: builtinVisible, backing: 2))

        // Measured defaults, centred by mpv on each screen.
        assertEq("centred on the main display: not moved", false,
                 hasMoved(CGRect(x: 0, y: 466, width: 3200, height: 900), from: Placement(),
                          visible: studioVisible, backing: 2))
        assertEq("centred on the built-in: not moved", false,
                 hasMoved(CGRect(x: 699, y: 2152, width: 1800, height: 506), from: Placement(),
                          visible: builtinVisible, backing: 2))
        // The opening animation grows the window about its centre: measured on
        // the built-in, 1501 + 908/2 and 1494 + 922/2 are both 1955.
        assertEq("centred window mid-animation: not moved", false,
                 hasMoved(CGRect(x: 7, y: 468, width: 3186, height: 896), from: Placement(),
                          visible: studioVisible, backing: 2))
        assertEq("centred window of another feed: not moved", false,
                 hasMoved(CGRect(x: 1360, y: 596, width: 480, height: 640), from: Placement(scale: 0.5),
                          visible: studioVisible, backing: 2))
        assertEq("centred window dragged: moved", true,
                 hasMoved(CGRect(x: 100, y: 466, width: 3200, height: 900), from: Placement(),
                          visible: studioVisible, backing: 2))

        // --- windowEvents -------------------------------------------------------

        let log = "1 video 7680 2160\n2 reset\n3 feed 2\n4 video 1920 2560\n"
        assertEq("all events read", [WindowEvent.video(7680, 2160), .reset, .feed(2), .video(1920, 2560)],
                 windowEvents(log, after: 0).events)
        assertEq("last sequence number", 4, windowEvents(log, after: 0).last)
        assertEq("only events not yet seen", [WindowEvent.video(1920, 2560)], windowEvents(log, after: 3).events)
        assertEq("nothing new", [WindowEvent](), windowEvents(log, after: 4).events)
        assertEq("nothing new keeps the count", 4, windowEvents(log, after: 4).last)
        assertEq("garbled lines skipped", [WindowEvent.reset],
                 windowEvents("x video 1 1\n1 video 7680\n2 video 0 5\n3 reset\n4 wobble\n5 feed x\n", after: 0).events)
        assertEq("empty file", [WindowEvent](), windowEvents("", after: 0).events)

        // --- expectedSize and resizedScale ------------------------------------

        let driveway = CGSize(width: 7680, height: 2160)
        let door = CGSize(width: 1920, height: 2560)
        // Measured on mpv 0.41: Driveway at scale 1 is fitted to each screen.
        assertEq("Driveway at 1 on the Studio Display: fitted to its width",
                 CGSize(width: 3200, height: 900),
                 expectedSize(video: driveway, scale: nil, visible: studioVisible, backing: 2))
        assertEq("Driveway at 1 on the built-in: fitted to its width",
                 CGSize(width: 1800, height: 506.25),
                 expectedSize(video: driveway, scale: 1, visible: builtinVisible, backing: 2))
        // Measured: scale 0.24 put Driveway at 922x259 on the built-in.
        assertEq("Driveway at 0.24: its own size, not fitted",
                 CGSize(width: 7680 * 0.24 / 2, height: 2160 * 0.24 / 2),
                 expectedSize(video: driveway, scale: 0.24, visible: builtinVisible, backing: 2))
        // Measured: Door at scale 0.25 came out 240x320.
        assertEq("Door at 0.25", CGSize(width: 240, height: 320),
                 expectedSize(video: door, scale: 0.25, visible: builtinVisible, backing: 2))
        assertEq("Door at 1 on the built-in: fitted to its height",
                 CGSize(width: 846.75, height: 1129),
                 expectedSize(video: door, scale: 1, visible: builtinVisible, backing: 2))

        assertEq("as mpv made it: not resized", nil,
                 resizedScale(window: CGRect(x: 0, y: 466, width: 3200, height: 900), video: driveway,
                              scale: nil, visible: studioVisible, backing: 2))
        assertEq("rounded to whole points by mpv: not resized", nil,
                 resizedScale(window: CGRect(x: 699, y: 2152, width: 1800, height: 506), video: driveway,
                              scale: 1, visible: builtinVisible, backing: 2))
        assertEq("scale kept across a feed switch: not resized", nil,
                 resizedScale(window: CGRect(x: 1494, y: 1960, width: 240, height: 320), video: door,
                              scale: 0.25, visible: builtinVisible, backing: 2))
        // Measured: the resize the settling period lost, 1220 wide to 1418.
        assertEq("resized: the new scale, from its width", 1418.0 * 2 / 7680,
                 resizedScale(window: CGRect(x: 1524, y: 605, width: 1418, height: 399), video: driveway,
                              scale: 0.3177, visible: studioVisible, backing: 2))
        assertEq("a fitted window shrunk by hand: resized", 3000.0 * 2 / 7680,
                 resizedScale(window: CGRect(x: 100, y: 466, width: 3000, height: 844), video: driveway,
                              scale: nil, visible: studioVisible, backing: 2))
        // Measured: dragged from the Studio Display to the built-in at 0.625,
        // Driveway was fitted to the built-in at 1799x506.
        assertEq("fitted on arriving at a smaller screen: not resized", nil,
                 resizedScale(window: CGRect(x: 300, y: 1900, width: 1799, height: 506), video: driveway,
                              scale: 0.625, visible: builtinVisible, backing: 2))

        assertEq("latest video report wins", CGSize(width: 1920, height: 2560),
                 latestVideo([.video(7680, 2160), .feed(2), .video(1920, 2560)], else: nil))
        assertEq("no video report keeps what was known", driveway,
                 latestVideo([.feed(2)], else: driveway))

        // --- track --------------------------------------------------------------

        let here = CGPoint(x: 1942, y: 0)
        let earlier = Placement(offset: CGPoint(x: 1542, y: 400), scale: 0.1638)
        func look(_ events: [WindowEvent] = [], moved: Bool = false, resizedTo: Double? = nil,
                  saved: Placement = earlier, sessionScale: Double? = 0.1638) -> TrackOutcome {
            return track(saved: saved, events: events, moved: moved, resizedTo: resizedTo,
                         offset: here, sessionScale: sessionScale)
        }

        assertEq("nothing happened: nothing changes", false, look().changed)
        assertEq("nothing happened: placement kept", earlier, look().placement)
        assertEq("drag: new position, same scale", Placement(offset: here, scale: 0.1638), look(moved: true).placement)
        assertEq("dragged in from another screen: keeps the size it had",
                 Placement(offset: here, scale: 0.5212),
                 look(moved: true, saved: Placement(), sessionScale: 0.5212).placement)
        assertEq("resize: new scale, corner where it is now",
                 Placement(offset: here, scale: 0.3), look(resizedTo: 0.3).placement)
        assertEq("resize: the session's scale follows", 0.3, look(resizedTo: 0.3).sessionScale)
        assertEq("resize and drag in one look: both kept",
                 Placement(offset: here, scale: 0.3), look(moved: true, resizedTo: 0.3).placement)
        assertEq("reset: back to default", Placement(), look([.reset], moved: true, resizedTo: 0.3).placement)
        assertEq("reset: reported", true, look([.reset]).wasReset)
        assertEq("reset: session scale cleared", nil, look([.reset]).sessionScale)
        assertEq("a feed switch changes nothing saved", false, look([.feed(2), .video(1920, 2560)]).changed)

        // --- trimmedLog -----------------------------------------------------------

        assertEq("short log kept whole", "a\nb\n", trimmedLog("a\nb\n", keeping: 3))
        assertEq("long log keeps its last lines", "c\nd\ne\n", trimmedLog("a\nb\nc\nd\ne\n", keeping: 3))
        assertEq("exactly at the limit: unchanged", "a\nb\nc\n", trimmedLog("a\nb\nc\n", keeping: 3))
        assertEq("empty log", "", trimmedLog("", keeping: 3))

        print("\(pass) passed, \(fail) failed")
        if fail > 0 { exit(1) }
    }
}
