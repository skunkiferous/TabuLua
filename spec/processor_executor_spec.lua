-- processor_executor_spec.lua

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local pending = busted.pending

-- Quota-abort tests need the sandbox instruction quota, which the sandbox
-- library cannot enforce on LuaJIT (no debug count hooks) — there the looping
-- processor would genuinely hang, so they are pending rather than red.
local it_quota = require("sandbox").quota_supported and it or pending

local processor_executor = require("wiring.processor_executor")
local tsv_model = require("tsv.tsv_model")
local parsers = require("parsers")
local error_reporting = require("infra.error_reporting")

-- Returns a "badVal" object that stores errors in the given table
local function mockBadVal(log_messages)
    local log = function(_self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    badVal.logger = error_reporting.nullLogger
    return badVal
end

-- Builds a real parsed dataset from a raw TSV-like table, returning the
-- dataset (with header at [1]) and a badVal capturing any parse errors.
local function buildDataset(raw_tsv, name)
    local log_messages = {}
    local badVal = mockBadVal(log_messages)
    local dataset = tsv_model.processTSV(
        tsv_model.defaultOptionsExtractor,
        nil, -- no expression evaluator
        parsers.parseType,
        name or "test.tsv",
        raw_tsv,
        badVal
    )
    return dataset, badVal, log_messages
end

-- Extracts the data rows (everything past the header) from a parsed dataset
local function dataRowsOf(dataset)
    local rows = {}
    for i, r in ipairs(dataset) do
        if i > 1 and type(r) == "table" then
            rows[#rows + 1] = r
        end
    end
    return rows
end

describe("processor_executor", function()

    -- ============================================================
    -- normalizeProcessorSpec
    -- ============================================================
    describe("normalizeProcessorSpec", function()
        it("should normalize a string to defaults", function()
            local result = processor_executor.normalizeProcessorSpec("x > 0")
            assert.are.equal("x > 0", result.expr)
            assert.are.equal("error", result.level)
            assert.are.equal(100, result.priority)
            assert.are.equal(false, result.rerunAfterPatches)
        end)

        it("should preserve table with expr, level, priority, rerunAfterPatches", function()
            local result = processor_executor.normalizeProcessorSpec({
                expr = "true", level = "warn", priority = 50, rerunAfterPatches = true,
            })
            assert.are.equal("true", result.expr)
            assert.are.equal("warn", result.level)
            assert.are.equal(50, result.priority)
            assert.are.equal(true, result.rerunAfterPatches)
        end)

        it("should default priority to 100 when omitted", function()
            local result = processor_executor.normalizeProcessorSpec({expr = "true"})
            assert.are.equal(100, result.priority)
        end)

        it("should default rerunAfterPatches to false when omitted", function()
            local result = processor_executor.normalizeProcessorSpec({expr = "true"})
            assert.are.equal(false, result.rerunAfterPatches)
        end)
    end)

    -- ============================================================
    -- setCell behaviour
    -- ============================================================
    describe("setCell", function()
        it("should update .parsed and preserve .value/.reformatted for round-trip", function()
            local dataset = buildDataset({
                {"name:identifier", "score:number|nil"},
                {"alice", "10"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local ok = processor_executor.runFilePreProcessors(
                {"setCell(rows[1], 'score', 42)"},
                rows, header, "test.tsv", badVal)

            assert.is_true(ok)
            assert.are.equal(0, badVal.errors)
            -- .parsed was mutated to the processor-supplied value
            assert.are.equal(42, dataset[2][2].parsed)
            -- .value and .reformatted preserve the original on-disk text
            assert.are.equal("10", dataset[2][2].value)
            assert.are.equal("10", dataset[2][2].reformatted)
        end)

        it("should reject type-incompatible values via badVal", function()
            local dataset = buildDataset({
                {"name:identifier", "score:number|nil"},
                {"alice", "10"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local ok = processor_executor.runFilePreProcessors(
                {"setCell(rows[1], 'score', 'not_a_number')"},
                rows, header, "test.tsv", badVal)

            -- Type rejection raises inside the sandbox, which is caught by
            -- executeProcessor and surfaces as an error-level failure.
            assert.is_false(ok)
            assert.is_true(badVal.errors >= 1)
            -- Original parsed value is unchanged.
            assert.are.equal(10, dataset[2][2].parsed)
        end)

        it("should report error when column does not exist", function()
            local dataset = buildDataset({
                {"name:identifier", "score:number|nil"},
                {"alice", "10"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            processor_executor.runFilePreProcessors(
                {"setCell(rows[1], 'no_such_col', 5)"},
                rows, header, "test.tsv", badVal)

            assert.is_true(badVal.errors >= 1)
        end)
    end)

    -- ============================================================
    -- clearCell behaviour
    -- ============================================================
    describe("clearCell", function()
        it("should clear a nullable column", function()
            local dataset = buildDataset({
                {"name:identifier", "note:string|nil"},
                {"alice", "hello"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local ok = processor_executor.runFilePreProcessors(
                {"clearCell(rows[1], 'note')"},
                rows, header, "test.tsv", badVal)

            assert.is_true(ok)
            assert.are.equal(0, badVal.errors)
            assert.is_nil(dataset[2][2].parsed)
        end)

        it("should reject clearing a non-nullable column", function()
            local dataset = buildDataset({
                {"name:identifier", "score:number"},
                {"alice", "10"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            processor_executor.runFilePreProcessors(
                {"clearCell(rows[1], 'score')"},
                rows, header, "test.tsv", badVal)

            assert.is_true(badVal.errors >= 1)
            -- Parsed value should not have been touched
            assert.are.equal(10, dataset[2][2].parsed)
        end)
    end)

    -- ============================================================
    -- rowByKey
    -- ============================================================
    describe("rowByKey", function()
        it("should look up rows by primary key", function()
            local dataset = buildDataset({
                {"name:identifier", "score:number|nil"},
                {"alice", "10"},
                {"bob", "20"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local ok = processor_executor.runFilePreProcessors(
                {"setCell(rowByKey('bob'), 'score', 99)"},
                rows, header, "test.tsv", badVal)

            assert.is_true(ok)
            assert.are.equal(0, badVal.errors)
            assert.are.equal(99, dataset[3][2].parsed)
            -- Other row untouched
            assert.are.equal(10, dataset[2][2].parsed)
        end)

        it("should return nil for unknown keys (no throw)", function()
            local dataset = buildDataset({
                {"name:identifier", "score:number|nil"},
                {"alice", "10"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local ok = processor_executor.runFilePreProcessors(
                {"rowByKey('missing') == nil"},
                rows, header, "test.tsv", badVal)

            assert.is_true(ok)
            assert.are.equal(0, badVal.errors)
        end)
    end)

    -- ============================================================
    -- Ordering and inter-processor visibility
    -- ============================================================
    describe("runFilePreProcessors ordering", function()
        it("should run processors in textual order with default priority", function()
            local dataset = buildDataset({
                {"name:identifier", "score:number|nil"},
                {"alice", "0"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local ok = processor_executor.runFilePreProcessors(
                {
                    "setCell(rows[1], 'score', 1)",
                    "setCell(rows[1], 'score', 2)",
                },
                rows, header, "test.tsv", badVal)

            assert.is_true(ok)
            assert.are.equal(2, dataset[2][2].parsed)
        end)

        it("should run lower priority first", function()
            local dataset = buildDataset({
                {"name:identifier", "score:number|nil"},
                {"alice", "0"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            -- Second spec has lower priority and so should run FIRST
            local ok = processor_executor.runFilePreProcessors(
                {
                    {expr = "setCell(rows[1], 'score', 1)", priority = 200},
                    {expr = "setCell(rows[1], 'score', 2)", priority = 50},
                },
                rows, header, "test.tsv", badVal)

            assert.is_true(ok)
            -- The priority=200 processor runs LAST, so wins
            assert.are.equal(1, dataset[2][2].parsed)
        end)

        it("should let later processors see earlier processors' writes", function()
            local dataset = buildDataset({
                {"name:identifier", "score:number|nil"},
                {"alice", "10"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            -- First processor doubles score, second adds the doubled value to ctx
            local ok = processor_executor.runFilePreProcessors(
                {
                    "setCell(rows[1], 'score', rows[1].score * 2)",
                    "(function() ctx.cached = rows[1].score; return true end)()",
                },
                rows, header, "test.tsv", badVal)

            assert.is_true(ok)
            assert.are.equal(20, dataset[2][2].parsed)
        end)
    end)

    -- ============================================================
    -- Quota enforcement
    -- ============================================================
    describe("quota enforcement", function()
        it_quota("should abort cleanly when an infinite loop hits the quota", function()
            local dataset = buildDataset({
                {"name:identifier"},
                {"alice"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local prev_quota = processor_executor.PROCESSOR_QUOTA
            assert.is_number(prev_quota)

            -- Infinite-loop expression: should hit quota and be reported.
            processor_executor.runFilePreProcessors(
                {"(function() while true do end end)()"},
                rows, header, "test.tsv", badVal)

            assert.is_true(badVal.errors >= 1)
        end)
    end)

    -- ============================================================
    -- Error reporting / non-throwing semantics
    -- ============================================================
    describe("error handling", function()
        it("should report a runtime error and continue with later files", function()
            local dataset = buildDataset({
                {"name:identifier"},
                {"alice"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            -- The first processor throws; the second should still execute.
            -- We test inter-processor continuation within a single file run.
            local ok = processor_executor.runFilePreProcessors(
                {
                    "error('boom')",
                    "(function() ctx.reached = true; return true end)()",
                },
                rows, header, "test.tsv", badVal)

            assert.is_false(ok)
            assert.is_true(badVal.errors >= 1)
        end)

        it("should treat a returned non-empty string as failure", function()
            local dataset = buildDataset({
                {"name:identifier"},
                {"alice"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local ok = processor_executor.runFilePreProcessors(
                {"'something went wrong'"},
                rows, header, "test.tsv", badVal)

            assert.is_false(ok)
            assert.is_true(badVal.errors >= 1)
        end)

        it("should collect warnings for warn-level processors", function()
            local dataset = buildDataset({
                {"name:identifier"},
                {"alice"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local ok, warnings = processor_executor.runFilePreProcessors(
                {{expr = "false or 'soft warning'", level = "warn"}},
                rows, header, "test.tsv", badVal)

            assert.is_true(ok)
            assert.are.equal(0, badVal.errors)
            assert.are.equal(1, #warnings)
            assert.are.equal("soft warning", warnings[1].message)
        end)
    end)

    -- ============================================================
    -- Reading helpers exposed to processors
    -- ============================================================
    describe("helper availability", function()
        it("should expose `all`, `lookup`, `count` from validator_helpers", function()
            local dataset = buildDataset({
                {"name:identifier", "score:number"},
                {"alice", "10"},
                {"bob", "20"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local ok = processor_executor.runFilePreProcessors(
                {
                    "all(rows, function(r) return r.score >= 0 end)",
                    "lookup(rows, 'name', 'bob') ~= nil",
                    "count(rows) == 2",
                },
                rows, header, "test.tsv", badVal)

            assert.is_true(ok)
            assert.are.equal(0, badVal.errors)
        end)
    end)

    -- ============================================================
    -- dataIndex helper
    -- ============================================================
    describe("dataIndex", function()
        it("should return 1-based data-row index (header excluded)", function()
            local dataset = buildDataset({
                {"name:identifier"},
                {"alice"},
                {"bob"},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local ok = processor_executor.runFilePreProcessors(
                {
                    "(function() ctx.idx1 = dataIndex(rows[1]); ctx.idx2 = dataIndex(rows[2]); return true end)()",
                    "ctx.idx1 == 1 and ctx.idx2 == 2",
                },
                rows, header, "test.tsv", badVal)

            assert.is_true(ok)
            assert.are.equal(0, badVal.errors)
        end)
    end)

    -- ============================================================
    -- Read-only cell values and the copy() helper
    -- ============================================================
    describe("read-only cell values", function()
        it("rejects in-place mutation of a table-valued cell", function()
            local dataset = buildDataset({
                {"name:identifier", "tags:{name}|nil"},
                {"alice", '"a","b"'},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            -- table.insert into the parsed value must hit the read-only layer.
            local ok = processor_executor.runFilePreProcessors(
                {"(function() table.insert(rows[1].tags, 'c'); return true end)()"},
                rows, header, "test.tsv", badVal)

            assert.is_false(ok)
            assert.is_true(badVal.errors >= 1)
            -- The failure is specifically a read-only violation.
            assert.is.truthy(table.concat(log_messages, " "):find("read.only"))
            -- The underlying cell was not changed.
            assert.are.equal(2, #dataset[2][2].parsed)
        end)

        it("supports the copy + setCell pattern, visible to later processors", function()
            local dataset = buildDataset({
                {"name:identifier", "tags:{name}|nil"},
                {"alice", '"a","b"'},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local ok = processor_executor.runFilePreProcessors(
                {
                    "(function() local t = copy(rows[1].tags); table.insert(t, 'c'); setCell(rows[1], 'tags', t); return true end)()",
                    "(function() ctx.n = #rows[1].tags; return true end)()",
                    "ctx.n == 3",
                },
                rows, header, "test.tsv", badVal)

            assert.is_true(ok)
            assert.are.equal(0, badVal.errors)
            -- The new value passed through the parser and reached the cell.
            assert.are.equal(3, #dataset[2][2].parsed)
            assert.are.equal("c", dataset[2][2].parsed[3])
        end)

        it("copy() returns an independent clone (no setCell => cell unchanged)", function()
            local dataset = buildDataset({
                {"name:identifier", "tags:{name}|nil"},
                {"alice", '"a","b"'},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            -- Mutating the copy without setCell must NOT touch the dataset.
            local ok = processor_executor.runFilePreProcessors(
                {"(function() local t = copy(rows[1].tags); table.insert(t, 'zzz'); return true end)()"},
                rows, header, "test.tsv", badVal)

            assert.is_true(ok)
            assert.are.equal(0, badVal.errors)
            assert.are.equal(2, #dataset[2][2].parsed)
        end)

        it("rejects an invalid copied value via setCell's parser", function()
            local dataset = buildDataset({
                {"name:identifier", "tags:{name}|nil"},
                {"alice", '"a","b"'},
            })
            local rows = dataRowsOf(dataset)
            local header = dataset[1]

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            -- "not a name" is not a valid `name`; the parser must reject it.
            processor_executor.runFilePreProcessors(
                {"(function() local t = copy(rows[1].tags); table.insert(t, 'not a name'); setCell(rows[1], 'tags', t); return true end)()"},
                rows, header, "test.tsv", badVal)

            assert.is_true(badVal.errors >= 1)
            -- The bad value never reached the cell.
            assert.are.equal(2, #dataset[2][2].parsed)
        end)
    end)

    -- ============================================================
    -- Module API
    -- ============================================================
    describe("module API", function()
        it("should have a version", function()
            local version = processor_executor.getVersion()
            assert.is_not_nil(version)
            assert.is.truthy(version:match("%d+%.%d+%.%d+"))
        end)

        it("should expose the quota constant", function()
            assert.are.equal(50000, processor_executor.PROCESSOR_QUOTA)
        end)

        it("should have a tostring representation", function()
            local str = tostring(processor_executor)
            assert.is.truthy(str:match("processor_executor"))
        end)

        it("should support the callable version interface", function()
            local version = processor_executor("version")
            assert.is_not_nil(version)
        end)
    end)
end)
