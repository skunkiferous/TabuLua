-- mathUtils.lua - Math utility functions for demo package
local M = {}

-- Constants
M.PI = 3.14159265359
M.E = 2.71828182846

-- Calculate area of a circle
function M.circleArea(radius)
    return M.PI * radius * radius
end

-- Calculate circumference of a circle
function M.circumference(radius)
    return 2 * M.PI * radius
end

-- Linear interpolation between two values
function M.lerp(a, b, t)
    return a + (b - a) * t
end

-- Clamp a value between min and max
function M.clamp(value, min, max)
    return math.max(min, math.min(max, value))
end

return M
