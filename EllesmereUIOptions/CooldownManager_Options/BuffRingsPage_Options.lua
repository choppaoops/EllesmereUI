if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-------------------------------------------------------------------------------
--  CooldownManager_Options\BuffRingsPage_Options.lua
--  Tracking Bars page, ring groups: the RING LAYOUT section of a group
--  displayed as rings (BuffBarsPage_Options.lua calls in from Edit Group). The
--  layout is group layout: a global group shares it across specs.
-------------------------------------------------------------------------------
local ns = EllesmereUI._ModuleNS["EllesmereUICooldownManager"]
if not ns then return end  -- module disabled: no options page

-- Returns the y below the last row.
function ns.CDMO_BuildTBRRingLayout(W, parent, y, gid, RefreshTBB)
    local hdr, h
    local function Value(key)
        local store = ns.TBBGroupRingStore(gid)
        local v = store and store[key]
        if v == nil then v = ns.TBR_RING_DEFAULTS[key] end
        return v
    end
    local function SetValue(key, v)
        local store = ns.TBBGroupRingStore(gid, true)
        if not store then return end
        store[key] = v
        RefreshTBB()
    end

    -------------------------------------------------------------------
    --  RING LAYOUT
    -------------------------------------------------------------------
    hdr, h = W:SectionHeader(parent, "RING LAYOUT", y);  y = y - h
    -- The ring group's own mover: it moves the centre.
    EllesmereUI.BuildSectionUnlockJump(hdr, { key = function()
        return ns.TBRMoverKey and ns.TBRMoverKey(gid) or nil
    end })

    -- Ring Order | Inner Size
    _, h = W:DualRow(parent, y,
        { type = "dropdown", text = "Ring Order",
          tooltip = "Which end of this group's bar list is the innermost ring.",
          values = { inner = "First Bar Innermost", outer = "First Bar Outermost" },
          order = { "inner", "outer" },
          getValue = function() return Value("ringOrder") end,
          setValue = function(v) SetValue("ringOrder", v) end },
        { type = "slider", text = "Inner Size",
          tooltip = "Outer diameter of the innermost ring.",
          min = 40, max = 400, step = 1,
          getValue = function() return Value("ringSize") end,
          setValue = function(v) SetValue("ringSize", v) end }
    );  y = y - h

    -- Ring Width | Ring Spacing
    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Ring Width",
          tooltip = "Thickness of every ring in this group.",
          min = 2, max = 40, step = 1,
          getValue = function() return Value("ringWidth") end,
          setValue = function(v) SetValue("ringWidth", v) end },
        { type = "slider", text = "Ring Spacing",
          tooltip = "Gap between neighbouring rings.",
          min = 0, max = 30, step = 1,
          getValue = function() return Value("ringGap") end,
          setValue = function(v) SetValue("ringGap", v) end }
    );  y = y - h

    return y
end

-------------------------------------------------------------------------------
--  Popout preview: the group's rings and texts as the live display lays them
--  out (ns.TBRPreviewModel), every ring up, with sample values. Static frames
--  of our own: no aura containers.
-------------------------------------------------------------------------------
local SAMPLE_FILL = { 0.75, 0.45, 0.6, 0.3, 0.85, 0.55 }
local pv -- { holder, rings = {}, rows = {} }

local function PreviewText(it)
    if it.kind == "name" then return it.text end
    if it.kind == "timer" then return it.interval and "3.2" or "12" end
    if it.kind == "count" then return "89" end
    return "3"
end

local function SpellIcon(cfg)
    local info = cfg.spellID and cfg.spellID > 0 and C_Spell.GetSpellInfo(cfg.spellID)
    return info and info.iconID or 134400
end

function ns.CDMO_HideTBRPreview()
    if pv then pv.holder:Hide() end
end

