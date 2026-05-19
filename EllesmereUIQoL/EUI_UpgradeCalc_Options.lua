-------------------------------------------------------------------------------
--  EUI_UpgradeCalc_Options.lua
--  Options page for the Upgrade Calculator feature (part of EllesmereUIQoL).
-------------------------------------------------------------------------------

local function GetAddonDB()
    -- Always delegate to the main module so we read from the same profile
    -- slice that persists via EllesmereUIDB (not the wiped EllesmereUIQoLDB).
    if EUIUpgCalc and EUIUpgCalc.GetOptsDB then
        return EUIUpgCalc.GetOptsDB()
    end
    EllesmereUIQoLDB                         = EllesmereUIQoLDB or {}
    EllesmereUIQoLDB.upgradeCalcOpts         = EllesmereUIQoLDB.upgradeCalcOpts or {}
    return EllesmereUIQoLDB.upgradeCalcOpts
end

local function BuildUpgradeCalcPage(pageName, parent, yOffset)
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h

    parent._showRowDivider = true
    _, h = W:Spacer(parent, y, 20); y = y - h

    ---------------------------------------------------------------------------
    --  DISPLAY
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "DISPLAY", y); y = y - h

    _, h = W:Toggle(parent,
        "Open on Login",
        y,
        function() return GetAddonDB().openOnLogin or false end,
        function(v) GetAddonDB().openOnLogin = v end,
        "Automatically opens the Upgrade Calculator window when you log in."
    ); y = y - h

    ---------------------------------------------------------------------------
    --  ACTIONS
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "ACTIONS", y); y = y - h

    local openBtnFrame
    openBtnFrame, h = W:WideButton(parent, "Open Calculator", y, function()
        local frame = _G["EUIUpgCalcFrame"]
        if frame then
            if frame:IsShown() then frame:Hide() else frame:Show() end
        end
    end)
    local innerBtn = select(1, openBtnFrame:GetChildren())
    if innerBtn then
        innerBtn:HookScript("OnEnter", function(self)
            if EllesmereUI.ShowWidgetTooltip then
                EllesmereUI.ShowWidgetTooltip(self, "Slash command: |cffffffff/euic|r")
            end
        end)
        innerBtn:HookScript("OnLeave", function()
            if EllesmereUI.HideWidgetTooltip then EllesmereUI.HideWidgetTooltip() end
        end)
    end
    y = y - h

    _, h = W:WideButton(parent, "Clear Upgrade Cache", y, function()
        if EUIUpgCalc and EUIUpgCalc.ClearCache then
            EUIUpgCalc:ClearCache()
        end
    end); y = y - h

    ---------------------------------------------------------------------------
    --  FILTERS
    ---------------------------------------------------------------------------
    local PP = EllesmereUI.PanelPP

    local function LiveRefresh()
        local fr = _G["EUIUpgCalcFrame"]
        if fr and fr:IsShown() and EUIUpgCalc and EUIUpgCalc.PopulateGear then
            EUIUpgCalc.PopulateGear()
        end
    end

    local SLOT_GROUP_ITEMS = {
        { key = "Armour",    label = "Armour"    },
        { key = "Jewellery", label = "Jewellery" },
        { key = "Trinkets",  label = "Trinkets"  },
        { key = "Weapons",   label = "Weapons"   },
    }

    local CREST_TRACK_ITEMS = {
        { key = "Adventurer", label = "Adventurer" },
        { key = "Veteran",    label = "Veteran"    },
        { key = "Champion",   label = "Champion"   },
        { key = "Hero",       label = "Hero"       },
        { key = "Myth",       label = "Myth"       },
    }

    _, h = W:SectionHeader(parent, "FILTERS", y); y = y - h

    -- Row 1: "Show Fully-Upgraded Items" toggle  |  "Slot Groups" checkbox dropdown
    local slotRow, slotRowH = W:DualRow(parent, y,
        { type = "toggle", text = "Show Fully-Upgraded Items",
          tooltip = "Show gear tiles for items already at their maximum item level.",
          getValue = function() return GetAddonDB().showMaxed or false end,
          setValue = function(v) GetAddonDB().showMaxed = v; LiveRefresh() end },
        { type = "dropdown", text = "Slot Groups",
          values = { __placeholder = "..." }, order = { "__placeholder" },
          getValue = function() return "__placeholder" end,
          setValue = function() end }
    )
    do
        local rightRgn = slotRow._rightRegion
        if rightRgn._control then rightRgn._control:Hide() end
        local cbDD, cbDDRefresh = EllesmereUI.BuildVisOptsCBDropdown(
            rightRgn, 210, rightRgn:GetFrameLevel() + 2,
            SLOT_GROUP_ITEMS,
            function(k)
                local sf = GetAddonDB().slotFilter
                return sf == nil or sf[k] ~= false
            end,
            function(k, v)
                local db = GetAddonDB()
                db.slotFilter = db.slotFilter or {}
                db.slotFilter[k] = v
                LiveRefresh()
            end
        )
        PP.Point(cbDD, "RIGHT", rightRgn, "RIGHT", -20, 0)
        rightRgn._control = cbDD
        rightRgn._lastInline = nil
        EllesmereUI.RegisterWidgetRefresh(cbDDRefresh)
    end
    y = y - slotRowH

    -- Row 2: "Hide Crafted Items" toggle  |  "Crest Rows" checkbox dropdown
    local crestRow, crestRowH = W:DualRow(parent, y,
        { type = "toggle", text = "Hide Crafted Items",
          tooltip = "Hide crafted items from the gear tile list.\nCrafted items cannot be upgraded at the Upgrade NPC.",
          getValue = function() return GetAddonDB().hideCrafted or false end,
          setValue = function(v) GetAddonDB().hideCrafted = v; LiveRefresh() end },
        { type = "dropdown", text = "Crest Rows",
          values = { __placeholder = "..." }, order = { "__placeholder" },
          getValue = function() return "__placeholder" end,
          setValue = function() end }
    )
    do
        local rightRgn = crestRow._rightRegion
        if rightRgn._control then rightRgn._control:Hide() end
        local cbDD, cbDDRefresh = EllesmereUI.BuildVisOptsCBDropdown(
            rightRgn, 210, rightRgn:GetFrameLevel() + 2,
            CREST_TRACK_ITEMS,
            function(k)
                local cf = GetAddonDB().crestFilter
                return cf == nil or cf[k] ~= false
            end,
            function(k, v)
                local db = GetAddonDB()
                db.crestFilter = db.crestFilter or {}
                db.crestFilter[k] = v
                LiveRefresh()
            end
        )
        PP.Point(cbDD, "RIGHT", rightRgn, "RIGHT", -20, 0)
        rightRgn._control = cbDD
        rightRgn._lastInline = nil
        EllesmereUI.RegisterWidgetRefresh(cbDDRefresh)
    end
    y = y - crestRowH

    _, h = W:Toggle(parent,
        "Show Earned / Cap Column",
        y,
        function() return GetAddonDB().showEarnedCap or false end,
        function(v) GetAddonDB().showEarnedCap = v; LiveRefresh() end,
        "Show the seasonal Earned / Cap column in the crest table."
    ); y = y - h

    _, h = W:Toggle(parent,
        "Show Still Available Column",
        y,
        function() return GetAddonDB().showWeeklyRemaining or false end,
        function(v) GetAddonDB().showWeeklyRemaining = v; LiveRefresh() end,
        "Show how many crests you can still earn before hitting the season cap (cap minus earned so far)."
    ); y = y - h

    ---------------------------------------------------------------------------
    --  APPEARANCE
    ---------------------------------------------------------------------------
    _, h = W:SectionHeader(parent, "APPEARANCE", y); y = y - h

    _, h = W:Slider(parent,
        "UI Scale",
        y,
        50, 150, 5,
        function() return GetAddonDB().uiScale or 100 end,
        function(v)
            GetAddonDB().uiScale = v
            if EUIUpgCalc and EUIUpgCalc.ApplyScale then
                EUIUpgCalc.ApplyScale()
            end
        end,
        "Scales the entire Upgrade Calculator window up or down."
    ); y = y - h

    _, h = W:Slider(parent,
        "Background Opacity",
        y,
        10, 100, 5,
        function() return GetAddonDB().bgOpacity or 96 end,
        function(v)
            GetAddonDB().bgOpacity = v
            if EUIUpgCalc and EUIUpgCalc.ApplyBgOpacity then
                EUIUpgCalc.ApplyBgOpacity()
            end
        end,
        "Controls how transparent the calculator window background is."
    ); y = y - h

    _, h = W:Spacer(parent, y, 20); y = y - h

    parent:SetHeight(math.abs(y - yOffset))

    return math.abs(y)
end

-- Open-on-login hook
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_LOGIN")
    if GetAddonDB().openOnLogin then
        C_Timer.After(1, function()
            local fr = _G["EUIUpgCalcFrame"]
            if fr then fr:Show() end
        end)
    end
end)

-- Expose page builder for EUI_QoL_Options.lua
_G._EUI_BuildUpgradeCalcPage = BuildUpgradeCalcPage

-- Expose reset helper for QoL onReset
_G._EUI_ResetUpgradeCalc = function()
    if EUIUpgCalc and EUIUpgCalc.GetOptsDB then
        local opts = EUIUpgCalc.GetOptsDB()
        for k in pairs(opts) do opts[k] = nil end
    elseif EllesmereUIQoLDB then
        EllesmereUIQoLDB.upgradeCalcOpts = {}
    end
    if EUIUpgCalc and EUIUpgCalc.ClearCache then
        EUIUpgCalc:ClearCache()
    end
    -- Also wipe the persisted queue and crest manual-add offsets.
    if EUIUpgCalc and EUIUpgCalc.GetOptsDB then
        local db = EUIUpgCalc.GetCalcDB and EUIUpgCalc.GetCalcDB()
        if db then db.queue = {}; db.crestManualAdds = {} end
    end
end
