--[[--
Tailscale switch for KOReader.

Turns Tailscale on or off from the Wi-Fi network: on when the device joins a
network that is not one of the home networks, off at home or when Wi-Fi goes
away. Nothing runs in between: the plugin only reacts to KOReader's own
network events, so it costs no battery while idle.

The work is done by tailscale-switch.sh, which NickelMenu can call too, and
the settings live in config.sh next to that script so both read the same file.

A home network entry is one of
    Name                      any network called Name
    aa:bb:cc:dd:ee:ff         the access point with that BSSID, whatever its name
    Name@aa:bb:cc:dd:ee:ff    that access point, and only under that name

@module koplugin.tailscale
--]]--

local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local SCRIPT_NAME = "tailscale-switch.sh"
local CONFIG_NAME = "config.sh"
local STATUS_DELAY = 4 -- seconds between a background "up" and the message about it
local KEYS = { "HOME_NETWORKS", "LOGIN_SERVER", "UP_ARGS", "TAILSCALE_BIN", "TAILSCALED_START", "AUTO", "NOTIFY" }
local DEFAULTS = {
    HOME_NETWORKS = "",
    LOGIN_SERVER = "",
    UP_ARGS = "--accept-routes",
    TAILSCALE_BIN = "",
    TAILSCALED_START = "",
    AUTO = "1",
    NOTIFY = "1",
}

local Tailscale = WidgetContainer:extend{
    name = "tailscale",
    is_doc_only = false,
}

-- Where tailscale-switch.sh and config.sh live. On a Kobo that is the .adds
-- folder NickelMenu uses as well; elsewhere the plugin keeps its own copy.
function Tailscale:switchDir()
    local dir = G_reader_settings:readSetting("tailscale_switch_dir")
    if dir and dir ~= "" then return dir end
    if Device:isKobo() then return "/mnt/onboard/.adds/tailscale-switch" end
    return DataStorage:getDataDir() .. "/settings/tailscale-switch"
end

function Tailscale:scriptPath()
    return self:switchDir() .. "/" .. SCRIPT_NAME
end

function Tailscale:configPath()
    return self:switchDir() .. "/" .. CONFIG_NAME
end

function Tailscale:init()
    self.config = self:readConfig()
    self.last_applied = nil
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    -- Started with Wi-Fi already up (for example from NickelMenu): decide once now,
    -- because the connected event has fired before this plugin existed.
    if self:autoEnabled() and NetworkMgr:isConnected() then
        UIManager:nextTick(function() self:applyByNetwork("startup") end)
    end
end

function Tailscale:onDispatcherRegisterActions()
    Dispatcher:registerAction("tailscale_toggle",
        { category = "none", event = "TailscaleToggle", title = _("Toggle Tailscale"), general = true })
    Dispatcher:registerAction("tailscale_by_network",
        { category = "none", event = "TailscaleByNetwork", title = _("Tailscale: switch by Wi-Fi network"), general = true })
end

-- Settings file ---------------------------------------------------------

local function unquote(raw)
    raw = raw:match("^%s*(.-)%s*$")
    local single = raw:match("^'(.*)'$")
    if single then
        return (single:gsub("'\\''", "'"))
    end
    local double = raw:match('^"(.*)"$')
    if double then
        return (double:gsub('\\(["\\$`])', "%1"))
    end
    return (raw:gsub("%s*#.*$", ""))
end

local function quote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

function Tailscale:readConfig()
    local config = {}
    for key, value in pairs(DEFAULTS) do config[key] = value end
    local file = io.open(self:configPath(), "r")
    if not file then return config end
    for line in file:lines() do
        local key, raw = line:match("^%s*([%u_]+)%s*=(.*)$")
        if key and DEFAULTS[key] ~= nil then
            config[key] = unquote(raw)
        elseif key == "HOME_SSIDS" and config.HOME_NETWORKS == "" then
            config.HOME_NETWORKS = unquote(raw) -- older files
        end
    end
    file:close()
    return config
