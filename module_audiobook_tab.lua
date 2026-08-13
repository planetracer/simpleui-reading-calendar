-- module_audiobook_tab.lua — "Audiobooks" nav-bar tab for SimpleUI
--
-- Registers an external SimpleUI action (id "audiobook_library") that can
-- be placed in the bottom navigation bar via  Simple UI → Tabs / Arrange
-- Tabs.  Tapping the tab opens a fullscreen Audiobook Library: every book
-- in  <koreader>/audiobooks/  (folders produced by the Audiobook Maker
-- app: audio + cover.jpg + meta.lua) listed with cover, author, series,
-- duration and listening progress.  Tap a book to play/resume it through
-- the audiobook plugin (stradichenko/audiobook.koplugin) when installed.
--
-- This file is loaded by the readingcalendar.koplugin wrapper (or
-- simpleui_ext).  The action registration happens at load time; the
-- returned homescreen-module shim stays disabled so nothing extra shows
-- on the homescreen itself.

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
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local Screen          = Device.screen

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

local _SUIStyle, _SH
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

local shelf_dir = DataStorage:getDataDir() .. "/audiobooks"
local AUDIO_EXTS = { m4b = true, mp3 = true, m4a = true, ogg = true, flac = true }

-- Directory of this file (for the bundled tab icon).
local _this_dir
do
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then
        _this_dir = src:sub(2):match("^(.*)[/\\][^/\\]+$")
    end
end

-- ---------------------------------------------------------------------------
-- Library scan (same folder layout as the Audiobook Shelf module)
-- ---------------------------------------------------------------------------

local function scanBooks()
    local books = {}
    if lfs.attributes(shelf_dir, "mode") == "directory" then
        for entry in lfs.dir(shelf_dir) do
            if entry ~= "." and entry ~= ".." then
                local full = shelf_dir .. "/" .. entry
                if lfs.attributes(full, "mode") == "directory" then
                    local audio
                    for f in lfs.dir(full) do
                        local ext = f:match("%.([^.]+)$")
                        if ext and AUDIO_EXTS[ext:lower()] then
                            audio = full .. "/" .. f
                            break
                        end
                    end
                    if audio then
                        local meta = {}
                        local okm, m = pcall(dofile, full .. "/meta.lua")
                        if okm and type(m) == "table" then meta = m end
                        local cover = full .. "/cover.jpg"
                        if lfs.attributes(cover, "mode") ~= "file" then
                            cover = nil
                        end
                        books[#books + 1] = {
                            title        = meta.title or entry,
                            author       = meta.author,
                            series       = meta.series,
                            series_index = tonumber(meta.series_index),
                            duration     = tonumber(meta.duration),
                            file         = audio,
                            cover        = cover,
                        }
                    end
                end
            end
        end
    end
    table.sort(books, function(a, b)
        local sa, sb = a.series or "\255", b.series or "\255"
        if sa ~= sb then return sa < sb end
        local ia, ib = a.series_index or 0, b.series_index or 0
        if ia ~= ib then return ia < ib end
        return (a.title or "") < (b.title or "")
    end)
    return books
end

local function fmtDuration(secs)
    secs = secs or 0
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
end

-- Listening progress from the audiobook plugin's saved positions
-- (G_reader_settings → audiobook_settings.audio_positions, djb2 path key).
local function positionKey(file_path)
    local hash = 5381
    for i = 1, #file_path do
        hash = ((hash * 32) + hash) + file_path:byte(i)
        hash = hash % 4294967296
    end
    return string.format("pos_%08x", hash)
end

local function listenedSeconds(file_path)
    local secs
    pcall(function()
        local settings = G_reader_settings:readSetting("audiobook_settings")
        local positions = settings and settings.audio_positions
        local entry = positions and positions[positionKey(file_path)]
        if entry and entry.path == file_path then
            secs = tonumber(entry.position)
        end
    end)
    return secs
end

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

