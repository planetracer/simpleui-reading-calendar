-- main.lua — SimpleUI extra modules (standalone wrapper)
--
-- Registers every module_*.lua in this folder with SimpleUI's module
-- registry (Reading Calendar, Audiobook Shelf, …).
-- Use this plugin when you have SimpleUI but NOT simpleui_ext installed.
-- (With simpleui_ext, just drop the module files into its modules/
-- folder instead — do not install both.)

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")

local ReadingCalendarPlugin = WidgetContainer:extend{
    name        = "readingcalendar",
    is_doc_only = false,
    _registry   = nil,
    _modules    = nil,
}

function ReadingCalendarPlugin:init()
    -- Delay one scheduler tick so SimpleUI's own init() has run first.
    UIManager:scheduleIn(0, function()
        self:_register()
    end)
end

function ReadingCalendarPlugin:_register()
    local ok, Registry = pcall(require, "desktop_modules/moduleregistry")
    if not ok or not Registry then
        logger.warn("readingcalendar: SimpleUI moduleregistry not found — " ..
                    "make sure the SimpleUI plugin is installed.")
        return
    end
    self._registry = Registry
    self._modules  = {}
    for entry in lfs.dir(self.path) do
        if entry:match("^module_.+%.lua$") then
            local ok_mod, mod = pcall(dofile, self.path .. "/" .. entry)
            if ok_mod and type(mod) == "table" and mod.id then
                Registry.register(mod)
                self._modules[#self._modules + 1] = mod
            else
                logger.warn("readingcalendar: failed to load " .. entry ..
                            ": " .. tostring(mod))
            end
        end
    end
end

-- Refresh cached data when a book is closed (today's stats, new files).
function ReadingCalendarPlugin:onCloseDocument()
    for _i, mod in ipairs(self._modules or {}) do
        if type(mod.invalidateCache) == "function" then
            pcall(mod.invalidateCache)
        end
    end
end

function ReadingCalendarPlugin:onClosePlugin()
    if self._registry and self._modules then
        for _i, mod in ipairs(self._modules) do
            pcall(self._registry.unregister, mod.id)
        end
    end
    self._registry = nil
    self._modules  = nil
end

return ReadingCalendarPlugin
