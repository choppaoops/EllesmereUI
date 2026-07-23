local _, ns = ...

-------------------------------------------------------------------------------
--  Tracking Bars: Circle (ring) progress region
--
--  An alternative to the horizontal StatusBar fill -- the remaining duration
--  runs around a thin, clean ring instead of along a bar. The ring is built
--  from many small solid-colour segments evenly placed on the circle's
--  perimeter (positions via cos/sin), so the CENTRE IS FULLY TRANSPARENT --
--  only the ring line itself is drawn, with nothing filling the middle. No
--  texture art is used (SetColorTexture), so there is no inner disc, mask, or
--  bevel to muddy the look.
--
--  Segments overlap (segment box >= spacing), so the arc reads as a continuous
--  smooth ring rather than dots. Thickness is the segment box size and is
--  freely adjustable. Progress fills clockwise from the top (12 o'clock):
--  progress 1 = full ring (buff just applied), 0 = empty (expired), mirroring
--  the bar's "value = remaining".
-------------------------------------------------------------------------------

local SEGMENTS = 72
local TWO_PI = math.pi * 2
local cos, sin, floor, max, min = math.cos, math.sin, math.floor, math.max, math.min

-- Create a circle-progress region as a child of `parent` (a TBB wrap frame).
-- Methods used by the buff-bar renderer:
--   SetCircleSize(size) / SetThickness(t) / SetColor(r,g,b) /
--   SetBackgroundShown(bool) / SetProgress(0..1) / Show / Hide.
function ns.CreateTBBCircle(parent)
    local region = CreateFrame("Frame", nil, parent)
    region:Hide()
    region.size = 50
    region.thickness = 4

    region.bgSeg = {}   -- dim full ring (optional background)
    region.fgSeg = {}   -- bright progress arc
    -- Precompute unit direction (clockwise from top) for each segment centre.
    region.dirX = {}
    region.dirY = {}
    for i = 1, SEGMENTS do
        -- i=1 at top; clockwise. x = sin(a), y = cos(a) so a=0 -> (0,1)=top.
        local a = (i - 1) / SEGMENTS * TWO_PI
        region.dirX[i] = sin(a)
        region.dirY[i] = cos(a)

        local bg = region:CreateTexture(nil, "BACKGROUND")
        bg:SetColorTexture(1, 1, 1, 1)
        bg:SetVertexColor(0, 0, 0, 0.5)
        bg:SetSnapToPixelGrid(false)
        bg:SetTexelSnappingBias(0)
        region.bgSeg[i] = bg

        local fg = region:CreateTexture(nil, "BORDER")
        fg:SetColorTexture(1, 1, 1, 1)
        fg:SetSnapToPixelGrid(false)
        fg:SetTexelSnappingBias(0)
        region.fgSeg[i] = fg
    end

    -- Reposition/resize every segment for the current size + thickness. The
    -- ring's mid-line radius keeps the whole ring inside the size x size box.
    local function Relayout()
        local t = region.thickness
        local radius = 0.5 * (region.size - t)
        if radius < 0 then radius = 0 end
        for i = 1, SEGMENTS do
            local dx, dy = region.dirX[i] * radius, region.dirY[i] * radius
            local bg, fg = region.bgSeg[i], region.fgSeg[i]
            bg:SetSize(t, t); bg:ClearAllPoints(); bg:SetPoint("CENTER", region, "CENTER", dx, dy)
            fg:SetSize(t, t); fg:ClearAllPoints(); fg:SetPoint("CENTER", region, "CENTER", dx, dy)
        end
    end

    function region:SetCircleSize(size)
        size = size or 50
        region.size = size
        region:SetSize(size, size)
        -- Keep thickness sane relative to size.
        region.thickness = max(1, min(region.thickness, 0.5 * size))
        Relayout()
    end

    function region:SetThickness(t)
        region.thickness = max(1, min(t or 4, 0.5 * region.size))
        Relayout()
    end

    function region:SetColor(cr, cg, cb)
        for i = 1, SEGMENTS do region.fgSeg[i]:SetVertexColor(cr or 1, cg or 1, cb or 1) end
    end

    function region:SetBackgroundShown(shown)
        shown = shown and true or false
        for i = 1, SEGMENTS do region.bgSeg[i]:SetShown(shown) end
    end

    -- progress: 1 = full ring, 0 = empty. The bright arc spans the first
    -- `progress` fraction of the ring clockwise from the top; the rest is hidden
    -- (only the dim background, if enabled, remains there).
    function region:SetProgress(progress)
        if progress ~= progress then progress = 0 end  -- NaN guard
        if progress < 0 then progress = 0 elseif progress > 1 then progress = 1 end
        local lit = floor(progress * SEGMENTS + 0.5)
        for i = 1, SEGMENTS do
            region.fgSeg[i]:SetShown(i <= lit)
        end
    end

    region:SetCircleSize(region.size)
    return region
end