end

function Tailscale:writeConfig()
    local dir = self:switchDir()
    if not util.pathExists(dir) then
        util.makePath(dir)
    end
    local file, err = io.open(self:configPath(), "w")
    if not file then
        logger.warn("Tailscale: cannot write", self:configPath(), err)
        UIManager:show(InfoMessage:new{ icon = "notice-warning", text = T(_("Cannot write %1"), self:configPath()) })
        return false
    end
    file:write("# tailscale-switch settings, written by the KOReader Tailscale plugin.\n")
    file:write("# Shared with tailscale-switch.sh and the NickelMenu entries.\n")
    file:write("# HOME_NETWORKS: comma separated, each 'Name', 'aa:bb:cc:dd:ee:ff' or 'Name@aa:bb:cc:dd:ee:ff'.\n")
    for i, key in ipairs(KEYS) do
        file:write(key, "=", quote(self.config[key]), "\n")
    end
    file:close()
    return true
end

function Tailscale:set(key, value)
    self.config[key] = value
    self:writeConfig()
end

function Tailscale:autoEnabled()
    return self.config.AUTO == "1"
end

-- Home network entries ------------------------------------------------------

local function isMac(text)
    return text ~= nil and text:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

-- "Name", "aa:bb:..." or "Name@aa:bb:..." -> { ssid = , bssid = }
local function parseEntry(text)
    text = (text or ""):match("^%s*(.-)%s*$")
    if text == "" then return nil end
    if isMac(text) then
        return { bssid = text:lower() }
    end
    local name, mac = text:match("^(.-)@(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)$")
    if name and name ~= "" then
        return { ssid = name, bssid = mac:lower() }
    end
    return { ssid = text }
end

local function entryText(entry)
    if entry.ssid and entry.bssid then return entry.ssid .. "@" .. entry.bssid end
    return entry.ssid or entry.bssid
end

local function entryMatches(entry, network)
    if entry.ssid and entry.ssid ~= network.ssid then return false end
    if entry.bssid and entry.bssid ~= (network.bssid or ""):lower() then return false end
    return entry.ssid ~= nil or entry.bssid ~= nil
end

local function sameEntry(a, b)
    return a.ssid == b.ssid and a.bssid == b.bssid
end

function Tailscale:homeEntries()
    local list = {}
    for item in (self.config.HOME_NETWORKS or ""):gmatch("[^,]+") do
        local entry = parseEntry(item)
        if entry then table.insert(list, entry) end
    end
    return list
end

function Tailscale:saveHomeEntries(entries)
    local texts = {}
    for i, entry in ipairs(entries) do table.insert(texts, entryText(entry)) end
    self:set("HOME_NETWORKS", table.concat(texts, ","))
end

function Tailscale:hasHomeEntry(entry)
    for i, existing in ipairs(self:homeEntries()) do
        if sameEntry(existing, entry) then return true end
    end
    return false
end

function Tailscale:toggleHomeEntry(entry)
    local entries, kept, found = self:homeEntries(), {}, false
    for i, existing in ipairs(entries) do
        if sameEntry(existing, entry) then
            found = true
        else
            table.insert(kept, existing)
        end
    end
    if not found then table.insert(kept, entry) end
    self:saveHomeEntries(kept)
    self.last_applied = nil
    return not found
end

function Tailscale:isHome(network)
    if not network or not (network.ssid or network.bssid) then return false end
    for i, entry in ipairs(self:homeEntries()) do
        if entryMatches(entry, network) then return true end
    end
    return false
end

-- { ssid = , bssid = } of the connected network, or nil.
function Tailscale:currentNetwork()
    local ok, network = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
    if ok and type(network) == "table" and network.ssid and network.ssid ~= "" then
        return { ssid = network.ssid, bssid = network.bssid and network.bssid:lower() or nil }
    end
    if NetworkMgr.lease_ssid and NetworkMgr.lease_ssid ~= "" then
        return { ssid = NetworkMgr.lease_ssid }
    end
    return nil
