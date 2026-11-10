-- Stub harness: Damage Meters Switch by Content (EUI_DamageMeters_Content.lua).
-- Loads the real file under stubs and drives zone-ins, keystone start and end,
-- reloads, manual changes, the options setters and the on/off switch, then
-- checks every window's meter type and segment and the events it registers.
--   lua .tools/tests/test_dm_content_switch.lua        (from the repository root)
local TARGET = DMC_TARGET or "EllesmereUIDamageMeters/EUI_DamageMeters_Content.lua"

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
    DamageMeterType = { DamageDone = 0, HealingDone = 2, Absorbs = 4, Interrupts = 5, Dispels = 6,
        DamageTaken = 7, AvoidableDamageTaken = 8, Deaths = 9, EnemyDamageTaken = 10 },
    DamageMeterSessionType = { Overall = 0, Current = 1 },
}
local T, S = Enum.DamageMeterType, Enum.DamageMeterSessionType

-- world state the stubs read
local world = { iType = "none", inst = 2552, key = false, delve = false, garrison = false }
local function Go(iType, inst, opts)
    opts = opts or {}
    world.iType, world.inst = iType, inst
    world.key, world.delve, world.garrison = opts.key or false, opts.delve or false, opts.garrison or false
end
GetInstanceInfo = function() return "Somewhere", world.iType, 0, "", 5, 0, false, world.inst end
C_ChallengeMode = { IsChallengeModeActive = function() return world.key end }
EUI_CLIENT_BLOCKED = nil
EllesmereUI = {
    IsInDungeon = function() return world.iType == "party" and not world.garrison end,
    IsInDelve = function() return world.delve end,
}

