-- Stub harness: the Damage Meters options page's SWITCH BY CONTENT section
-- (EUI_DamageMeters_Options.lua) over the real EUI_DamageMeters_Content.lua.
-- Builds the whole page under permissive stubs (pre-build pass), finds the
-- section's rows and drives them: the toggle, Configure For, each window's
-- Meter Type (Same as Default included) and Segment, and the greyed state.
--   lua .tools/tests/test_dm_content_options.lua        (from the repository root)
local OPTIONS = DMO_TARGET or "EllesmereUIOptions/EUI_DamageMeters_Options.lua"
local CONTENT = "EllesmereUIDamageMeters/EUI_DamageMeters_Content.lua"

local fails = 0
local function check(cond, msg)
    if not cond then
        fails = fails + 1
        print("  FAIL: " .. msg)
    end
end
local function eq(a, b, msg)
    check(a == b, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

Enum = {
    DamageMeterType = { DamageDone = 0, HealingDone = 2, Interrupts = 5, Dispels = 6,
        DamageTaken = 7, AvoidableDamageTaken = 8, Deaths = 9, EnemyDamageTaken = 10 },
    DamageMeterSessionType = { Overall = 0, Current = 1 },
}
local T, S = Enum.DamageMeterType, Enum.DamageMeterSessionType

-- permissive stubs: any unknown member is a function returning a stub frame and a height
local frameMeta
frameMeta = { __index = function(t, k)
    if type(k) == "string" and k:sub(1, 1) == "_" and k ~= "_rightRegion" and k ~= "_leftRegion" then return nil end
    if k == "_rightRegion" or k == "_leftRegion" then local f = setmetatable({}, frameMeta); rawset(t, k, f); return f end
    if k == "GetScript" then return function(self, n) return rawget(self, "__s_" .. n) end end
    if k == "GetFrameLevel" or k == "GetWidth" or k == "GetHeight" then return function() return 1 end end
    if k == "SetScript" then return function(self, n, fn) rawset(self, "__s_" .. n, fn) end end
    if k == "GetRegions" or k == "GetChildren" then return function() end end
    return function() return setmetatable({}, frameMeta) end
end }
local function Frame() return setmetatable({}, frameMeta) end
local function Permissive(t)
    return setmetatable(t or {}, { __index = function() return function() return Frame(), 30 end end })
end

EUI_CLIENT_BLOCKED = nil
IsLoggedIn = function() return true end
CreateFrame = function() return Frame() end
C_Timer = { After = function() end }
GetInstanceInfo = function() return "x", "party", 0, "", 5, 0, false, 2526 end
C_ChallengeMode = { IsChallengeModeActive = function() return false end }

local rows = {}
local W = Permissive({})
function W:SectionHeader(_, text) rows[#rows + 1] = { header = text }; return Frame(), 30 end
function W:DualRow(_, _, left, right) rows[#rows + 1] = { left = left, right = right }; return Frame(), 30 end

local refreshes = 0
EllesmereUI = Permissive({
    _prebuilding = true,
    L = function(s) return s end,
    Lf = function(s, ...) return string.format(s, ...) end,
    Widgets = W, PP = Permissive({}),
    _Pool = { CreateFrame = function() return Frame() end, IsIdle = function() return true end },
    BlizzStyle = Permissive({ Note = function(_, y) return y end, Active = function() return nil end,
        Gate = function(_, c) return c end }),
    BuildVisibilityRow = function() return Frame(), 30 end,
    GetBorderTextureDropdown = function() return { solid = "Solid" }, { "solid" } end,
    IsInDungeon = function() return true end, IsInDelve = function() return false end,
})
local lastForce
function EllesmereUI:RefreshPage(force) refreshes = refreshes + 1; lastForce = force end
local registered
function EllesmereUI:RegisterModule(_, spec) registered = spec end

-- the module namespace, its profile and the real Content.lua on stub internals
local cfg = { windowCount = 2, windows = {} }
_G._EDM_DB = { profile = { dm = cfg } }
local function WinDB(i)
    cfg.windows[i] = cfg.windows[i] or {}
    return cfg.windows[i]
end
WinDB(1).curDMType, WinDB(1).curSession = T.DamageDone, S.Overall
WinDB(2).curDMType, WinDB(2).curSession = T.HealingDone, S.Current
local NAMES = {}
for _, v in pairs(T) do NAMES[v] = true end
local ns = { EDM = {}, _windows = {} }
ns._dmInternals = { DB = function() return cfg end, WinDB = WinDB, DM_TYPE_NAMES = NAMES, _windows = ns._windows }
function ns.ApplySegmentSelection() end
EllesmereUI._ModuleNS = { EllesmereUIDamageMeters = ns }
assert(loadfile(CONTENT))("EllesmereUIDamageMeters", ns)
assert(loadfile(OPTIONS))()
assert(registered and registered.buildPage, "page registered")

local function Build()
    rows = {}
    local ok, err = pcall(registered.buildPage, "Damage Meters", Frame(), 0)
    check(ok, "page builds: " .. tostring(err))
end
local function Find(text)
    for _, r in ipairs(rows) do
        if r.left and r.left.text == text then return r.left, r end
        if r.right and r.right.text == text then return r.right, r end
    end
end

Build()
local hdr = false
for _, r in ipairs(rows) do if r.header == "SWITCH BY CONTENT" then hdr = true end end
check(hdr, "section header present")
local toggle = Find("Switch by Content")
local pick = Find("Configure For")
local type1 = Find("Window 1 Meter Type")
local seg1 = Find("Window 1 Segment")
local type2 = Find("Window 2 Meter Type")
check(toggle and pick and type1 and seg1 and type2, "rows present")
check(Find("Window 3 Meter Type") == nil, "one row per window (2 windows)")
eq(toggle.getValue(), false, "toggle off by default")
check(pick.disabled() and type1.disabled() and seg1.disabled(), "rows greyed while off")
eq(pick.getValue(), "dungeon", "Configure For starts at the current content")
eq(type1.getValue(), tostring(T.DamageDone), "off, Dungeon: Window 1 shows the type it would take, not a Same as Default key")
eq(seg1.getValue(), tostring(S.Overall), "off: segment shows what the window has")

-- on
toggle.setValue(true)
eq(cfg.contentSwitch, true, "toggle writes the setting")
check(not pick.disabled(), "rows live while on")
eq(WinDB(1).content.default.dmType, T.DamageDone, "toggle on seeds Default")
Build()
type1, seg1 = Find("Window 1 Meter Type"), Find("Window 1 Segment")
check(type1.values.same ~= nil and type1.order[1] == "same", "Same as Default offered for Dungeon")

-- a Dungeon type for window 1
type1.setValue(tostring(T.Interrupts))
eq(WinDB(1).content.dungeon.dmType, T.Interrupts, "type writes the Dungeon pair")
eq(WinDB(1).content.dungeon.session, S.Overall, "the pair starts from Default's segment")
eq(type1.getValue(), tostring(T.Interrupts), "type reads the pair")
seg1.setValue(tostring(S.Current))
eq(WinDB(1).content.dungeon.session, S.Current, "segment writes the Dungeon pair")
eq(WinDB(1).content.default.session, S.Overall, "Default untouched")
-- Same as Default
type1.setValue("same")
eq(WinDB(1).content.dungeon, nil, "Same as Default clears the pair")
eq(type1.getValue(), tostring(T.DamageDone), "after Same as Default the row shows Default's type")
eq(seg1.getValue(), tostring(S.Overall), "segment then shows Default's")

-- Configure For Default: no Same as Default, edits Default
pick.setValue("default")
eq(lastForce, true, "Configure For rebuilds the page")
Build()
type1, seg1 = Find("Window 1 Meter Type"), Find("Window 1 Segment")
eq(type1.values.same, nil, "no Same as Default for Default")
type1.setValue(tostring(T.Deaths))
eq(WinDB(1).content.default.dmType, T.Deaths, "type writes Default")
check(refreshes > 0, "setters refresh the page")

-- every row shows a value its list has a label for, on every content (never a raw key)
for _, key in ipairs(ns.DMContentKeys) do
    pick.setValue(key)
    Build()
    for i = 1, 2 do
        local tr, sr = Find("Window " .. i .. " Meter Type"), Find("Window " .. i .. " Segment")
        check(tr.values[tr.getValue()] ~= nil, key .. ": window " .. i .. " type label exists (" .. tostring(tr.getValue()) .. ")")
        check(sr.values[sr.getValue()] ~= nil, key .. ": window " .. i .. " segment label exists")
    end
end
pick = Find("Configure For")

-- off again greys the rows and keeps the pairs
toggle = Find("Switch by Content")
toggle.setValue(false)
check(type1.disabled(), "greyed again")
eq(WinDB(1).content.default.dmType, T.Deaths, "pairs kept while off")

if fails == 0 then print("test_dm_content_options: all checks passed") end
os.exit(fails == 0 and 0 or 1)
