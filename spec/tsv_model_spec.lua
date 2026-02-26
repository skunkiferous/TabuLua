-- tsv_model_spec.lua

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each

local tsv_model = require("tsv_model")
local error_reporting = require("error_reporting")
local parsers = require("parsers")

local canProcessCell = tsv_model.internal.canProcessCell
local isExpression = tsv_model.isExpression

-- Returns a "badVal" object that store errors in the given table
local function mockBadVal(log_messages)
    local log = function(self, msg) table.insert(log_messages, msg) end
    local badVal = error_reporting.badValGen(log)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

-- Simple options extractor that just returns the name
local function mockOptionsExtractor(name, options)
    return name
end

-- Simple parser finder that supports basic types
local function mockParserFinder(badVal, type_spec)
    if type_spec == "string" then
        return function(badVal, value) return tostring(value), tostring(value) end
    elseif type_spec == "number" then
        return function(badVal, value)
            local num = tonumber(value)
            if num then return num, tostring(value) end
            return nil, tostring(value)
        end
    elseif type_spec == "boolean" then
        return function(badVal, value)
            if value == "true" or value == true then return true, tostring(value) end
            if value == "false" or value == false then return false, tostring(value) end
            return nil, tostring(value)
        end
    end
    return nil
end

describe("tsv_model", function()
    describe("processTSV", function()
        it("should process simple TSV data", function()
            local raw_tsv = {
                {"name:string", "age:number", "active:boolean"},
                {"Alice", "25", "true"},
                {"Bob", "30", "false"}
            }
            
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil, -- no expression evaluation
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            assert.equals("name:string", dataset[1][1].value)
            assert.equals("age:number", dataset[1][2].evaluated)
            assert.equals("active:boolean", dataset[1][3].parsed)
            assert.equals("name:string", dataset[1][1].reformatted)
            assert.equals("age:number", tostring(dataset[1][2]))
            assert.equals("boolean", dataset[1][3].type_spec)
            assert.equals("Alice", dataset[2][1].value)
            assert.equals('25', dataset[2][2].evaluated) -- No expression, so evaluated==value
            assert.equals(25, dataset[2][2].parsed)
            assert.equals('25', dataset[2][2].reformatted)
            assert.equals('true', dataset[2][3].evaluated) -- No expression, so evaluated==value
            assert.equals(true, dataset[2][3].parsed)
            assert.equals('true', dataset[2][3].reformatted)
            assert.equals(30, dataset["Bob"][2].parsed)
            assert.equals('{active:boolean,age:number,name:string}', dataset[1].__type_spec)
        end)

        it("should handle expressions", function()
            local raw_tsv = {
                {"name:string", "value:number", "double:number"},
                {"Item1", "10", "=self[2] * 2"},
                {"Item2", "20", "=self.value * 2"}
            }
            
            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                expr_eval,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            assert.equals("=self[2] * 2", dataset[2][3].value)
            assert.equals(20, dataset[2][3].evaluated)
            assert.equals(20, dataset[2][3].parsed)
            assert.equals('=self[2] * 2', dataset[2][3].reformatted)
            assert.equals("=self.value * 2", dataset[3][3].value)
            assert.equals(40, dataset[3][3].evaluated)
            assert.equals(40, dataset[3][3].parsed)
            assert.equals('=self.value * 2', dataset[3][3].reformatted)
        end)

        it("should handle comments and blank lines", function()
            local raw_tsv = {
                {"name:string", "value:number"},
                "# Comment line",
                {"Item1", "10"},
                "",
                {"Item2", "20"}
            }
            
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.equals("# Comment line", dataset[2])
            assert.equals("", dataset[4])
            assert.equals("Item1", dataset[3][1].value)
            assert.equals("Item2", dataset[5][1].value)
        end)

        it("should detect duplicate column names", function()
            local raw_tsv = {
                {"name:string", "value:number", "name:string"},
                {"Item1", "10", "test"}
            }
            
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_nil(dataset)
            assert.equals(1, #log_messages)
            assert.equals("Bad type_spec name, col 3 in test.tsv on line 1: 'name' (Duplicate column name!)", log_messages[1])
        end)

        it("should detect duplicate primary keys", function()
            local raw_tsv = {
                {"id:string", "value:number"},
                {"Item1", "10"},
                {"Item1", "20"}
            }
            
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.equals(1, #log_messages)
            assert.equals("Bad string id, col 1 in test.tsv on line 3 (Item1): 'Item1' (Duplicate primary key!)", log_messages[1])
        end)

        it("should support row access by primary key and column name", function()
            local raw_tsv = {
                {"id:string", "value:number"},
                {"Item1", "10"},
                {"Item2", "20"}
            }
            
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                mockBadVal({})
            )

            assert.equals(10, dataset("Item1", "value").parsed)
            assert.equals(20, dataset("Item2", 2).parsed)
            
            local row = dataset("Item1")
            assert.equals("Item1", row.id.value)
            assert.equals(10, row.value.parsed)
        end)
    end)

    describe("defaultOptionsExtractor", function()
        it("should handle published columns", function()
            local options = {}
            local name = tsv_model.defaultOptionsExtractor("column!", options)
            assert.equals("column", name)
            assert.is_true(options.published)
        end)

        it("should handle normal columns", function()
            local options = {}
            local name = tsv_model.defaultOptionsExtractor("column", options)
            assert.equals("column", name)
            assert.is_nil(options.published)
        end)
    end)

    describe("expressionEvaluatorGenerator", function()
        it("should evaluate expressions with context", function()
            local env = {base = 10}
            local eval = tsv_model.expressionEvaluatorGenerator(env, error_reporting.nullLogger)
            
            local context = {value = 5}
            local result = eval(context, "=self.value + base")
            assert.equals(15, result)
        end)

        it("should handle non-expressions", function()
            local eval = tsv_model.expressionEvaluatorGenerator({}, error_reporting.nullLogger)
            
            local result = eval({}, "normal value")
            assert.equals("normal value", result)
        end)

        it("should handle evaluation errors", function()
            local eval = tsv_model.expressionEvaluatorGenerator({}, error_reporting.nullLogger)
            
            local result, error = eval({}, "=invalid + syntax")
            assert.is_nil(result)
            assert.is_not_nil(error)
        end)
    end)

    describe("transpose", function()
        it("should process simple TSV data", function()
            local transposed_raw_tsv = {
                {"name:string", "Alice", "Bob"},
                {"age:number", "25", "30"},
                {"active:boolean", "true", "false"}
            }
            
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil, -- no expression evaluation
                mockParserFinder,
                "test.tsv",
                transposed_raw_tsv,
                badVal,
                nil,
                true -- transpose
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            assert.equals("Alice", dataset[2][1].value)
            assert.equals(25, dataset[2][2].parsed)
            assert.equals(true, dataset[2][3].parsed)
            assert.equals(30, dataset["Bob"][2].parsed)
        end)

        it("should trigger based on source name", function()
            local transposed_raw_tsv = {
                {"name:string", "Alice", "Bob"},
                {"age:number", "25", "30"},
                {"active:boolean", "true", "false"}
            }
            
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil, -- no expression evaluation
                mockParserFinder,
                "test.transposed.tsv",
                transposed_raw_tsv,
                badVal,
                nil,
                false -- let transpose be set automatically
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            assert.equals("Alice", dataset[2][1].value)
            assert.equals(25, dataset[2][2].parsed)
            assert.equals(true, dataset[2][3].parsed)
            assert.equals(30, dataset["Bob"][2].parsed)
        end)

        it("should handle tables with comments and blank lines", function()
            local transposed_raw_tsv = {
                { "a", "b", "c" },
                "# Comment line",
                "",
                { "d", "e", "f" }
            }
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil, -- no expression evaluation
                mockParserFinder,
                "test.tsv",
                transposed_raw_tsv,
                badVal,
                nil,
                true -- transpose
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)

            assert.equals("a:string", dataset[1][1].value)
            assert.equals("__comment1:comment", dataset[1][2].value)
            assert.equals("__comment2:comment", dataset[1][3].value)
            assert.equals("d:string", dataset[1][4].value)

            assert.equals("b", dataset[2][1].value)
            assert.equals("# Comment line", dataset[2][2].value)
            assert.equals("", dataset[2][3].value)
            assert.equals("e", dataset[2][4].value)
        end)

        it("should produce transposed output from tostring", function()
            local transposed_raw_tsv = {
                {"name:string", "Alice", "Bob"},
                {"age:number", "25", "30"},
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.transposed.tsv",
                transposed_raw_tsv,
                badVal,
                nil,
                false -- let transpose be set automatically from filename
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)

            -- tostring should produce transposed output (one field per line)
            local output = tostring(dataset)
            -- The output should have field:type\tvalue per line (transposed format)
            local lines = {}
            for line in output:gmatch("[^\n]+") do
                lines[#lines+1] = line
            end
            -- Should have 2 field rows (name and age), each with 2 data columns
            assert.equals(2, #lines)
            assert.is_truthy(lines[1]:find("^name:string\t"))
            assert.is_truthy(lines[2]:find("^age:number\t"))
        end)

        it("should produce non-transposed output for normal files", function()
            local raw_tsv = {
                {"name:string", "age:number"},
                {"Alice", "25"},
                {"Bob", "30"},
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal,
                nil,
                false
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)

            local output = tostring(dataset)
            local lines = {}
            for line in output:gmatch("[^\n]+") do
                lines[#lines+1] = line
            end
            -- Should have 3 rows: header + 2 data rows (non-transposed)
            assert.equals(3, #lines)
            assert.is_truthy(lines[1]:find("^name:string\t"))
            assert.is_truthy(lines[2]:find("^Alice\t"))
        end)

        it("should preserve comments in transposed output", function()
            -- Transposed file with a comment line becomes a __comment placeholder column
            local transposed_with_comment = {
                "# This is a comment",  -- Comment line (string, not table)
                {"name:string", "TestValue"},
                {"level:number", "42"},
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.transposed.tsv",
                transposed_with_comment,
                badVal,
                nil,
                true  -- transpose
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)

            -- Verify the dataset has 3 columns after transpose: __comment1, name, level
            local header = dataset[1]
            assert.equals(3, #header)
            assert.equals("__comment1", header[1].name)
            assert.equals("comment", header[1].type_spec)
            assert.equals("name", header[2].name)
            assert.equals("level", header[3].name)

            -- tostring should produce transposed output with comment preserved
            local output = tostring(dataset)
            local lines = {}
            for line in output:gmatch("[^\n]+") do
                lines[#lines+1] = line
            end
            -- Should have 3 lines: comment, name field, level field
            assert.equals(3, #lines)
            assert.equals("# This is a comment", lines[1])
            assert.is_truthy(lines[2]:find("^name:string\t"))
            assert.is_truthy(lines[3]:find("^level:number\t"))
        end)

        it("should process report original row/col on error", function()
            local transposed_raw_tsv = {
                {"name:string", "Alice", "Bob"},
                {"age:number", "25", "abc"},
            }
            
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil, -- no expression evaluation
                parsers.parseType,
                "test.tsv",
                transposed_raw_tsv,
                badVal,
                nil,
                true -- transpose
            )

            assert.is_not_nil(dataset)
            assert.equals(1, #log_messages)
            assert.equals("Bad number age, col 3 in test.tsv on line 2 (Bob): 'abc'", log_messages[1])
        end)
    end)

    describe("table_subscribers", function()
        it("should work globally", function()
            local raw_tsv = {
                {"name:string", "value:number", "double:number"},
                {"Item1", "10", "=self[2] * 2"},
                {"Item2", "20", "=self.value * 2"}
            }
            
            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            
            local published = {}

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                expr_eval,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal,
                function(col, row, cell)
                    local col_idx = col.idx
                    local row_idx = row.__idx
                    if not published[row_idx] then
                        published[row_idx] = {}
                    end
                    published[row_idx][col_idx] = cell.reformatted
                end
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            assert.equals('10', published[2][2])
            assert.equals('=self[2] * 2', published[2][3])
            assert.equals('20', published[3][2])
            assert.equals('=self.value * 2', published[3][3])
        end)

        it("should work for individual columns", function()
            local raw_tsv = {
                {"name:string", "value:number", "double:number"},
                {"Item1", "10", "=self[2] * 2"},
                {"Item2", "20", "=self.value * 2"}
            }
            
            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            
            local published = {}
            local function subscriber(col, row, cell)
                local col_idx = col.idx
                local row_idx = row.__idx
                if not published[row_idx] then
                    published[row_idx] = {}
                end
                published[row_idx][col_idx] = cell.reformatted
            end

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                expr_eval,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal,
                {value=subscriber}
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            assert.equals('10', published[2][2])
            assert.is_nil(published[2][3])
            assert.equals('20', published[3][2])
            assert.is_nil(published[3][3])
        end)
    end)

    describe("canProcessCell", function()
        local header = {
            name = {idx = 1},
            value = {idx = 2},
            result = {idx = 3},
            volume = {idx = 4},
            mass = {idx = 5},
        }

        local done_idx = {[1] = true, [2] = true, [4] = true}

        it("should return true for non-expressions", function()
            assert.is_true(canProcessCell(header, done_idx, "hello"))
            assert.is_true(canProcessCell(header, done_idx, 123))
            assert.is_true(canProcessCell(header, done_idx, nil))
        end)

        it("should return true for expressions without self references", function()
            assert.is_true(canProcessCell(header, done_idx, "=1+2"))
            assert.is_true(canProcessCell(header, done_idx, "=Organic.Wood.density"))
        end)

        it("should return true when all referenced columns are processed", function()
            assert.is_true(canProcessCell(header, done_idx, "=self.name + self[2]"))
            assert.is_true(canProcessCell(header, done_idx, "=self['name'] + self.value"))
            assert.is_true(canProcessCell(header, done_idx, "=self.volume*Organic.Wood.density"))
        end)

        it("should return false when referenced columns are not processed", function()
            assert.is_false(canProcessCell(header, done_idx, "=self.result * 2"))
            assert.is_false(canProcessCell(header, done_idx, "=self.mass + self.volume"))
            assert.is_false(canProcessCell(header, done_idx, "=self[3] + self[5]"))
        end)

        it("should correctly handle complex expressions with multiple references", function()
            assert.is_true(canProcessCell(header, done_idx, "=self.volume + (self.name or self.value)"))
            assert.is_false(canProcessCell(header, done_idx, "=self.volume + (self.mass or self.result)"))
        end)

        it("should handle expressions that mix self references with other identifiers", function()
            -- This was the problematic case that was fixed
            assert.is_true(canProcessCell(header, done_idx, "=self.volume*Organic.Wood.density"))
            assert.is_true(canProcessCell(header, done_idx, "=self.volume*CONSTANTS.pi"))
            assert.is_false(canProcessCell(header, done_idx, "=self.mass*Organic.Wood.density"))
        end)

        it("should ignore self references inside string literals", function()
            -- "self" inside a string literal should NOT be treated as a column reference
            -- mass (idx 5) is NOT in done_idx, so if detected it would return false
            assert.is_true(canProcessCell(header, done_idx, [[="self.mass"]]))
            assert.is_true(canProcessCell(header, done_idx, [[='self.mass']]))
            assert.is_true(canProcessCell(header, done_idx, [[="The self.mass value"]]))

            -- Mixed case: string literal with self + actual self reference to processed column
            assert.is_true(canProcessCell(header, done_idx, [[="self.mass:" .. self.value]]))

            -- Mixed case: string literal with self + actual self reference to unprocessed column
            assert.is_false(canProcessCell(header, done_idx, [[="self.value:" .. self.mass]]))
        end)
    end)

    describe("isExpression", function()
        it("should return true for strings starting with '='", function()
            assert.is_true(isExpression("=1+2"))
            assert.is_true(isExpression("=self.value"))
            assert.is_true(isExpression("="))
            assert.is_true(isExpression("=hello world"))
        end)

        it("should return false for strings not starting with '='", function()
            assert.is_false(isExpression("hello"))
            assert.is_false(isExpression(""))
            assert.is_false(isExpression(" =1+2"))
            assert.is_false(isExpression("1+2=3"))
        end)

        it("should return false for non-string values", function()
            assert.is_false(isExpression(nil))
            assert.is_false(isExpression(123))
            assert.is_false(isExpression(true))
            assert.is_false(isExpression({}))
            assert.is_false(isExpression(function() end))
        end)
    end)

    describe("circular expression dependencies", function()
        it("should fail with assertion error on circular dependencies", function()
            -- All columns are expressions forming a cycle, so none can be processed
            local raw_tsv = {
                {"a:number", "b:number"},
                {"=self.b + 1", "=self.a + 1"}
            }

            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            -- Circular dependency: a depends on b, b depends on a
            -- This should trigger the assertion in processTSV
            assert.has_error(function()
                tsv_model.processTSV(
                    mockOptionsExtractor,
                    expr_eval,
                    mockParserFinder,
                    "test.tsv",
                    raw_tsv,
                    badVal
                )
            end)
        end)

        it("should fail on three-way circular dependencies", function()
            -- All columns are expressions forming a 3-way cycle
            local raw_tsv = {
                {"a:number", "b:number", "c:number"},
                {"=self.c + 1", "=self.a + 1", "=self.b + 1"}
            }

            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            assert.has_error(function()
                tsv_model.processTSV(
                    mockOptionsExtractor,
                    expr_eval,
                    mockParserFinder,
                    "test.tsv",
                    raw_tsv,
                    badVal
                )
            end)
        end)

        it("should handle self-referential expressions as circular", function()
            -- A single column that references itself
            local raw_tsv = {
                {"value:number"},
                {"=self.value + 1"}
            }

            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            -- A column referencing itself is a circular dependency
            assert.has_error(function()
                tsv_model.processTSV(
                    mockOptionsExtractor,
                    expr_eval,
                    mockParserFinder,
                    "test.tsv",
                    raw_tsv,
                    badVal
                )
            end)
        end)
    end)

    describe("very long expressions", function()
        it("should fail when expression exceeds operation quota", function()
            -- Create an expression that will exceed EXPRESSION_MAX_OPERATIONS (10000)
            -- A simple way is to create a deeply nested or looping computation
            local raw_tsv = {
                {"name:string", "value:number"},
                -- This expression creates a very long loop that exceeds the quota
                {"Item1", "=(function() local s=0; for i=1,100000 do s=s+i end; return s end)()"}
            }

            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                expr_eval,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            -- The dataset is returned but with an error logged
            assert.is_not_nil(dataset)
            assert.equals(1, #log_messages)
            -- The error message should mention quota exceeded (case-insensitive check)
            assert.is_truthy(log_messages[1]:lower():match("quota"))
        end)

        it("should handle expressions just under the quota", function()
            -- Create an expression that stays under the quota
            local raw_tsv = {
                {"name:string", "value:number"},
                -- A simpler expression that won't exceed the quota
                {"Item1", "=(function() local s=0; for i=1,100 do s=s+i end; return s end)()"}
            }

            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                expr_eval,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            -- Sum of 1 to 100 = 5050
            assert.equals(5050, dataset[2][2].parsed)
        end)
    end)

    describe("default values", function()
        it("should apply literal default to empty cells", function()
            local raw_tsv = {
                {"name:string", "status:string:Unknown"},
                {"Item1", ""},       -- empty -> Unknown
                {"Item2", "Active"}  -- has value -> Active
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            assert.equals("Unknown", dataset[2][2].parsed)
            assert.equals("Active", dataset[3][2].parsed)
        end)

        it("should apply default expression to empty cells", function()
            local raw_tsv = {
                {"name:string", "value:number", "computed:number:=self.value*2"},
                {"Item1", "10", ""},      -- empty cell should get default
                {"Item2", "20", "15"}     -- cell with value should keep it
            }

            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                expr_eval,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            -- Item1: empty cell gets default =self.value*2 => 10*2 = 20
            assert.equals(20, dataset[2][3].parsed)
            -- Item2: cell with value keeps its value
            assert.equals(15, dataset[3][3].parsed)
        end)

        it("should parse complex type specs with default", function()
            -- Type spec contains colons: {a:number,b:string}
            local raw_tsv = {
                {"name:string", "data:{a:number,b:string}:={a=0,b=''}"},
                {"Item1", ""}
            }

            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                expr_eval,
                parsers.parseType,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            assert.equals(0, dataset[2][2].parsed.a)
            assert.equals('', dataset[2][2].parsed.b)
        end)

        it("should handle column with trailing colon but no default", function()
            local raw_tsv = {
                {"name:string", "value:number:"},  -- trailing colon, no default
                {"Item1", "10"}
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            assert.is_nil(dataset[1][2].default_expr)
        end)

        it("should preserve default expression in column string representation", function()
            local raw_tsv = {
                {"name:string", "value:number:=100"},
                {"Item1", ""}
            }

            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                expr_eval,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            -- Check column tostring includes default
            assert.equals("value:number:=100", tostring(dataset[1][2]))
            -- Check column value/reformatted includes default
            assert.equals("value:number:=100", dataset[1][2].value)
        end)

        it("should work with dependencies on other columns", function()
            local raw_tsv = {
                {"a:number", "b:number:=self.a+1", "c:number:=self.b+1"},
                {"10", "", ""}
            }

            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                expr_eval,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            assert.equals(10, dataset[2][1].parsed)
            assert.equals(11, dataset[2][2].parsed)  -- a+1
            assert.equals(12, dataset[2][3].parsed)  -- b+1
        end)

        it("should not apply default if cell has whitespace-only value", function()
            local raw_tsv = {
                {"name:string", "status:string:Default"},
                {"Item1", "   "},  -- whitespace-only is NOT empty, keeps whitespace
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            -- Whitespace-only cell keeps its value (not treated as empty)
            assert.equals("   ", dataset[2][2].parsed)
        end)

        it("should keep reformatted output empty when default is used", function()
            local raw_tsv = {
                {"name:string", "value:number:=100"},
                {"Item1", ""},       -- empty -> uses default, but reformatted stays empty
                {"Item2", "50"}      -- has value -> reformatted is "50"
            }

            local env = {}
            local expr_eval = tsv_model.expressionEvaluatorGenerator(env)
            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                expr_eval,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            -- Item1: empty cell uses default for parsed, but reformatted stays empty
            assert.equals("", dataset[2][2].value)          -- original value was empty
            assert.equals(100, dataset[2][2].parsed)        -- default was applied
            assert.equals("", dataset[2][2].reformatted)    -- reformatted stays empty
            -- Item2: cell with value keeps its value
            assert.equals("50", dataset[3][2].value)
            assert.equals(50, dataset[3][2].parsed)
            assert.equals("50", dataset[3][2].reformatted)
        end)
    end)

    describe("column name validation", function()
        it("should mark valid identifier names as valid", function()
            local raw_tsv = {
                {"name:string", "value:number", "isActive:boolean"},
                {"Item1", "10", "true"}
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            assert.is_true(dataset[1][1].valid_name)
            assert.is_true(dataset[1][2].valid_name)
            assert.is_true(dataset[1][3].valid_name)
        end)

        it("should mark names starting with underscore as valid", function()
            local raw_tsv = {
                {"_name:string", "_123:number"},
                {"Item1", "10"}
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            assert.is_true(dataset[1][1].valid_name)
            assert.is_true(dataset[1][2].valid_name)
        end)

        it("should report error and mark invalid names containing hyphen", function()
            local raw_tsv = {
                {"name:string", "bad-name:number"},
                {"Item1", "10"}
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.equals(1, #log_messages)
            assert.is_truthy(log_messages[1]:match("not a valid identifier"))
            assert.is_true(dataset[1][1].valid_name)
            assert.is_false(dataset[1][2].valid_name)
        end)

        it("should report error for names starting with digit", function()
            local raw_tsv = {
                {"123name:string", "value:number"},
                {"Item1", "10"}
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.equals(1, #log_messages)
            assert.is_truthy(log_messages[1]:match("not a valid identifier"))
            assert.is_false(dataset[1][1].valid_name)
            assert.is_true(dataset[1][2].valid_name)
        end)

        it("should report error for names containing spaces", function()
            local raw_tsv = {
                {"name:string", "my value:number"},
                {"Item1", "10"}
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.equals(1, #log_messages)
            assert.is_truthy(log_messages[1]:match("not a valid identifier"))
        end)

        it("should exclude invalid column names from __type_spec", function()
            local raw_tsv = {
                {"name:string", "bad-name:number", "value:number"},
                {"Item1", "10", "20"}
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            -- __type_spec should only contain valid identifier names
            local typeSpec = dataset[1].__type_spec
            assert.is_truthy(typeSpec:match("name:string"))
            assert.is_truthy(typeSpec:match("value:number"))
            -- bad-name should NOT be in the type spec
            assert.is_falsy(typeSpec:match("bad%-name"))
        end)

        it("should generate empty record type if all columns have invalid names", function()
            local raw_tsv = {
                {"123:string", "bad-name:number"},
                {"Item1", "10"}
            }

            local log_messages = {}
            local badVal = mockBadVal(log_messages)

            local dataset = tsv_model.processTSV(
                mockOptionsExtractor,
                nil,
                mockParserFinder,
                "test.tsv",
                raw_tsv,
                badVal
            )

            assert.is_not_nil(dataset)
            assert.equals(2, #log_messages)  -- Two invalid column name errors
            -- __type_spec should be empty record
            assert.equals("{}", dataset[1].__type_spec)
        end)
    end)

    describe("preamble support", function()
        it("should parse a TSV that has one comment line before the header", function()
            local raw_tsv = {
                "# this is a preamble comment",
                {"name:string", "age:number"},
                {"Alice", "25"},
            }
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor, nil, mockParserFinder, "test.tsv", raw_tsv, badVal)
            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            -- dataset[1] is still the header
            assert.equals("name", dataset[1][1].name)
            assert.equals("number", dataset[1][2].type_spec)
            -- dataset[2] is the first data row
            assert.equals("Alice", dataset[2][1].parsed)
            assert.equals(25, dataset[2][2].parsed)
        end)

        it("should parse a TSV that has multiple comment/blank lines before the header", function()
            local raw_tsv = {
                "###[[[",
                "###return \"name:string\\tval:number\"",
                "###]]]",
                {"name:string", "val:number"},
                "###[[[end]]]",
                {"alpha", "1"},
                {"beta", "2"},
            }
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor, nil, mockParserFinder, "test.tsv", raw_tsv, badVal)
            assert.is_not_nil(dataset)
            assert.same({}, log_messages)
            -- dataset[1] is the header (raw_tsv[4])
            assert.equals("name", dataset[1][1].name)
            -- dataset[2] is the comment "###[[[end]]]"
            assert.equals("###[[[end]]]", dataset[2])
            -- dataset[3] and [4] are the data rows
            assert.equals("alpha", dataset[3][1].parsed)
            assert.equals(2, dataset[4][2].parsed)
        end)

        it("should expose preamble via dataset.__preamble", function()
            local raw_tsv = {
                "# line one",
                "# line two",
                {"name:string"},
                {"Alice"},
            }
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor, nil, mockParserFinder, "test.tsv", raw_tsv, badVal)
            assert.is_not_nil(dataset)
            local p = dataset.__preamble
            assert.is_not_nil(p)
            assert.equals(2, #p)
            assert.equals("# line one", p[1])
            assert.equals("# line two", p[2])
        end)

        it("should return nil __preamble when there is no preamble", function()
            local raw_tsv = {
                {"name:string"},
                {"Alice"},
            }
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor, nil, mockParserFinder, "test.tsv", raw_tsv, badVal)
            assert.is_not_nil(dataset)
            assert.is_nil(dataset.__preamble)
        end)

        it("should round-trip preamble via tostring()", function()
            local raw_tsv = {
                "# preamble",
                {"name:string", "val:number"},
                {"Alice", "1"},
            }
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor, nil, mockParserFinder, "test.tsv", raw_tsv, badVal)
            assert.is_not_nil(dataset)
            local result = tostring(dataset)
            assert.equals("# preamble\nname:string\tval:number\nAlice\t1", result)
        end)

        it("should return the correct error when all lines are comments", function()
            local raw_tsv = {
                "# only comment",
                "# another comment",
            }
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor, nil, mockParserFinder, "test.tsv", raw_tsv, badVal)
            assert.is_nil(dataset)
            assert.is_true(#log_messages > 0)
        end)

        it("should keep row.__idx as the original raw_tsv line number", function()
            local raw_tsv = {
                "# preamble",
                {"name:string"},
                {"Alice"},
            }
            local log_messages = {}
            local badVal = mockBadVal(log_messages)
            local row_indices = {}
            local dataset = tsv_model.processTSV(
                mockOptionsExtractor, nil, mockParserFinder, "test.tsv", raw_tsv, badVal,
                function(_, row, _)
                    row_indices[#row_indices+1] = row.__idx
                end)
            assert.is_not_nil(dataset)
            -- raw_tsv[3] is "Alice", so __idx should be 3
            assert.equals(3, row_indices[1])
        end)
    end)
end)
