-- global_reset_spec.lua
-- Tests for the global_reset module

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

-- Use the shared instance only for API surface tests that do NOT call reset()
local global_reset = require("global_reset")

--- Creates a fresh, isolated global_reset instance with an empty registry.
--- The shared instance in package.loaded is preserved so other modules are
--- unaffected.  This lets us call reset() safely in tests without firing
--- reset functions registered by real modules (parsers, named_logger, etc.).
local function getFreshInstance()
    local saved = package.loaded["global_reset"]
    package.loaded["global_reset"] = nil
    local fresh = require("global_reset")
    package.loaded["global_reset"] = saved
    return fresh
end

describe("global_reset", function()

    describe("getVersion", function()
        it("should return a semantic version string", function()
            assert.is_string(global_reset.getVersion())
            assert.truthy(global_reset.getVersion():match("^%d+%.%d+%.%d+$"))
        end)
    end)

    describe("callable API", function()
        it("should support version via call syntax", function()
            local ver = global_reset("version")
            assert.is_not_nil(ver)
        end)

        it("should error on unknown operation", function()
            assert.has_error(function()
                global_reset("nonexistent")
            end)
        end)
    end)

    describe("tostring", function()
        it("should return module name and version", function()
            local s = tostring(global_reset)
            assert.truthy(s:match("^global_reset version %d+%.%d+%.%d+$"))
        end)
    end)

    describe("read-only", function()
        it("should prevent modification of the API table", function()
            assert.has_error(function()
                global_reset.foo = "bar"
            end)
        end)
    end)

    describe("register", function()
        it("should accept a function", function()
            -- Use a fresh instance so we don't pollute the shared registry
            local fresh = getFreshInstance()
            assert.has_no.errors(function()
                fresh.register(function() end)
            end)
        end)

        it("should accept a function via call syntax", function()
            local fresh = getFreshInstance()
            assert.has_no.errors(function()
                fresh("register", function() end)
            end)
        end)

        it("should reject a non-function argument", function()
            local fresh = getFreshInstance()
            assert.has_error(function()
                fresh.register("not a function")
            end)
            assert.has_error(function()
                fresh.register(42)
            end)
            assert.has_error(function()
                fresh.register(nil)
            end)
        end)
    end)

    describe("reset", function()
        it("should call all registered reset functions", function()
            local fresh = getFreshInstance()
            local called_a = false
            local called_b = false
            fresh.register(function() called_a = true end)
            fresh.register(function() called_b = true end)
            fresh.reset()
            assert.is_true(called_a)
            assert.is_true(called_b)
        end)

        it("should allow multiple resets", function()
            local fresh = getFreshInstance()
            local count = 0
            fresh.register(function() count = count + 1 end)
            fresh.reset()
            fresh.reset()
            assert.are.equal(2, count)
        end)

        it("should not error when no functions are registered", function()
            local fresh = getFreshInstance()
            assert.has_no.errors(function()
                fresh.reset()
            end)
        end)

        it("should reset simulated module state", function()
            local fresh = getFreshInstance()
            -- Simulate a module with a cache
            local cache = { a = 1, b = 2 }
            fresh.register(function()
                for k in pairs(cache) do
                    cache[k] = nil
                end
            end)
            assert.are.same({ a = 1, b = 2 }, cache)
            fresh.reset()
            assert.are.same({}, cache)
        end)

        it("should preserve registrations across resets", function()
            local fresh = getFreshInstance()
            local count = 0
            fresh.register(function() count = count + 1 end)
            fresh.reset()
            fresh.reset()
            fresh.reset()
            assert.are.equal(3, count)
        end)
    end)
end)