end

-- Names of the networks KOReader has saved, sorted.
function Tailscale:savedNetworkNames()
    local names = {}
    local ok, saved = pcall(NetworkMgr.getAllSavedNetworks, NetworkMgr)
    if ok and type(saved) == "table" and type(saved.data) == "table" then
        for ssid, network in pairs(saved.data) do
            if type(network) == "table" and type(ssid) == "string" and ssid ~= "" then
                table.insert(names, ssid)
            end
        end
    end
    table.sort(names)
    return names
end

-- Running the switch ------------------------------------------------------

function Tailscale:scriptAvailable()
    return util.pathExists(self:scriptPath())
end

function Tailscale:command(action, ...)
    local cmd = "sh " .. quote(self:scriptPath()) .. " " .. action
    for i, arg in ipairs({ ... }) do cmd = cmd .. " " .. quote(arg) end
    return cmd
end

-- Runs an action and waits for it. Only used for "down", which returns at once.
function Tailscale:runNow(action)
    if not self:scriptAvailable() then return false end
    logger.info("Tailscale:", action)
    return os.execute(self:command(action) .. " >/dev/null 2>&1") == 0
end

-- Runs an action in the background so the UI never waits on tailscale up.
function Tailscale:runDetached(action)
    if not self:scriptAvailable() then return false end
    logger.info("Tailscale (background):", action)
    os.execute(self:command(action) .. " >/dev/null 2>&1 &")
    return true
end

-- One of running, stopped, needs-login, no-daemon, no-binary, no-script.
function Tailscale:state()
    if not self:scriptAvailable() then return "no-script" end
    local pipe = io.popen(self:command("state") .. " 2>/dev/null", "r")
    if not pipe then return "no-script" end
    local state = pipe:read("*l")
    pipe:close()
    return state and state:match("^%s*(%S+)") or "no-daemon"
end

function Tailscale:isRunning()
    return self:state() == "running"
end

local STATE_TEXT = {
    running = _("Tailscale is on"),
    stopped = _("Tailscale is off"),
    ["needs-login"] = _("Tailscale needs a login. Run tailscale up once over SSH."),
    ["no-daemon"] = _("tailscaled is not running"),
    ["no-binary"] = _("The tailscale binary was not found"),
    ["no-script"] = _("tailscale-switch.sh was not found"),
}

function Tailscale:stateText(state)
    return STATE_TEXT[state or self:state()] or state
end

function Tailscale:notify(text, timeout)
    if self.config.NOTIFY ~= "1" then return end
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 2 })
end

function Tailscale:notifyStateLater(prefix)
    UIManager:scheduleIn(STATUS_DELAY, function()
        local state = self:state()
        local text = self:stateText(state)
        if prefix then text = prefix .. "\n" .. text end
        self:notify(text, state == "running" and 2 or 4)
    end)
end

-- Decides from the current Wi-Fi network and acts on it.
function Tailscale:applyByNetwork(reason)
    if not self:scriptAvailable() then
        logger.warn("Tailscale: switch script missing at", self:scriptPath())
        return
    end
    local network = self:currentNetwork()
    local target = (network and not self:isHome(network)) and "up" or "down"
    local key = target .. "|" .. (network and entryText(network) or "")
    if self.last_applied == key and reason ~= "manual" then
        logger.dbg("Tailscale: already applied", key)
        return
    end
    self.last_applied = key
    logger.info("Tailscale: network", network and entryText(network) or "(none)", "->", target, "(" .. tostring(reason) .. ")")
    if target == "up" then
        self:runDetached("up")
        self:notifyStateLater(T(_("Not at home (%1)"), network.ssid))
    else
        self:runNow("down")
        if network then
            self:notify(T(_("At home (%1): Tailscale off"), network.ssid))
        end
    end
end

-- KOReader events ---------------------------------------------------------

function Tailscale:onNetworkConnected()
    if self:autoEnabled() then
        self:applyByNetwork("connected")
    end
