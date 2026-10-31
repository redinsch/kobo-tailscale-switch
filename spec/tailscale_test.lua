-- Runs the KOReader plugin against the real tailscale-switch.sh with a fake
-- tailscale on the PATH. Usage, from the kobo-tailscale folder:
--   luajit spec/tailscale_test.lua <dir with fake tailscale/pidof/pgrep/wpa_cli>
local fake_bin = assert(arg[1], "pass the folder with the fake tailscale")
local work = os.getenv("TMPDIR") or "/tmp"
local switch_dir = work .. "/tailscale_test_switch"
os.execute("rm -rf " .. switch_dir .. " && mkdir -p " .. switch_dir)
os.execute("cp adds/tailscale-switch/tailscale-switch.sh " .. switch_dir .. "/")
local state_file = work .. "/tailscale_test_state"
os.execute("rm -f " .. state_file .. " " .. state_file .. ".lastup /tmp/fake_tailscaled_running")

-- Everything the plugin runs inherits this environment.
local real_execute, real_popen = os.execute, io.popen
local prefix = "PATH=" .. fake_bin .. ":$PATH FAKE_TS_STATE=" .. state_file .. " "
os.execute = function(cmd) return real_execute(prefix .. cmd) end
io.popen = function(cmd, mode) return real_popen(prefix .. cmd, mode) end

package.path = "koreader/tailscale.koplugin/?.lua;" .. package.path
local shown, scheduled, ticks = {}, {}, {}
local connected, ssid, bssid, saved = false, nil, nil, {}
package.loaded["gettext"] = function(text) return text end
package.loaded["ffi/util"] = { template = function(text, ...)
    local values = { ... }
    return (text:gsub("%%(%d+)", function(index) return tostring(values[tonumber(index)]) end))
end }
package.loaded["datastorage"] = { getDataDir = function() return work end }
package.loaded["device"] = { isKobo = function() return false end }
package.loaded["dispatcher"] = { registerAction = function() end }
package.loaded["logger"] = { dbg = function() end, info = function() end, warn = function() end }
package.loaded["util"] = {
    pathExists = function(path) local f = io.open(path, "r"); if f then f:close() return true end return false end,
    makePath = function(path) real_execute("mkdir -p " .. path) end,
}
package.loaded["ui/widget/infomessage"] = { new = function(_, opts) table.insert(shown, opts.text); return opts end }
package.loaded["ui/widget/inputdialog"] = { new = function(_, opts) return opts end }
package.loaded["ui/network/manager"] = {
    lease_ssid = nil,
    isConnected = function() return connected end,
    getCurrentNetwork = function() return ssid and { ssid = ssid, bssid = bssid } or nil end,
    getAllSavedNetworks = function() return { data = saved } end,
}
package.loaded["ui/uimanager"] = {
    show = function() end, close = function() end,
    nextTick = function(_, fn) table.insert(ticks, fn) end,
    scheduleIn = function(_, _seconds, fn) table.insert(scheduled, fn) end,
}
package.loaded["ui/widget/container/widgetcontainer"] = { extend = function(_, proto)
    proto.__index = proto
    proto.new = function(cls, opts) local o = setmetatable(opts or {}, cls); o:init(); return o end
    return proto
end }
G_reader_settings = { readSetting = function(_, key) if key == "tailscale_switch_dir" then return switch_dir end end }

local function assertEqual(actual, expected, label)
    if actual ~= expected then error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual))) end
end
-- Waits for a background run of the script to finish (the daemon start sleeps a second).
local function settle()
    real_execute("for i in $(seq 1 50); do pgrep -f tailscale-switch.sh >/dev/null || exit 0; sleep 0.1; done")
end
local function flush(list) local fns = { unpack(list) }; for i = #list, 1, -1 do list[i] = nil end; for _, fn in ipairs(fns) do fn() end end

local Tailscale = require("main")
local menu = { registerToMainMenu = function() end }

