-- Right-click menu and feed switching for unifi-viewer.
--
-- mpv 0.41 has the read-write `menu-data` property and the `context-menu`
-- command, but not the menu.conf file support that landed after it, so the menu
-- is built here rather than declared in a config file. Building it in a script
-- also lets the tick follow whichever feed is playing.
--
-- Feeds come from a file written by view.sh rather than being parsed here, so
-- lib.sh stays the single source of truth for config and URL handling.
--
--   --script-opts=unifi-feeds_file=<path>,unifi-state_file=<path>,unifi-window_file=<path>

local mp = require "mp"
local assdraw = require "mp.assdraw"
local options = require "mp.options"

local opts = { feeds_file = "", state_file = "", window_file = "" }
options.read_options(opts, "unifi")

local feeds = {}      -- array of { index, key, name, url }
local by_index = {}
local current = nil
local overlay = mp.create_osd_overlay("ass-events")
local dimmed = false

local function read_feeds()
    local f = opts.feeds_file ~= "" and io.open(opts.feeds_file) or nil
    if not f then
        return
    end
    for line in f:lines() do
        -- "<index>\t<key>\t<name>\t<url>"
        local index, key, name, url = line:match("^(%d+)\t(%S)\t([^\t]*)\t(.+)$")
        if index then
            local feed = {
                index = tonumber(index),
                key = key,
                name = name ~= "" and name or ("Feed " .. index),
                url = url,
            }
            feeds[#feeds + 1] = feed
            by_index[feed.index] = feed
        end
    end
    f:close()
end

local function read_current()
    local f = opts.state_file ~= "" and io.open(opts.state_file) or nil
    if not f then
        return nil
    end
    local line = f:read("*l")
    f:close()
    return line and tonumber(line:match("^%s*(%d+)")) or nil
end

local function write_current(index)
    if opts.state_file == "" then
        return
    end
    local f = io.open(opts.state_file, "w")
    if f then
        f:write(tostring(index), "\n")
        f:close()
    end
end

local function build_menu()
    local items = {}

    for _, feed in ipairs(feeds) do
        items[#items + 1] = {
            title = feed.name,
            cmd = "script-message unifi-select " .. feed.index,
            shortcut = feed.key,
            state = (feed.index == current) and { "checked" } or {},
        }
    end

    if #items > 0 then
        items[#items + 1] = { type = "separator" }
        items[#items + 1] = {
            title = "Reload (back to live)",
            cmd = "script-message unifi-reload",
            shortcut = "r",
        }
    end
    -- quit 20 is view.sh's signal to open the settings window and come back.
    -- Plain comma, since the macOS menu bar's own "Settings…" holds Cmd+, and
    -- AppKit consumes menu key equivalents before mpv sees them.
    items[#items + 1] = { title = "Camera Settings...", cmd = "quit 20", shortcut = "," }
    items[#items + 1] = { type = "separator" }
    items[#items + 1] = { title = "Quit", cmd = "quit 5", shortcut = "q" }

    mp.set_property_native("menu-data", items)
end

-- Switching feeds means an RTSP handshake of several seconds during which the
-- window would otherwise sit on a frozen last frame, looking hung. Cover it with
-- a translucent panel naming the feed being opened, cleared once frames arrive.
local function show_loading(name)
    local w = mp.get_property_number("osd-width") or 1920
    local h = mp.get_property_number("osd-height") or 1080

    local ass = assdraw.ass_new()
    -- Dim panel over the whole frame. In ASS, alpha 00 is opaque and FF is
    -- invisible, so 99 leaves the old picture faintly visible underneath.
    ass:new_event()
    ass:append("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H000000&\\1a&H70&}")
    ass:draw_start()
    ass:rect_cw(0, 0, w, h)
    ass:draw_stop()

    -- Sized off the frame height so it reads the same on a 360p and a 2160p
    -- stream. These feeds are very wide, so height is the sane reference.
    ass:new_event()
    ass:append(string.format(
        "{\\an5\\pos(%d,%d)\\bord2\\3c&H000000&\\shad0\\1c&HFFFFFF&\\fs%d}Loading %s",
        w / 2, h / 2, math.max(22, math.floor(h / 10)), name))

    overlay.res_x = w
    overlay.res_y = h
    overlay.data = ass.text
    overlay:update()
    dimmed = true
end

local function hide_loading()
    if dimmed then
        overlay:remove()
        dimmed = false
    end
end

-- Window size ---------------------------------------------------------------
--
-- mpv sizes the window itself when a feed opens: each at --window-scale of its
-- own size, shrunk to fit the screen if it is larger. A resize by hand shows up
-- in the same property, current-window-scale, so mpv's own changes have to be
-- told apart: anything from a feed opening until shortly after its first frame
-- is mpv's; anything after that is yours.
--
-- A resize by hand then becomes the --window-scale for the rest of the
-- session, so the next feed opens at your size rather than back at full size,
-- and is reported to the menu bar button, which keeps it for this screen.

local settling = true       -- mpv is still sizing the window itself
local settled_scale = nil   -- current-window-scale once it had finished
local settle_timer = nil
local report_timer = nil
local pending_scale = nil   -- the latest size of a resize not yet reported

-- Numbering carries on from the lines already in the file: a reset restarts
-- mpv, and the menu bar button skips any number it has seen before.
local seq = 0
if opts.window_file ~= "" then
    local f = io.open(opts.window_file)
    if f then
        for _ in f:lines() do
            seq = seq + 1
        end
        f:close()
    end
end

local function report(event)
    if opts.window_file == "" then
        return
    end
    seq = seq + 1
    local f = io.open(opts.window_file, "a")
    if f then
        f:write(tostring(seq), " ", event, "\n")
        f:close()
    end
end

-- A resize still waiting to be reported is dropped too: once a feed is
-- opening, the size it would read is mpv's, not yours.
local function settle()
    settling = true
    if settle_timer then
        settle_timer:kill()
        settle_timer = nil
    end
    if report_timer then
        report_timer:kill()
        report_timer = nil
    end
end

-- 1.5s after the first frame: long enough for mpv's own resize to land.
local function settle_after_first_frame()
    if settle_timer then
        settle_timer:kill()
    end
    settle_timer = mp.add_timeout(1.5, function()
        settle_timer = nil
        settling = false
        settled_scale = mp.get_property_number("current-window-scale")
    end)
end

-- Uses the size mpv last sent rather than asking again: at shutdown the window
-- may already be gone.
local function report_resize()
    report_timer = nil
    local final = pending_scale
    if not settling and final and math.abs(final - settled_scale) >= 0.005 then
        settled_scale = final
        mp.set_property_number("window-scale", final)
        report(string.format("scale %.4f", final))
    end
end

mp.observe_property("current-window-scale", "number", function(_, scale)
    if settling or not scale or not settled_scale then
        return
    end
    -- Kept even when back at the settled size, so a drag that ends where it
    -- started reports nothing rather than a size from part-way through.
    pending_scale = scale
    if math.abs(scale - settled_scale) < 0.005 then
        return
    end
    -- A drag sends a stream of sizes; act on where it stops.
    if report_timer then
        report_timer:kill()
    end
    report_timer = mp.add_timeout(0.5, report_resize)
end)

-- Closing right after a resize must not lose it: report it now rather than
-- when the half second would have run out.
mp.register_event("shutdown", function()
    if report_timer then
        report_timer:kill()
        report_resize()
    end
end)

-- Back to mpv's default: each feed at its own size, centred on this screen.
-- Done by restarting mpv — quit 21 is view.sh's signal to drop the saved scale
-- and position and start again — because moving an open window is unreliable:
-- on mpv 0.41 a runtime --geometry lands in the wrong place on any display but
-- the main one, measured from the main display's left edge. A window placed at
-- startup is right on every display.
local function reset_window()
    report("reset")
    mp.command("quit 21")
end

-- Switching goes through here rather than a bare loadfile so the state file and
-- the tick stay in step with what is playing. view.sh reads that state file to
-- resume the right feed after a reconnect.
local function select_feed(index, force)
    local feed = by_index[tonumber(index or "")]
    if not feed then
        return
    end
    if feed.index == current and not force then
        return
    end

    current = feed.index
    write_current(feed.index)
    build_menu()
    show_loading(feed.name)
    settle()
    mp.commandv("loadfile", feed.url)
end

-- Reopening the stream is the only real "back to live" for RTSP: there is no
-- seeking on a live feed, so a reload is what discards whatever was buffered.
local function reload_feed()
    if current and by_index[current] then
        select_feed(current, true)
    end
end

read_feeds()
current = read_current()
build_menu()

mp.register_script_message("unifi-select", function(index) select_feed(index, false) end)
mp.register_script_message("unifi-reload", reload_feed)
mp.register_script_message("unifi-reset-window", reset_window)

-- The macOS menu bar is mpv's own and cannot be customised. Its Playback menu
-- sends commands straight to the core, bypassing input.conf entirely, so no
-- binding change can stop these. Pin the properties that matter instead.
--
--   Toggle Pause      -> a live camera has nothing to resume to, so pausing
--                        only leaves a stale frame with no obvious way back
--   Toggle Loop File  -> view.sh relies on --loop-file=inf to tell a dropped
--                        stream from a deliberate quit. Turning it off would
--                        make the app exit silently on the next drop.
--   speed             -> meaningless on a live stream
mp.observe_property("pause", "bool", function(_, paused)
    if paused then
        mp.set_property_bool("pause", false)
    end
end)

mp.observe_property("loop-file", "native", function(_, value)
    if value ~= "inf" and value ~= math.huge then
        mp.set_property("loop-file", "inf")
    end
end)

mp.observe_property("speed", "number", function(_, speed)
    if speed and math.abs(speed - 1.0) > 0.001 then
        mp.set_property_number("speed", 1.0)
    end
end)

-- Cover the initial connect too, not just switches.
if current and by_index[current] then
    show_loading(by_index[current].name)
end

-- playback-restart is the point frames are actually being shown; file-loaded
-- can fire while the picture is still blank.
mp.register_event("playback-restart", function()
    hide_loading()
    if settling then
        settle_after_first_frame()
    end
end)

mp.register_event("file-loaded", function()
    -- The state file can change from outside this script, so re-sync the tick.
    local index = read_current()
    if index and index ~= current then
        current = index
        build_menu()
    end
end)

-- A dropped stream re-opens via --loop-file=inf; show the panel again while it
-- reconnects rather than freezing on the last frame.
mp.register_event("end-file", function(e)
    if e and e.reason == "eof" and current and by_index[current] then
        show_loading(by_index[current].name)
        settle()
    end
end)