end

function Tailscale:onNetworkDisconnecting()
    self.last_applied = nil
    if self:autoEnabled() then
        -- Wi-Fi is still up for a moment, and tailscale down only talks to the
        -- local daemon anyway. Waiting for it keeps the suspend path tidy.
        self:runNow("down")
    end
end

function Tailscale:onResume()
    if self:autoEnabled() and NetworkMgr:isConnected() then
        UIManager:nextTick(function() self:applyByNetwork("resume") end)
    end
end

function Tailscale:onTailscaleToggle()
    self:toggle()
end

function Tailscale:onTailscaleByNetwork()
    self.last_applied = nil
    self:applyByNetwork("manual")
end

function Tailscale:toggle()
    if not self:scriptAvailable() then
        UIManager:show(InfoMessage:new{ icon = "notice-warning",
            text = T(_("tailscale-switch.sh was not found at\n%1"), self:scriptPath()) })
        return
    end
    self.last_applied = nil
    if self:isRunning() then
        self:runNow("down")
        self:notify(_("Tailscale off"))
    else
        self:runDetached("up")
        self:notify(_("Starting Tailscale…"))
        self:notifyStateLater()
    end
end

function Tailscale:showStatus()
    if not self:scriptAvailable() then
        UIManager:show(InfoMessage:new{ icon = "notice-warning",
            text = T(_("tailscale-switch.sh was not found at\n%1"), self:scriptPath()) })
        return
    end
    local pipe = io.popen(self:command("status") .. " 2>&1", "r")
    local output = pipe and pipe:read("*a") or ""
    if pipe then pipe:close() end
    output = output:match("^%s*(.-)%s*$")
    if output == "" then output = self:stateText() end
    UIManager:show(InfoMessage:new{ text = output, timeout = 30 })
end

-- Menu ----------------------------------------------------------------------

