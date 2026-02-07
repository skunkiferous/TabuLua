-- gameLib.lua - Game utility functions for Chronicles of Tabulua
-- This code library is registered in Manifest.transposed.tsv and available
-- in expressions (=gameLib.func(...)) and COG blocks (###gameLib.func(...)).
local M = {}

-- Constants
M.PI = 3.14159265359

-- Calculate area of a circle
function M.circleArea(radius)
    return M.PI * radius * radius
end

-- Linear interpolation between two values
-- a: start value, b: end value, t: interpolation factor (0.0 to 1.0)
function M.lerp(a, b, t)
    return a + (b - a) * t
end

-- Clamp a value between min and max bounds
function M.clamp(value, minVal, maxVal)
    return math.max(minVal, math.min(maxVal, value))
end

-- Convert a percent value to a multiplier for damage calculations
-- The percent type parses "150%" as 1.5 and "3/2" as 1.5
-- This function simply returns the value as-is (it is already a multiplier)
function M.percentToMultiplier(pct)
    return pct
end

-- Scale a base value by level using a linear growth curve
-- base: starting value, level: character level, growth: growth factor per level
function M.levelScale(base, level, growth)
    return base * (1 + (level - 1) * (growth or 0.1))
end

return M
