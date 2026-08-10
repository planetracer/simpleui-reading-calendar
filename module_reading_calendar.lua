-- module_reading_calendar.lua — Reading Calendar for the SimpleUI homescreen
--
-- A month-view calendar where every day you read shows the cover(s) of the
-- book(s) you read that day — multiple books stack with a small offset.
-- Days without reading show the plain day number. A stats strip at the top
-- shows BOOKS / PAGES / PAGES-PER-READING-DAY for the displayed month.
--
-- Interactions:
--   • Swipe left/right on the module  → next / previous month
--   • Tap left/right side of header   → previous / next month
--   • Tap month name                  → jump back to current month
--   • Tap a day with covers          → popup listing that day's books
--
-- INSTALL (either way works):
--   a) Drop this file into  simpleui_ext.koplugin/modules/  (auto-registered)
--   b) Use the bundled readingcalendar.koplugin wrapper (SimpleUI only)
--
-- Data comes from KOReader's statistics database (statistics.sqlite3).
-- Covers come from SimpleUI's cover cache; books are matched to files via
-- the partial_md5_checksum stored in each book's sidecar, resolved lazily
-- from reading history and cached persistently.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage     = require("datastorage")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LuaSettings     = require("luasettings")
local OverlapGroup    = require("ui/widget/overlapgroup")
local SQ3             = require("lua-ljsqlite3/init")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local Screen          = Device.screen

-- Translation: prefer simpleui_ext's helper when present, degrade gracefully.
local _
do
    local ok, i18n = pcall(require, "sui_ext_i18n")
    if ok and i18n and i18n.translate then
        _ = i18n.translate
    else
        local ok2, gettext = pcall(require, "gettext")
        _ = (ok2 and gettext) or function(s) return s end
    end
end

-- Lazy SimpleUI internals (never hard-fail if something is missing).
local _Config, _SUISettings, _SUIStyle, _SH
local function getConfig()
    if not _Config then
        local ok, m = pcall(require, "sui_config")
        if ok then _Config = m end
    end
    return _Config
end
local function getSettings()
    if not _SUISettings then
        local ok, m = pcall(require, "sui_store")
        if ok then _SUISettings = m end
    end
    return _SUISettings
end
local function getStyle()
    if not _SUIStyle then
        local ok, m = pcall(require, "sui_style")
        if ok then _SUIStyle = m end
    end
    return _SUIStyle
end
local function getSH()
    if not _SH then
        local ok, m = pcall(require, "desktop_modules/module_books_shared")
        if ok then _SH = m end
    end
    return _SH
end

local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

-- Persistent md5 → filepath map (survives restarts; avoids re-scanning
-- the whole reading history with one sidecar read per book on every boot).
local map_file = DataStorage:getDataDir() .. "/reading_calendar_map.lua"
local MapStore = LuaSettings:open(map_file)

-- Settings keys (under ctx.pfx, i.e. "simpleui_hs_").
local SK_WEEK_MONDAY = "rcal_week_starts_monday"
local SK_MAX_STACK   = "rcal_max_stack"

local MAX_STACK_DEFAULT = 3

-- ---------------------------------------------------------------------------
-- Month helpers
-- ---------------------------------------------------------------------------

-- Displayed month as an offset from the current month (0 = this month).
local _month_offset = 0

local function monthForOffset(offset)
    local now = os.date("*t")
    local m = now.month + offset
    local y = now.year + math.floor((m - 1) / 12)
    m = (m - 1) % 12 + 1
    return y, m
end

local function daysInMonth(y, m)
    local next_y, next_m = y, m + 1
    if next_m == 13 then next_y, next_m = y + 1, 1 end
    return math.floor((os.time{ year = next_y, month = next_m, day = 1, hour = 12 }
                     - os.time{ year = y,      month = m,      day = 1, hour = 12 }) / 86400 + 0.5)
end

local function fmtDuration(secs)
    secs = secs or 0
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
end

-- ---------------------------------------------------------------------------
-- Statistics DB — per-day books for one month
-- ---------------------------------------------------------------------------

-- Cache: one entry per "YYYY-MM", invalidated when the stats DB mtime changes.
local _month_cache = {}

local function dbMtime()
    return lfs.attributes(db_path, "modification") or 0
end

