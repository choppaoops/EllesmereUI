if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
--------------------------------------------------------------------------------
--  EllesmereUICdmBuffRings.lua
--  Tracking Bar groups displayed as rings: each such group draws its aura bars
--  as concentric rings round one centre, layered in bar-list order (Ring Order
--  picks which end sits innermost). Display mode, ring layout and the centre
--  are group settings (ns.TBBGroupRingStore); every ring group has its own
--  unlock mover. Presets and cooldown bars stay bars (ns.TBBIsRing).
--
--  Everything is drawn by the engine, so a ring is exact in combat with secret
--  values and costs no per-tick Lua:
--    * Ring: one aura slot per ring in its own container. The slot button owns
--      a Cooldown whose swipe texture is a ring (bound with
--      SetDurationCooldown). Absent aura = the engine hides the button; the
--      other rings keep their places (slots are not laid out).
--    * Texts and icons: per position (Center, Bottom, Left, Right) and unit, a
--      geometry container of groups G_i (filter = ids of rings i..N, one
--      frame, length = ring i's step out), so the visible ones add up to the
--      outermost VISIBLE ring's outer radius, and a row container hung from
--      its outer edge: one row per ring with that ring's icon and texts, so
--      they always sit just outside the outermost ring that is up, in ring
--      order. Lua never reads a remaining time, a count or a shown state.
--  Own debuffs on the target (cooldownInfo.selfAura == false) use "target"
--  containers.
--
--  Masks do not clip a Cooldown's swipe, so the ring shape lives in the
--  texture: media/basics/rings holds 51 ring textures whose width is a fixed
--  share of the texture, 10% apart (.tools/buff-rings/make_ring_art.pl).
--  Each ring picks the one closest to the wanted width and is sized so that
--  any width error is split between its two edges.
--
--  ENGINE RULE (measured): every call under an aura button is legal inside
--  initializeFrame and while auras are not secret, and denied while they
--  are. Look changes go through AK.RestyleSoon, which re-queues a denied key
--  for the restriction lift. Visibility, opacity and the kept track live on
--  each ring's wrapper, outside the button, so they stay writable in combat.
--
--  Frames are permanent, so every container is pooled and re-pointed
--  (candidate filters, layout, unit) instead of rebuilt; groups are declared
--  once per pool slot and switched off when unused.
--
--  Cost model: no ring group, no frame, container or event.
--------------------------------------------------------------------------------
local _, ns = ...

local AK

local floor, max, abs = math.floor, math.max, math.abs

-- ring_NN.png: width / texture width = RING_K0 * RING_KF^(NN-1); the outer edge
-- sits RING_PAD texels inside the RING_SIZE texture. Keep in step with the art.
local RING_TEX = "Interface\\AddOns\\EllesmereUI\\media\\basics\\rings\\ring_%02d.png"
local RING_SIZE, RING_PAD, RING_K0, RING_KF, RING_COUNT = 512, 1, 0.004, 1.1, 51
local RING_OUTER = 0.5 - RING_PAD / RING_SIZE -- outer radius / texture width
local RING_K = {}
for i = 1, RING_COUNT do RING_K[i] = RING_K0 * RING_KF ^ (i - 1) end

-- Group ring layout defaults: outer diameter of the innermost ring, ring width,
-- gap between rings, and which end of the bar list sits innermost.
local RING_DEFAULTS = { ringSize = 140, ringWidth = 10, ringGap = 3, ringOrder = "inner" }
ns.TBR_RING_DEFAULTS = RING_DEFAULTS

-- Gap between the outermost visible ring and the texts outside it.
local TEXT_MARGIN = 2

local function LayoutValue(store, key)
    local v = store and store[key]
    if v == nil then return RING_DEFAULTS[key] end
    return v
end

-- Texture for a ring whose centre line runs at radius `mid`, `width` wide.
-- Returns { tex, d (texture size), width, inner, outer } with the real width
-- and edges: the width error is split evenly between the two edges.
local function PickRing(mid, width)
    local best, bestD, bestErr
    for i = 1, RING_COUNT do
        local k = RING_K[i]
        local d = mid / (RING_OUTER - k / 2)
        local err = abs(k * d - width)
        if not bestErr or err < bestErr then best, bestD, bestErr = i, d, err end
    end
    local w = RING_K[best] * bestD
    local outer = bestD * RING_OUTER
    return { tex = RING_TEX:format(best), d = bestD, width = w, outer = outer, inner = outer - w }
end

--------------------------------------------------------------------------------
--  Per-bar text, icon and look settings (the bar options are shared with bars)
--------------------------------------------------------------------------------
local POSITIONS = { center = true, bottom = true, left = true, right = true }

local function RingPos(v)
    if POSITIONS[v] then return v end
    return nil -- "none", or a bar-only position
end

local function NamePos(cfg)
    return RingPos(cfg.namePosition or ((cfg.showName ~= false) and "left" or "none"))
end

local function TimerPos(cfg)
    return RingPos(cfg.timerPosition or (cfg.showTimer and "right" or "none"))
end

local function StacksPos(cfg)
    return RingPos(cfg.stacksPosition or "center")
end

local function IconPos(cfg)
    local v = cfg.iconDisplay
    if v == "left" or v == "right" then return v end
    return nil
end

local function TextColor(cfg, prefix)
    local r, g, b, a = cfg[prefix .. "TextR"], cfg[prefix .. "TextG"], cfg[prefix .. "TextB"], cfg[prefix .. "TextA"]
    if r == nil then r = 1 end
    if g == nil then g = 1 end
    if b == nil then b = 1 end
    if a == nil then a = 0.9 end
    return r, g, b, a
end

local function DisplayName(cfg)
    local name = cfg.name
    if (not name or name == "") and cfg.spellID and cfg.spellID > 0 then
        local info = C_Spell.GetSpellInfo(cfg.spellID)
        name = info and info.name
    end
    return name or ""
end

-- Text widths for side-by-side texts (Left / Right). Our own FontString, never
-- under an aura button, so it is readable in any state.
local ruler
local function TextWidth(text, size)
    if not ruler then
        local f = CreateFrame("Frame", nil, UIParent)
        f:Hide()
        ruler = f:CreateFontString(nil, "OVERLAY")
    end
    EllesmereUI.ApplyModuleFont(ruler, nil, size, "cdm")
    ruler:SetText(text)
    return ruler:GetStringWidth() or (size * #text * 0.6)
end

--------------------------------------------------------------------------------
--  State
--------------------------------------------------------------------------------
local sets = {}       -- mover key -> ring set
local watcher         -- target / faction refresh, registered only while rings exist
local pendingRegen
local liftHooked
local serial = 0

-- A global group keeps one identity across specs (its registry key); a local one
-- is its group id on the active spec.
local function MoverKey(gid)
    local gk = ns.TBBGroupGlobalKey and ns.TBBGroupGlobalKey(gid)
    if gk then return "TBRG_" .. gk end
    return "TBR_" .. gid
end
ns.TBRMoverKey = MoverKey

local function AuraFilter(unit)
    if unit == "target" then return { "HARMFUL", "PLAYER" } end
    return { "HELPFUL" }
end

local function IdSig(include)
    local ids = {}
    for id in pairs(include) do ids[#ids + 1] = id end
    table.sort(ids)
    return table.concat(ids, ",")
end

--------------------------------------------------------------------------------
--  Rings
--------------------------------------------------------------------------------

-- AK applyExtra: runs at init (after the regions exist) and on every restyle.
-- Under aura secrecy the first write throws, and the restyle worker defers the key.
local function ApplyRingLook(button, d, style)
    local rd = d.ring
    if not rd then return end -- the init pass runs once before InitRing builds the regions
    local s = style.ring
    if rd.tex ~= s.tex then
        rd.cd:SetSwipeTexture(s.tex)
        rd.track:SetTexture(s.tex)
        rd.tex = s.tex
    end
    rd.cd:SetSwipeColor(s.r, s.g, s.b, s.a)
    rd.cd:SetReverse(s.reverse)
    -- With the kept track (Hide When Inactive off) the background lives on the wrapper.
    rd.track:SetVertexColor(s.bgR, s.bgG, s.bgB, s.keepTrack and 0 or s.bgA)
end

-- initializeFrame window: the only time the button itself may be anchored.
local function InitRing(r, button, d)
    button:ClearAllPoints()
    button:SetPoint("CENTER", r.wrapper, "CENTER", 0, 0)
    pcall(button.SetMouseClickEnabled, button, false)
    pcall(button.SetMouseMotionEnabled, button, false)

    local s = r.style.ring
    local holder = CreateFrame("Frame", nil, button)
    holder:SetAllPoints(button)
    holder:EnableMouse(false)
    local track = holder:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints(holder)
    track:SetTexture(s.tex)

    local cd = CreateFrame("Cooldown", nil, holder, "CooldownFrameTemplate")
    cd:SetAllPoints(holder)
    -- No edge: the stock edge texture draws as a long radial wedge over a ring swipe.
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetHideCountdownNumbers(true)
    cd:SetSwipeTexture(s.tex)

    d.ring = { tex = s.tex, track = track, cd = cd }
    button:SetDurationCooldown(cd)
    ApplyRingLook(button, d, r.style)
end

local function NewRing(set)
    serial = serial + 1
    local r = { styleKey = "tbrRing" .. serial }
    r.wrapper = CreateFrame("Frame", nil, set.host)
    r.wrapper:SetPoint("CENTER", set.host, "CENTER", 0, 0)
    r.wrapper:EnableMouse(false)
    r.keep = CreateFrame("Frame", nil, r.wrapper)
    r.keep:SetAllPoints(r.wrapper)
    r.keepTex = r.keep:CreateTexture(nil, "BACKGROUND")
    r.keepTex:SetAllPoints(r.keep)
    r.style = { noRegions = true, width = 1, height = 1, applyExtra = ApplyRingLook, ring = {} }
    AK.styles[r.styleKey] = r.style
    return r
end

-- Point a pooled ring at a bar: unit, spell ids, look and size.
local function FillRing(r, layer)
    local cfg, geo = layer.cfg, layer.geo
    local st, s = r.style, r.style.ring
    st.width, st.height = geo.d, geo.d
    s.tex = geo.tex
    s.r, s.g, s.b, s.a = cfg.fillR or 1, cfg.fillG or 1, cfg.fillB or 1, cfg.fillA or 1
    s.bgR, s.bgG, s.bgB, s.bgA = cfg.bgR or 0, cfg.bgG or 0, cfg.bgB or 0, cfg.bgA or 0.4
    s.keepTrack = layer.keepTrack
    s.reverse = cfg.reverseFill and true or false

    r.wrapper:SetSize(geo.d, geo.d)
    r.wrapper:SetAlpha(cfg.opacity or 1)
    r.keepTex:SetTexture(geo.tex)
    r.keepTex:SetVertexColor(s.bgR, s.bgG, s.bgB, s.bgA)
    r.keep:SetShown(s.keepTrack)

    local sig = IdSig(layer.include)
    if not r.container then
        r.unit, r.sig = layer.unit, sig
        r.container = AK.CreateContainer(r.wrapper, layer.unit, {
            point = { "CENTER", r.wrapper, "CENTER", 0, 0 },
            slots = { {
                key = "r",
                filter = AuraFilter(layer.unit),
                candidateFilters = { includeSpellIDs = layer.include },
                style = r.styleKey,
                extraInit = function(button, d) InitRing(r, button, d) end,
            } },
        })
        r.container:SetFrameLevel(r.wrapper:GetFrameLevel() + 2)
        return
    end
    if not r.active and r.container.SetAuraSlotEnabled then
        r.container:SetAuraSlotEnabled("r", true)
    end
    if r.unit ~= layer.unit then
        r.unit = layer.unit
        r.container:SetAuraSlotFilterString("r", AK.Filter(unpack(AuraFilter(layer.unit))))
        r.container:SetUnit(layer.unit)
    end
    if r.sig ~= sig then
        r.sig = sig
        r.container:SetAuraSlotCandidateFilters("r", { includeSpellIDs = layer.include })
    end
    AK.RestyleSoon(r.styleKey)
end

local function ParkRing(r)
    r.active = false
    r.wrapper:Hide()
    if r.container and r.container.SetAuraSlotEnabled then
        r.container:SetAuraSlotEnabled("r", false)
    end
end

--------------------------------------------------------------------------------
--  Text and icon columns
--
--  Per position and unit, up to two flow containers:
--    * geometry (Bottom / Left / Right): groups G_i laid end to end from the
--      inner edge, so its outer edge is the outermost visible ring's outer edge;
--    * rows: one row per ring holding that ring's icon and texts at this
--      position, stacked down. Bottom hangs the rows from the geometry's outer
--      edge; Left / Right hang them by their middle, so the stack stays
--      centred on 9 / 3 o'clock; Center hangs them from the centre.
--  The engine sizes both containers from what is shown, so the anchors follow
--  the auras with no Lua.
--------------------------------------------------------------------------------
local FLOW = AnchorUtil and AnchorUtil.FlowDirection

-- geo: the geometry container's anchor point, growth and axis.
-- rows: where the row container hangs (its own point on the geometry's point,
-- or on the centre), the flow anchor its rows are laid out from, and the edge
-- of the player rows that target rows at the same position hang from.
local COLUMN = {
    center = { rows = { point = "TOP",   on = "CENTER", anchor = "TOP",      under = "BOTTOM",      growH = "Right" } },
    bottom = { geo = { point = "TOP",   growH = "Right", growV = "Down", vertical = true },
               rows = { point = "TOP",   on = "BOTTOM", anchor = "TOP",      under = "BOTTOM",      growH = "Right" } },
    right  = { geo = { point = "LEFT",  growH = "Right", growV = "Down", vertical = false },
               rows = { point = "LEFT",  on = "RIGHT",  anchor = "TOPLEFT",  under = "BOTTOMLEFT",  growH = "Right" } },
    left   = { geo = { point = "RIGHT", growH = "Left",  growV = "Down", vertical = false },
               rows = { point = "RIGHT", on = "LEFT",   anchor = "TOPRIGHT", under = "BOTTOMRIGHT", growH = "Left" } },
}

-- Order of the items in a row, from the ring outward: fixed widths first, so the
-- numbers of stacked rows line up and the names, of any length, end the row.
local ROW_KINDS = { "icon", "timer", "stacks", "name" }
local ROW_CODE = { icon = "i", timer = "t", stacks = "s", name = "n" }
local ROW_GAP = 4

AK = EllesmereUI.AuraKit
if AK then AK.styles.tbrGeo = { noRegions = true, width = 1, height = 1 } end

-- AK applyExtra for a row. Each item sits at its offset along the row, measured
-- from the side next to the ring.
local function ApplyRow(button, d, style)
    local row = d.row
    if not row then return end -- the init pass runs once before InitRow builds the regions
    local s = style.row
    row.host:SetAlpha(s.alpha)
    for _, it in ipairs(s.items) do
        local region = row.regions[it.kind]
        if region then
            region:ClearAllPoints()
            region:SetPoint(s.point, row.host, s.point, it.x + it.ox, it.oy)
            if it.kind == "icon" then
                region:SetSize(it.size, it.size)
            else
                EllesmereUI.ApplyModuleFont(region, nil, it.size, "cdm")
                region:SetTextColor(it.r, it.g, it.b, it.a)
                if it.kind == "name" then
                    region:SetText(it.text)
                elseif it.kind == "timer" and row.fmtKey ~= it.fmtKey then
                    local opts = AK.BuildDurationTextOpts(it.fmt, nil, it.interval)
                    if AK.SetDurationTextSafe(button, region, opts) then
                        row.fmtKey = it.fmtKey
                    elseif AK.AurasRestricted() then
                        error("ring timer rebind denied") -- deferred to the restriction lift
                    end
                end
            end
        end
    end
end

-- initializeFrame for a row: one region per item, bound to the button by kind.
-- Fonts are set before the FontStrings are registered (the engine writes into
-- them at once).
local function InitRow(kinds, button, d, style)
    pcall(button.SetMouseClickEnabled, button, false)
    pcall(button.SetMouseMotionEnabled, button, false)
    local host = CreateFrame("Frame", nil, button)
    host:SetAllPoints(button)
    host:EnableMouse(false)
    local row = { host = host, regions = {} }
    local items = {}
    for _, it in ipairs(style.row.items) do items[it.kind] = it end
    for _, kind in ipairs(kinds) do
        local it = items[kind]
        if kind == "icon" then
            local tex = host:CreateTexture(nil, "ARTWORK")
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.regions.icon = tex
            button:SetIcon(tex)
        else
            local fs = host:CreateFontString(nil, "OVERLAY")
            EllesmereUI.ApplyModuleFont(fs, nil, it and it.size or 11, "cdm")
            row.regions[kind] = fs
            if kind == "stacks" then
                button:SetApplicationCount(fs, {})
            elseif kind == "timer" and it then
                AK.SetDurationTextSafe(button, fs, AK.BuildDurationTextOpts(it.fmt, nil, it.interval))
                row.fmtKey = it.fmtKey
            end
        end
    end
    d.row = row
    ApplyRow(button, d, style)
end

-- A pooled flow container whose groups are declared on demand.
local function NewBox(parent, unit, point, relTo, relPoint, layout, vertical)
    local box = { groups = {} }
    box.container = AK.CreateContainer(parent, unit, {
        point = { point, relTo, relPoint, 0, 0 },
        layout = layout,
    })
    AK.SetContainerAxis(box.container, vertical)
    return box
end

local function NewColumn(set, pos, unit)
    local spec = COLUMN[pos]
    local col = { pos = pos, unit = unit }
    col.anchor = CreateFrame("Frame", nil, set.host)
    col.anchor:SetSize(1, 1)
    col.anchor:SetPoint("CENTER", set.host, "CENTER", 0, 0)
    col.anchor:EnableMouse(false)
    local rowsOn, rowsRel = col.anchor, "CENTER"
    if spec.geo then
        local g = spec.geo
        col.geo = NewBox(col.anchor, unit, g.point, col.anchor, "CENTER",
            { anchorPoint = g.point, growthH = FLOW[g.growH], growthV = FLOW[g.growV] }, g.vertical)
        rowsOn, rowsRel = col.geo.container, spec.rows.on
    end
    local r = spec.rows
    col.rows = NewBox(col.anchor, unit, r.point, rowsOn, rowsRel,
        { anchorPoint = r.anchor, growthH = FLOW[r.growH], growthV = FLOW.Down }, true)
    col.rows.container:SetFrameLevel(set.host:GetFrameLevel() + 20)
    return col
end

-- Bring one container's groups in line with `want` (ordered list of
-- { key, include, w, h, row = style, kinds }); unwanted groups get cap 0. A key
-- always holds one kind of group ("g3", "itn2"), so a pooled group never changes
-- what it binds. Each record is stamped only after its call went through.
local function ApplyGroups(box, unit, want)
    local c = box.container
    local declaredNew = false
    local used = {}
    for n = 1, #want do
        local g = want[n]
        used[g.key] = true
        local layout = { elementWidth = g.w, elementHeight = g.h, layoutIndex = n }
        local layoutSig = g.w .. "x" .. g.h .. "@" .. n
        local filterSig = IdSig(g.include)
        local rec = box.groups[g.key]
        if not rec then
            rec = {}
            if g.row then
                serial = serial + 1
                rec.styleKey = "tbrRow" .. serial
                AK.styles[rec.styleKey] = { noRegions = true, applyExtra = ApplyRow }
            else
                rec.styleKey = "tbrGeo"
            end
            box.groups[g.key] = rec
        end
        if g.row then
            local st = AK.styles[rec.styleKey]
            st.width, st.height, st.row = g.w, g.h, g.row
        end
        if not rec.declared then
            local kinds, styleKey = g.kinds, rec.styleKey
            AK.AddGroupToContainer(c, {
                key = g.key, filter = AuraFilter(unit), maxFrameCount = 1,
                candidateFilters = { includeSpellIDs = g.include },
                style = styleKey, layout = layout,
                extraInit = g.row and function(button, d)
                    InitRow(kinds, button, d, AK.styles[styleKey])
                end or nil,
            })
            rec.declared, rec.on = true, true
            rec.filterSig, rec.layoutSig = filterSig, layoutSig
            declaredNew = true
        else
            if not rec.on then
                AK.SetGroupCap(c, g.key, 1)
                rec.on = true
            end
            if rec.filterSig ~= filterSig then
                c:SetAuraGroupCandidateFilters(g.key, { includeSpellIDs = g.include })
                rec.filterSig = filterSig
            end
            if rec.layoutSig ~= layoutSig then
                c:SetAuraGroupLayout(g.key, layout)
                rec.layoutSig = layoutSig
            end
            if g.row then AK.RestyleSoon(rec.styleKey) end
        end
    end
    for key, rec in pairs(box.groups) do
        if not used[key] and rec.on then
            AK.SetGroupCap(c, key, 0)
            rec.on = false
        end
    end
    if declaredNew then c:UpdateAllAuras() end
end

local function ParkColumn(col)
    if col.geo then ApplyGroups(col.geo, col.unit, {}) end
    ApplyGroups(col.rows, col.unit, {})
    col.active = false
    col.anchor:Hide()
end

-- One ring's row at a position: its items in row order with their offsets, and
-- the row's size. Left / Right rows start at the side next to the ring; Bottom
-- and Center rows are centred, each item on the middle of its slot, so a short
-- value ("3" in a "00" slot) sits on the ring's vertical axis.
local function RowStyle(layer, pos, kinds)
    local cfg = layer.cfg
    local s = { alpha = cfg.opacity or 1, items = {} }
    local centred = pos == "bottom" or pos == "center"
    s.point = centred and "CENTER" or (pos == "left") and "RIGHT" or "LEFT"
    local x, h = 0, 0
    for _, kind in ipairs(kinds) do
        local it = { kind = kind }
        local w
        if kind == "icon" then
            it.size = cfg.iconSize or 24
            it.ox, it.oy = cfg.iconX or 0, cfg.iconY or 0
            w, h = it.size, max(h, it.size)
        else
            it.size = cfg[kind .. "Size"] or 11
            it.ox, it.oy = cfg[kind .. "X"] or 0, cfg[kind .. "Y"] or 0
            it.r, it.g, it.b, it.a = TextColor(cfg, kind)
            local sample
            if kind == "name" then
                it.text = DisplayName(cfg)
                sample = it.text
            elseif kind == "timer" then
                local fmt = cfg.timerDecimals and ns.TBBDecimalFormatter
                    and ns.TBBDecimalFormatter(cfg.timerDecimalThreshold)
                it.fmt = fmt or AK.GetDurationFormatter(false)
                it.fmtKey = fmt and ("d" .. tostring(cfg.timerDecimalThreshold)) or "w"
                it.interval = fmt and 0.05 or nil
                sample = "00.0"
            else
                sample = "00"
            end
            w = floor(TextWidth(sample, it.size) + 0.5)
            h = max(h, it.size + 2)
        end
        if centred then
            it.x = x + w / 2
        else
            it.x = (pos == "left") and -x or x
        end
        x = x + w + ROW_GAP
        s.items[#s.items + 1] = it
    end
    local width = max(x - ROW_GAP, 1)
    if centred then
        for _, it in ipairs(s.items) do it.x = it.x - width / 2 end
    end
    return s, width, max(h, 1)
end

-- Every column of a set from its layers (innermost first). Rings hidden by their
-- Visibility settings drop out of the geometry and lose their rows.
local function ApplyColumns(set)
    local layers = set.layers
    local n = #layers

    -- Items per position and unit, a row per ring in ring order.
    local wantBy = {}
    for i = 1, n do
        local layer = layers[i]
        if layer.visible then
            local cfg = layer.cfg
            local at = { icon = IconPos(cfg), timer = TimerPos(cfg), stacks = StacksPos(cfg), name = NamePos(cfg) }
            local byPos = {}
            for _, kind in ipairs(ROW_KINDS) do
                local p = at[kind]
                if p then
                    local k = byPos[p]
                    if not k then
                        k = {}
                        byPos[p] = k
                    end
                    k[#k + 1] = kind
                end
            end
            for p, kinds in pairs(byPos) do
                local key = p .. ":" .. layer.unit
                local w = wantBy[key]
                if not w then
                    w = { pos = p, unit = layer.unit, rows = {} }
                    wantBy[key] = w
                end
                w.rows[#w.rows + 1] = { layer = i, kinds = kinds }
            end
        end
    end

    -- Player columns first: a target column at the same position hangs its rows
    -- under the player rows instead of laying out its own.
    local order = {}
    for key, w in pairs(wantBy) do
        if w.unit == "player" then table.insert(order, 1, key) else order[#order + 1] = key end
    end

    local seen = {}
    for _, key in ipairs(order) do
        local w = wantBy[key]
        seen[key] = true
        local col = set.cols[key]
        if not col then
            col = NewColumn(set, w.pos, w.unit)
            set.cols[key] = col
        end
        local lead = w.unit ~= "player" and set.cols[w.pos .. ":player"]
        if lead and not wantBy[w.pos .. ":player"] then lead = nil end

        -- Where outside texts start: the inner edge of the innermost ring, or past
        -- every ring this column cannot see (a kept track, a ring on the other
        -- unit): those count as always there, so no text ever covers them.
        local start = n > 0 and layers[1].geo.inner or 0
        local firstGeo = 1
        for i = 1, n do
            local l = layers[i]
            if l.visible and (l.keepTrack or l.unit ~= w.unit) then
                start = l.geo.outer
                firstGeo = i + 1
            end
        end

        -- Geometry: G_i shows while any ring from i outward is up, so the shown
        -- ones reach the outer edge of the outermost ring that is up.
        if col.geo then
            local horizontal = w.pos ~= "bottom"
            local geo, prevR = {}, start
            for i = firstGeo, lead and 0 or n do
                local include
                for j = i, n do
                    local l = layers[j]
                    if l.visible and l.unit == w.unit then
                        include = include or {}
                        for id in pairs(l.include) do include[id] = true end
                    end
                end
                if not include then break end
                local len = max(layers[i].geo.outer - prevR, 0.01)
                prevR = layers[i].geo.outer
                geo[#geo + 1] = { key = "g" .. i, include = include,
                    w = horizontal and len or 1, h = horizontal and 1 or len }
            end
            ApplyGroups(col.geo, w.unit, geo)
        end

        local rows, count, firstH = {}, {}, 0
        for _, r in ipairs(w.rows) do
            local code = ""
            for _, kind in ipairs(r.kinds) do code = code .. ROW_CODE[kind] end
            count[code] = (count[code] or 0) + 1
            local style, rw, rh = RowStyle(layers[r.layer], w.pos, r.kinds)
            if #rows == 0 then firstH = rh end
            rows[#rows + 1] = { key = code .. count[code], include = layers[r.layer].include,
                w = rw, h = rh, row = style, kinds = r.kinds }
        end
        ApplyGroups(col.rows, w.unit, rows)

        -- Column origin: the inner edge of the geometry (outside positions), or
        -- half the first row above the centre (Center). The rows keep a margin
        -- off the geometry's outer edge.
        local x, y, mx, my = 0, 0, 0, 0
        if w.pos == "bottom" then
            y, my = -start, -TEXT_MARGIN
        elseif w.pos == "right" then
            x, mx = start, TEXT_MARGIN
        elseif w.pos == "left" then
            x, mx = -start, -TEXT_MARGIN
        else
            y = firstH / 2
        end
        col.anchor:ClearAllPoints()
        col.anchor:SetPoint("CENTER", set.host, "CENTER", x, y)
        local spec = COLUMN[w.pos].rows
        local rc = col.rows.container
        rc:ClearAllPoints()
        if lead then
            -- Under the player rows, edge on edge (their container shrinks to the
            -- rows that are shown, so these follow).
            rc:SetPoint(spec.anchor, lead.rows.container, spec.under, 0, 0)
        else
            rc:SetPoint(spec.point, col.geo and col.geo.container or col.anchor, spec.on, mx, my)
        end
        col.active = true
        col.anchor:Show()
    end
    for key, col in pairs(set.cols) do
        if not seen[key] and col.active then ParkColumn(col) end
    end
end

--------------------------------------------------------------------------------
--  Visibility (the wrapper and the columns are outside the aura buttons)
--------------------------------------------------------------------------------

-- Visibility mode and options, each bar's own verdict. Unlock mode keeps every ring up.
local function LayerVisible(layer)
    if EllesmereUI._unlockActive then return true end
    return not ns.TBBVisibilityHides(layer.cfg)
end

local function RunColumns(set)
    local ok, err = pcall(ApplyColumns, set)
    if ok then
        set.colsPending = nil
        return
    end
    if AK.AurasRestricted() then
        set.colsPending = true -- container calls refused: redo at the restriction lift
    else
        geterrorhandler()(err)
    end
end

local function ApplyVisibility(set)
    local changed = false
    for i = 1, #set.layers do
        local layer = set.layers[i]
        local vis = LayerVisible(layer)
        if layer.visible ~= vis then
            layer.visible = vis
            changed = true
        end
        layer.ring.wrapper:SetShown(vis)
    end
    return changed
end

-- Driven by the CDM visibility pass (combat, group, mount, target, zone edges).
function ns.TBBRings_ApplyVisibility()
    for _, set in pairs(sets) do
        if set.layers and #set.layers > 0 and ApplyVisibility(set) then
            RunColumns(set)
        end
    end
end

local function OnRestrictionLift()
    for _, set in pairs(sets) do
        if set.colsPending then RunColumns(set) end
    end
end

--------------------------------------------------------------------------------
--  Host, mover, watcher
--------------------------------------------------------------------------------

-- Saved centre, unless an unlock anchor link owns the frame (or the unlock
-- session is dragging it).
local function PlaceHost(set)
    if EllesmereUI._unlockActive then return end
    local host = set.host
    local anchored = EllesmereUI.IsUnlockAnchored and EllesmereUI.IsUnlockAnchored(set.key)
    if anchored and host:GetLeft() then return end
    local store = ns.TBBGroupRingStore(set.gid)
    local pos = store and store.ringPos
    host:ClearAllPoints()
    if pos and pos.point then
        host:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
    else
        host:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

-- One mover per ring group, re-registered every sync so its label follows the group
-- name. Never unregistered (that would prune its saved anchor links); isHidden
-- covers specs where the group has no rings.
local function RegisterMover(set)
    if not EllesmereUI.RegisterUnlockElements then return end
    local name = ns.TBBGroupName(set.gid) or (EllesmereUI.L("Group") .. " " .. set.gid)
    EllesmereUI:RegisterUnlockElements({ EllesmereUI.MakeUnlockElement({
        key   = set.key,
        label = EllesmereUI.Lf("Tracking Rings: %s", name),
        group = "Cooldown Manager",
        order = 652,
        noResize = true,
        noSizeMatchTarget = true,
        isHidden = function() return not (set.layers and #set.layers > 0) end,
        isAnchored = function() return false end,
        getFrame = function() return (set.layers and #set.layers > 0) and set.host or nil end,
        getSize = function() return set.size, set.size end,
        savePos = function(_, point, relPoint, x, y)
            local store = ns.TBBGroupRingStore(set.gid, true)
            if store then store.ringPos = { point = point, relPoint = relPoint, x = x, y = y } end
            PlaceHost(set)
        end,
        loadPos = function()
            local store = ns.TBBGroupRingStore(set.gid)
            return store and store.ringPos
        end,
        clearPos = function()
            local store = ns.TBBGroupRingStore(set.gid)
            if store then store.ringPos = nil end
        end,
        applyPos = function() PlaceHost(set) end,
    }) }, "EllesmereUICooldownManager")
end

local function NewSet(key)
    local host = CreateFrame("Frame", nil, UIParent)
    host:SetSize(1, 1)
    host:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    host:SetFrameStrata("MEDIUM")
    host:SetFrameLevel(100)
    host:EnableMouse(false)
    local set = { key = key, host = host, size = 1, rings = {}, cols = {}, layers = {} }
    sets[key] = set
    return set
end

local function OnTarget(info)
    if not info then return false end
    local selfAura, hasAura = info.selfAura, info.hasAura
    if issecretvalue and (issecretvalue(selfAura) or issecretvalue(hasAura)) then return false end
    return hasAura == true and selfAura == false
end

-- A cinematic briefly drops the player's assistability, which voids the spell-ID
-- filter engine-side; target containers also need a reparse on every target swap.
local function OnWatcherEvent(_, event)
    for _, set in pairs(sets) do
        for _, r in pairs(set.rings) do
            if r.active and (event ~= "PLAYER_TARGET_CHANGED" or r.unit == "target") then
                r.container:UpdateAllAuras()
            end
        end
        for _, col in pairs(set.cols) do
            if col.active and (event ~= "PLAYER_TARGET_CHANGED" or col.unit == "target") then
                if col.geo then col.geo.container:UpdateAllAuras() end
                col.rows.container:UpdateAllAuras()
            end
        end
    end
end

local function UpdateWatcher(anyRing, anyTarget)
    if not anyRing then
        if watcher then watcher:UnregisterAllEvents() end
        return
    end
    if not watcher then
        watcher = ns.TakeShell()
        watcher:SetScript("OnEvent", OnWatcherEvent)
    end
    watcher:RegisterUnitEvent("UNIT_FACTION", "player", "target")
    if anyTarget then
        watcher:RegisterEvent("PLAYER_TARGET_CHANGED")
    else
        watcher:UnregisterEvent("PLAYER_TARGET_CHANGED")
    end
end

--------------------------------------------------------------------------------
--  Sync
--------------------------------------------------------------------------------

-- Lay one group's rings out from its ring layout. Geometry runs innermost first;
-- Ring Order picks which bar takes each layer. Returns true when a ring is on the target.
local function LayoutSet(set, list)
    local store = ns.TBBGroupRingStore(set.gid)
    local size = LayoutValue(store, "ringSize")
    local width = LayoutValue(store, "ringWidth")
    local gap = LayoutValue(store, "ringGap")
    local outerFirst = LayoutValue(store, "ringOrder") == "outer"
    local anyTarget = false
    local layers = {}
    local prevOuter
    for step = 1, #list do
        local x = list[outerFirst and (#list - step + 1) or step]
        local mid = prevOuter and (prevOuter + gap + width / 2) or (size / 2 - width / 2)
        local geo = PickRing(max(mid, 1), width)
        prevOuter = geo.outer
        local r = set.rings[step]
        if not r then
            r = NewRing(set)
            set.rings[step] = r
        end
        local layer = { cfg = x.w.cfg, include = x.w.include, unit = x.unit, geo = geo, ring = r,
            keepTrack = x.w.cfg.hideWhenInactive == false }
        layer.visible = LayerVisible(layer)
        FillRing(r, layer)
        r.active = true
        r.wrapper:SetShown(layer.visible)
        layers[step] = layer
        if x.unit == "target" then anyTarget = true end
    end
    for step = #list + 1, #set.rings do
        if set.rings[step].active then ParkRing(set.rings[step]) end
    end
    set.layers = layers
    set.size = prevOuter and prevOuter * 2 or 1
    set.host:SetSize(set.size, set.size)
    local first = layers[1] and layers[1].cfg
    set.host:SetFrameStrata(first and first.strata or "MEDIUM")
    return anyTarget
end

local function ParkSet(set)
    for _, r in ipairs(set.rings) do
        if r.active then ParkRing(r) end
    end
    for _, col in pairs(set.cols) do
        if col.active then ParkColumn(col) end
    end
    set.layers = {}
    set.host:Hide()
end

local function SyncAfterCombat()
    if pendingRegen then
        pendingRegen = nil
        ns.TBBRings_Sync()
    end
end

function ns.TBBRings_Sync()
    AK = AK or (EllesmereUI and EllesmereUI.AuraKit)
    if not AK then return end
    local p = ns.ECME and ns.ECME.db and ns.ECME.db.profile
    local work = not (p and p.cdmBars and p.cdmBars.useBlizzardBuffBars)
        and ns.TBBCollectAuraSlots(ns.TBBIsRing) or nil
    if not work and not next(sets) then return end

    -- Container setters are not proven legal under aura secrecy: re-point at regen.
    if InCombatLockdown() then
        pendingRegen = true
        ns.CombatQueue.Defer("TBBRingsSync", SyncAfterCombat)
        return
    end
    pendingRegen = nil
    if not liftHooked then
        liftHooked = true
        AK.OnRestrictionLift(OnRestrictionLift)
    end

    -- Wanted rings per group, in bar order.
    local want = {}
    for n = 1, #(work or {}) do
        local w = work[n]
        local gid = ns.TBBBarGroupID(w.cfg)
        local key = MoverKey(gid)
        local ws = want[key]
        if not ws then
            ws = { gid = gid, list = {} }
            want[key] = ws
        end
        ws.list[#ws.list + 1] = { unit = OnTarget(w.info) and "target" or "player", w = w }
    end

    for key, set in pairs(sets) do
        if not want[key] and set.layers and #set.layers > 0 then ParkSet(set) end
    end

    local anyRing, anyTarget = false, false
    for key, ws in pairs(want) do
        local set = sets[key] or NewSet(key)
        set.gid = ws.gid
        set.host:Show()
        if LayoutSet(set, ws.list) then anyTarget = true end
        RunColumns(set)
        PlaceHost(set)
        RegisterMover(set)
        anyRing = true
    end
    UpdateWatcher(anyRing, anyTarget)
end
