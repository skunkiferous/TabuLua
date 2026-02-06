-- bossLib.lua - Boss encounter utility functions for the Shadow Realm expansion
-- This library is registered in the expansion's Manifest.transposed.tsv.
-- It is available in expressions and COG blocks within expansion data files.
local M = {}

-- Boss damage scaling multiplier
-- Bosses deal 20% more than their scaling percentage suggests
function M.bossScaling(percentValue)
    return percentValue * 1.2
end

-- Calculate phase transition HP threshold
-- Returns the HP value at which a boss enters the next phase
function M.phaseThreshold(maxHp, phaseCount, phaseIndex)
    return maxHp * (1 - phaseIndex / phaseCount)
end

return M