local function fetchMonthData(y, m)
    local key = string.format("%04d-%02d", y, m)
    local mtime = dbMtime()
    local hit = _month_cache[key]
    if hit and hit.mtime == mtime then return hit end

    local data = {
        mtime     = mtime,
        days      = {},   -- day number (1..31) → sorted list of book entries
        books     = 0,
        pages     = 0,
        dur       = 0,
        days_read = 0,
    }
    _month_cache[key] = data

    if lfs.attributes(db_path, "mode") ~= "file" then return data end
    local ok_open, conn = pcall(SQ3.open, db_path)
    if not ok_open or not conn then return data end

    local start_ts = os.time{ year = y, month = m, day = 1, hour = 0, min = 0, sec = 0 }
    local end_y, end_m = y, m + 1
    if end_m == 13 then end_y, end_m = y + 1, 1 end
    local end_ts = os.time{ year = end_y, month = end_m, day = 1, hour = 0, min = 0, sec = 0 }

    local sql = string.format([[
        SELECT strftime('%%d', ps.start_time, 'unixepoch', 'localtime') AS day_num,
               ps.id_book,
               b.title,
               b.authors,
               b.md5,
               count(DISTINCT ps.page) AS pages,
               sum(ps.duration)        AS dur
        FROM page_stat ps
        JOIN book b ON b.id = ps.id_book
        WHERE ps.start_time >= %d AND ps.start_time < %d
        GROUP BY day_num, ps.id_book
        ORDER BY day_num ASC, dur DESC;
    ]], start_ts, end_ts)

    local distinct_books = {}
    local ok_q = pcall(function()
        local stmt = conn:prepare(sql)
        for row in stmt:rows() do
            local day  = tonumber(row[1])
            local entry = {
                id_book = tonumber(row[2]),
                title   = row[3] or "?",
                authors = row[4],
                md5     = row[5],
                pages   = tonumber(row[6]) or 0,
                dur     = tonumber(row[7]) or 0,
            }
            if day then
                local list = data.days[day]
                if not list then
                    list = {}
                    data.days[day] = list
                    data.days_read = data.days_read + 1
                end
                list[#list + 1] = entry
                data.pages = data.pages + entry.pages
                data.dur   = data.dur + entry.dur
                if entry.id_book and not distinct_books[entry.id_book] then
                    distinct_books[entry.id_book] = true
                    data.books = data.books + 1
                end
            end
        end
        stmt:close()
    end)
    if not ok_q then
        logger.warn("reading_calendar: month query failed for " .. key)
    end
    pcall(function() conn:close() end)
    return data
end

-- ---------------------------------------------------------------------------
-- Current reading streak (consecutive days ending today / yesterday)
-- ---------------------------------------------------------------------------

local _streak_cache  -- { mtime, streak }, invalidated when the DB changes

local function currentStreak()
    local mtime = dbMtime()
    if _streak_cache and _streak_cache.mtime == mtime then
        return _streak_cache.streak
    end
    local streak = 0
    if lfs.attributes(db_path, "mode") == "file" then
        local ok_open, conn = pcall(SQ3.open, db_path)
        if ok_open and conn then
            local read_days = {}
            pcall(function()
                local stmt = conn:prepare([[
                    SELECT DISTINCT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS d
                    FROM page_stat ORDER BY d DESC LIMIT 1200;
                ]])
                for row in stmt:rows() do read_days[row[1]] = true end
                stmt:close()
            end)
            pcall(function() conn:close() end)
            local t = os.time()
            -- No pages yet today: the streak is still alive, count from yesterday.
            if not read_days[os.date("%Y-%m-%d", t)] then t = t - 86400 end
            while read_days[os.date("%Y-%m-%d", t)] do
                streak = streak + 1
                t = t - 86400
            end
        end
    end
    _streak_cache = { mtime = mtime, streak = streak }
    return streak
end

-- ---------------------------------------------------------------------------
-- Configurable stats strip
-- ---------------------------------------------------------------------------

local SK_STATS = "rcal_stats"

local STAT_DEFS = {
    { key = "books",     label = _("BOOKS"),     value = function(d) return d.books end },
    { key = "pages",     label = _("PAGES"),     value = function(d) return d.pages end },
    { key = "pages_day", label = _("PAGES/DAY"), value = function(d)
          return d.days_read > 0 and math.floor(d.pages / d.days_read + 0.5) or 0 end },
    { key = "time",      label = _("TIME"),      value = function(d) return fmtDuration(d.dur) end },
    { key = "time_day",  label = _("TIME/DAY"),  value = function(d)
          return fmtDuration(d.days_read > 0 and math.floor(d.dur / d.days_read + 0.5) or 0) end },
    { key = "days",      label = _("DAYS"),      value = function(d) return d.days_read end },
    { key = "streak",    label = _("STREAK"),    value = function() return currentStreak() end },
}
local STAT_DEFAULT = { "books", "pages", "pages_day" }

-- Returns the enabled stat defs in STAT_DEFS order (at least one).
local function enabledStats(S, pfx)
    local keys = (S and S:readSetting(pfx .. SK_STATS)) or STAT_DEFAULT
    local set = {}
    for _i, k in ipairs(keys) do set[k] = true end
    local out = {}
    for _i, def in ipairs(STAT_DEFS) do
        if set[def.key] then out[#out + 1] = def end
    end
    if #out == 0 then out[1] = STAT_DEFS[1] end
    return out
end

-- ---------------------------------------------------------------------------
-- md5 → filepath resolution (for covers)
-- ---------------------------------------------------------------------------

local _md5_map       = MapStore:readSetting("md5_map") or {}
local _map_dirty     = false
local _scanned_files = {}   -- filepath → true (checked this session)

local function flushMap()
    if _map_dirty then
        MapStore:saveSetting("md5_map", _md5_map)
        MapStore:flush()
        _map_dirty = false
    end
end

-- Read a file's partial_md5_checksum from its sidecar (no writes).
local function sidecarMd5(fp)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok then return nil end
    local md5
    pcall(function()
        local ds = DocSettings:open(fp)
        md5 = ds:readSetting("partial_md5_checksum")
    end)
    return md5
end

-- Try to resolve every md5 in `wanted` (set: md5 → true) to a filepath.
-- Walks reading history lazily, newest first, stopping as soon as all wanted
-- md5s are known. Results persist in MapStore across sessions.
local function resolveMd5s(wanted)
    local missing = 0
    for md5 in pairs(wanted) do
        local fp = _md5_map[md5]
        if not fp or lfs.attributes(fp, "mode") ~= "file" then
            missing = missing + 1
        end
    end
    if missing == 0 then return end

    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or not ReadHistory or type(ReadHistory.hist) ~= "table" then return end

    for _i, item in ipairs(ReadHistory.hist) do
        if missing == 0 then break end
        local fp = item.file
        if fp and not _scanned_files[fp] and lfs.attributes(fp, "mode") == "file" then
            _scanned_files[fp] = true
            local md5 = sidecarMd5(fp)
            if md5 and _md5_map[md5] ~= fp then
                _md5_map[md5] = fp
                _map_dirty = true
            end
            if md5 and wanted[md5] then
                missing = missing - 1
            end
        end
    end
    flushMap()
end

local function fileForMd5(md5)
    if not md5 then return nil end
    local fp = _md5_map[md5]
    if fp and lfs.attributes(fp, "mode") == "file" then return fp end
    return nil
end

-- ---------------------------------------------------------------------------
-- Widget builders
-- ---------------------------------------------------------------------------

local function makeText(text, face, fgcolor, bold, max_width)
    return TextWidget:new{
        text      = text,
        face      = face,
        bold      = bold,
        fgcolor   = fgcolor or Blitbuffer.COLOR_BLACK,
        padding   = 0,
        max_width = max_width,
    }
end

-- One stat column: big value over a small caps label, centered in col_w.
local function makeStatCol(value, label, col_w, val_face, lbl_face)
    local val_w = makeText(tostring(value), val_face, Blitbuffer.COLOR_BLACK, true)
    local lbl_w = makeText(label, lbl_face, Blitbuffer.COLOR_DARK_GRAY)
    return VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = val_w:getSize().h },
            val_w,
        },
        CenterContainer:new{
            dimen = Geom:new{ w = col_w, h = lbl_w:getSize().h },
            lbl_w,
        },
    }
