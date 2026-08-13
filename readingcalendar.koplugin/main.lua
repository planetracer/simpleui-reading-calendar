-- main.lua — Reading Calendar (standalone wrapper)
--
-- Registers module_reading_calendar.lua with SimpleUI's module registry.
-- Use this plugin when you have SimpleUI but NOT simpleui_ext installed.
-- (With simpleui_ext, just drop module_reading_calendar.lua into its
-- modules/ folder instead — do not install both.)

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")

local ReadingCalendarPlugin = WidgetContainer:extend{
    name        = "readingcalendar",
    is_doc_only = false,
    _registry   = nil,
    _module     = nil,
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
    local ok_mod, mod = pcall(dofile, self.path .. "/module_reading_calendar.lua")
    if not ok_mod or type(mod) ~= "table" then
        logger.warn("readingcalendar: failed to load module: " .. tostring(mod))
        return
    end
    Registry.register(mod)
    self._registry = Registry
    self._module   = mod
end

-- Refresh stats when a book is closed so the calendar shows today's session.
function ReadingCalendarPlugin:onCloseDocument()
    if self._module and type(self._module.invalidateCache) == "function" then
        self._module.invalidateCache()
    end
end

function ReadingCalendarPlugin:onClosePlugin()
    if self._registry and self._module then
        self._registry.unregister(self._module.id)
    end
    self._registry = nil
    self._module   = nil
end

return ReadingCalendarPlugin
