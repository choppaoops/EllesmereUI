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