-- Draws the preview into `parent`, centred on the returned holder. `selected`
-- (optional) is the bar being edited: the other rings dim. `onSelect(cfg)` runs
-- when a row is clicked. Returns the holder and its extents from the centre
-- (left, right, top, bottom, all positive).
function ns.CDMO_DrawTBRPreview(parent, gid, cfgs, selected, onSelect)
    if not pv then
        pv = { rings = {}, rows = {} }
        pv.holder = CreateFrame("Frame", nil, parent)
        pv.holder:SetSize(1, 1)
    end
    local holder = pv.holder
    holder:SetParent(parent)
    holder:SetFrameStrata(parent:GetFrameStrata())
    holder:SetFrameLevel(parent:GetFrameLevel() + 20)
    holder:Show()

    local layers, cols = ns.TBRPreviewModel(gid, cfgs)
    local outer = #layers > 0 and layers[#layers].geo.outer or 0
    local ext = { l = outer, r = outer, t = outer, b = outer }

    for i, layer in ipairs(layers) do
        local r = pv.rings[i]
        if not r then
            r = CreateFrame("Frame", nil, holder)
            r.track = r:CreateTexture(nil, "BACKGROUND")
            r.track:SetAllPoints()
            r.cd = CreateFrame("Cooldown", nil, r, "CooldownFrameTemplate")
            r.cd:SetAllPoints()
            r.cd:SetDrawEdge(false)
            r.cd:SetDrawBling(false)
            r.cd:SetHideCountdownNumbers(true)
            pv.rings[i] = r
        end
        local cfg, geo = layer.cfg, layer.geo
        r:ClearAllPoints()
        r:SetPoint("CENTER", holder, "CENTER", 0, 0)
        r:SetSize(geo.d, geo.d)
        r:SetFrameLevel(holder:GetFrameLevel() + 1)
        r.track:SetTexture(geo.tex)
        r.track:SetVertexColor(cfg.bgR or 0, cfg.bgG or 0, cfg.bgB or 0, cfg.bgA or 0.4)
        r.cd:SetSwipeTexture(geo.tex)
        r.cd:SetSwipeColor(cfg.fillR or 1, cfg.fillG or 1, cfg.fillB or 1, cfg.fillA or 1)
        r.cd:SetReverse(cfg.reverseFill and true or false)
        local frac = SAMPLE_FILL[(i - 1) % #SAMPLE_FILL + 1]
        r.cd:SetCooldown(GetTime() - frac * 60, 60)
        r.cd:SetPaused(true)
        -- Texts set On Ring, on the band at their clock positions.
        r.fs = r.fs or {}
        for _, fs in pairs(r.fs) do fs:Hide() end
        local texts = ns.TBRRingTextStyles and ns.TBRRingTextStyles(cfg)
        if texts then
            if not r.textHost then
                r.textHost = CreateFrame("Frame", nil, r)
                r.textHost:SetAllPoints()
            end
            r.textHost:SetFrameLevel(r.cd:GetFrameLevel() + 2)
            local mid = geo.outer - geo.width / 2
            for kind, t in pairs(texts) do
                local fs = r.fs[kind]
                if not fs then
                    fs = r.textHost:CreateFontString(nil, "OVERLAY")
                    r.fs[kind] = fs
                end
                EllesmereUI.ApplyModuleFont(fs, nil, t.size, "cdm")
                fs:SetTextColor(t.r, t.g, t.b, t.a)
                local x, yy = ns.TBRClockOffset(t.clock, mid)
                fs:ClearAllPoints()
                fs:SetPoint("CENTER", r.textHost, "CENTER", x + t.ox, yy + t.oy)
                fs:SetText(PreviewText({ kind = kind, text = t.text, interval = t.interval }))
                fs:Show()
            end
        end
        r:SetAlpha((selected and selected ~= cfg) and 0.35 or (cfg.opacity or 1))
        r:Show()
    end
    for i = #layers + 1, #pv.rings do pv.rings[i]:Hide() end

    local used = 0
    for pos, col in pairs(cols) do
        local total = 0
        for _, row in ipairs(col.rows) do total = total + row.h end
        local top
        if pos == "left" or pos == "right" then
            top = col.y + total / 2
        elseif pos == "center" then
            top = col.rows[1] and col.rows[1].h / 2 or 0
        else
            top = col.y
        end
        for _, row in ipairs(col.rows) do
            used = used + 1
            local f = pv.rows[used]
            if not f then
                f = CreateFrame("Button", nil, holder)
                f.icon = f:CreateTexture(nil, "ARTWORK")
                f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                f.fs = {}
                pv.rows[used] = f
            end
            local cfg = layers[row.layer].cfg
            f:ClearAllPoints()
            f:SetSize(row.w, row.h)
            f:SetFrameLevel(holder:GetFrameLevel() + 5)
            if pos == "right" then
                f:SetPoint("TOPLEFT", holder, "CENTER", col.x, top)
                ext.r = math.max(ext.r, col.x + row.w)
            elseif pos == "left" then
                f:SetPoint("TOPRIGHT", holder, "CENTER", col.x, top)
                ext.l = math.max(ext.l, -col.x + row.w)
            else
                f:SetPoint("TOP", holder, "CENTER", 0, top)
                ext.l = math.max(ext.l, row.w / 2)
                ext.r = math.max(ext.r, row.w / 2)
            end
            ext.t = math.max(ext.t, top)
            ext.b = math.max(ext.b, row.h - top)
            top = top - row.h
            f.icon:Hide()
            for _, fs in pairs(f.fs) do fs:Hide() end
            local s = row.style
            for _, it in ipairs(s.items) do
                if it.kind == "icon" then
                    f.icon:ClearAllPoints()
                    f.icon:SetPoint(s.point, f, s.point, it.x + it.ox, it.oy)
                    f.icon:SetSize(it.size, it.size)
                    f.icon:SetTexture(SpellIcon(cfg))
                    f.icon:Show()
                else
                    local fs = f.fs[it.kind]
                    if not fs then
                        fs = f:CreateFontString(nil, "OVERLAY")
                        f.fs[it.kind] = fs
                    end
                    EllesmereUI.ApplyModuleFont(fs, nil, it.size, "cdm")
                    fs:SetTextColor(it.r, it.g, it.b, it.a)
                    fs:ClearAllPoints()
                    fs:SetPoint(s.point, f, s.point, it.x + it.ox, it.oy)
                    fs:SetText(PreviewText(it))
                    fs:Show()
                end
            end
            f:SetAlpha((selected and selected ~= cfg) and 0.35 or s.alpha)
            f:SetScript("OnMouseDown", onSelect and function() onSelect(cfg) end or nil)
            f:Show()
        end
    end
    for i = used + 1, #pv.rows do pv.rows[i]:Hide() end

    return holder, ext.l, ext.r, ext.t, ext.b
end