local function coverWidget(book, w, h)
    if book.cover then
        local ok, bb = pcall(function()
            local RenderImage = require("ui/renderimage")
            return RenderImage:renderImageFile(book.cover, false, w - 2, h - 2)
        end)
        if ok and bb then
            local ok2, img = pcall(function()
                return require("ui/widget/imagewidget"):new{
                    image            = bb,
                    image_disposable = true,
                    width            = w - 2,
                    height           = h - 2,
                    scale_factor     = 1,
                }
            end)
            if ok2 and img then
                return FrameContainer:new{
                    bordersize = 1, padding = 0, margin = 0,
                    color = Blitbuffer.COLOR_BLACK,
                    dimen = Geom:new{ w = w, h = h },
                    img,
                }
            end
        end
    end
    local SH = getSH()
    if SH then
        local ok, ph = pcall(SH.coverPlaceholder, book.title, book.author, w, h)
        if ok and ph then return ph end
    end
    return FrameContainer:new{
        width = w, height = h,
        bordersize = Size.border.thin, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_GRAY_E,
        VerticalSpan:new{ width = 0 },
    }
end

local function progressBar(book, width)
    local secs = listenedSeconds(book.file)
    if not secs or not book.duration or book.duration <= 0 then return nil end
    local pct = math.max(0, math.min(1, secs / book.duration))
    if pct < 0.005 then return nil end
    local ok, bar = pcall(function()
        local ProgressWidget = require("ui/widget/progresswidget")
        return ProgressWidget:new{
            width      = width,
            height     = math.max(2, Screen:scaleBySize(3)),
            percentage = pct,
            margin_h   = 0, margin_v = 0, radius = 0, bordersize = 0,
        }
    end)
    if ok then return bar end
    return nil
end

local function findAudiobookPlugin()
    local ap
    pcall(function()
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        if fm and fm.audiobook then ap = fm.audiobook end
    end)
    if not ap then
        pcall(function()
            local ReaderUI = require("apps/reader/readerui")
            local rd = ReaderUI.instance
            if rd and rd.audiobook then ap = rd.audiobook end
        end)
    end
    return ap
end

-- ---------------------------------------------------------------------------
-- Fullscreen Audiobook Library window
-- ---------------------------------------------------------------------------

local _open_window  -- the currently shown library view, if any

-- Sort modes for the library view (persisted in SimpleUI settings).
local SORT_KEY = "simpleui_hs_rcab_tab_sort"
local SORT_NEXT = { series = "author", author = "title", title = "series" }

local function getSortMode()
    local m
    pcall(function()
        local S = require("sui_store")
        m = S:readSetting(SORT_KEY)
    end)
    if m ~= "series" and m ~= "author" and m ~= "title" then m = "series" end
    return m
end

local function setSortMode(m)
    pcall(function()
        local S = require("sui_store")
        S:set(SORT_KEY, m)
    end)
end

local function sortLabel(m)
    if m == "author" then return _("Author") end
    if m == "title" then return _("Title") end
    return _("Series")
end

local function sortBooks(books, mode)
    table.sort(books, function(a, b)
        if mode == "title" then
            return (a.title or "") < (b.title or "")
        elseif mode == "author" then
            local aa, ab = a.author or "\255", b.author or "\255"
            if aa ~= ab then return aa < ab end
        end
        local sa, sb = a.series or "\255", b.series or "\255"
        if sa ~= sb then return sa < sb end
        local ia, ib = a.series_index or 0, b.series_index or 0
        if ia ~= ib then return ia < ib end
        return (a.title or "") < (b.title or "")
    end)
end

local showLibrary  -- forward declaration (repage reopens at a new page)

