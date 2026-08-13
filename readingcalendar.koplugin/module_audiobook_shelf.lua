-- module_audiobook_shelf.lua — Audiobook Shelf for the SimpleUI homescreen
--
-- Shows the audiobooks stored in  <koreader>/audiobooks/  as a grid of
-- covers, organized like books: sorted by series, position in series,
-- then title. Each audiobook is one folder produced by the Audiobook
-- Maker desktop app:
--
--   koreader/audiobooks/<Title>/
--     <Title>.m4b     (audio, may also be .mp3/.m4a)
--     cover.jpg       (book cover)
--     meta.lua        (title / author / series / series_index / duration)
--
-- Interactions:
--   • Tap a cover → popup with cover, title, author, series and a Play
--     row. Play hands the file to the audiobook plugin
--     (stradichenko/audiobook.koplugin) when installed.
--   • Long-press (module menu): columns, rows, wireless sync from the
--     Audiobook Maker app's server, scale.
--
-- INSTALL: same as the Reading Calendar module (simpleui_ext modules/
-- folder, or the bundled readingcalendar.koplugin wrapper).

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

local shelf_dir = DataStorage:getDataDir() .. "/audiobooks"

local SK_COLS   = "rcab_cols"
local SK_ROWS   = "rcab_rows"
local SK_SERVER = "rcab_server"

local AUDIO_EXTS = { m4b = true, mp3 = true, m4a = true, ogg = true, flac = true }

-- ---------------------------------------------------------------------------
-- Library scan
-- ---------------------------------------------------------------------------

local _scan_cache  -- { mtime, books }

local function dirMtime()
    return lfs.attributes(shelf_dir, "modification") or 0
end

local function scanBooks()
    local mtime = dirMtime()
    if _scan_cache and _scan_cache.mtime == mtime then
        return _scan_cache.books
    end
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
                        local ok, m = pcall(dofile, full .. "/meta.lua")
                        if ok and type(m) == "table" then meta = m end
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
    _scan_cache = { mtime = mtime, books = books }
    return books
end

-- ---------------------------------------------------------------------------
-- Widgets
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

local function fmtDuration(secs)
    secs = secs or 0
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    return string.format("%dm", m)
end

-- Listening progress, read from the audiobook plugin's saved positions
-- (G_reader_settings → audiobook_settings.audio_positions, keyed by a
-- djb2 hash of the file path — mirrored here so the shelf shows progress
-- even before the player has been opened this session).
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
            margin_h   = 0,
            margin_v   = 0,
            radius     = 0,
            bordersize = 0,
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
            local rd = ReaderUI.instance or (ReaderUI._getRunningInstance
                and ReaderUI:_getRunningInstance())
            if rd and rd.audiobook then ap = rd.audiobook end
        end)
    end
    return ap
end

