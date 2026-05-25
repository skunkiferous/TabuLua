-- type_wiring_user_tsv_spec.lua
-- Tests for the type-based "wiring file" mechanism (Phase 3b of
-- TODO/type_wiring.md). A file whose typeName is (or extends) the
-- built-in `type_wiring_def` record type has its rows dispatched as
-- type_wiring.register() calls by the standard onLoad cascade — no
-- hard-coded TypeWiring.tsv basename detection.

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local type_wiring = require("type_wiring")
local builtin_wiring = require("builtin_wiring")
local files_desc = require("files_desc")
local parsers = require("parsers")
local file_util = require("file_util")
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

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

describe("type_wiring_def built-in", function()
    it("is registered as a parseable record type", function()
        local parser = parsers.parseType(error_reporting.nullBadVal,
            "type_wiring_def", false)
        assert.is_not_nil(parser)
    end)

    it("has an onLoad registered in the type-wiring registry", function()
        assert.is_true(type_wiring.hasOnLoad("type_wiring_def", {}))
    end)

    it("propagates the wiring to subtypes via extends", function()
        -- A user-named subtype of type_wiring_def inherits the onLoad
        -- through the standard cascade walk — same as any built-in.
        assert.is_true(type_wiring.hasOnLoad("MyWiringFile",
            {MyWiringFile = "type_wiring_def"}))
    end)
end)

describe("builtin_wiring.onLoadTypeWiringDef", function()
    local temp_dir

    before_each(function()
        temp_dir = "test_temp_" .. os.time() .. "_" .. math.random(10000)
        lfs.mkdir(temp_dir)
    end)

    after_each(function()
        for entry in lfs.dir(temp_dir) do
            if entry ~= "." and entry ~= ".." then
                os.remove(path_join(temp_dir, entry))
            end
        end
        lfs.rmdir(temp_dir)
        type_wiring.restoreState()
    end)

    -- Writes a TSV body to a file, parses it via loadDescriptorFile, and
    -- returns the parsed file table. This is the same shape onLoad
    -- handlers receive at engine load time.
    local function parseFixture(name, body)
        local path = path_join(temp_dir, name)
        assert(file_util.writeFile(path, body))
        local bv = mockBadVal()
        local file = files_desc.loadDescriptorFile(path, {}, {}, bv)
        assert.equals(0, #bv._errors,
            "parse errors: " .. table.concat(bv._errors, " | "))
        assert.is_not_nil(file)
        return file
    end

    it("registers a per-typeName fileValidator from a row", function()
        local body =
            "typeName:name\tfileValidators:{validator_spec}|nil\n"
            .. 'TwdTestA\t{expr="true"}'
        local file = parseFixture("Wiring1.tsv", body)
        builtin_wiring.onLoadTypeWiringDef(
            file, "type_wiring_def", {}, mockBadVal(), {})
        local fv = {}
        type_wiring.applyWiring("TwdTestA", {}, {fileValidators = fv})
        assert.equals(1, #fv)
        assert.equals("true", fv[1].expr)
    end)

    it("registers a per-typeName preProcessor from a row", function()
        local body =
            "typeName:name\tpreProcessors:{processor_spec}|nil\n"
            .. 'TwdTestB\t{expr="true",priority=50}'
        local file = parseFixture("Wiring2.tsv", body)
        builtin_wiring.onLoadTypeWiringDef(
            file, "type_wiring_def", {}, mockBadVal(), {})
        local pre = {}
        type_wiring.applyWiring("TwdTestB", {}, {preProcessors = pre})
        assert.equals(1, #pre)
        assert.equals("true", pre[1].expr)
        assert.equals(50, pre[1].priority)
    end)

    -- (Empty / duplicate typeName values are rejected by the TSV parser
    -- itself — typeName is the file's primary key — so those cases never
    -- reach onLoad. The PK constraint is the right enforcement layer.)

    it("registers an unknown typeName harmlessly (Phase 3 Q5)", function()
        local body =
            "typeName:name\tfileValidators:{validator_spec}|nil\n"
            .. 'TwdNeverExtendedType\t{expr="true"}'
        local file = parseFixture("Wiring4.tsv", body)
        builtin_wiring.onLoadTypeWiringDef(
            file, "type_wiring_def", {}, mockBadVal(), {})
        -- A file whose extends chain doesn't include TwdNeverExtendedType
        -- gets no wired contributions; no errors.
        local fv = {}
        type_wiring.applyWiring("OtherType",
            {OtherType = "Type"}, {fileValidators = fv})
        assert.equals(0, #fv)
    end)

    it("accumulates contributions when a row's list column has two specs", function()
        -- Cross-row accumulation is blocked by the PK constraint, but a
        -- single row can carry multiple specs in its list column.
        local body =
            "typeName:name\tfileValidators:{validator_spec}|nil\n"
            .. 'TwdAccumType\t{expr="true"},{expr="self.x > 0"}'
        local file = parseFixture("Wiring5.tsv", body)
        builtin_wiring.onLoadTypeWiringDef(
            file, "type_wiring_def", {}, mockBadVal(), {})
        local fv = {}
        type_wiring.applyWiring("TwdAccumType", {}, {fileValidators = fv})
        assert.equals(2, #fv)
    end)

    it("preserves the per-entry processor_spec metadata fields", function()
        local body =
            "typeName:name\tpreProcessors:{processor_spec}|nil\n"
            .. 'TwdMetadataType\t{expr="true",priority=42,rerunAfterPatches=true}'
        local file = parseFixture("Wiring6.tsv", body)
        builtin_wiring.onLoadTypeWiringDef(
            file, "type_wiring_def", {}, mockBadVal(), {})
        local pre = {}
        type_wiring.applyWiring("TwdMetadataType", {}, {preProcessors = pre})
        assert.equals(1, #pre)
        assert.equals(42, pre[1].priority)
        assert.is_true(pre[1].rerunAfterPatches)
    end)

    it("fires via the cascade when a user-named subtype extends type_wiring_def", function()
        -- A user package can give its wiring file a custom typeName (e.g.
        -- MyTwd) with superType=type_wiring_def. The onLoad fires for that
        -- file because the cascade walks the extends chain.
        local body =
            "typeName:name\tfileValidators:{validator_spec}|nil\n"
            .. 'TwdCascadeTarget\t{expr="true"}'
        local file = parseFixture("MyCustomWiring.tsv", body)
        local extends = {MyTwd = "type_wiring_def"}
        -- Simulate what applyWiring does at load time for a file declaring
        -- typeName=MyTwd, superType=type_wiring_def.
        type_wiring.applyWiring("MyTwd", extends, {
            file = file, badVal = mockBadVal(), loadEnv = {},
        })
        local fv = {}
        type_wiring.applyWiring("TwdCascadeTarget", {}, {fileValidators = fv})
        assert.equals(1, #fv)
    end)
end)
