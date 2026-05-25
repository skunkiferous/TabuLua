-- type_wiring_bootstrap_spec.lua
-- Tests for the Phase 3a bootstrap surface: makeBootstrapAPI's proxy
-- semantics + the seal closure, plus manifest_info.runPackageBootstraps'
-- dispatch behaviour. See TODO/type_wiring.md.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local after_each = busted.after_each

local type_wiring = require("type_wiring")
require("builtin_wiring")
local manifest_info = require("manifest_info")
local error_reporting = require("error_reporting")

local function mockBadVal()
    local errors = {}
    local bv = error_reporting.badValGen(function(_self, msg)
        errors[#errors + 1] = msg
    end)
    bv.logger = error_reporting.nullLogger
    bv.source_name = "test"
    bv.line_no = 1
    bv._errors = errors
    return bv
end

describe("type_wiring.makeBootstrapAPI", function()

    after_each(function() type_wiring.restoreState() end)

    it("returns an api table with register and registerModule", function()
        local api, seal = type_wiring.makeBootstrapAPI()
        assert.is_table(api)
        assert.is_function(seal)
        assert.is_function(api.register)
        assert.is_function(api.registerModule)
    end)

    it("api.register proxies onto type_wiring.register while unsealed", function()
        local api = type_wiring.makeBootstrapAPI()
        api.register("BootTestA", {onLoad = function() end})
        assert.is_true(type_wiring.hasOnLoad("BootTestA", {}))
    end)

    it("api.registerModule proxies onto type_wiring.registerModule", function()
        local api = type_wiring.makeBootstrapAPI()
        api.registerModule("boot_test_mod", {
            descriptorColumns = {
                {name = "bootCol", type = "name|nil", fieldOnMeta = "lcFn2BootCol"},
            },
        })
        local cols = type_wiring.descriptorColumnsByName()
        assert.is_not_nil(cols.bootCol)
    end)

    it("errors on api.register after seal()", function()
        local api, seal = type_wiring.makeBootstrapAPI()
        seal()
        local ok, err = pcall(api.register, "AfterSeal", {onLoad = function() end})
        assert.is_false(ok)
        assert.is_string(err)
        assert.is_not_nil(err:find("bootstrap phase has ended", 1, true))
    end)

    it("errors on api.registerModule after seal()", function()
        local api, seal = type_wiring.makeBootstrapAPI()
        seal()
        local ok, err = pcall(api.registerModule, "after_seal", {})
        assert.is_false(ok)
        assert.is_not_nil(err:find("bootstrap phase has ended", 1, true))
    end)

    it("seal() captures the api as of call time, not lookup time", function()
        -- A bootstrap that stashes api.register into library state and
        -- invokes it AFTER seal still hits the seal check, because the
        -- proxy closure checks `sealed` on each invocation.
        local api, seal = type_wiring.makeBootstrapAPI()
        local stashed = api.register
        seal()
        local ok, err = pcall(stashed, "Stashed", {onLoad = function() end})
        assert.is_false(ok)
        assert.is_not_nil(err:find("bootstrap phase has ended", 1, true))
    end)

    it("the api table itself is read-only (api.register cannot be reassigned)", function()
        local api = type_wiring.makeBootstrapAPI()
        assert.has_error(function() api.register = function() end end)
        assert.has_error(function() api.someNew = "x" end)
    end)

    it("each call to makeBootstrapAPI is an independent (api, seal) pair", function()
        local _api1, seal1 = type_wiring.makeBootstrapAPI()
        local api2, seal2 = type_wiring.makeBootstrapAPI()
        seal1()
        -- Sealing pair 1 must NOT affect pair 2.
        assert.has_no_error(function()
            api2.register("IndependentSeal", {onLoad = function() end})
        end)
        seal2()
        assert.is_true(type_wiring.hasOnLoad("IndependentSeal", {}))
    end)
end)

describe("manifest_info.runPackageBootstraps", function()

    after_each(function() type_wiring.restoreState() end)

    it("invokes each entry's fn(api) in package-dependency order", function()
        local trace = {}
        local function makeFn(label)
            return function(api)
                trace[#trace + 1] = label
                api.register("Order_" .. label, {onLoad = function() end})
            end
        end
        local loadEnv = {
            libA = {boot_a = makeFn("A")},
            libB = {boot_b = makeFn("B")},
        }
        local packages = {
            pkgA = {path = "pkgA", bootstrap = {{library = "libA", fn = "boot_a"}}},
            pkgB = {path = "pkgB", bootstrap = {{library = "libB", fn = "boot_b"}}},
        }
        local order = {"pkgA", "pkgB"}
        local api = type_wiring.makeBootstrapAPI()
        manifest_info.runPackageBootstraps(mockBadVal(), packages, order, loadEnv, api)
        assert.same({"A", "B"}, trace)
        assert.is_true(type_wiring.hasOnLoad("Order_A", {}))
        assert.is_true(type_wiring.hasOnLoad("Order_B", {}))
    end)

    it("reports error via badVal when bootstrap names an unloaded library", function()
        local packages = {
            pkg = {path = "pkg", bootstrap = {{library = "missing", fn = "boot"}}},
        }
        local bv = mockBadVal()
        manifest_info.runPackageBootstraps(bv, packages, {"pkg"}, {}, type_wiring.makeBootstrapAPI())
        assert.is_true(#bv._errors > 0)
        local err = table.concat(bv._errors, "\n")
        assert.is_not_nil(err:find("missing", 1, true))
    end)

    it("reports error via badVal when fn is not a function on the library", function()
        local loadEnv = {lib = {something_else = "not a function"}}
        local packages = {
            pkg = {path = "pkg", bootstrap = {{library = "lib", fn = "boot"}}},
        }
        local bv = mockBadVal()
        manifest_info.runPackageBootstraps(bv, packages, {"pkg"}, loadEnv, type_wiring.makeBootstrapAPI())
        assert.is_true(#bv._errors > 0)
        local err = table.concat(bv._errors, "\n")
        assert.is_not_nil(err:find("boot", 1, true))
        assert.is_not_nil(err:find("lib", 1, true))
    end)

    it("reports a raised error from bootstrap fn without aborting other packages", function()
        local laterRan = false
        local loadEnv = {
            badLib = {boot = function() error("boom") end},
            goodLib = {boot = function() laterRan = true end},
        }
        local packages = {
            pkgBad  = {path = "pkgBad",  bootstrap = {{library = "badLib",  fn = "boot"}}},
            pkgGood = {path = "pkgGood", bootstrap = {{library = "goodLib", fn = "boot"}}},
        }
        local order = {"pkgBad", "pkgGood"}
        local bv = mockBadVal()
        manifest_info.runPackageBootstraps(bv, packages, order, loadEnv, type_wiring.makeBootstrapAPI())
        assert.is_true(#bv._errors > 0)
        assert.is_true(laterRan, "later packages must still be processed")
    end)

    it("is a no-op for packages without a bootstrap field", function()
        local packages = {plain = {path = "plain"}}
        local bv = mockBadVal()
        assert.has_no_error(function()
            manifest_info.runPackageBootstraps(bv, packages, {"plain"}, {},
                type_wiring.makeBootstrapAPI())
        end)
        assert.equals(0, #bv._errors)
    end)
end)