-- frames and timers
local frames, timers = {}, {}
CreateFrame = function()
    local f = { events = {}, script = nil }
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterAllEvents() self.events = {} end
    function f:SetScript(_, fn) self.script = fn end
    frames[#frames + 1] = f
    return f
end
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
local function RunTimers() local t = timers; timers = {}; for _, fn in ipairs(t) do fn() end end
local function Fire(event)
    for _, f in ipairs(frames) do if f.events[event] and f.script then f.script(f, event) end end
end
local function ZoneIn() Fire("PLAYER_ENTERING_WORLD"); Fire("ZONE_CHANGED_NEW_AREA"); RunTimers() end

-- profile, windows and the internals the file reads
local cfg = { windowCount = 3, windows = {} }
local function WinDB(i)
    cfg.windows[i] = cfg.windows[i] or { width = 375, height = 150 }
    return cfg.windows[i]
end
local NAMES = {}
for _, v in pairs(T) do if v ~= T.Absorbs then NAMES[v] = true end end
local windows = {}
local setCalls, segCalls = 0, {}
local function NewWindow(i, dmType, session)
    local wdb = WinDB(i)
    wdb.curDMType, wdb.curSession = dmType, session
    local W = { idx = i, curDMType = dmType, curSession = session }
    function W.SetDMType(t) setCalls = setCalls + 1; W.curDMType = t; wdb.curDMType = t end
    windows[i] = W
    return W
end
local ns = {}
ns._dmInternals = { DB = function() return cfg end, WinDB = WinDB, DM_TYPE_NAMES = NAMES, _windows = windows }
function ns.ApplySegmentSelection(W, sessionType, sessionID, noSync)
    segCalls[#segCalls + 1] = { idx = W.idx, noSync = noSync }
    W.curSession = sessionType; WinDB(W.idx).curSession = sessionType; W.curSessionID = sessionID
end

local w1 = NewWindow(1, T.DamageDone, S.Overall)
local w2 = NewWindow(2, T.DamageDone, S.Current)
local w3 = NewWindow(3, T.Deaths, S.Current)
WinDB(1).mythicStartDMType = T.DamageDone
WinDB(3).mythicStartDMType = T.Deaths
WinDB(1).autoSwapMythic = true

local fn = assert(loadfile(TARGET))
fn("EllesmereUIDamageMeters", ns)
eq(ns._dmInternals.broken, false, "file loaded")
local ev = frames[1] and frames[1].events or {}
check(next(ev) == nil, "zero cost: nothing registered at load")

-- off: login sync registers nothing, zone-ins change nothing
ns.DMContentSync()
check(next(frames[1].events) == nil, "off: no events after the login sync")
Go("party", 2526) ZoneIn()
eq(w1.curDMType, T.DamageDone, "off: window untouched")
check(WinDB(1).content == nil, "off: nothing seeded")

-- switch on in the open world: seeds Default from what each window shows
Go("none", 2552)
cfg.contentSwitch = true
ns.DMContentSync(true)
check(frames[1].events.PLAYER_ENTERING_WORLD and frames[1].events.ZONE_CHANGED_NEW_AREA
    and frames[1].events.ACTIVE_DELVE_DATA_UPDATE, "on: zone and delve events registered")
eq(WinDB(1).content.default.dmType, T.DamageDone, "seed: w1 Default type")
eq(WinDB(1).content.default.session, S.Overall, "seed: w1 Default segment")
eq(WinDB(3).content.mythic.dmType, T.Deaths, "seed: w3 Mythic+ from Default on M+ Start")
eq(WinDB(1).content.mythic.session, S.Current, "seed: w1 Mythic+ segment Current (auto swap was on)")
check(WinDB(2).content.mythic == nil, "seed: w2 has no Default on M+ Start, no Mythic+ pair")
eq(cfg.contentLast.key, "default", "on: last content recorded")
eq(setCalls, 0, "on: nothing switched (Default is what they show)")

-- options: a Dungeon pair for w1 while in the open world does not switch it now
ns.DMContentSet(1, "dungeon", "dmType", T.HealingDone)
eq(WinDB(1).content.dungeon.session, S.Overall, "set: new pair starts from Default's segment")
eq(w1.curDMType, T.DamageDone, "set: other content's pair waits")
ns.DMContentSet(2, "dungeon", "session", S.Overall)

-- enter a dungeon (one deferred apply for both events)
Go("party", 2526) Fire("PLAYER_ENTERING_WORLD"); Fire("ZONE_CHANGED_NEW_AREA")
eq(#timers, 1, "zone-in: one deferred apply for both events")
RunTimers()
eq(w1.curDMType, T.HealingDone, "dungeon: w1 takes its Dungeon pair")
eq(w2.curSession, S.Overall, "dungeon: w2 takes its Dungeon segment")
eq(w3.curDMType, T.Deaths, "dungeon: w3 uses Default")
check(segCalls[#segCalls] and segCalls[#segCalls].noSync == true, "segment switch skips Sync Segment Selection")

-- manual change, then a reload in the same dungeon keeps it
w1.SetDMType(T.Interrupts)
ZoneIn()
eq(w1.curDMType, T.Interrupts, "reload in the same content keeps a manual change")

-- keystone start: Mythic+ pairs
ns.DMContentKeyStart()
eq(w1.curDMType, T.DamageDone, "key start: w1 Mythic+ type")
eq(w1.curSession, S.Current, "key start: w1 Mythic+ segment")
eq(w3.curDMType, T.Deaths, "key start: w3 Mythic+ type")
eq(cfg.contentLast.key, "mythic", "key start: last is Mythic+")
-- completion (the game no longer reports a key) and a reload inside: still Mythic+
w1.SetDMType(T.HealingDone); w1.curSession = S.Overall
world.key = false
ZoneIn()
eq(w1.curDMType, T.HealingDone, "after the key, a reload in the instance keeps the window")
eq(ns.DMContentCurrent(), "mythic", "after the key, the same instance still reads Mythic+")

-- out to the open world: Default pairs, a pinned past segment is cleared
w2.curSessionID = 77
Go("none", 2552) ZoneIn()
eq(w1.curDMType, T.DamageDone, "open world: w1 Default type")
eq(w1.curSession, S.Overall, "open world: w1 Default segment")
eq(w2.curSessionID, nil, "open world: w2 pinned segment cleared")
eq(w2.curSession, S.Current, "open world: w2 Default segment")
-- a new dungeon run is Dungeon again, not Mythic+
Go("party", 2526) ZoneIn()
eq(ns.DMContentCurrent(), "dungeon", "re-entering after leaving reads Dungeon")
eq(w1.curDMType, T.HealingDone, "re-entering: w1 Dungeon pair again")

-- Same as Default clears a pair and shows Default at once when it is the current content
ns.DMContentClear(1, "dungeon")
check(WinDB(1).content.dungeon == nil, "clear: pair removed")
eq(w1.curDMType, T.DamageDone, "clear: current content falls back to Default now")
ns.DMContentClear(1, "default")
check(WinDB(1).content.default ~= nil, "clear: Default cannot be cleared")
-- editing the current content's pair shows it at once
ns.DMContentSet(3, "dungeon", "dmType", T.Interrupts)
eq(w3.curDMType, T.Interrupts, "set: the current content's pair shows at once")

-- content mapping
local cases = {
    { "raid", 2657, nil, "raid" }, { "arena", 1, nil, "arena" }, { "pvp", 2, nil, "battleground" },
    { "scenario", 3, { delve = true }, "delve" }, { "scenario", 4, nil, "default" },
    { "party", 1158, { garrison = true }, "default" }, { "none", 2552, nil, "default" },
    { "party", 2526, { key = true }, "mythic" },
}
for _, c in ipairs(cases) do
    Go(c[1], c[2], c[3])
    eq(ns.DMContentCurrent(), c[4], "content for " .. c[1] .. (c[3] and " +opts" or ""))
end

-- a delve that starts after the zone-in: the delve data event re-checks
Go("scenario", 3)
ZoneIn()
WinDB(1).content.delve = { dmType = T.Dispels, session = S.Current }
world.delve = true
Fire("ACTIVE_DELVE_DATA_UPDATE") RunTimers()
eq(w1.curDMType, T.Dispels, "delve: started after the zone-in, applied on the delve data event")

-- a window not built yet only gets its saved fields; a Threat window is left alone
windows[3] = nil
WinDB(3).content.raid = { dmType = T.Dispels, session = S.Overall }
w2.curDMType = "threat"
WinDB(2).content.raid = { dmType = T.Dispels, session = S.Overall }
Go("raid", 2657) ZoneIn()
eq(WinDB(3).curDMType, T.Dispels, "unbuilt window: saved type set")
eq(WinDB(3).curSession, S.Overall, "unbuilt window: saved segment set")
eq(w2.curDMType, "threat", "Threat window left alone")
windows[3] = w3
w2.curDMType = T.DamageDone

-- a bad saved type is ignored, the segment still applies
WinDB(1).content.arena = { dmType = 99, session = S.Current }
Go("arena", 1) ZoneIn()
eq(w1.curDMType, T.DamageDone, "unknown saved type ignored")
eq(w1.curSession, S.Current, "segment applied with an unknown type")

-- key start while off does nothing; switching off unregisters and forgets the last content.
-- A zone-in's deferred apply still queued when the switch goes off does nothing.
WinDB(1).content.raid = { dmType = T.Deaths, session = S.Overall }
Go("raid", 2657) Fire("PLAYER_ENTERING_WORLD")
cfg.contentSwitch = false
ns.DMContentSync(true)
RunTimers()
check(w1.curDMType ~= T.Deaths, "off: a queued zone-in apply does nothing")
check(next(frames[1].events) == nil, "off again: events unregistered")
eq(cfg.contentLast, nil, "off again: last content forgotten")
local before = w1.curDMType
Go("party", 2526, { key = true })
ns.DMContentKeyStart()
eq(w1.curDMType, before, "off: key start does nothing")

-- a window added later is seeded when the switch comes back on
cfg.windowCount = 4
NewWindow(4, T.EnemyDamageTaken, S.Current)
cfg.contentSwitch = true
ns.DMContentSync(true)
eq(WinDB(4).content.default.dmType, T.EnemyDamageTaken, "new window seeded on switch-on")

if fails == 0 then print("test_dm_content_switch: all checks passed") end
os.exit(fails == 0 and 0 or 1)
