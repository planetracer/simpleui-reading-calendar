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

    local th_h = math.floor(content_h * 0.115)
    local th_w = math.floor(th_h / 1.5 + 0.5)
    local row_h = th_h + row_pad

    local books = scanBooks()
    local page = start_page or 1

    local window  -- forward declaration

    local head_face  = Font:getFace(face_bold, fs_title)
    local row_face   = Font:getFace(face_bold, fs_row)
    local meta_face  = Font:getFace(face_reg, fs_meta)

    local header_h = math.max(Screen:scaleBySize(36), math.floor(content_h * 0.08))
    local footer_h = math.floor(content_h * 0.07)
    local list_h = content_h - pad - header_h - footer_h
    local per_page = math.max(1, math.floor(list_h / (row_h + row_pad)))
    local total_pages = math.max(1, math.ceil(#books / per_page))

    local function buildContent()
        local content = VerticalGroup:new{ align = "left" }

        -- ── Header: title + count, close X on the right ──
        local title_w = makeText(_("AUDIOBOOKS"), head_face,
            Blitbuffer.COLOR_BLACK, true)
        local count_w = makeText(string.format("%d", #books), meta_face,
            Blitbuffer.COLOR_DARK_GRAY)
        local close_w = makeText("✕", head_face, Blitbuffer.COLOR_BLACK, true)
        local close_box = InputContainer:new{
            dimen = Geom:new{ w = header_h, h = header_h },
            CenterContainer:new{
                dimen = Geom:new{ w = header_h, h = header_h },
                close_w,
            },
        }
        close_box.ges_events = {
            TapX = { GestureRange:new{ ges = "tap", range = function() return close_box.dimen end } },
        }
        function close_box:onTapX()
            UIManager:close(window)
            return true
        end
        local head_left = HorizontalGroup:new{
            align = "center",
            title_w,
            HorizontalSpan:new{ width = row_pad },
            count_w,
        }
        local hl_w = head_left:getSize().w
        local header = HorizontalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = inner_w - header_h, h = header_h },
                head_left,
            },
            close_box,
        }
        content[#content + 1] = header

        -- ── Book rows ──
        local first = (page - 1) * per_page + 1
        local last = math.min(#books, first + per_page - 1)
        local rows = {}
        for i = first, last do
            local b = books[i]
            local text_w = inner_w - th_w - row_pad
            local col = VerticalGroup:new{ align = "left" }
            col[#col + 1] = makeText(b.title, row_face,
                Blitbuffer.COLOR_BLACK, true, text_w)
            if b.author then
                col[#col + 1] = makeText(b.author, meta_face,
                    Blitbuffer.COLOR_DARK_GRAY, false, text_w)
            end
            local detail = {}
            if b.series then
                detail[#detail + 1] = b.series
                    .. (b.series_index and (" #" .. tostring(b.series_index)) or "")
            end
            if b.duration and b.duration > 0 then
                detail[#detail + 1] = fmtDuration(b.duration)
            end
            local secs = listenedSeconds(b.file)
            if secs and b.duration and b.duration > 0 then
                detail[#detail + 1] = string.format(_("%d%% listened"),
                    math.floor(100 * math.min(1, secs / b.duration) + 0.5))
            end
            if #detail > 0 then
                col[#col + 1] = makeText(table.concat(detail, " · "),
                    meta_face, Blitbuffer.COLOR_DARK_GRAY, false, text_w)
            end
            local bar = progressBar(b, text_w)
            if bar then
                col[#col + 1] = VerticalSpan:new{ width = math.floor(row_pad / 2) }
                col[#col + 1] = bar
            end

            local hg = HorizontalGroup:new{
                align = "center",
                coverWidget(b, th_w, th_h),
                HorizontalSpan:new{ width = row_pad },
                col,
            }
            local row = InputContainer:new{
                dimen = Geom:new{ w = inner_w, h = row_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = inner_w, h = row_h },
                    hg,
                },
            }
            local _b = b
            row.ges_events = {
                TapBook = { GestureRange:new{ ges = "tap", range = function() return row.dimen end } },
            }
            function row:onTapBook()
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
            rows[#rows + 1] = row
            content[#content + 1] = row
            content[#content + 1] = VerticalSpan:new{ width = row_pad }
        end

        if #books == 0 then
            content[#content + 1] = VerticalSpan:new{ width = row_pad * 2 }
            content[#content + 1] = makeText(
                _("No audiobooks yet."),
                row_face, Blitbuffer.COLOR_DARK_GRAY, true, inner_w)
            content[#content + 1] = VerticalSpan:new{ width = row_pad }
            content[#content + 1] = makeText(
                _("Create books with the Audiobook Maker app, then send via USB or Wi-Fi sync."),
                meta_face, Blitbuffer.COLOR_DARK_GRAY, false, inner_w)
        end

        -- ── Footer: page navigation ──
        if total_pages > 1 then
            local prev_w = makeText("‹", head_face,
                page > 1 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY, true)
            local page_w = makeText(string.format("%d / %d", page, total_pages),
                meta_face, Blitbuffer.COLOR_DARK_GRAY)
            local next_w = makeText("›", head_face,
                page < total_pages and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY, true)
            local third = math.floor(inner_w / 3)
            local prev_box = InputContainer:new{
                dimen = Geom:new{ w = third, h = footer_h },
                CenterContainer:new{ dimen = Geom:new{ w = third, h = footer_h }, prev_w },
            }
            local next_box = InputContainer:new{
                dimen = Geom:new{ w = third, h = footer_h },
                CenterContainer:new{ dimen = Geom:new{ w = third, h = footer_h }, next_w },
            }
            prev_box.ges_events = {
                TapPrev = { GestureRange:new{ ges = "tap", range = function() return prev_box.dimen end } },
            }
            next_box.ges_events = {
                TapNext = { GestureRange:new{ ges = "tap", range = function() return next_box.dimen end } },
            }
            local function repage(delta)
                local np = page + delta
                if np < 1 or np > total_pages then return end
                UIManager:close(window)
                showLibrary(np)
            end
            function prev_box:onTapPrev() repage(-1); return true end
            function next_box:onTapNext() repage(1); return true end
            content[#content + 1] = HorizontalGroup:new{
                align = "center",
                prev_box,
                CenterContainer:new{ dimen = Geom:new{ w = third, h = footer_h }, page_w },
                next_box,
            }
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
