local _, ns = ...

-------------------------------------------------------------------------------
--  Tracking Bars: Circle (ring) progress region
--
--  An alternative to the horizontal StatusBar fill -- the remaining duration
--  sweeps around a thin ring instead of along a bar. The ring is drawn with the
--  four-quadrant progressive-reveal technique (each 90 degree quadrant is one
--  textured quad whose two free vertices are pushed to the progress edge via
--  SetVertexOffset, and whose texcoords are recomputed to match). The geometry
--  is adapted from Liquid's TimelineReminders CircleRegion, which is the same
--  method WeakAuras' circular progress uses.
--
--  Body texture: EllesmereUI's circle border art is already a ring (annulus),
--  so no inner mask is needed -- the wedge reveal clips that ring to the arc up
--  to the current angle. Ring thickness is defined by the texture and scales
--  with the circle size.
--
--  Depletes clockwise from the top (12 o'clock): progress 1 = full ring,
--  0 = empty, matching the bar's "value = remaining" fill.
-------------------------------------------------------------------------------

local RING_TEXTURE = "Interface\\AddOns\\EllesmereUI\\media\\portraits\\circle_border.tga"

local UL, UR, LL, LR = UPPER_LEFT_VERTEX, UPPER_RIGHT_VERTEX, LOWER_LEFT_VERTEX, LOWER_RIGHT_VERTEX
local Clamp = Clamp or function(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end
local rad, cos, sin, floor = math.rad, math.cos, math.sin, math.floor

local function WithinRangeExclusive(v, lo, hi) return v > lo and v < hi end

-- Mirror a quadrant texture horizontally about its own width (used by the two
-- quadrants whose texcoord winding needs flipping so the arc joins cleanly).
local function HorizontallyMirror(texture)
    local width = texture:GetWidth()
    local ULx, ULy = texture:GetVertexOffset(UL)
    local URx, URy = texture:GetVertexOffset(UR)
    local LLx, LLy = texture:GetVertexOffset(LL)
    local LRx, LRy = texture:GetVertexOffset(LR)
    texture:SetVertexOffset(UL,  width - ULx, ULy)
    texture:SetVertexOffset(UR, -width - URx, URy)
    texture:SetVertexOffset(LL,  width - LLx, LLy)
    texture:SetVertexOffset(LR, -width - LRx, LRy)
end

-- Create a circle-progress region as a child of `parent` (a TBB wrap frame).
-- Returns a plain frame with the methods used by the buff-bar renderer:
-- SetCircleSize / SetColor / SetBackgroundShown / SetProgress / Show / Hide.
function ns.CreateTBBCircle(parent)
    local region = CreateFrame("Frame", nil, parent)
    region:Hide()
    region.size = 50

    region.backgroundTextures = {}
    region.foregroundTextures = {}

    for i = 1, 4 do
        local bgt = region:CreateTexture(nil, "BACKGROUND")
        bgt:SetTexture(RING_TEXTURE)
        bgt:SetVertexColor(0, 0, 0, 0.5)
        bgt:SetSnapToPixelGrid(false)
        bgt:SetTexelSnappingBias(0)
        region.backgroundTextures[i] = bgt

        local fgt = region:CreateTexture(nil, "BORDER")
        fgt:SetTexture(RING_TEXTURE)
        fgt:SetSnapToPixelGrid(false)
        fgt:SetTexelSnappingBias(0)
        region.foregroundTextures[i] = fgt
    end

    -- Static quadrant anchors + base texcoords (each quad covers one 90 degree
    -- corner of the texture; CENTER is the shared inner corner).
    -- Upper right (0-90 degrees)
    region.backgroundTextures[1]:SetPoint("BOTTOMLEFT", region, "CENTER")
    region.backgroundTextures[1]:SetPoint("TOPRIGHT", region, "TOPRIGHT")
    region.backgroundTextures[1]:SetTexCoord(0.5, 0, 0.5, 0.5, 1, 0, 1, 0.5)
    region.foregroundTextures[1]:SetPoint("BOTTOMLEFT", region, "CENTER")
    region.foregroundTextures[1]:SetPoint("TOPRIGHT", region, "TOPRIGHT")
    -- Lower right (90-180 degrees)
    region.backgroundTextures[2]:SetPoint("TOPLEFT", region, "CENTER")
    region.backgroundTextures[2]:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT")
    region.backgroundTextures[2]:SetTexCoord(0.5, 0.5, 0.5, 1, 1, 0.5, 1, 1)
    region.foregroundTextures[2]:SetPoint("TOPLEFT", region, "CENTER")
    region.foregroundTextures[2]:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT")
    -- Lower left (180-270 degrees)
    region.backgroundTextures[3]:SetPoint("TOPRIGHT", region, "CENTER")
    region.backgroundTextures[3]:SetPoint("BOTTOMLEFT", region, "BOTTOMLEFT")
    region.backgroundTextures[3]:SetTexCoord(0, 0.5, 0, 1, 0.5, 0.5, 0.5, 1)
    region.foregroundTextures[3]:SetPoint("TOPRIGHT", region, "CENTER")
    region.foregroundTextures[3]:SetPoint("BOTTOMLEFT", region, "BOTTOMLEFT")
    -- Upper left (270-360 degrees)
    region.backgroundTextures[4]:SetPoint("BOTTOMRIGHT", region, "CENTER")
    region.backgroundTextures[4]:SetPoint("TOPLEFT", region, "TOPLEFT")
    region.backgroundTextures[4]:SetTexCoord(0, 0, 0, 0.5, 0.5, 0, 0.5, 0.5)
    region.foregroundTextures[4]:SetPoint("BOTTOMRIGHT", region, "CENTER")
    region.foregroundTextures[4]:SetPoint("TOPLEFT", region, "TOPLEFT")

    -- Reset every foreground quad to its full (un-clipped) quadrant.
    function region:SetFull()
        region.foregroundTextures[1]:ClearVertexOffsets()
        region.foregroundTextures[1]:SetTexCoord(0.5, 0, 0.5, 0.5, 1, 0, 1, 0.5)
        region.foregroundTextures[2]:ClearVertexOffsets()
        region.foregroundTextures[2]:SetTexCoord(0.5, 0.5, 0.5, 1, 1, 0.5, 1, 1)
        region.foregroundTextures[3]:ClearVertexOffsets()
        region.foregroundTextures[3]:SetTexCoord(0, 0.5, 0, 1, 0.5, 0.5, 0.5, 1)
        region.foregroundTextures[4]:ClearVertexOffsets()
        region.foregroundTextures[4]:SetTexCoord(0, 0, 0, 0.5, 0.5, 0, 0.5, 0.5)
    end

    -- Draw the ring filled from the top clockwise up to `degrees` (0..360).
    local function SetDegrees(degrees)
        degrees = Clamp(degrees, 0, 360)
        local radius = 0.5 * region.size
        local r = rad(90 - degrees)
        region:SetFull()
        local u = cos(r)
        local v = sin(r)

        region.foregroundTextures[1]:SetShown(degrees < 90)
        if degrees == 0 or WithinRangeExclusive(degrees, 0, 90) then
            region.foregroundTextures[1]:SetVertexOffset(UR, -u * radius, (v - 1) * radius)
            region.foregroundTextures[1]:SetTexCoord(0, 0, 0, 0.5, 0.5 * (1 - u), 0.5 * (1 - v), 0.5, 0.5)
            HorizontallyMirror(region.foregroundTextures[1])
        end

        region.foregroundTextures[2]:SetShown(degrees < 180)
        if degrees == 90 or WithinRangeExclusive(degrees, 90, 180) then
            region.foregroundTextures[2]:SetVertexOffset(UR, (u - 1) * radius, v * radius)
            region.foregroundTextures[2]:SetTexCoord(0.5, 0.5, 0.5, 1, 0.5 * (1 + u), 0.5 * (1 - v), 1, 1)
        end

        region.foregroundTextures[3]:SetShown(degrees < 270)
        if degrees == 180 or WithinRangeExclusive(degrees, 180, 270) then
            region.foregroundTextures[3]:SetVertexOffset(LL, -u * radius, (v + 1) * radius)
            region.foregroundTextures[3]:SetTexCoord(0.5, 0.5, 0.5 * (1 - u), 0.5 * (1 - v), 1, 0.5, 1, 1)
            HorizontallyMirror(region.foregroundTextures[3])
        end

        region.foregroundTextures[4]:SetShown(degrees < 360)
        if degrees == 270 or WithinRangeExclusive(degrees, 270, 360) then
            region.foregroundTextures[4]:SetVertexOffset(LL, (u + 1) * radius, v * radius)
            region.foregroundTextures[4]:SetTexCoord(0, 0, 0.5 * (1 + u), 0.5 * (1 - v), 0.5, 0, 0.5, 0.5)
        end
    end

    -- Public: square footprint + font-independent sizing.
    function region:SetCircleSize(size)
        size = size or 50
        region.size = size
        region:SetSize(size, size)
    end

    function region:SetColor(cr, cg, cb)
        for i = 1, 4 do region.foregroundTextures[i]:SetVertexColor(cr or 1, cg or 1, cb or 1) end
    end

    function region:SetBackgroundShown(shown)
        for i = 1, 4 do region.backgroundTextures[i]:SetShown(shown and true or false) end
    end

    -- progress: 1 = full ring (buff just applied), 0 = empty (expired).
    -- Depletes clockwise from the top, mirroring value = remaining.
    function region:SetProgress(progress)
        progress = Clamp(progress or 0, 0, 1)
        SetDegrees((1 - progress) * 360)
    end

    region:SetFull()
    region:SetCircleSize(region.size)
    return region
end
