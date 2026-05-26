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

-- Type-Wiring bootstrap (v0.21.0). Registered in the manifest's
-- `bootstrap` field; invoked once at engine init with the type-wiring
-- registration `api`.
--
-- This bootstrap demonstrates the code-library path of Type Wiring by
-- registering a sandbox helper that any validator expression in the
-- expansion can call: `isShadowRealm(name)` returns true for the small
-- set of names canonical to the Shadow Realm content. Users can wire
-- this into a validator like `isShadowRealm(self.name) or 'unknown name'`.
--
-- It also registers a tiny enginePostPasses callback that runs once
-- after all files load, just to show the engine-post-pass shape. A
-- real expansion might check cross-file invariants here.
function M.bootstrap(api)
    -- Local data the registered helper closes over.
    local shadowNames = {
        ["Voidlord"] = true,
        ["Eclipse"]  = true,
        ["Shade"]    = true,
    }

    api.registerModule("bossLib", {
        sandboxHelpers = {
            validator = {
                isShadowRealm = function(name)
                    return shadowNames[name] == true
                end,
            },
        },
        enginePostPasses = {
            function(tsv_files, joinMeta, badVal)
                -- Returning true means the cross-file post-pass succeeded.
                -- A real check would inspect tsv_files / joinMeta and
                -- report any inconsistencies via badVal.
                return true
            end,
        },
    })
end

return M