end

-- A day cell with 1..max_stack stacked covers. Lower covers peek out
-- behind the top one with a small diagonal offset (newest/most-read on top).
-- Registers each cover in cover_slots so updateCovers() can swap in
-- freshly-extracted bitmaps without a full rebuild.
local function makeCoverStack(day_books, cell_w, cell_h, max_stack, cover_slots)
    local SH = getSH()
    local n = math.min(#day_books, max_stack)
    local off = n > 1 and math.max(2, math.floor(cell_w * 0.10)) or 0
    -- Box left for one cover once the stack offsets are subtracted.
    local box_w = cell_w - off * (n - 1)
    local box_h = cell_h - off * (n - 1)
    -- Keep book proportions (2:3): when fit-to-screen squashes cells the box
    -- gets wider than 2:3 — narrow the cover instead of cropping its art.
    local cover_h = box_h
    local cover_w = math.min(box_w, math.floor(box_h / 1.5 + 0.5))
    -- Center the whole fanned pile horizontally in the cell.
    local base_x = math.floor((cell_w - (cover_w + off * (n - 1))) / 2)

    local group = OverlapGroup:new{
        dimen = Geom:new{ w = cell_w, h = cell_h },
        allow_mirroring = false,
    }
    -- Draw back-to-front: entry n (least read) at top-right, entry 1 on top
    -- at bottom-left, like a fanned pile.
    for i = n, 1, -1 do
        local entry = day_books[i]
        local fp = fileForMd5(entry.md5)
        local cover
        if fp and SH then
            cover = SH.getBookCover(fp, cover_w, cover_h, "center", 0.15)
        end
        if not cover and SH then
            cover = SH.coverPlaceholder(entry.title, nil, cover_w, cover_h)
        end
        if not cover then -- SimpleUI internals unavailable: plain frame
            cover = FrameContainer:new{
                width = cover_w, height = cover_h,
                bordersize = Size.border.thin, padding = 0, margin = 0,
                background = Blitbuffer.COLOR_GRAY_E,
                VerticalSpan:new{ width = 0 },
            }
        end
        local dx = base_x + (i - 1) * off
        local dy = (n - i) * off
        cover.overlap_offset = { dx, dy }
        group[#group + 1] = cover
        if fp and cover_slots then
            cover_slots[#cover_slots + 1] = {
                fp        = fp,
                w         = cover_w,
                h         = cover_h,
                align     = "center",
                stretch   = 0.15,
                container = group,
                idx       = #group,
                offset    = { dx, dy },
            }
        end
    end
    return group
end

-- Rich popup for one day: cover, title, author, pages and time per book.
-- Tap a book row to open that book; tap outside the sheet to dismiss.
local MAX_POPUP_ROWS = 6

local function showDayPopup(y, m, day, day_books, ctx, month_names)
    local Style = getStyle()
    local SH    = getSH()
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    local face_reg  = Style and Style.FACE_REGULAR or "cfont"
    local face_bold = Style and Style.FACE_BOLD or "tfont"
    local fs_head = math.max(14, math.floor((Style and Style.FS_SUBTITLE or 20) * 1.1))
    local fs_row  = math.max(12, (Style and Style.FS_DETAIL or 15))
    local fs_meta = math.max(10, (Style and Style.FS_CAPTION or 12))

    local head_face = Font:getFace(face_bold, fs_head)
    local row_face  = Font:getFace(face_bold, fs_row)
    local meta_face = Font:getFace(face_reg, fs_meta)

    local pad     = Size.padding.fullscreen
    local popup_w = math.floor(sw * 0.88)
    local inner_w = popup_w - 2 * pad
    local row_pad = Size.padding.default

    local th_h = math.floor(sh * 0.085)
    local th_w = math.floor(th_h / 1.5 + 0.5)

    local popup  -- forward declaration for row closures

    local LineWidget
    do
        local okl, lw = pcall(require, "ui/widget/linewidget")
        if okl then LineWidget = lw end
    end
    local function separator()
        if LineWidget then
            return LineWidget:new{
                dimen      = Geom:new{ w = inner_w, h = Size.line.thin },
                background = Blitbuffer.COLOR_GRAY,
            }
        end
        return VerticalSpan:new{ width = row_pad }
    end

    local content = VerticalGroup:new{ align = "center" }

    -- Header: "10 AUGUST" over the year.
    content[#content + 1] = makeText(
        string.format("%d %s", day, month_names[m]), head_face, Blitbuffer.COLOR_BLACK, true, inner_w)
    content[#content + 1] = makeText(tostring(y), meta_face, Blitbuffer.COLOR_DARK_GRAY)
    content[#content + 1] = VerticalSpan:new{ width = row_pad }

    local total_pages, total_dur = 0, 0
    local shown = math.min(#day_books, MAX_POPUP_ROWS)
    for bi, b in ipairs(day_books) do
        total_pages = total_pages + b.pages
        total_dur   = total_dur + b.dur
        if bi <= shown then
            local fp = fileForMd5(b.md5)
            local cover
            if SH then
                if fp then cover = SH.getBookCover(fp, th_w, th_h, "center", 0.15) end
                if not cover then cover = SH.coverPlaceholder(b.title, b.authors, th_w, th_h) end
            end

            local text_w = inner_w - (cover and (th_w + row_pad) or 0)
            local col = VerticalGroup:new{ align = "left" }
            col[#col + 1] = makeText(b.title, row_face, Blitbuffer.COLOR_BLACK, true, text_w)
            if b.authors and b.authors ~= "" then
                col[#col + 1] = makeText(b.authors, meta_face, Blitbuffer.COLOR_DARK_GRAY, false, text_w)
            end
            col[#col + 1] = VerticalSpan:new{ width = math.floor(row_pad / 2) }
            col[#col + 1] = makeText(
                string.format("%d %s · %s", b.pages, _("pages"), fmtDuration(b.dur)),
                meta_face, Blitbuffer.COLOR_DARK_GRAY, false, text_w)

            local hg = HorizontalGroup:new{ align = "center" }
            if cover then
                hg[#hg + 1] = cover
                hg[#hg + 1] = HorizontalSpan:new{ width = row_pad }
            end
            hg[#hg + 1] = col

            local row_h = math.max(cover and th_h or 0, col:getSize().h) + row_pad
            local row = InputContainer:new{
                dimen = Geom:new{ w = inner_w, h = row_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = inner_w, h = row_h },
                    hg,
                },
            }
            if fp then
                local _fp = fp
                row.ges_events = {
                    TapBook = { GestureRange:new{ ges = "tap", range = function() return row.dimen end } },
                }
                function row:onTapBook()
                    UIManager:close(popup)
                    local opened = false
                    if ctx and type(ctx.open_fn) == "function" then
                        opened = pcall(ctx.open_fn, _fp)
                    end
                    if not opened then
                        pcall(function() require("apps/reader/readerui"):showReader(_fp) end)
                    end
                    return true
                end
            end

            if bi > 1 then content[#content + 1] = separator() end
            content[#content + 1] = row
        end
    end
    if #day_books > shown then
        content[#content + 1] = makeText(
            string.format(_("+ %d more"), #day_books - shown),
            meta_face, Blitbuffer.COLOR_DARK_GRAY)
    end

    if #day_books > 1 then
        content[#content + 1] = separator()
        content[#content + 1] = VerticalSpan:new{ width = math.floor(row_pad / 2) }
        content[#content + 1] = makeText(
            string.format("%s · %d %s · %s", _("TOTAL"), total_pages, _("pages"), fmtDuration(total_dur)),
            meta_face, Blitbuffer.COLOR_BLACK, true, inner_w)
    end

    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius     = Size.radius.window,
        padding    = pad,
        content,
    }
    popup = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        CenterContainer:new{ dimen = Geom:new{ w = sw, h = sh }, frame },
    }
    popup.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } },
    }
    function popup:onTapClose(_arg, ges)
        if frame.dimen and ges.pos:notIntersectWith(frame.dimen) then
            UIManager:close(popup, "ui")
        end
        return true
    end
    UIManager:show(popup, "ui")
end

-- ---------------------------------------------------------------------------
-- The module
-- ---------------------------------------------------------------------------

local _DEFAULT_LABEL = nil  -- calendar draws its own header; no section label

local M = {
    id              = "reading_calendar",
    name            = _("Reading Calendar"),
    description     = _("Month calendar with the covers of the books you read each day"),
    default_enabled = true,       -- simpleui_ext: load this module file
    label           = _DEFAULT_LABEL,
    enabled_key     = "reading_calendar",
    default_on      = true,       -- shown on the homescreen once installed
    has_covers      = true,       -- e-ink dithering + cover extraction poll
    is_book_mod     = true,       -- enables surgical slot refresh for month nav
}

local MONTH_NAMES = {
    _("JANUARY"), _("FEBRUARY"), _("MARCH"), _("APRIL"), _("MAY"), _("JUNE"),
    _("JULY"), _("AUGUST"), _("SEPTEMBER"), _("OCTOBER"), _("NOVEMBER"), _("DECEMBER"),
}
local DAY_NAMES_SUN = { _("SUN"), _("MON"), _("TUE"), _("WED"), _("THU"), _("FRI"), _("SAT") }

function M.build(w, ctx)
    local Config = getConfig()
    local S      = getSettings()
    local Style  = getStyle()
    local pfx    = ctx and ctx.pfx or "simpleui_hs_"

    local scale = 1.0
    if Config and Config.getModuleScale then
        scale = Config.getModuleScale("reading_calendar", pfx) or 1.0
    end

    local week_starts_monday = S and S:isTrue(pfx .. SK_WEEK_MONDAY) or false
    local max_stack = (S and tonumber(S:readSetting(pfx .. SK_MAX_STACK))) or MAX_STACK_DEFAULT

    local face_reg  = Style and Style.FACE_REGULAR or "cfont"
    local face_bold = Style and Style.FACE_BOLD or "tfont"
    local fs_title   = math.max(16, math.floor((Style and Style.FS_TITLE or 22) * 1.5 * scale))
    local fs_value   = math.max(12, math.floor((Style and Style.FS_SUBTITLE or 20) * scale))
    local fs_caption = math.max(8,  math.floor((Style and Style.FS_CAPTION or 12) * scale))
    local fs_detail  = math.max(9,  math.floor((Style and Style.FS_DETAIL or 15) * scale))
    local fs_day     = math.max(10, math.floor((Style and Style.FS_BODY or 18) * scale))

    local y, m = monthForOffset(_month_offset)
    local data = fetchMonthData(y, m)

    -- Resolve covers for every book shown this month.
    local wanted = {}
    for _day, list in pairs(data.days) do
        for i = 1, math.min(#list, max_stack) do
            if list[i].md5 then wanted[list[i].md5] = true end
        end
    end
    pcall(resolveMd5s, wanted)

    local now = os.date("*t")
    local is_current_month = (y == now.year and m == now.month)

    -- ── Header: year + month name ────────────────────────────────────────
    local year_w  = makeText(tostring(y), Font:getFace(face_reg, fs_detail), Blitbuffer.COLOR_DARK_GRAY)
    local month_w = makeText(MONTH_NAMES[m], Font:getFace(face_bold, fs_title), Blitbuffer.COLOR_BLACK, true)
    local header = VerticalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = w, h = year_w:getSize().h },  year_w },
        CenterContainer:new{ dimen = Geom:new{ w = w, h = month_w:getSize().h }, month_w },
    }

    -- ── Stats strip (columns are user-configurable, see getMenuItems) ────
    local stat_defs = enabledStats(S, pfx)
    local col_w = math.floor(w / #stat_defs)
    local val_face = Font:getFace(face_bold, fs_value)
    local lbl_face = Font:getFace(face_reg, fs_caption)
    local stats_row = HorizontalGroup:new{ align = "top" }
    for _i, def in ipairs(stat_defs) do
        stats_row[#stats_row + 1] = makeStatCol(def.value(data), def.label, col_w, val_face, lbl_face)
    end

    -- ── Weekday names ────────────────────────────────────────────────────
    local gap = math.max(2, Screen:scaleBySize(3))
    local side = Size.padding.small
    local cell_w = math.floor((w - 2 * side - 6 * gap) / 7)
    local grid_w = cell_w * 7 + gap * 6
    local left_margin = side + math.floor((w - 2 * side - grid_w) / 2)

    local dayname_face = Font:getFace(face_reg, fs_caption)
    local dayname_row = HorizontalGroup:new{ align = "center" }
    dayname_row[#dayname_row + 1] = HorizontalSpan:new{ width = left_margin }
    for i = 0, 6 do
        local idx = week_starts_monday and (i % 7) + 2 or i + 1
        if idx == 8 then idx = 1 end
        local t = makeText(DAY_NAMES_SUN[idx], dayname_face, Blitbuffer.COLOR_BLACK, true)
        dayname_row[#dayname_row + 1] = CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = t:getSize().h },
            t,
        }
        if i < 6 then
            dayname_row[#dayname_row + 1] = HorizontalSpan:new{ width = gap }
        end
    end

    -- ── Calendar grid ────────────────────────────────────────────────────
    local row_gap = math.max(3, Screen:scaleBySize(5))
    local ndays = daysInMonth(y, m)
    local first_wday = os.date("*t", os.time{ year = y, month = m, day = 1, hour = 12 }).wday -- 1=Sun
    local start_wday = week_starts_monday and 2 or 1
    local lead = (first_wday - start_wday) % 7
    local nrows = math.ceil((lead + ndays) / 7)

    -- Fit to screen: cover aspect (1.5 × width) is the ceiling, but when the
    -- full grid would overflow the homescreen's visible content area the
    -- cells shrink so header + stats + day names + all rows fit on one page.
    local header_gap = Size.padding.default
    local hs_for_h = ctx and ctx._hs_widget
    local ok_core, core = pcall(require, "sui_core")
    core = ok_core and core or nil
    local content_h = (hs_for_h and hs_for_h._layout_content_h)
        or (core and core.getContentHeight and core.getContentHeight())
        or math.floor(Screen:getHeight() * 0.8)
    -- Spacing the homescreen inserts above the module: the per-module gap
    -- (default MOD_GAP), plus one extra MOD_GAP when the top bar is off.
    local mod_gap = (core and core.MOD_GAP) or Screen:scaleBySize(23)
    local gap_px = (Config and Config.getModuleGapPx
        and Config.getModuleGapPx("reading_calendar", pfx, mod_gap)) or mod_gap
    local overhead = gap_px + mod_gap
    local fixed_h = header:getSize().h + header_gap
        + stats_row:getSize().h + header_gap
        + dayname_row:getSize().h + math.floor(header_gap / 2)
    local grid_budget = content_h - overhead - fixed_h
    local cell_h = math.floor(cell_w * 1.5)
    local fit_h = math.floor(grid_budget / nrows) - row_gap
    if fit_h < cell_h then cell_h = fit_h end
    cell_h = math.max(cell_h, math.floor(cell_w * 0.6))

    local day_face        = Font:getFace(face_reg, fs_day)
    local cover_slots     = {}
    local grid            = VerticalGroup:new{ align = "left" }
    local weeks_days      = {}   -- row → { col → day number or false } for tap hit-testing
    local cur_row         = nil
    local cur_row_days    = nil
    local col             = 0

    local function openRow()
        cur_row = HorizontalGroup:new{ align = "center" }
        cur_row[#cur_row + 1] = HorizontalSpan:new{ width = left_margin }
        cur_row_days = {}
        weeks_days[#weeks_days + 1] = cur_row_days
        col = 0
    end
    local function closeRow()
        if cur_row then
            grid[#grid + 1] = cur_row
            grid[#grid + 1] = VerticalSpan:new{ width = row_gap }
            cur_row = nil
        end
    end
    local function addCell(widget, daynum)
        if col > 0 then
            cur_row[#cur_row + 1] = HorizontalSpan:new{ width = gap }
        end
        cur_row[#cur_row + 1] = CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = cell_h },
            widget,
        }
        cur_row_days[col + 1] = daynum or false
        col = col + 1
        if col == 7 then closeRow() end
    end

    openRow()
    for _i = 1, lead do
        addCell(VerticalSpan:new{ width = 0 }, nil)
    end
    for day = 1, ndays do
        if not cur_row then openRow() end
        local books = data.days[day]
        if books and #books > 0 then
            addCell(makeCoverStack(books, cell_w, cell_h, max_stack, cover_slots), day)
        else
            local is_future = is_current_month and day > now.day
                or (_month_offset > 0)
            local t = makeText(tostring(day), day_face,
                is_future and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK)
            addCell(t, day)
        end
    end
    if cur_row then
        while col < 7 do
            addCell(VerticalSpan:new{ width = 0 }, nil)
        end
    end

    -- ── Assemble ─────────────────────────────────────────────────────────
    local body = VerticalGroup:new{
        align = "left",
        header,
        VerticalSpan:new{ width = header_gap },
        stats_row,
        VerticalSpan:new{ width = header_gap },
        dayname_row,
        VerticalSpan:new{ width = math.floor(header_gap / 2) },
        grid,
    }

    local body_size = body:getSize()
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = body_size.h },
        body,
    }
    tappable._cover_slots = cover_slots

    -- Geometry snapshot for tap hit-testing.
    local header_h   = header:getSize().h + header_gap + stats_row:getSize().h + header_gap
    local grid_top   = header_h + dayname_row:getSize().h + math.floor(header_gap / 2)

    local function refresh(hs)
        if hs and hs._refreshBookModSlot then
            local ok = hs:_refreshBookModSlot("reading_calendar")
            if ok then return end
        end
        if hs and hs._refreshImmediate then
            hs:_refreshImmediate(true)
        end
    end

    local hs = ctx and ctx._hs_widget

    local function gotoMonth(delta)
        if delta > 0 and _month_offset >= 0 then return end -- never past current month
        _month_offset = _month_offset + delta
        refresh(hs)
    end

    function tappable:onTap(_arg, ges)
        local x = ges.pos.x - self.dimen.x
        local ty = ges.pos.y - self.dimen.y
        if ty < header_h then
            if x < w / 3 then
                gotoMonth(-1)
            elseif x > 2 * w / 3 then
                gotoMonth(1)
            elseif _month_offset ~= 0 then
                _month_offset = 0
                refresh(hs)
            end
            return true
        end
        if ty >= grid_top then
            local row = math.floor((ty - grid_top) / (cell_h + row_gap)) + 1
            local gx = x - left_margin
            local colidx = math.floor(gx / (cell_w + gap)) + 1
            local days_row = weeks_days[row]
            local day = days_row and days_row[colidx]
            if day and data.days[day] then
                showDayPopup(y, m, day, data.days[day], ctx, MONTH_NAMES)
                return true
            end
        end
        return true
    end

    function tappable:onSwipe(_arg, ges)
        if ges.direction == "west" then
            gotoMonth(1)
            return true
        elseif ges.direction == "east" then
            gotoMonth(-1)
            return true
        end
        return false
    end

    tappable.ges_events = {
        Tap   = { GestureRange:new{ ges = "tap",   range = function() return tappable.dimen end } },
        Swipe = { GestureRange:new{ ges = "swipe", range = function() return tappable.dimen end } },
    }

    return tappable
end

-- Called by the homescreen cover poll while background cover extraction is
-- running: retries every unresolved cover slot and swaps the bitmap in.
-- Returns true when nothing is pending anymore.
function M.updateCovers(widget, _ctx)
    if not widget or not widget._cover_slots then return true end
    local SH = getSH()
    local Config = getConfig()
    if not SH then return true end
    local all_done = true
    for _i, slot in ipairs(widget._cover_slots) do
        local cover = SH.getBookCover(slot.fp, slot.w, slot.h, slot.align, slot.stretch)
        if cover then
            cover.overlap_offset = slot.offset
            slot.container[slot.idx] = cover
        elseif not (Config and Config.isCoverMissing and Config.isCoverMissing(slot.fp)) then
            all_done = false
        end
    end
    return all_done
end

-- Rough height estimate for layout previews (real height comes from build(),
-- which fits itself to the visible content area — so cap the estimate too).
function M.getHeight(ctx)
    local w = (ctx and (ctx.col_w or ctx.inner_w)) or Screen:getWidth()
    local cell_w = math.floor(w / 7)
    local est = math.floor(cell_w * 1.5 * 6 + w * 0.35)
    return math.min(est, math.floor(Screen:getHeight() * 0.9))
end

-- Drops the month cache so fresh stats are fetched on the next build.
-- simpleui_ext calls this automatically when a document is closed.
function M.invalidateCache()
    _month_cache = {}
end

function M.getMenuItems(ctx_menu)
    local Config = getConfig()
    local S = getSettings()
    if not Config or not S then return nil end
    local pfx = ctx_menu.pfx
    local refresh = ctx_menu.refresh
    local stats_sub = {}
    for _i, def in ipairs(STAT_DEFS) do
        local key = def.key
        stats_sub[#stats_sub + 1] = {
            text = def.label,
            checked_func = function()
                local keys = S:readSetting(pfx .. SK_STATS) or STAT_DEFAULT
                for _k, k in ipairs(keys) do
                    if k == key then return true end
                end
                return false
            end,
            keep_menu_open = true,
            callback = function()
                local keys = S:readSetting(pfx .. SK_STATS) or STAT_DEFAULT
                local out, found = {}, false
                for _k, k in ipairs(keys) do
                    if k == key then found = true else out[#out + 1] = k end
                end
                if not found then out[#out + 1] = key end
                S:set(pfx .. SK_STATS, out)
                if refresh then refresh() end
            end,
        }
    end

    local items = {
        {
            text = _("Statistics"),
            sub_item_table = stats_sub,
        },
        {
            text = _("Start week on Monday"),
            checked_func = function() return S:isTrue(pfx .. SK_WEEK_MONDAY) end,
            callback = function()
                S:set(pfx .. SK_WEEK_MONDAY, not S:isTrue(pfx .. SK_WEEK_MONDAY))
                if refresh then refresh() end
            end,
        },
    }
    if Config.makeScaleItem then
        items[#items + 1] = Config.makeScaleItem({
            text_func = function()
                local pct = Config.getModuleScalePct and Config.getModuleScalePct("reading_calendar", pfx) or 100
                return pct == 100 and _("Scale")
                    or string.format("%s (%d%%)", _("Scale"), pct)
            end,
            enabled_func = function() return not (Config.isScaleLinked and Config.isScaleLinked()) end,
            title = _("Scale"),
            info  = _("Scale for this module.\n100% is the default size."),
            get = function() return Config.getModuleScalePct("reading_calendar", pfx) end,
            set = function(v) Config.setModuleScale(v, "reading_calendar", pfx) end,
            refresh = refresh,
        })
    end
    return items
end

return M
