-- tsv_diff_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local raw_tsv = require("tsv.raw_tsv")
local tsv_diff = require("tsv_diff")
local file_util = require("infra.file_util")
local compression = require("content.compression")

--- Helper: build a raw TSV from a multi-line string.
local function tsv(s)
    return raw_tsv.stringToRawTSV(s)
end

--- Helper: creates a fresh, unique temporary directory and returns its path.
local function mkTempDir()
    local td = file_util.pathJoin(file_util.getSystemTempDir(),
        "tsvdifftest_" .. tostring(os.time()) .. "_" .. tostring(math.random(1000000)))
    assert(file_util.mkdir(td))
    return td
end

--- Helper: writes `content` as a plain file at `dir/rel`, creating parents.
local function writeAt(dir, rel, content)
    local path = file_util.pathJoin(dir, rel)
    assert(file_util.mkdir(file_util.getParentPath(path)))
    assert(file_util.writeFile(path, content))
    return path
end

--- Helper: writes `content` gzip-compressed as a binary file at `dir/rel`.
local function writeGzAt(dir, rel, content)
    local path = file_util.pathJoin(dir, rel)
    assert(file_util.mkdir(file_util.getParentPath(path)))
    local gz = assert(compression.compress("gzip", content))
    assert(file_util.writeFileBinary(path, gz))
    return path
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

    -- ================================================================
    -- COMPRESSED FILES (gzip)
    -- ================================================================

    describe("compressed files", function()
        local dir = ""
        before_each(function() dir = mkTempDir() end)
        after_each(function()
            if dir ~= "" then file_util.deleteTempDir(dir); dir = "" end
        end)

        it("should compare two gzipped files by uncompressed content", function()
            local p1 = writeGzAt(dir, "a.tsv.gz", "name\tval\njohn\t1")
            local p2 = writeGzAt(dir, "b.tsv.gz", "name\tval\njohn\t2")
            local identical, output, diffCount = tsv_diff.diff(p1, p2)
            assert.is_false(identical)
            assert.equals(1, diffCount)
            assert.truthy(output:find("1"))
            assert.truthy(output:find("2"))
        end)

        it("should report identical gzipped files as identical", function()
            local p1 = writeGzAt(dir, "a.tsv.gz", "name\tval\njohn\t1\njane\t2")
            local p2 = writeGzAt(dir, "b.tsv.gz", "name\tval\njohn\t1\njane\t2")
            local identical, _, diffCount = tsv_diff.diff(p1, p2)
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)

        it("should compare a gzipped file against a plain file", function()
            local p1 = writeAt(dir, "plain.tsv", "name\tval\njohn\t1")
            local p2 = writeGzAt(dir, "comp.tsv.gz", "name\tval\njohn\t9")
            local identical, _, diffCount = tsv_diff.diff(p1, p2)
            assert.is_false(identical)
            assert.equals(1, diffCount)
        end)

        it("should decompress a gzip file even without a .gz extension (magic)", function()
            -- Write gzip bytes under a plain .tsv name: sniffed via magic bytes.
            local gz = assert(compression.compress("gzip", "name\tval\njohn\t1"))
            local p1 = file_util.pathJoin(dir, "magic.tsv")
            assert(file_util.writeFileBinary(p1, gz))
            local p2 = writeAt(dir, "plain.tsv", "name\tval\njohn\t1")
            local identical, _, diffCount = tsv_diff.diff(p1, p2)
            assert.is_true(identical)
            assert.equals(0, diffCount)
        end)
    end)

    -- ================================================================
    -- DIRECTORY MODE
    -- ================================================================

    describe("directory mode", function()
        local dir1, dir2 = "", ""
        before_each(function() dir1 = mkTempDir(); dir2 = mkTempDir() end)
        after_each(function()
            if dir1 ~= "" then file_util.deleteTempDir(dir1); dir1 = "" end
            if dir2 ~= "" then file_util.deleteTempDir(dir2); dir2 = "" end
        end)

        it("should report identical directories as identical", function()
            writeAt(dir1, "a.tsv", "name\tval\njohn\t1")
            writeAt(dir1, "sub/b.tsv", "id\tx\n1\t2")
            writeAt(dir2, "a.tsv", "name\tval\njohn\t1")
            writeAt(dir2, "sub/b.tsv", "id\tx\n1\t2")
            local identical, output, stats = tsv_diff.diff(dir1, dir2)
            assert.is_true(identical)
            assert.equals(2, stats.compared)
            assert.equals(0, stats.differing)
            assert.truthy(output:find("Directories are identical"))
        end)

        it("should detect a file that differs between the trees", function()
            writeAt(dir1, "a.tsv", "name\tval\njohn\t1")
            writeAt(dir2, "a.tsv", "name\tval\njohn\t2")
            local identical, output, stats = tsv_diff.diff(dir1, dir2)
            assert.is_false(identical)
            assert.equals(1, stats.differing)
            assert.truthy(output:find("~ a.tsv"))
            -- the per-file diff is inlined
            assert.truthy(output:find("1"))
            assert.truthy(output:find("2"))
        end)

        it("should recurse into subdirectories", function()
            writeAt(dir1, "deep/nested/x.tsv", "id\tv\n1\ta")
            writeAt(dir2, "deep/nested/x.tsv", "id\tv\n1\tb")
            local identical, output, stats = tsv_diff.diff(dir1, dir2)
            assert.is_false(identical)
            assert.equals(1, stats.differing)
            assert.truthy(output:find("deep/nested/x.tsv"))
        end)

        it("should report files only in the left tree as removed", function()
            writeAt(dir1, "only1.tsv", "id\tv\n1\ta")
            writeAt(dir1, "shared.tsv", "id\tv\n1\ta")
            writeAt(dir2, "shared.tsv", "id\tv\n1\ta")
            local identical, output, stats = tsv_diff.diff(dir1, dir2)
            assert.is_false(identical)
            assert.equals(1, stats.only1)
            assert.equals(0, stats.only2)
            assert.truthy(output:find("- only1.tsv"))
        end)

        it("should report files only in the right tree as added", function()
            writeAt(dir1, "shared.tsv", "id\tv\n1\ta")
            writeAt(dir2, "shared.tsv", "id\tv\n1\ta")
            writeAt(dir2, "only2.tsv", "id\tv\n1\ta")
            local _, output, stats = tsv_diff.diff(dir1, dir2)
            assert.equals(1, stats.only2)
            assert.truthy(output:find("%+ only2.tsv"))
        end)

        it("should pair a plain file with its gzipped counterpart", function()
            -- Same logical path, one plain and one gzipped, identical content.
            writeAt(dir1, "data/Item.tsv", "id\tv\n1\ta")
            writeGzAt(dir2, "data/Item.tsv.gz", "id\tv\n1\ta")
            local identical, _, stats = tsv_diff.diff(dir1, dir2)
            assert.is_true(identical)
            assert.equals(1, stats.compared)
            assert.equals(0, stats.only1)
            assert.equals(0, stats.only2)
        end)

        it("should diff a plain file against a differing gzipped counterpart", function()
            writeAt(dir1, "data/Item.tsv", "id\tv\n1\ta")
            writeGzAt(dir2, "data/Item.tsv.gz", "id\tv\n1\tZ")
            local identical, _, stats = tsv_diff.diff(dir1, dir2)
            assert.is_false(identical)
            assert.equals(1, stats.compared)
            assert.equals(1, stats.differing)
        end)

        it("should ignore non-TSV files in the trees", function()
            writeAt(dir1, "a.tsv", "id\tv\n1\ta")
            writeAt(dir1, "notes.txt", "ignore me")
            writeAt(dir2, "a.tsv", "id\tv\n1\ta")
            writeAt(dir2, "readme.md", "ignore me too")
            local identical, _, stats = tsv_diff.diff(dir1, dir2)
            assert.is_true(identical)
            assert.equals(1, stats.compared)
        end)

        it("should pass options through to per-file comparison", function()
            writeAt(dir1, "a.tsv", "name\tval\njohn\thello")
            writeAt(dir2, "a.tsv", "name\tval\njohn\t  hello  ")
            local identical = tsv_diff.diff(dir1, dir2, { trim = true })
            assert.is_true(identical)
        end)

        it("should suppress inline diff bodies under --summary", function()
            writeAt(dir1, "a.tsv", "name\tval\njohn\t1")
            writeAt(dir2, "a.tsv", "name\tval\njohn\t2")
            local _, output = tsv_diff.diff(dir1, dir2, { summary = true })
            assert.truthy(output:find("~ a.tsv"))
            -- the per-file cell detail must not be inlined
            assert.is_nil(output:find("val: '1' %-> '2'"))
        end)

        it("should be callable directly via diffDirectories", function()
            writeAt(dir1, "a.tsv", "id\tv\n1\ta")
            writeAt(dir2, "a.tsv", "id\tv\n1\ta")
            local identical, _, stats = tsv_diff.diffDirectories(dir1, dir2)
            assert.is_true(identical)
            assert.equals(1, stats.compared)
        end)
    end)
end)