function Tailscale:editText(touchmenu_instance, opts)
    local dialog
    dialog = InputDialog:new{
        title = opts.title,
        input = self.config[opts.key] or "",
        input_hint = opts.hint,
        description = opts.description,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local value = dialog:getInputText():match("^%s*(.-)%s*$")
                UIManager:close(dialog)
                self:set(opts.key, value)
                self.last_applied = nil
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- The picker: the connected network first, as its access point and as its
-- name, then every network KOReader knows, then entries that fit neither.
function Tailscale:homeNetworkItems()
    local items = {}
    local covered = {}
    local function checkbox(entry, text, help)
        covered[entryText(entry)] = true
        return {
            text = text,
            help_text = help,
            checked_func = function() return self:hasHomeEntry(entry) end,
            callback = function() self:toggleHomeEntry(entry) end,
        }
    end

    local current = self:currentNetwork()
    if current then
        if current.bssid then
            table.insert(items, checkbox({ ssid = current.ssid, bssid = current.bssid },
                T(_("%1 (this access point, %2)"), current.ssid, current.bssid),
                _("Only this access point counts as home. Another network with the same name, or another access point of a mesh, does not.")))
        end
        local item = checkbox({ ssid = current.ssid },
            T(_("%1 (any network with this name)"), current.ssid),
            _("Every network with this name counts as home."))
        item.separator = true
        table.insert(items, item)
    end

    for i, ssid in ipairs(self:savedNetworkNames()) do
        if not (current and current.ssid == ssid) then
            table.insert(items, checkbox({ ssid = ssid }, ssid))
        end
    end

    local extra = 0
    for i, entry in ipairs(self:homeEntries()) do
        if not covered[entryText(entry)] then
            if extra == 0 and #items > 0 then items[#items].separator = true end
            extra = extra + 1
            table.insert(items, checkbox(entry, entryText(entry), _("Entered by hand. Untick to remove.")))
        end
    end

    if #items > 0 then items[#items].separator = true end
    table.insert(items, {
        text = _("Edit as text"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:editText(touchmenu_instance, {
                key = "HOME_NETWORKS",
                title = _("Home networks"),
                hint = "Home,aa:bb:cc:dd:ee:ff,Office@11:22:33:44:55:66",
                description = _("Comma separated. Each entry is a network name, an access point (BSSID), or name@BSSID for that access point only under that name."),
            })
        end,
    })
    return items
end

local function orNone(value)
    if value == nil or value == "" then return _("none") end
    return value
end

function Tailscale:homeNetworksSummary()
    local entries = self:homeEntries()
    if #entries == 0 then return _("none") end
    local names = {}
    for i, entry in ipairs(entries) do table.insert(names, entry.ssid or entry.bssid) end
    return table.concat(names, ", ")
end

function Tailscale:addToMainMenu(menu_items)
    menu_items.tailscale = {
        text = _("Tailscale"),
        sorting_hint = "network",
        checked_func = function() return self:isRunning() end,
        hold_callback = function(touchmenu_instance)
            self:toggle()
            touchmenu_instance:updateItems()
        end,
        sub_item_table = {
            {
                text_func = function() return T(_("Tailscale: %1"), self:stateText()) end,
                checked_func = function() return self:isRunning() end,
                check_callback_updates_menu = true,
                callback = function(touchmenu_instance)
                    self:toggle()
                    touchmenu_instance:updateItems()
                end,
            },
            {
                text = _("Switch by Wi-Fi network"),
                help_text = _("On when connected to a network that is not a home network, off at home or without Wi-Fi. Reacts only to network changes, nothing runs in the background."),
                checked_func = function() return self:autoEnabled() end,
                callback = function()
                    self:set("AUTO", self:autoEnabled() and "0" or "1")
                    if self:autoEnabled() then
                        self.last_applied = nil
                        if NetworkMgr:isConnected() then self:applyByNetwork("manual") end
                    end
                end,
            },
            {
                text = _("Apply to the current network now"),
                keep_menu_open = true,
                callback = function() self:onTailscaleByNetwork() end,
                separator = true,
            },
            {
                text_func = function() return T(_("Home networks: %1"), self:homeNetworksSummary()) end,
                help_text = _("Tailscale stays off on these networks. Tick the connected network, one you have saved, or type an entry."),
                sub_item_table_func = function() return self:homeNetworkItems() end,
                separator = true,
            },
            {
                text_func = function() return T(_("Login server: %1"), orNone(self.config.LOGIN_SERVER)) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editText(touchmenu_instance, {
                        key = "LOGIN_SERVER",
                        title = _("Login server"),
                        hint = "https://headscale.example.org",
                        description = _("Passed to tailscale up as --login-server. Leave empty for the Tailscale default."),
                    })
                end,
            },
            {
                text_func = function() return T(_("Flags for tailscale up: %1"), orNone(self.config.UP_ARGS)) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editText(touchmenu_instance, {
                        key = "UP_ARGS",
                        title = _("Flags for tailscale up"),
                        hint = "--accept-routes",
                    })
                end,
            },
            {
                text_func = function() return T(_("Command to start tailscaled: %1"), orNone(self.config.TAILSCALED_START)) end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editText(touchmenu_instance, {
                        key = "TAILSCALED_START",
                        title = _("Command to start tailscaled"),
                        hint = "tailscaled --state=/mnt/onboard/.adds/tailscale/state >/dev/null 2>&1 &",
                        description = _("Run when tailscaled is not running. Leave empty if something else starts it."),
                    })
                end,
            },
            {
                text = _("Show a message after switching"),
                checked_func = function() return self.config.NOTIFY == "1" end,
                callback = function() self:set("NOTIFY", self.config.NOTIFY == "1" and "0" or "1") end,
                separator = true,
            },
            {
                text = _("Show Tailscale status"),
                keep_menu_open = true,
                callback = function() self:showStatus() end,
            },
            {
                text_func = function() return T(_("Settings file: %1"), self:configPath()) end,
                enabled_func = function() return false end,
            },
        },
    }
end

return Tailscale