showLibrary = function(start_page)
    if _open_window then
        local w = _open_window
        _open_window = nil
        pcall(function() UIManager:close(w) end)
    end
    local okU, UI = pcall(require, "sui_core")
    local okC, SConfig = pcall(require, "sui_config")
    UI = okU and UI or nil
    SConfig = okC and SConfig or nil

    local Style = getStyle()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    -- Content area between SimpleUI's top bar and bottom nav bar — the view
    -- lives inside SimpleUI's chrome, like the Library, not over it.
    local content_h = (UI and UI.getContentHeight and UI.getContentHeight()) or sh
    local face_reg  = Style and Style.FACE_REGULAR or "cfont"
    local face_bold = Style and Style.FACE_BOLD or "tfont"
    local fs_title = math.max(16, math.floor((Style and Style.FS_TITLE or 22) * 1.2))
    local fs_row   = math.max(12, (Style and Style.FS_DETAIL or 15))
    local fs_meta  = math.max(10, (Style and Style.FS_CAPTION or 12))

    local pad     = Size.padding.fullscreen
    local inner_w = sw - 2 * pad
    local row_pad = Size.padding.default

    local books = scanBooks()
    local sort_mode = getSortMode()
    sortBooks(books, sort_mode)
    local page = start_page or 1

    local window  -- forward declaration

    local head_face  = Font:getFace(face_bold, fs_title)
    local band_face  = Font:getFace(face_bold, math.max(11, fs_meta + 2))
    local meta_face  = Font:getFace(face_reg, fs_meta)

    -- Library-style grid: 3 large covers per row, like the file browser.
    local cols = 3
    local gap  = math.max(6, Screen:scaleBySize(10))
    local cover_w = math.floor((inner_w - (cols - 1) * gap) / cols)
    local cover_h = math.floor(cover_w * 1.5)

    local header_block_h = math.max(Screen:scaleBySize(44), math.floor(content_h * 0.09))
    local list_h = content_h - pad - header_block_h
    local grid_rows = math.max(1, math.floor(list_h / (cover_h + gap)))
    local per_page = cols * grid_rows
    local total_pages = math.max(1, math.ceil(#books / per_page))
    if page > total_pages then page = total_pages end

    -- One grid cell: big cover with a library-style centered title band,
    -- a % badge top-right and a thin progress bar near the bottom.
    local function makeCell(b)
        local og = OverlapGroup:new{
            dimen = Geom:new{ w = cover_w, h = cover_h },
            allow_mirroring = false,
        }
        og[#og + 1] = coverWidget(b, cover_w, cover_h)
        local band_pad = math.max(3, Screen:scaleBySize(4))
        local band_text = makeText(b.title, band_face, Blitbuffer.COLOR_BLACK,
            true, cover_w - 4 * band_pad)
        local band = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0, margin = 0, padding = band_pad,
            CenterContainer:new{
                dimen = Geom:new{ w = cover_w - 2 * band_pad, h = band_text:getSize().h },
                band_text,
            },
        }
        band.overlap_offset = { 0, math.floor((cover_h - band:getSize().h) / 2) }
        og[#og + 1] = band
        local secs = listenedSeconds(b.file)
        if secs and b.duration and b.duration > 0 then
            local pct = math.floor(100 * math.min(1, secs / b.duration) + 0.5)
            local btxt = makeText(pct .. "%", meta_face, Blitbuffer.COLOR_BLACK, true)
            local badge = FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE,
                bordersize = Size.border.thin, margin = 0,
                padding = math.max(2, Screen:scaleBySize(3)),
                btxt,
            }
            local bs = badge:getSize()
            badge.overlap_offset = { cover_w - bs.w - Screen:scaleBySize(4), Screen:scaleBySize(4) }
            og[#og + 1] = badge
            local bar = progressBar(b, cover_w - 2 * band_pad)
            if bar then
                bar.overlap_offset = { band_pad, cover_h - Screen:scaleBySize(9) }
                og[#og + 1] = bar
            end
        end
        local cell = InputContainer:new{
            dimen = Geom:new{ w = cover_w, h = cover_h },
            og,
        }
        cell.ges_events = {
            TapBook = { GestureRange:new{ ges = "tap", range = function() return cell.dimen end } },
        }
        local _b = b
        function cell:onTapBook()
            local ap = findAudiobookPlugin()
            if ap and type(ap._playAudioFile) == "function" then
                UIManager:close(window)
                local okp, err = pcall(function() ap:_playAudioFile(_b.file) end)
                if not okp then
                    logger.warn("audiobook_tab: play failed: " .. tostring(err))
                end
            else
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = _("Audiobook player not installed.\n\nInstall audiobook.koplugin to play; this tab organizes the library."),
                })
            end
            return true
        end
        return cell
    end

    local function buildContent()
        local content = VerticalGroup:new{ align = "left" }

        -- ── Header: centered title + page line, sort toggle on the right ──
        local title_w = makeText(_("Audiobooks"), head_face,
            Blitbuffer.COLOR_BLACK, true)
        local page_w = makeText(
            string.format(_("Page %d of %d"), page, total_pages),
            meta_face, Blitbuffer.COLOR_DARK_GRAY)
        local head_stack = VerticalGroup:new{ align = "center", title_w, page_w }
        local sort_w = makeText(_("Sort") .. ": " .. sortLabel(sort_mode),
            meta_face, Blitbuffer.COLOR_BLACK)
        local sort_box_w = sort_w:getSize().w + row_pad
        local sort_box = InputContainer:new{
            dimen = Geom:new{ w = sort_box_w, h = header_block_h },
            CenterContainer:new{
                dimen = Geom:new{ w = sort_box_w, h = header_block_h },
                sort_w,
            },
        }
        sort_box.ges_events = {
            TapSort = { GestureRange:new{ ges = "tap", range = function() return sort_box.dimen end } },
        }
        function sort_box:onTapSort()
            setSortMode(SORT_NEXT[sort_mode] or "series")
            showLibrary(1)
            return true
        end
        local header = OverlapGroup:new{
            dimen = Geom:new{ w = inner_w, h = header_block_h },
            allow_mirroring = false,
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = header_block_h },
                head_stack,
            },
        }
        sort_box.overlap_offset = { inner_w - sort_box_w, 0 }
        header[#header + 1] = sort_box
        content[#content + 1] = header

        -- ── Cover grid ──
        local first = (page - 1) * per_page + 1
        local last = math.min(#books, first + per_page - 1)
        local i = first
        for _r = 1, grid_rows do
            if i > last then break end
            local hrow = HorizontalGroup:new{ align = "top" }
            for c = 1, cols do
                if i > last then break end
                if c > 1 then hrow[#hrow + 1] = HorizontalSpan:new{ width = gap } end
                hrow[#hrow + 1] = makeCell(books[i])
                i = i + 1
            end
            content[#content + 1] = hrow
            content[#content + 1] = VerticalSpan:new{ width = gap }
        end

        if #books == 0 then
            content[#content + 1] = VerticalSpan:new{ width = row_pad * 2 }
            content[#content + 1] = makeText(_("No audiobooks yet."),
                band_face, Blitbuffer.COLOR_DARK_GRAY, true, inner_w)
            content[#content + 1] = VerticalSpan:new{ width = row_pad }
            content[#content + 1] = makeText(
                _("Create books with the Audiobook Maker app, then send via USB or Wi-Fi sync."),
                meta_face, Blitbuffer.COLOR_DARK_GRAY, false, inner_w)
        end
        return content
    end

    -- Inner content widget, sized to the area between top bar and nav bar.
    local inner = InputContainer:new{
        dimen = Geom:new{ w = sw, h = content_h },
        HorizontalGroup:new{
            align = "top",
            HorizontalSpan:new{ width = pad },
            VerticalGroup:new{
                align = "left",
                VerticalSpan:new{ width = math.floor(pad / 2) },
                buildContent(),
            },
        },
    }

    window = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        covers_fullscreen = true,
    }
    -- Wrap with SimpleUI's own top bar + bottom nav bar so this reads as a
    -- native SimpleUI view (tab stays highlighted); plain fullscreen if the
    -- SimpleUI internals are unavailable.
    local wrapped_ok = false
    if UI and UI.wrapWithNavbar then
        local tabs = SConfig and SConfig.loadTabConfig and SConfig.loadTabConfig() or nil
        local okw = pcall(function()
            local nc, wrapped, bar, topbar, bar_idx, tb_on, tb_idx =
                UI.wrapWithNavbar(inner, "audiobook_library", tabs)
            if UI.applyNavbarState then
                UI.applyNavbarState(window, nc, bar, topbar, bar_idx, tb_on, tb_idx, tabs)
            end
            window[1] = wrapped
        end)
        wrapped_ok = okw and window[1] ~= nil
    end
    if not wrapped_ok then
        window[1] = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0, padding = 0, margin = 0,
            width = sw, height = sh,
            inner,
        }
    end
    function window:onCloseWidget()
        if _open_window == window then _open_window = nil end
    end
    window.ges_events = {
        SwipeClose = { GestureRange:new{ ges = "swipe", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } },
    }
    function window:onSwipeClose(_arg, ges)
        if ges.direction == "south" then
            UIManager:close(window)
            return true
        elseif ges.direction == "west" then
            if page < total_pages then showLibrary(page + 1) end
            return true
        elseif ges.direction == "east" then
            if page > 1 then showLibrary(page - 1) end
            return true
        end
        return false
    end
    _open_window = window
    UIManager:show(window, "full")
end

-- ---------------------------------------------------------------------------
-- Register the SimpleUI action (runs once at plugin load)
-- ---------------------------------------------------------------------------

local function registerAction()
    local okQA, QA = pcall(require, "sui_quickactions")
    local okC, Config = pcall(require, "sui_config")
    if not (okQA and QA and QA.register and okC and Config) then
        logger.warn("audiobook_tab: SimpleUI QA/Config unavailable; tab not registered")
        return
    end
    local icon = Config.ICON.collections
    if _this_dir then
        local custom = _this_dir .. "/icon_audiobooks.svg"
        if lfs.attributes(custom, "mode") == "file" then icon = custom end
    end
    QA.register({
        id      = "audiobook_library",
        label   = _("Audiobooks"),
        icon    = icon,
        execute = function(_ctx) showLibrary() end,
    })
    -- Close the library view whenever another tab/action executes, so
    -- tapping Home/Library/etc. in the nav bar behaves like leaving a tab.
    if not QA._audiobook_tab_hooked then
        QA._audiobook_tab_hooked = true
        local orig_execute = QA.execute
        QA.execute = function(id, ctx)
            if _open_window and id ~= "audiobook_library" then
                local w = _open_window
                _open_window = nil
                pcall(function() UIManager:close(w) end)
            end
            return orig_execute(id, ctx)
        end
    end
    -- Also list it in the action catalogue so it appears in the
    -- Tabs / Arrange Tabs pools alongside the built-ins.
    if Config.ALL_ACTIONS and Config.ACTION_BY_ID
        and not Config.ACTION_BY_ID.audiobook_library then
        local desc = { id = "audiobook_library", label = _("Audiobooks"), icon = icon }
        Config.ALL_ACTIONS[#Config.ALL_ACTIONS + 1] = desc
        Config.ACTION_BY_ID.audiobook_library = desc
    end
    -- The nav bar builds (and loadTabConfig caches its tab list) BEFORE this
    -- registration runs at startup, pruning our then-unknown id — which made
    -- the tab vanish on every KOReader restart. If the saved config contains
    -- our id, drop the pruned cache and rebuild the bar.
    pcall(function()
        local S = require("sui_store")
        local raw = S:readSetting("simpleui_bar_tabs")
        if type(raw) ~= "table" then return end
        local has = false
        for _i, v in ipairs(raw) do
            if v == "audiobook_library" then has = true; break end
        end
        if not has then return end
        if Config.saveTabConfig then Config.saveTabConfig(raw) end -- clears cache
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        local sp = fm and fm._simpleui_plugin
        if sp and sp._scheduleRebuild then sp:_scheduleRebuild() end
    end)
end

pcall(registerAction)

-- ---------------------------------------------------------------------------
-- Homescreen-module shim (keeps the wrapper's registry happy; never shown)
-- ---------------------------------------------------------------------------

return {
    id         = "audiobook_library_tab",
    name       = _("Audiobooks Tab"),
    description = _("Adds the Audiobooks tab action (enable it under Simple UI → Tabs)"),
    default_on = false,
    isEnabled  = function() return false end,
    build      = function() return nil end,
}