-- Fresh start without a config: defaults, nothing applied without Wi-Fi.
local plugin = Tailscale:new{ ui = { menu = menu } }
assertEqual(plugin.config.UP_ARGS, "--accept-routes", "default up flags")
assertEqual(plugin:autoEnabled(), true, "automatic by default")
assertEqual(#ticks, 0, "no network, nothing scheduled at start")
assertEqual(plugin:state(), "no-daemon", "state is asked of the script")

-- Settings round trip, including quotes and umlauts.
plugin:set("HOME_NETWORKS", "Zuhause@AA:BB:CC:DD:EE:FF, Rob's Büro, 11:22:33:44:55:66")
plugin:set("LOGIN_SERVER", "https://hs.example")
plugin:set("TAILSCALED_START", "touch /tmp/fake_tailscaled_running")
local again = Tailscale:new{ ui = { menu = menu } }
assertEqual(again.config.HOME_NETWORKS, "Zuhause@AA:BB:CC:DD:EE:FF, Rob's Büro, 11:22:33:44:55:66", "home networks survive the file")
assertEqual(again:isHome({ ssid = "Rob's Büro" }), true, "entries are trimmed")
assertEqual(again:isHome({ ssid = "Zuhause", bssid = "aa:bb:cc:dd:ee:ff" }), true, "name and access point")
assertEqual(again:isHome({ ssid = "Zuhause", bssid = "aa:bb:cc:dd:ee:00" }), false, "same name, another access point")
assertEqual(again:isHome({ ssid = "Zuhause" }), false, "same name, access point unknown")
assertEqual(again:isHome({ ssid = "Whatever", bssid = "11:22:33:44:55:66" }), true, "an access point under any name")
assertEqual(again:isHome({ ssid = "Cafe", bssid = "00:00:00:00:00:01" }), false, "a foreign network")
local config = io.open(switch_dir .. "/config.sh"):read("*a")
assert(config:find("HOME_NETWORKS='Zuhause@AA:BB:CC:DD:EE:FF, Rob'\\''s Büro, 11:22:33:44:55:66'", 1, true), "the file is a shell file")
-- An older file with HOME_SSIDS still reads.
local old = io.open(switch_dir .. "/config.sh", "w")
old:write("HOME_SSIDS='Altes Netz'\n")
old:close()
assertEqual(Tailscale:new{ ui = { menu = menu } }.config.HOME_NETWORKS, "Altes Netz", "HOME_SSIDS is read as HOME_NETWORKS")
again:writeConfig()

-- Joining a foreign network brings Tailscale up in the background.
connected, ssid, bssid = true, "Hotel WLAN", "de:ad:be:ef:00:01"
plugin = again
plugin:onNetworkConnected()
settle()
assertEqual(plugin:state(), "running", "foreign network: up")
assertEqual(#scheduled, 1, "the result is announced later")
flush(scheduled)
assertEqual(shown[#shown], "Not at home (Hotel WLAN)\nTailscale is on", "with the network and the state")
local lastup = io.open(state_file .. ".lastup"):read("*l")
assertEqual(lastup, "up --timeout=30s --login-server=https://hs.example --accept-routes", "the configured flags")

-- The same event again does nothing more.
local before = #shown
plugin:onNetworkConnected()
settle()
assertEqual(#shown, before, "a repeated connect on the same network is ignored")

-- Leaving Wi-Fi brings it down, at once.
plugin:onNetworkDisconnecting()
assertEqual(plugin:state(), "stopped", "disconnect: down")

-- Home network: down, with a note. The same name elsewhere is foreign.
ssid, bssid = "Zuhause", "AA:BB:CC:DD:EE:FF"
plugin:onNetworkConnected()
settle()
assertEqual(plugin:state(), "stopped", "home: stays down")
assertEqual(shown[#shown], "At home (Zuhause): Tailscale off", "and says so")
ssid, bssid = "Zuhause", "aa:bb:cc:dd:ee:02"
plugin:onNetworkConnected()
settle()
assertEqual(plugin:state(), "running", "another box called Zuhause: up")
plugin:onNetworkDisconnecting()

-- Automatic off: events do nothing; the manual toggle still works.
plugin:set("AUTO", "0")
ssid, bssid = "Hotel WLAN", "de:ad:be:ef:00:01"
plugin:onNetworkConnected()
settle()
assertEqual(plugin:state(), "stopped", "automatic off: connect does nothing")
plugin:toggle()
settle()
assertEqual(plugin:state(), "running", "manual toggle: up")
plugin:toggle()
assertEqual(plugin:state(), "stopped", "manual toggle: down")

-- Started with Wi-Fi already up, automatic on: applied once on the next tick.
plugin:set("AUTO", "1")
local third = Tailscale:new{ ui = { menu = menu } }
assertEqual(#ticks, 1, "startup with Wi-Fi schedules one decision")
flush(ticks)
settle()
assertEqual(third:state(), "running", "and applies it")

-- Resume on a home network turns it off again.
ssid, bssid = "Zuhause", "aa:bb:cc:dd:ee:ff"
third:onResume()
flush(ticks)
assertEqual(third:state(), "stopped", "resume at home: down")

-- The menu is built without touching the script until opened.
local items = {}
third:addToMainMenu(items)
assertEqual(items.tailscale.sorting_hint, "network", "lives in the Network menu")
assertEqual(#items.tailscale.sub_item_table, 10, "ten entries")
assertEqual(items.tailscale.sub_item_table[4].text_func(), "Home networks: Zuhause, Rob's Büro, 11:22:33:44:55:66", "home networks are summarised by name")

-- The picker lists the connected network twice, the saved ones, and hand-made entries.
saved = { ["Cafe Nord"] = { ssid = "Cafe Nord" }, Zuhause = { ssid = "Zuhause" }, ["Rob's Büro"] = { ssid = "Rob's Büro" } }
ssid, bssid = "Hotel WLAN", "de:ad:be:ef:00:01"
local picker = items.tailscale.sub_item_table[4].sub_item_table_func()
local texts = {}
for _, item in ipairs(picker) do table.insert(texts, item.text) end
assertEqual(texts[1], "Hotel WLAN (this access point, de:ad:be:ef:00:01)", "the connected access point comes first")
assertEqual(texts[2], "Hotel WLAN (any network with this name)", "then its name")
assertEqual(texts[3], "Cafe Nord", "then the saved networks, sorted")
assertEqual(texts[4], "Rob's Büro", "including a home one")
assertEqual(texts[5], "Zuhause", "the saved name of a home entry with access point")
assertEqual(texts[6], "Zuhause@aa:bb:cc:dd:ee:ff", "the exact entry is listed as itself")
assertEqual(texts[7], "11:22:33:44:55:66", "and the access point entry")
assertEqual(texts[8], "Edit as text", "then the text editor")
assertEqual(#picker, 8, "nothing else")
assertEqual(picker[4].checked_func(), true, "a saved home network is ticked")
assertEqual(picker[5].checked_func(), false, "the bare name is not, only the access point entry is")
assertEqual(picker[1].checked_func(), false, "the hotel is not home")
picker[1].callback()
assertEqual(picker[1].checked_func(), true, "ticking adds the access point")
assertEqual(third:isHome({ ssid = "Hotel WLAN", bssid = "DE:AD:BE:EF:00:01" }), true, "case does not matter")
assertEqual(third:isHome({ ssid = "Hotel WLAN", bssid = "de:ad:be:ef:00:02" }), false, "another hotel box is foreign")
picker[1].callback()
assertEqual(picker[1].checked_func(), false, "ticking again removes it")
picker[6].callback()
assertEqual(third:isHome({ ssid = "Zuhause", bssid = "aa:bb:cc:dd:ee:ff" }), false, "a hand-made entry can be unticked")
third:set("HOME_NETWORKS", "Zuhause@aa:bb:cc:dd:ee:ff,Rob's Büro,11:22:33:44:55:66")

-- Missing script: no crash, a warning instead.
G_reader_settings.readSetting = function() return work .. "/nowhere" end
local lost = Tailscale:new{ ui = { menu = menu } }
assertEqual(lost:state(), "no-script", "missing script is reported")
lost:onNetworkConnected()
lost:toggle()
assert(shown[#shown]:find("was not found", 1, true), "the toggle explains what is missing")

print("spec/tailscale_test.lua: ok")
