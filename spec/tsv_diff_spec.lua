-- tsv_diff_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local raw_tsv = require("raw_tsv")
local tsv_diff = require("tsv_diff")

--- Helper: build a raw TSV from a multi-line string.
local function tsv(s)
    return raw_tsv.stringToRawTSV(s)
end

describe("tsv_diff", function()

    -- ================================================================
    -- IDENTICAL FILES
    -- ================================================================

    describe("identical files", function()
        it("should report identical when both files are the same", function()
            local data = tsv("name\tage\njohn\t30\njane\t25")
            local identical, output, diffCount = tsv_diff.diff(data, data)
            assert.is_true(identical)
            assert.equals(0, diffCount)
            assert.truthy(output:find("identical"))
        end)

        it("should report identical with comments and blank lines", function()
            local a = tsv("name\tage\n# comment\njohn\t30\n\njane\t25")
            local b = tsv("name\tage\njohn\t30\njane\t25")
            local identical, _, diffCount = tsv_diff.diff(a, b)
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should report identical for single header, no data rows", function()
            local a = tsv("name\tage")
            local b = tsv("name\tage")
            local identical, _, diffCount = tsv_diff.diff(a, b)
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)
    end)

    -- ================================================================
    -- COLUMN ANALYSIS
    -- ================================================================

    describe("column analysis", function()
        it("should detect added columns", function()
            local a = tsv("name\tage\njohn\t30")
            local b = tsv("name\tage\temail\njohn\t30\tjohn@x")
            local identical, output, _, colInfo = tsv_diff.diff(a, b)
            assert.is_false(identical) -- structural difference
            assert.equals(0, #colInfo.removedCols)
            assert.equals(1, #colInfo.addedCols)
            assert.equals("email", colInfo.addedCols[1])
            assert.truthy(output:find("Added columns"))
        end)

        it("should detect removed columns", function()
            local a = tsv("name\tage\temail\njohn\t30\tjohn@x")
            local b = tsv("name\tage\njohn\t30")
            local identical, output, _, colInfo = tsv_diff.diff(a, b)
            assert.is_false(identical)
            assert.equals(1, #colInfo.removedCols)
            assert.equals("email", colInfo.removedCols[1])
            assert.equals(0, #colInfo.addedCols)
            assert.truthy(output:find("Removed columns"))
        end)

        it("should detect primary key mismatch", function()
            local a = tsv("id\tval\n1\ta")
            local b = tsv("name\tval\njohn\ta")
            local _, output, _, colInfo = tsv_diff.diff(a, b)
            assert.is_false(colInfo.pkMatch)
            assert.truthy(output:find("Primary key MISMATCH"))
        end)

        it("should not compare column order (except PK)", function()
            local a = tsv("name\tage\temail\njohn\t30\tjohn@x")
            local b = tsv("name\temail\tage\njohn\tjohn@x\t30")
            local identical, _, diffCount = tsv_diff.diff(a, b)
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)
    end)

    -- ================================================================
    -- ORDER-BASED MODE
    -- ================================================================

    describe("order-based mode", function()
        it("should detect changed cells", function()
            local a = tsv("name\tage\njohn\t30\njane\t25")
            local b = tsv("name\tage\njohn\t31\njane\t25")
            local identical, output, diffCount = tsv_diff.diff(a, b)
            assert.is_false(identical)
            assert.equals(1, diffCount)
            assert.truthy(output:find("age"))
            assert.truthy(output:find("30"))
            assert.truthy(output:find("31"))
        end)

        it("should detect added rows (file 2 has more rows)", function()
            local a = tsv("name\tage\njohn\t30")
            local b = tsv("name\tage\njohn\t30\njane\t25")
            local identical, output, diffCount = tsv_diff.diff(a, b)
            assert.is_false(identical)
            assert.equals(1, diffCount)
            assert.truthy(output:find("%+"))
        end)

        it("should detect removed rows (file 1 has more rows)", function()
            local a = tsv("name\tage\njohn\t30\njane\t25")
            local b = tsv("name\tage\njohn\t30")
            local identical, output, diffCount = tsv_diff.diff(a, b)
            assert.is_false(identical)
            assert.equals(1, diffCount)
            assert.truthy(output:find("%-"))
        end)

        it("should include context rows", function()
            local a = tsv("name\tval\na\t1\nb\t2\nc\t3\nd\t4\ne\t5")
            local b = tsv("name\tval\na\t1\nb\t2\nc\tX\nd\t4\ne\t5")
            local _, output = tsv_diff.diff(a, b, { context = 1 })
            -- Row 3 (c) changed, context=1 should show rows 2 and 4
            assert.truthy(output:find("row 2"))
            assert.truthy(output:find("row 3"))
            assert.truthy(output:find("row 4"))
        end)

        it("should show separator between non-adjacent context blocks", function()
            local a = tsv("name\tval\na\t1\nb\t2\nc\t3\nd\t4\ne\t5\nf\t6")
            local b = tsv("name\tval\na\tX\nb\t2\nc\t3\nd\t4\ne\t5\nf\tY")
            local _, output = tsv_diff.diff(a, b, { context = 0 })
            assert.truthy(output:find("%.%.%."))
        end)
    end)

    -- ================================================================
    -- PRIMARY-KEY-BASED MODE
    -- ================================================================

    describe("primary-key-based mode", function()
        it("should match rows by primary key", function()
            local a = tsv("name\tage\njohn\t30\njane\t25")
            local b = tsv("name\tage\njane\t25\njohn\t31")
            local identical, output, diffCount = tsv_diff.diff(a, b, { mode = "pk" })
            assert.is_false(identical)
            assert.equals(1, diffCount) -- john's age changed, jane matched
            assert.truthy(output:find("john"))
            assert.truthy(output:find("30"))
            assert.truthy(output:find("31"))
        end)

        it("should detect added rows by PK", function()
            local a = tsv("name\tage\njohn\t30")
            local b = tsv("name\tage\njohn\t30\njane\t25")
            local identical, output, diffCount = tsv_diff.diff(a, b, { mode = "pk" })
            assert.is_false(identical)
            assert.equals(1, diffCount)
            assert.truthy(output:find("%+"))
            assert.truthy(output:find("jane"))
        end)

        it("should detect removed rows by PK", function()
            local a = tsv("name\tage\njohn\t30\njane\t25")
            local b = tsv("name\tage\njohn\t30")
            local identical, output, diffCount = tsv_diff.diff(a, b, { mode = "pk" })
            assert.is_false(identical)
            assert.equals(1, diffCount)
            assert.truthy(output:find("%-"))
            assert.truthy(output:find("jane"))
        end)

        it("should report identical when rows are reordered but equal", function()
            local a = tsv("name\tage\njohn\t30\njane\t25")
            local b = tsv("name\tage\njane\t25\njohn\t30")
            local identical, _, diffCount = tsv_diff.diff(a, b, { mode = "pk" })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should error when PKs dont match and no mapping", function()
            local a = tsv("id\tval\n1\ta")
            local b = tsv("name\tval\njohn\ta")
            local result, err = tsv_diff.diff(a, b, { mode = "pk" })
            assert.is_nil(result)
            assert.truthy(err:find("primary key columns differ"))
        end)

        it("should work with mapped PK columns", function()
            local a = tsv("id\tval\n1\ta\n2\tb")
            local b = tsv("key\tval\n1\ta\n2\tX")
            local identical, output, diffCount = tsv_diff.diff(a, b, {
                mode = "pk",
                columnMap = { id = "key" },
            })
            assert.is_false(identical)
            assert.equals(1, diffCount)
            assert.truthy(output:find("val"))
        end)
    end)

    -- ================================================================
    -- COLUMN MAPPING
    -- ================================================================

    describe("column mapping", function()
        it("should map renamed columns", function()
            local a = tsv("name\told_score\njohn\t100")
            local b = tsv("name\tnew_score\njohn\t100")
            local identical, _, diffCount = tsv_diff.diff(a, b, {
                columnMap = { old_score = "new_score" },
            })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should detect differences on mapped columns", function()
            local a = tsv("name\told_score\njohn\t100")
            local b = tsv("name\tnew_score\njohn\t200")
            local identical, output, diffCount = tsv_diff.diff(a, b, {
                columnMap = { old_score = "new_score" },
            })
            assert.is_false(identical)
            assert.equals(1, diffCount)
            assert.truthy(output:find("100"))
            assert.truthy(output:find("200"))
        end)

        it("should show column mappings in report", function()
            local a = tsv("name\told_col\njohn\t1")
            local b = tsv("name\tnew_col\njohn\t1")
            local _, output = tsv_diff.diff(a, b, {
                columnMap = { old_col = "new_col" },
            })
            assert.truthy(output:find("Column mappings"))
            assert.truthy(output:find("old_col"))
            assert.truthy(output:find("new_col"))
        end)

        it("should support multiple mappings", function()
            local a = tsv("name\tcol_a\tcol_b\njohn\t1\t2")
            local b = tsv("name\tcol_x\tcol_y\njohn\t1\t2")
            local identical, _, diffCount = tsv_diff.diff(a, b, {
                columnMap = { col_a = "col_x", col_b = "col_y" },
            })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)
    end)

    -- ================================================================
    -- TRIM OPTION
    -- ================================================================

    describe("trim option", function()
        it("should ignore leading/trailing whitespace when trim is true", function()
            local a = tsv("name\tval\njohn\thello")
            local b = tsv("name\tval\njohn\t  hello  ")
            local identical, _, diffCount = tsv_diff.diff(a, b, { trim = true })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should detect whitespace differences when trim is false", function()
            local a = tsv("name\tval\njohn\thello")
            local b = tsv("name\tval\njohn\t  hello  ")
            local identical, _, diffCount = tsv_diff.diff(a, b)
            assert.is_false(identical)
            assert.equals(1, diffCount)
        end)
    end)

    -- ================================================================
    -- IGNORE-CASE OPTION
    -- ================================================================

    describe("ignore-case option", function()
        it("should ignore case when ignoreCase is true", function()
            local a = tsv("name\tval\njohn\tHello")
            local b = tsv("name\tval\njohn\thello")
            local identical, _, diffCount = tsv_diff.diff(a, b, { ignoreCase = true })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should detect case differences when ignoreCase is false", function()
            local a = tsv("name\tval\njohn\tHello")
            local b = tsv("name\tval\njohn\thello")
            local identical, _, diffCount = tsv_diff.diff(a, b)
            assert.is_false(identical)
            assert.equals(1, diffCount)
        end)
    end)

    -- ================================================================
    -- EPSILON OPTION
    -- ================================================================

    describe("epsilon option", function()
        it("should treat close numbers as equal with epsilon", function()
            local a = tsv("name\tval\njohn\t1.0000")
            local b = tsv("name\tval\njohn\t1.0001")
            local identical, _, diffCount = tsv_diff.diff(a, b, { epsilon = 0.001 })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should detect differences beyond epsilon", function()
            local a = tsv("name\tval\njohn\t1.0")
            local b = tsv("name\tval\njohn\t1.5")
            local identical, _, diffCount = tsv_diff.diff(a, b, { epsilon = 0.001 })
            assert.is_false(identical)
            assert.equals(1, diffCount)
        end)

        it("should not apply epsilon to non-numeric values", function()
            local a = tsv("name\tval\njohn\tabc")
            local b = tsv("name\tval\njohn\tabd")
            local identical, _, diffCount = tsv_diff.diff(a, b, { epsilon = 100 })
            assert.is_false(identical)
            assert.equals(1, diffCount)
        end)

        it("should handle integer values with epsilon", function()
            local a = tsv("name\tval\njohn\t100")
            local b = tsv("name\tval\njohn\t101")
            local identical, _, diffCount = tsv_diff.diff(a, b, { epsilon = 2 })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)
    end)

    -- ================================================================
    -- ONLY / EXCLUDE OPTIONS
    -- ================================================================

    describe("only option", function()
        it("should compare only specified columns", function()
            local a = tsv("name\tage\temail\njohn\t30\tjohn@x")
            local b = tsv("name\tage\temail\njohn\t31\tjohn@y")
            local identical, _, diffCount = tsv_diff.diff(a, b, {
                only = { name = true, age = true },
            })
            assert.is_false(identical)
            assert.equals(1, diffCount) -- age differs
        end)

        it("should ignore unselected columns", function()
            local a = tsv("name\tage\temail\njohn\t30\tjohn@x")
            local b = tsv("name\tage\temail\njohn\t30\tjohn@y")
            local identical, _, diffCount = tsv_diff.diff(a, b, {
                only = { name = true, age = true },
            })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)
    end)

    describe("exclude option", function()
        it("should exclude specified columns from comparison", function()
            local a = tsv("name\tage\ttimestamp\njohn\t30\t2024-01-01")
            local b = tsv("name\tage\ttimestamp\njohn\t30\t2024-06-15")
            local identical, _, diffCount = tsv_diff.diff(a, b, {
                exclude = { "timestamp" },
            })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should exclude columns from structural analysis too", function()
            local a = tsv("name\tage\njohn\t30")
            local b = tsv("name\tage\textra\njohn\t30\tx")
            local _, _, _, colInfo = tsv_diff.diff(a, b, {
                exclude = { "extra" },
            })
            assert.equals(0, #colInfo.addedCols)
        end)
    end)

    -- ================================================================
    -- MAX-DIFFS OPTION
    -- ================================================================

    describe("max-diffs option", function()
        it("should stop after maxDiffs differences", function()
            local a = tsv("name\tval\na\t1\nb\t2\nc\t3\nd\t4\ne\t5")
            local b = tsv("name\tval\na\tX\nb\tX\nc\tX\nd\tX\ne\tX")
            local _, output, diffCount = tsv_diff.diff(a, b, { maxDiffs = 2 })
            assert.equals(2, diffCount)
            assert.truthy(output:find("truncated"))
        end)
    end)

    -- ================================================================
    -- SUMMARY OPTION
    -- ================================================================

    describe("summary option", function()
        it("should suppress cell-level detail", function()
            local a = tsv("name\tval\njohn\t1")
            local b = tsv("name\tval\njohn\t2")
            local _, output = tsv_diff.diff(a, b, { summary = true })
            -- Should have the row marker but no cell-level "col: 'x' -> 'y'" detail
            assert.truthy(output:find("~"))
            assert.is_nil(output:find("val: '1' %-> '2'"))
        end)
    end)

    -- ================================================================
    -- QUIET OPTION
    -- ================================================================

    describe("quiet option", function()
        it("should suppress diff lines but show summary", function()
            local a = tsv("name\tval\njohn\t1")
            local b = tsv("name\tval\njohn\t2")
            local _, output = tsv_diff.diff(a, b, { quiet = true })
            assert.truthy(output:find("Summary"))
            assert.is_nil(output:find("row 1"))
        end)
    end)

    -- ================================================================
    -- ERROR HANDLING
    -- ================================================================

    describe("error handling", function()
        it("should error on empty file (no header)", function()
            local a = tsv("# only a comment")
            local b = tsv("name\tval\njohn\t1")
            local result, err = tsv_diff.diff(a, b)
            assert.is_nil(result)
            assert.truthy(err:find("no header"))
        end)

        it("should error on invalid mode", function()
            local a = tsv("name\tval\njohn\t1")
            assert.has_error(function()
                tsv_diff.diff(a, a, { mode = "invalid" })
            end)
        end)

        it("should error on non-existent file", function()
            local a = tsv("name\tval\njohn\t1")
            local result, err = tsv_diff.diff("/no/such/file.tsv", a)
            assert.is_nil(result)
            assert.truthy(err:find("Error reading file 1"))
        end)
    end)

    -- ================================================================
    -- EDGE CASES
    -- ================================================================

    describe("edge cases", function()
        it("should handle missing cells (shorter rows)", function()
            local a = tsv("name\tage\temail\njohn\t30\tjohn@x")
            local b = tsv("name\tage\temail\njohn\t30")
            local identical, output, diffCount = tsv_diff.diff(a, b)
            assert.is_false(identical)
            assert.equals(1, diffCount)
            assert.truthy(output:find("email"))
        end)

        it("should handle columns in different order with same data", function()
            -- Columns reordered but same values
            local a = tsv("name\ta\tb\njohn\t1\t2\njane\t3\t4")
            local b = tsv("name\tb\ta\njohn\t2\t1\njane\t4\t3")
            local identical, _, diffCount = tsv_diff.diff(a, b)
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should handle one common column only (the PK)", function()
            local a = tsv("name\tcol1\njohn\t1")
            local b = tsv("name\tcol2\njohn\t2")
            local _, _, diffCount, colInfo = tsv_diff.diff(a, b)
            assert.equals(1, #colInfo.commonCols) -- only "name"
            assert.equals(0, diffCount) -- PK matches, no other common cols to diff
        end)

        it("should combine trim and ignore-case", function()
            local a = tsv("name\tval\njohn\t  Hello  ")
            local b = tsv("name\tval\njohn\thello")
            local identical, _, diffCount = tsv_diff.diff(a, b, {
                trim = true,
                ignoreCase = true,
            })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should combine epsilon with trim", function()
            local a = tsv("name\tval\njohn\t 1.0000 ")
            local b = tsv("name\tval\njohn\t1.0001")
            local identical, _, diffCount = tsv_diff.diff(a, b, {
                trim = true,
                epsilon = 0.001,
            })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)
    end)

    -- ================================================================
    -- OUTPUT FORMAT
    -- ================================================================

    describe("output format", function()
        it("should show unified-diff style header", function()
            local a = tsv("name\tval\njohn\t1")
            local b = tsv("name\tval\njohn\t2")
            local _, output = tsv_diff.diff(a, b)
            assert.truthy(output:find("--- file1"))
            assert.truthy(output:find("%+%+%+ file2"))
        end)

        it("should use ~ for changed rows in order mode", function()
            local a = tsv("name\tval\njohn\t1")
            local b = tsv("name\tval\njohn\t2")
            local _, output = tsv_diff.diff(a, b)
            assert.truthy(output:find("~ row 1"))
        end)

        it("should show PK in brackets for pk mode", function()
            local a = tsv("name\tval\njohn\t1")
            local b = tsv("name\tval\njohn\t2")
            local _, output = tsv_diff.diff(a, b, { mode = "pk" })
            assert.truthy(output:find("%[john%]"))
        end)

        it("should show pk mode summary breakdown", function()
            local a = tsv("name\tval\njohn\t1\njane\t2")
            local b = tsv("name\tval\njohn\t9\nbob\t3")
            local _, output = tsv_diff.diff(a, b, { mode = "pk" })
            assert.truthy(output:find("Rows changed: 1"))
            assert.truthy(output:find("Rows added: 1"))
            assert.truthy(output:find("Rows removed: 1"))
        end)
    end)

    -- ================================================================
    -- TYPED COLUMN HEADERS (name:type[:default])
    -- ================================================================

    describe("typed column headers", function()
        it("should handle name:type headers in both files", function()
            local a = tsv("name:string\tage:integer\njohn\t30\njane\t25")
            local b = tsv("name:string\tage:integer\njohn\t30\njane\t25")
            local identical, _, diffCount = tsv_diff.diff(a, b)
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should detect differences with typed headers", function()
            local a = tsv("name:string\tage:integer\njohn\t30")
            local b = tsv("name:string\tage:integer\njohn\t31")
            local identical, _, diffCount = tsv_diff.diff(a, b)
            assert.is_false(identical)
            assert.equals(1, diffCount)
        end)

        it("should match columns by full typed header", function()
            -- Columns reordered but same typed headers
            local a = tsv("name:string\tage:integer\tscore:float\njohn\t30\t9.5")
            local b = tsv("name:string\tscore:float\tage:integer\njohn\t9.5\t30")
            local identical, _, diffCount = tsv_diff.diff(a, b)
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should detect type changes as column add/remove", function()
            -- Same name but different type = different column header string
            local a = tsv("name:string\tval:integer\njohn\t30")
            local b = tsv("name:string\tval:float\njohn\t30")
            local _, _, _, colInfo = tsv_diff.diff(a, b)
            assert.equals(1, #colInfo.commonCols) -- only "name:string"
            assert.equals(1, #colInfo.addedCols)   -- "val:float"
            assert.equals(1, #colInfo.removedCols)  -- "val:integer"
        end)

        it("should map typed columns with / separator", function()
            local a = tsv("name:string\told_score:integer\njohn\t100")
            local b = tsv("name:string\tnew_score:integer\njohn\t100")
            local identical, _, diffCount = tsv_diff.diff(a, b, {
                columnMap = { ["old_score:integer"] = "new_score:integer" },
            })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should map columns with type change via /", function()
            local a = tsv("name:string\tval:integer\njohn\t100")
            local b = tsv("name:string\tval:float\njohn\t100")
            local identical, _, diffCount = tsv_diff.diff(a, b, {
                columnMap = { ["val:integer"] = "val:float" },
            })
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should handle name:type:default headers", function()
            local a = tsv("name:string\tval:integer:0\njohn\t30")
            local b = tsv("name:string\tval:integer:0\njohn\t30")
            local identical, _, diffCount = tsv_diff.diff(a, b)
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should work in pk mode with typed PK column", function()
            local a = tsv("name:name\tage:integer\njohn\t30\njane\t25")
            local b = tsv("name:name\tage:integer\njane\t25\njohn\t31")
            local identical, _, diffCount = tsv_diff.diff(a, b, { mode = "pk" })
            assert.is_false(identical)
            assert.equals(1, diffCount) -- john's age changed
        end)

        it("should map typed PK columns in pk mode", function()
            local a = tsv("id:integer\tval:string\n1\ta\n2\tb")
            local b = tsv("key:integer\tval:string\n1\ta\n2\tX")
            local identical, _, diffCount = tsv_diff.diff(a, b, {
                mode = "pk",
                columnMap = { ["id:integer"] = "key:integer" },
            })
            assert.is_false(identical)
            assert.equals(1, diffCount)
        end)
    end)
end)
