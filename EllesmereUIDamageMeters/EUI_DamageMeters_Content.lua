if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  EUI_DamageMeters_Content.lua
--
--  Switch by Content (off by default): every window keeps a meter type and a
--  segment for each kind of content and takes them when the player enters
--  that content. Content without its own pair uses the window's Default pair.
--  Reads the earlier Damage Meters files through ns and ns._dmInternals.
-------------------------------------------------------------------------------
local _, ns = ...
local I = ns._dmInternals
-- EllesmereUIDamageMeters.lua or an earlier EUI_DamageMeters_*.lua file
-- failed to load.
if not I or I.broken then return end
I.broken = true

local EUI = EllesmereUI

local DB, WinDB, DM_TYPE_NAMES, _windows = I.DB, I.WinDB, I.DM_TYPE_NAMES, I._windows

-- Options order. "default" is the open world and any content not listed.
local CONTENT_KEYS = { "default", "dungeon", "mythic", "raid", "delve", "arena", "battleground" }
local CONTENT_NAMES = {
    default = "Default", dungeon = "Dungeon", mythic = "Mythic+", raid = "Raid",
    delve = "Delve", arena = "Arena", battleground = "Battleground",
}
ns.DMContentKeys, ns.DMContentNames = CONTENT_KEYS, CONTENT_NAMES

local function KeyActive()
    return C_ChallengeMode and C_ChallengeMode.IsChallengeModeActive
        and C_ChallengeMode.IsChallengeModeActive()
end

-- The content the player is in, and the instance ID. A keystone that started
-- stays Mythic+ until the instance is left, so its completion and a reload
-- inside it keep the Mythic+ pair.
local function CurrentContent(keyStarted)
    local _, iType, _, _, _, _, _, instID = GetInstanceInfo()
    if EUI.IsInDungeon() then
        if keyStarted or KeyActive() then return "mythic", instID end
        local last = DB().contentLast
        if last and last.key == "mythic" and last.inst == instID then return "mythic", instID end
        return "dungeon", instID
    end
    if iType == "raid" then return "raid", instID end
    if iType == "arena" then return "arena", instID end
    if iType == "pvp" then return "battleground", instID end
    if EUI.IsInDelve() then return "delve", instID end
    return "default", instID
end
function ns.DMContentCurrent() return (CurrentContent()) end

-- A window's pair for one content: its own, else its Default pair, else none.
local function PairFor(wdb, key)
    local c = wdb.content
    return c and (c[key] or c.default)
end

-- Shows a window's pair for one content. A window not built yet only gets
-- its saved type and segment, which its build reads.
local function ApplyWindow(idx, key)
    local wdb = WinDB(idx)
    local pair = PairFor(wdb, key)
    if not pair then return end
    local dmType = DM_TYPE_NAMES[pair.dmType] and pair.dmType or nil
    local W = _windows[idx]
    if not W then
        if dmType then wdb.curDMType = dmType end
        if pair.session then wdb.curSession = pair.session end
        return
    end
    -- A Threat window (WoW Forever) is left alone.
    if W.curDMType == "threat" then return end
    if dmType and W.curDMType ~= dmType then W.SetDMType(dmType) end
    if pair.session and (W.curSession ~= pair.session or W.curSessionID) then
        ns.ApplySegmentSelection(W, pair.session, nil, true)
    end
end

-- Applies every window's pair when the content differs from the last one
-- applied (saved, so a reload in the same content keeps manual changes).
local function Apply(keyStarted)
    local cfg = DB()
    if not cfg.contentSwitch then return end
    local key, inst = CurrentContent(keyStarted)
    local last = cfg.contentLast
    if last and last.key == key then
        last.inst = inst
        return
    end
    cfg.contentLast = { key = key, inst = inst }
    for i = 1, math.max(1, cfg.windowCount or 1) do ApplyWindow(i, key) end
end

-- First time on: the Default pair is what the window shows now, and Mythic+
-- takes the window's Default on M+ Start type when it has one.
local function Seed(idx)
    local wdb = WinDB(idx)
    if wdb.content then return end
    local dmType = DM_TYPE_NAMES[wdb.curDMType] and wdb.curDMType or Enum.DamageMeterType.DamageDone
    local session = wdb.curSession or Enum.DamageMeterSessionType.Current
    wdb.content = { default = { dmType = dmType, session = session } }
    if DM_TYPE_NAMES[wdb.mythicStartDMType] then
        wdb.content.mythic = {
            dmType = wdb.mythicStartDMType,
            session = wdb.autoSwapMythic and Enum.DamageMeterSessionType.Current or session,
        }
    end
end

-- Inert until the feature is on: no events are registered on it while off.
local eventFrame = CreateFrame("Frame")
local pending = false
local function DeferredApply()
    pending = false
    Apply()
end
-- A loading screen can send both events; the instance and delve state are
-- read half a second later, as the session refresh after a zone-in does.
eventFrame:SetScript("OnEvent", function()
    if pending then return end
    pending = true
    C_Timer.After(0.5, DeferredApply)
end)

-- Login, profile swap and the options toggle: events on while the feature is
-- on, off otherwise. applyNow applies the current content right away.
function ns.DMContentSync(applyNow)
    local cfg = DB()
    if cfg.contentSwitch then
        for i = 1, math.max(1, cfg.windowCount or 1) do Seed(i) end
        eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        -- A delve can start after its zone-in; pcall in case the event is ever retired
        pcall(eventFrame.RegisterEvent, eventFrame, "ACTIVE_DELVE_DATA_UPDATE")
        if applyNow then Apply() end
    else
        eventFrame:UnregisterAllEvents()
        cfg.contentLast = nil
    end
end

-- Keystone start, after State.lua's own reset and auto-swap.
function ns.DMContentKeyStart()
    if DB().contentSwitch then Apply(true) end
end

-- Options: a window's own pair for one content (nil = uses Default).
function ns.DMContentGet(idx, key)
    local c = WinDB(idx).content
    return c and c[key]
end

-- Options: sets one field of a window's pair for one content, starting it from
-- the Default pair when the content had none. The window shows it at once when
-- it is the pair for the content the player is in.
function ns.DMContentSet(idx, key, field, value)
    Seed(idx)
    local wdb = WinDB(idx)
    local pair = wdb.content[key]
    if not pair then
        local def = wdb.content.default
        pair = { dmType = def.dmType, session = def.session }
        wdb.content[key] = pair
    end
    pair[field] = value
    local cur = CurrentContent()
    if PairFor(wdb, cur) == pair and DB().contentSwitch then ApplyWindow(idx, cur) end
end

-- Options: a content goes back to the window's Default pair.
function ns.DMContentClear(idx, key)
    local wdb = WinDB(idx)
    if key == "default" or not wdb.content then return end
    wdb.content[key] = nil
    local cur = CurrentContent()
    if cur == key and DB().contentSwitch then ApplyWindow(idx, cur) end
end

I.broken = false
