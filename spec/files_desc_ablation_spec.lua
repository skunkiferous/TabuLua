-- files_desc_ablation_spec.lua
-- Ablation coverage for the L4 schema shrink (Phase 2a of
-- TODO/type_wiring.md). For each of the ten now-optional Files.tsv
-- columns, generate a synthetic Files.tsv that omits exactly that
-- column and confirm loadDescriptorFiles still parses it without
-- crashing on nil-from-missing-map. The shrunk schema is correct;
-- this spec catches downstream consumers that quietly assumed a
-- column was always present.

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local files_desc = require("files_desc")
local file_util = require("file_util")
local error_reporting = require("error_reporting")

local badValGen = error_reporting.badValGen

-- The ten optional descriptor columns covered by the L4 shrink. Each row
-- carries the column's "name:type" header string and an example value the
-- column's parse function will accept. The example value must round-trip
-- through the type-spec parser cleanly.
local OPTIONAL_COLUMNS = {
    {header = "publishContext:name|nil",                  value = "myCtx"},
    {header = "publishColumn:name|nil",                   value = "myCol"},
    {header = "joinInto:filepath|nil",                    value = "Items.tsv"},
    {header = "joinColumn:name|nil",                      value = "name"},
    {header = "export:boolean|nil",                       value = "true"},
    {header = "joinedTypeName:type_spec|nil",             value = "Item"},
    {header = "variant:name|nil",                         value = "default"},
    {header = "rowValidators:{validator_spec}|nil",       value = ""},
    {header = "fileValidators:{validator_spec}|nil",      value = ""},
    {header = "preProcessors:{processor_spec}|nil",       value = ""},
    {header = "edgesFor:filepath|nil",                    value = ""},
}

local CORE_HEADERS = {
    "fileName:filepath",
    "typeName:type_spec",
    "superType:super_type",
    "baseType:boolean",
    "loadOrder:number",
    "description:text",
}

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

describe("files_desc L4 ablation", function()
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
    end)

    -- Single-row Files.tsv body referencing a placeholder data file.
    -- The values column-by-column matches whichever headers are present.
    local function buildAndLoad(headers, rowValues)
        local file_path = path_join(temp_dir, "files.tsv")
        local body = table.concat(headers, "\t") .. "\n"
            .. table.concat(rowValues, "\t")
        assert(file_util.writeFile(file_path, body))

        local log_messages = {}
        local badVal = badValGen(function(_self, msg)
            table.insert(log_messages, msg) end)
        badVal.source_name = "test"
        badVal.line_no = 1
        badVal.logger = error_reporting.nullLogger

        local prios = {}
        local post_proc_files = {}
        local extends = {}
        local lcFn2Type = {}
        local lcFn2Ctx = {}
        local lcFn2Col = {}
        local lcFn2JoinInto = {}
        local lcFn2JoinColumn = {}
        local lcFn2Export = {}
        local lcFn2JoinedTypeName = {}
        local lcFn2RowValidators = {}
        local lcFn2FileValidators = {}
        local lcFn2PreProcessors = {}
        local lcFn2LineNo = {}
        local lcFn2EdgesFor = {}
        local raw_files = {}
        local result = files_desc.loadDescriptorFiles(
            {file_path}, prios, {[file_path] = "test"},
            post_proc_files, extends, lcFn2Type, lcFn2Ctx, lcFn2Col,
            lcFn2JoinInto, lcFn2JoinColumn, lcFn2Export, lcFn2JoinedTypeName,
            lcFn2RowValidators, lcFn2FileValidators, lcFn2PreProcessors,
            lcFn2LineNo, raw_files, {}, badVal, nil, {}, lcFn2EdgesFor)
        return {
            result = result,
            lcFn2Type = lcFn2Type,
            lcFn2Ctx = lcFn2Ctx,
            lcFn2Col = lcFn2Col,
            lcFn2JoinInto = lcFn2JoinInto,
            lcFn2EdgesFor = lcFn2EdgesFor,
            badVal = badVal,
            log_messages = log_messages,
        }
    end

    it("parses a Files.tsv containing only the six intrinsic core columns", function()
        local rowVals = {"Items.tsv", "Item", "", "true", "1", "Item file"}
        local r = buildAndLoad(CORE_HEADERS, rowVals)
        assert.is_not_nil(r.result)
        assert.equals("Item", r.lcFn2Type["items.tsv"])
    end)

    -- For each optional column, build a Files.tsv that includes ALL the
    -- core columns + every optional column EXCEPT the one under ablation,
    -- and assert the load succeeds with no nil-deref crashes.
    for _, omit in ipairs(OPTIONAL_COLUMNS) do
        it("loads cleanly when '" .. omit.header .. "' is omitted", function()
            local headers = {}
            for _, h in ipairs(CORE_HEADERS) do headers[#headers + 1] = h end
            for _, c in ipairs(OPTIONAL_COLUMNS) do
                if c.header ~= omit.header then
                    headers[#headers + 1] = c.header
                end
            end
            local rowVals = {"Items.tsv", "Item", "", "true", "1", "Item file"}
            for _, c in ipairs(OPTIONAL_COLUMNS) do
                if c.header ~= omit.header then
                    rowVals[#rowVals + 1] = c.value
                end
            end
            local r = buildAndLoad(headers, rowVals)
            assert.is_not_nil(r.result,
                "load should succeed when '" .. omit.header .. "' is absent")
        end)
    end
end)