-- Detail popup: cover, metadata, Play row. Tap outside to dismiss.
local function showBookPopup(book)
    local Style = getStyle()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local face_reg  = Style and Style.FACE_REGULAR or "cfont"
    local face_bold = Style and Style.FACE_BOLD or "tfont"
    local fs_head = math.max(14, math.floor((Style and Style.FS_SUBTITLE or 20) * 1.1))
    local fs_meta = math.max(10, (Style and Style.FS_CAPTION or 12))

    local pad     = Size.padding.fullscreen
    local popup_w = math.floor(sw * 0.8)
    local inner_w = popup_w - 2 * pad
    local row_pad = Size.padding.default

    local cov_h = math.floor(sh * 0.28)
    local cov_w = math.floor(cov_h / 1.5 + 0.5)

    local popup

    local content = VerticalGroup:new{ align = "center" }
    content[#content + 1] = coverWidget(book, cov_w, cov_h)
    content[#content + 1] = VerticalSpan:new{ width = row_pad }
    content[#content + 1] = makeText(book.title,
        Font:getFace(face_bold, fs_head), Blitbuffer.COLOR_BLACK, true, inner_w)
    if book.author then
        content[#content + 1] = makeText(book.author,
            Font:getFace(face_reg, fs_meta), Blitbuffer.COLOR_DARK_GRAY, false, inner_w)
    end
    local detail = {}
    if book.series then
        detail[#detail + 1] = book.series
            .. (book.series_index and (" #" .. tostring(book.series_index)) or "")
    end
    if book.duration and book.duration > 0 then
        detail[#detail + 1] = fmtDuration(book.duration)
    end
    if #detail > 0 then
        content[#content + 1] = makeText(table.concat(detail, " · "),
            Font:getFace(face_reg, fs_meta), Blitbuffer.COLOR_DARK_GRAY, false, inner_w)
    end
    local secs = listenedSeconds(book.file)
    if secs and book.duration and book.duration > 0 then
        local pct = math.floor(100 * math.min(1, secs / book.duration) + 0.5)
        content[#content + 1] = makeText(
            string.format(_("%d%% listened · at %s"), pct, fmtDuration(secs)),
            Font:getFace(face_reg, fs_meta), Blitbuffer.COLOR_DARK_GRAY, false, inner_w)
    end
    content[#content + 1] = VerticalSpan:new{ width = row_pad }

    local play_label = makeText("▶  " .. _("Play"),
        Font:getFace(face_bold, fs_head), Blitbuffer.COLOR_BLACK, true)
    local play_h = play_label:getSize().h + row_pad
    local play_row = InputContainer:new{
        dimen = Geom:new{ w = inner_w, h = play_h },
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = play_h },
            play_label,
        },
    }
    play_row.ges_events = {
        TapPlay = { GestureRange:new{ ges = "tap", range = function() return play_row.dimen end } },
    }
    function play_row:onTapPlay()
        UIManager:close(popup)
        local ap = findAudiobookPlugin()
        if ap and type(ap._playAudioFile) == "function" then
            local ok, err = pcall(function() ap:_playAudioFile(book.file) end)
            if not ok then
                logger.warn("audiobook_shelf: play failed: " .. tostring(err))
            end
        else
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Audiobook player not installed.\n\nInstall audiobook.koplugin to play; the shelf only organizes the library."),
            })
        end
        return true
    end
    content[#content + 1] = play_row

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
-- Wireless sync from the Audiobook Maker app's server
-- ---------------------------------------------------------------------------

local function jsonDecode(s)
    for _i, name in ipairs({ "json", "dkjson", "rapidjson" }) do
        local ok, mod = pcall(require, name)
        if ok and mod and mod.decode then
            local ok2, t = pcall(mod.decode, s)
            if ok2 and type(t) == "table" then return t end
        end
    end
    return nil
end

local function httpGet(url, sink_path)
    local http  = require("socket.http")
    local ltn12 = require("ltn12")
    http.TIMEOUT = 60
    if sink_path then
        local f = io.open(sink_path, "wb")
        if not f then return nil, "cannot write " .. sink_path end
        local _r, code = http.request{ url = url, sink = ltn12.sink.file(f) }
        if code ~= 200 then
            os.remove(sink_path)
            return nil, "HTTP " .. tostring(code)
        end
        return true
    end
    local chunks = {}
    local _r, code = http.request{ url = url, sink = ltn12.sink.table(chunks) }
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    return table.concat(chunks)
end

local function urlEncode(s)
    return (s:gsub("[^%w%-%._~/]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function writeMetaLua(path, b)
    local function q(s)
        return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
    end
    local lines = { "return {" }
    lines[#lines + 1] = "    title = " .. q(b.title or "") .. ","
    if b.author and b.author ~= "" then
        lines[#lines + 1] = "    author = " .. q(b.author) .. ","
    end
    if b.series and b.series ~= "" then
        lines[#lines + 1] = "    series = " .. q(b.series) .. ","
    end
    if tonumber(b.series_index) then
        lines[#lines + 1] = "    series_index = " .. tostring(tonumber(b.series_index)) .. ","
    end
    if tonumber(b.duration) then
        lines[#lines + 1] = "    duration = " .. tostring(tonumber(b.duration)) .. ","
    end
    lines[#lines + 1] = "}"
    local f = io.open(path, "w")
    if f then
        f:write(table.concat(lines, "\n") .. "\n")
        f:close()
    end
end

local function syncFromServer(server, refresh)
    local InfoMessage = require("ui/widget/infomessage")
    server = server:gsub("/+$", "")
    local body, err = httpGet(server .. "/index.json")
    if not body then
        UIManager:show(InfoMessage:new{
            text = _("Could not reach the server:") .. "\n" .. tostring(err)
                .. "\n\n" .. server,
        })
        return
    end
    local data = body and jsonDecode(body)
    if not data or type(data.books) ~= "table" then
        UIManager:show(InfoMessage:new{ text = _("Bad response from server.") })
        return
    end
    lfs.mkdir(shelf_dir)
    local new_count, fail = 0, 0
    for _i, b in ipairs(data.books) do
        local dir = shelf_dir .. "/" .. b.folder
        local target = dir .. "/" .. b.m4b
        local have = lfs.attributes(target, "size")
        if have ~= b.m4b_size then
            local msg = InfoMessage:new{
                text = _("Downloading:") .. " " .. (b.title or b.folder),
            }
            UIManager:show(msg)
            UIManager:forceRePaint()
            lfs.mkdir(dir)
            local base = server .. "/" .. urlEncode(b.folder)
            local ok_a = httpGet(base .. "/" .. urlEncode(b.m4b), target)
            if b.cover then
                httpGet(base .. "/cover.jpg", dir .. "/cover.jpg")
            end
            writeMetaLua(dir .. "/meta.lua", b)
            UIManager:close(msg)
            if ok_a then new_count = new_count + 1 else fail = fail + 1 end
        end
    end
    _scan_cache = nil
    UIManager:show(InfoMessage:new{
        text = string.format(_("Sync done: %d new, %d failed, %d total."),
            new_count, fail, #data.books),
        timeout = 4,
    })
    if refresh then refresh() end
end

-- ---------------------------------------------------------------------------
-- The module
-- ---------------------------------------------------------------------------

local M = {
    id              = "audiobook_shelf",
    name            = _("Audiobook Shelf"),
    description     = _("Your audiobook library as a shelf of covers"),
    default_enabled = true,
    label           = _("AUDIOBOOKS"),
    enabled_key     = "audiobook_shelf",
    default_on      = true,
    has_covers      = true,   -- enables e-ink dithering for the cover bitmaps
}

function M.updateCovers(_widget, _ctx)
    return true  -- covers render synchronously; nothing pending
end

function M.build(w, ctx)
    local Config = getConfig()
    local S      = getSettings()
    local pfx    = ctx and ctx.pfx or "simpleui_hs_"

    local cols = (S and tonumber(S:readSetting(pfx .. SK_COLS))) or 4
    local rows = (S and tonumber(S:readSetting(pfx .. SK_ROWS))) or 2
    if Config and Config.getModuleScale then
        -- scale affects cover size indirectly through columns; nothing to do
    end

    local books = scanBooks()

    local side = Size.padding.small
    local gap  = math.max(3, Screen:scaleBySize(6))
    local cover_w = math.floor((w - 2 * side - (cols - 1) * gap) / cols)
    local cover_h = math.floor(cover_w * 1.5)
    local row_gap = math.max(3, Screen:scaleBySize(6))
    local shown_rows = math.min(rows, math.max(1, math.ceil(#books / cols)))
    local shown = math.min(#books, cols * shown_rows)

    local bar_h = math.max(2, Screen:scaleBySize(3)) + 2
    local grid = VerticalGroup:new{ align = "left" }
    local idx = 1
    for _r = 1, shown_rows do
        local hrow = HorizontalGroup:new{ align = "top" }
        hrow[#hrow + 1] = HorizontalSpan:new{ width = side }
        for c = 1, cols do
            if idx > shown then break end
            if c > 1 then
                hrow[#hrow + 1] = HorizontalSpan:new{ width = gap }
            end
            local cell = VerticalGroup:new{ align = "center" }
            cell[#cell + 1] = coverWidget(books[idx], cover_w, cover_h)
            cell[#cell + 1] = VerticalSpan:new{ width = 2 }
            -- Uniform cell height whether or not there is progress yet.
            cell[#cell + 1] = progressBar(books[idx], cover_w)
                or VerticalSpan:new{ width = bar_h - 2 }
            hrow[#hrow + 1] = cell
            idx = idx + 1
        end
        grid[#grid + 1] = hrow
        grid[#grid + 1] = VerticalSpan:new{ width = row_gap }
    end

    if #books == 0 then
        local Style = getStyle()
        local face = Font:getFace(Style and Style.FACE_REGULAR or "cfont",
            math.max(10, (Style and Style.FS_DETAIL or 15)))
        local t = makeText(_("No audiobooks yet — sync from the Audiobook Maker app or copy folders into koreader/audiobooks."),
            face, Blitbuffer.COLOR_DARK_GRAY, false, w - 2 * side)
        grid[#grid + 1] = HorizontalGroup:new{
            HorizontalSpan:new{ width = side }, t,
        }
    end

    local body_size = grid:getSize()
    local tappable = InputContainer:new{
        dimen = Geom:new{ w = w, h = body_size.h },
        grid,
    }

    function tappable:onTap(_arg, ges)
        if #books == 0 then return true end
        local x = ges.pos.x - self.dimen.x
        local y = ges.pos.y - self.dimen.y
        local row = math.floor(y / (cover_h + bar_h + row_gap)) + 1
        local col = math.floor((x - side) / (cover_w + gap)) + 1
        if row >= 1 and col >= 1 and col <= cols then
            local i = (row - 1) * cols + col
            if i >= 1 and i <= shown then
                showBookPopup(books[i])
            end
        end
        return true
    end

    tappable.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } },
    }
    return tappable
end

function M.getHeight(ctx)
    local w = (ctx and (ctx.col_w or ctx.inner_w)) or Screen:getWidth()
    local S = getSettings()
    local pfx = "simpleui_hs_"
    local cols = (S and tonumber(S:readSetting(pfx .. SK_COLS))) or 4
    local rows = (S and tonumber(S:readSetting(pfx .. SK_ROWS))) or 2
    local cover_w = math.floor(w / cols)
    local bar_h = math.max(2, Screen:scaleBySize(3)) + 2
    return math.floor((cover_w * 1.5 + bar_h + Screen:scaleBySize(6)) * rows)
end

function M.invalidateCache()
    _scan_cache = nil
end

function M.getMenuItems(ctx_menu)
    local Config = getConfig()
    local S = getSettings()
    if not S then return nil end
    local pfx = ctx_menu.pfx
    local refresh = ctx_menu.refresh

    local function pick(setting_key, title, values, default)
        local sub = {}
        for _i, v in ipairs(values) do
            sub[#sub + 1] = {
                text = tostring(v),
                checked_func = function()
                    local cur = tonumber(S:readSetting(pfx .. setting_key)) or default
                    return cur == v
                end,
                callback = function()
                    S:set(pfx .. setting_key, v)
                    if refresh then refresh() end
                end,
            }
        end
        return { text = title, sub_item_table = sub }
    end

    local items = {
        pick(SK_COLS, _("Columns"), { 3, 4, 5, 6 }, 4),
        pick(SK_ROWS, _("Rows"), { 1, 2, 3 }, 2),
        {
            text = _("Sync from PC (Audiobook Maker)"),
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local dialog
                dialog = InputDialog:new{
                    title = _("Audiobook Maker server"),
                    input = S:readSetting(pfx .. SK_SERVER) or "http://192.168.1.:8123",
                    input_hint = "http://<pc-ip>:8123",
                    buttons = {{
                        {
                            text = _("Cancel"),
                            callback = function() UIManager:close(dialog) end,
                        },
                        {
                            text = _("Sync"),
                            is_enter_default = true,
                            callback = function()
                                local server = dialog:getInputText()
                                UIManager:close(dialog)
                                if server and server ~= "" then
                                    S:set(pfx .. SK_SERVER, server)
                                    syncFromServer(server, refresh)
                                end
                            end,
                        },
                    }},
                }
                UIManager:show(dialog)
                dialog:onShowKeyboard()
            end,
        },
    }
    if Config and Config.makeScaleItem then
        items[#items + 1] = Config.makeScaleItem({
            text_func = function()
                local pct = Config.getModuleScalePct and Config.getModuleScalePct("audiobook_shelf", pfx) or 100
                return pct == 100 and _("Scale")
                    or string.format("%s (%d%%)", _("Scale"), pct)
            end,
            enabled_func = function() return not (Config.isScaleLinked and Config.isScaleLinked()) end,
            title = _("Scale"),
            info  = _("Scale for this module.\n100% is the default size."),
            get = function() return Config.getModuleScalePct("audiobook_shelf", pfx) end,
            set = function(v) Config.setModuleScale(v, "audiobook_shelf", pfx) end,
            refresh = refresh,
        })
    end
    return items
end

return M
