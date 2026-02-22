-- Module name
local NAME = "tsv_model"

-- Module logger
local logger = require( "named_logger").getLogger(NAME)

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 11, 0)

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

local string_utils = require("string_utils")
local trim = string_utils.trim
local split = string_utils.split
local read_only = require("read_only")
local readOnly = read_only.readOnly
local table_utils = require("table_utils")
local keys = table_utils.keys

local predicates = require("predicates")
local isFullSeq = predicates.isFullSeq
local isBasic = predicates.isBasic
local isCallable = predicates.isCallable
local isIdentifier = predicates.isIdentifier

local raw_tsv_module = require("raw_tsv")
local isRawTSV = raw_tsv_module.isRawTSV
local transposeRawTSV = raw_tsv_module.transposeRawTSV

local error_reporting = require("error_reporting")

local sandbox = require("sandbox")

local parsers = require("parsers")

local exploded_columns = require("exploded_columns")
local analyzeExplodedColumns = exploded_columns.analyzeExplodedColumns
local assembleExplodedValue = exploded_columns.assembleExplodedValue
local isExplodedColumnName = exploded_columns.isExplodedColumnName
local isExplodedCollectionName = exploded_columns.isExplodedCollectionName
local parseExplodedCollectionName = exploded_columns.parseExplodedCollectionName
local validateExplodedCollections = exploded_columns.validateExplodedCollections

-- Expression evaluation quota. Expression that use more operation than this will fail.
local EXPRESSION_MAX_OPERATIONS = 10000

-- Header Column name separator
local HDR_SEP = ':'

-- "Transposed" TSV can be detected by ending with ".transposed.tsv"
local TRANSPOSED_TSV_EXT = ".transposed.tsv"

-- Registers optional column subscribers
local function registerColumnSubscribers(params, col_name, column)
    -- To enable the expression evaluator to use "constants" that were just defined previously,
    -- we have to "publish" the value of each table cell, as it is parsed.
    local table_subscribers = params.table_subscribers
    if table_subscribers then
        if isCallable(table_subscribers) then
            column.subscribers = table_subscribers
        elseif table_subscribers[col_name] then
            local col_subscribers = table_subscribers[col_name]
            if isCallable(col_subscribers) then
                column.subscribers = col_subscribers
            elseif type(col_subscribers) == "table" then
                for _, subscriber in ipairs(col_subscribers) do
                    if not isCallable(subscriber) then
                        error("subscriber is not a function: " .. type(subscriber))
                    end
                end
                column.subscribers = function (col, row, cell)
                    for _, subscriber in ipairs(col_subscribers) do
                        subscriber(col, row, cell)
                    end
                end
            end
        end
    end
end

-- Create an immutable TSV header column. Returns the column.
-- col_idx is the index of the column in the header row
-- column is the description of the column in the header row
-- params contains these fields:
-- options_extractor is a function that takes the column name, extract the options, if any,
-- and return them in a table, after the "cleaned up" column name.
-- expr_eval, the expression evaluator, is a function that takes (context,expr) and returns
-- the evaluated expression, and an optional error message. "context" is mapped to "self" when
-- evaluating the expression. In this particular case, expr_eval is used on the column type
-- specification.
-- parser_finder is a function that takes (badVal,col_type) and returns col_parser
-- source_name is used in error messages
-- header is the parsed header row. It is required in case the column type is an expression
-- errors is a list used to store error messages
-- A column is a read-only table with fields: name, idx, type_spec, type, parser, options
-- The type_spec, which defaults to "string", can be an expression, and so must be evaluated.
-- The evaluated type_spec ia stored in "type", and should still be a string.
-- If parser_finder cannot find a parser for "type", the parser will be nil.
local function newHeaderColumn(params, col_idx, column)
    local badVal = params.badVal
    badVal.col_name = ""
    badVal.col_idx = col_idx

    if type(column) == "string" then
        column = trim(column)
    else
        badVal(tostring(column), "Header column is not a string, but was " .. type(column) ..
            " Defaulting to '?'")
        column = "?"
    end
    local pos = column:find(HDR_SEP)
    local result = {}
    local col_name = pos and trim(column:sub(1, pos - 1)) or column
    if params.options_extractor then
        col_name = params.options_extractor(col_name, result)
    end
    badVal.col_name = col_name

    -- Validate column name is a valid identifier, exploded path, or collection column
    local valid_name = isIdentifier(col_name)
    local is_exploded = false
    local exploded_path = nil
    local is_collection = false
    local collection_info = nil

    if not valid_name then
        -- Check for collection notation first (e.g., "items[1]" or "stats[1]=")
        if isExplodedCollectionName(col_name) then
            valid_name = true
            is_exploded = true
            is_collection = true
            collection_info = parseExplodedCollectionName(col_name)
            -- Build exploded_path from base_path
            exploded_path = split(collection_info.base_path, ".")
        -- Check if it's a valid exploded column name (e.g., "location.level" or "position._1")
        elseif isExplodedColumnName(col_name) then
            valid_name = true
            is_exploded = true
            exploded_path = split(col_name, ".")
        else
            badVal(col_name, "Column name is not a valid identifier or exploded path")
        end
    end

    -- Parse type_spec and optional default_expr using partial type parser
    local col_type_spec = ""
    local default_expr = nil

    if pos then
        local after_name = column:sub(pos + 1)
        local parsed_type, remainder = parsers.internal.type_parser_partial(after_name)
        if parsed_type then
            col_type_spec = trim(after_name)
            -- Check for default value after the type spec
            if remainder and remainder ~= "" then
                col_type_spec = trim(after_name:sub(1,-(#remainder+1)))
                local trimmed = trim(remainder)
                if trimmed:sub(1,1) == HDR_SEP then
                    default_expr = trim(trimmed:sub(2))
                    if #default_expr == 0 then
                        default_expr = nil  -- Empty default means no default
                    end
                elseif #trimmed > 0 then
                    badVal(column, "Unexpected text after type specification: " .. trimmed)
                end
            end
        else
            -- Fallback: treat entire remainder as type_spec (backwards compatibility)
            col_type_spec = trim(after_name)
        end
    end

    local cn = (col_name == "?") and ("#" .. tostring(col_idx)) or col_name
    if #col_type_spec == 0 then
        col_type_spec = "string"
        if not pos then
            -- No ':' separator found — column has no type annotation at all
            logger:warn(params.source_name .. ": column '" .. cn
                .. "' has no type annotation (expected format: name:type); defaulting to string")
        else
            logger:debug(params.source_name .. "." .. cn ..": Defaulting to string")
        end
    end
    local col_type = col_type_spec
    if params.expr_eval then
        local ct, problem = params.expr_eval(params.header, col_type_spec)
        if not ct then
            badVal(col_type_spec, "Cannot evaluate column type: " .. problem)
        elseif type(ct) ~= "string" then
            badVal(col_type_spec, "Column type was not evaluated to a string, but " .. type(ct))
        else
            col_type = ct
        end
    end
    local col_parser = params.parser_finder(badVal, col_type)
    -- We don't need to use readOnly() on the column, because it will be read-only
    -- anyway, since the header is itself read-only. BUT, we do it anyway, because it
    -- it is more efficient, than repeatedly creating temporary read-only copies.
    result.name = col_name
    result.idx = col_idx
    result.type_spec = col_type_spec
    result.type = col_type
    -- result.parser will be nil, if col_type is not a valid parser type
    -- In that case, the column cannot be parsed
    result.parser = col_parser
    -- default_expr is nil if no default value was specified
    result.default_expr = default_expr
    -- valid_name is true if the column name is a valid identifier (or exploded path)
    result.valid_name = valid_name
    -- is_exploded is true if the column name contains dots (e.g., "location.level")
    -- or uses collection notation (e.g., "items[1]")
    result.is_exploded = is_exploded
    -- exploded_path is the split path segments (e.g., {"location", "level"})
    result.exploded_path = exploded_path
    -- is_collection is true if the column uses bracket notation (e.g., "items[1]")
    result.is_collection = is_collection
    -- collection_info contains {base_path, index, is_map_value} for collection columns
    result.collection_info = collection_info

    -- Registers optional column subscribers
    registerColumnSubscribers(params, col_name, result)

    return readOnly(result, params.opt_index)
end

-- Shared "cell"" metatable
local cell_mt = {
    __index = function(t, k)
        -- {value,evaluated,parsed,reformatted}
        if k == "value" then
            return t[1]
        elseif k == "evaluated" then
            return t[2]
        elseif k == "parsed" then
            return t[3]
        elseif k == "reformatted" then
            return t[4]
        end
        return nil
    end,
    __tostring = function (t) return t[4] end,
    __type = "cell"
}

-- Returns true, if the value is an expression
local function isExpression(value)
    return type(value) == "string" and value:sub(1,1) == '='
end


-- Returns a new function, that can "process" a table cell
local function processCell(expr_eval, badVal)
    local result = function (col, row, value)
        -- We assume that row[1] must be the primary key
        badVal.col_name = col.name
        badVal.col_idx = col.idx
        local oldCT = badVal.col_types[#badVal.col_types]
        if badVal.line_no == 1 then
            badVal.col_types[#badVal.col_types] = "type_spec"
        else
            badVal.col_types[#badVal.col_types] = col.type_spec
        end
        -- Apply default value if cell is empty and column has a default expression
        local original_value = value
        local used_default = false
        if (value == nil or value == "") and col.default_expr then
            value = col.default_expr
            used_default = true
        end
        local evaluated = value
        if expr_eval then
            -- Non-expression values should be returned unchanged
            -- We assume "computed" values are always in "parsed" format

            -- By parsing the "evaluated" value (in "parsed" context, as we assume it will probably
            -- be a number/boolean/... instead of the string representation of the evaluation),
            -- we then have both the "parsed" value, and the "reformatted" value. But we can't
            -- output the "reformatted" value in the reformatted files, because we would loose the
            -- original expression.
            local v, problem = expr_eval(row, value)
            if problem ~= nil then
                badVal(value, "Failed to evaluate: " .. problem)
            else
                evaluated = v
            end
        end
        local parsed = evaluated
        local reformatted = value
        if col.parser then -- else "all is lost" for this column anyway
            -- if "value" was not an expression ...
            if evaluated == value then
                -- Then parse as expected
                parsed, reformatted = col.parser(badVal, value, "tsv")
            else
                -- Else act like the value was extracted from a parsed value
                parsed, reformatted = col.parser(badVal, evaluated, "parsed")
            end
        end
        if isExpression(value) then
            reformatted = value
        end
        -- If we used the default value, keep the reformatted output as empty
        -- so that the default is not written to the file
        if used_default then
            reformatted = original_value or ""
        end

        -- We save some space in every cell, by not storing the "keys", but using a metatable
        -- together with a sequence of size 3, to access them seamlessly
        -- Use original_value for cells that used default, so cell.value reflects the actual TSV content
        local cell_value = used_default and (original_value or "") or value
        local cell = readOnly({cell_value,evaluated,parsed,reformatted}, cell_mt)

        local subscribers = col.subscribers
        if subscribers then
            -- col contains a reference to all the required meta-data, like the column name and
            -- index, reference to the header ...
            -- row contains the *data* about the row, in particular, the primary key
            subscribers(col, row, cell)
        end
        badVal.col_types[#badVal.col_types] = oldCT
        return cell
    end
    return result
end

-- Create an immutable TSV header. Returns the header
-- options_extractor is a function that takes the column name, extract the options, if any,
-- and adds them in a table, after the "cleaned up" column name.
-- expr_eval, the expression evaluator, is a function that takes (context,expr) and returns
-- the evaluated expression, and an optional error message. "context" is mapped to "self" when
-- evaluating the expression.
-- parser_finder is a function that takes (badVal,col_type) and returns col_parser or nil on error
-- source_name is used in error messages
-- raw_tsv is a "raw tsv" structure, as created by file_util.stringToRawTSV()
-- badVal is a used to log errors
-- A column is a read-only table with fields: name, idx, type_spec, type, parser, options
-- The type_spec, which defaults to "string", can be an expression, and so must be evaluated.
-- The evaluated type_spec ia stored in "type", and should still be a string.
-- If parser_finder cannot find a parser for "type", the parser will be nil.
-- table_subscribers allows defining "callable" subscribers for specific columns.
-- The parser returns the parsed-value or nil if the value cannot be parsed.
local function newHeader(options_extractor, expr_eval, parser_finder, source_name, header_row,
    badVal, dataset, table_subscribers)
    assert(type(badVal.col_types) == "table", "badVal.col_types: "..tostring(badVal.col_types))
    assert(#badVal.col_types == 1, "#badVal.col_types: "..tostring(#badVal.col_types))
    assert(badVal.col_types[1] == '', "badVal.col_types[1]: "..tostring(badVal.col_types[1]))

    local hr
    if type(header_row) == "table" then
        if isFullSeq(header_row) then
            hr = {}
            for i, v in ipairs(header_row) do
                hr[i] = tostring(v)
            end
        end
    elseif type(header_row) == "string" and #(trim(header_row)) > 0 then
        if header_row:match("^%s*#") then
            badVal(nil, "header_row cannot be a comment; skipping this file!")
            return nil
        end
        hr = split(header_row)
    end
    if not hr then
        badVal(nil, "file is empty or has no valid header row")
        return nil
    end
    -- badVal.col_types[#badVal.col_types] was set to '' in caller. We *replace* it, until we exit
    badVal.col_types[#badVal.col_types] = "type_spec"
    local header = {__dataset=dataset, __source=source_name}
    local col_to_string = function (col)
        local s = col.name..':'..col.type_spec
        if col.default_expr then s = s .. ':' .. col.default_expr end
        return s
    end
    local col_call_func = processCell(expr_eval, badVal)
    local col_opt_index = {header=header, __tostring = col_to_string, __call = col_call_func,
        __type = "column", __index=function(c, k)
            -- "Normal" table cells always have: {value,evaluated,parsed,reformatted}
            if k == 'value' or k == 'evaluated' or k == 'parsed' or k == 'reformatted' then
                local s = c.name..':'..c.type_spec
                if c.default_expr then s = s .. ':' .. c.default_expr end
                return s
            end
            return nil
        end}
    local params = {options_extractor=options_extractor, expr_eval=expr_eval, header=header,
        parser_finder=parser_finder, source_name=source_name, badVal=badVal,
        opt_index=col_opt_index,table_subscribers=table_subscribers}
    for col_idx, ch in ipairs(hr) do
        local col = newHeaderColumn(params, col_idx, ch)
        header[col_idx] = col
        if header[col.name] then
            badVal(col.name, "Duplicate column name!")
            badVal.col_types[#badVal.col_types] = ''
            return nil
        else
            header[col.name] = col
        end
    end

    -- Validate exploded collection columns (arrays/maps) for consistency
    local valid, err = validateExplodedCollections(header)
    if not valid then
        badVal(nil, err)
        badVal.col_types[#badVal.col_types] = ''
        return nil
    end

    -- Analyze exploded columns first so we can build the type spec correctly
    local exploded_map = analyzeExplodedColumns(header)

    local ts = ""
    local names = {}
    local processed_roots = {}
    for i, c in ipairs(header) do
        if i > 1 then
            ts = ts .. "\t"
        end
        ts = ts .. c.reformatted
        -- Only include columns with valid identifier names in the type spec
        if c.valid_name then
            if c.is_exploded and c.exploded_path then
                -- For exploded columns, include only the root name (once)
                local root_name = c.exploded_path[1]
                if not processed_roots[root_name] then
                    processed_roots[root_name] = true
                    names[root_name] = true
                end
            else
                -- Regular column
                names[c.name] = true
            end
        end
    end

    -- We want *sorted* column names for the record type specification
    local spec = "{"
    local first = true
    for _, c in ipairs(keys(names)) do
        if not first then
            spec = spec .. ","
        end
        first = false
        if exploded_map[c] then
            -- Collapsed exploded column: use the analyzed structure's type_spec
            spec = spec .. c .. ':' .. exploded_map[c].type_spec
        else
            -- Regular column
            spec = spec .. c .. ':' .. header[c].type_spec
        end
    end
    spec = spec .. "}"

    local header_tostring = function (p) return ts end
    badVal.col_types[#badVal.col_types] = ''
    return readOnly(header, {__tostring = header_tostring,
        __type = "header", __type_spec = spec, __exploded_map = exploded_map})
end

-- Returns true, if the value is not an expression, OR does not require the value of "unprocessed"
-- row cells.
local function canProcessCell(header, done_idx, value)
    -- Quick checks for non-expressions
    if not isExpression(value) or not value:find('self') then
        return true
    end

    -- Strip string literals to avoid false positives for self inside quotes
    local code = value:gsub('"[^"]*"', ''):gsub("'[^']*'", '')

    -- After stripping strings, re-check if there are any self references
    if not code:find('self') then
        return true
    end

    -- Find all references to self in the expression
    local canProcess = true

    -- Match both self[<something>] and self.<something> patterns
    for ref in code:gmatch("self[%.%[]([%w_]+)[%]%.]?") do
        -- If it's a quoted string inside brackets, extract the actual name
        local col_name = (ref:match('"([^"]+)"')) or (ref:match("'([^']+)'")) or ref
        
        -- If it's a number (index), convert to number, otherwise look up column index
        local idx
        if col_name:match("^%d+$") then
            idx = tonumber(col_name)
        else
            -- Look up the column index from the header
            local col = header[col_name]
            idx = col and col.idx
        end
        
        -- If we found an index and it's not in done_idx, we can't process yet
        if idx and not done_idx[idx] then
            canProcess = false
            break
        end
    end
    
    return canProcess
end

-- Process one single row cell
local function doCell(badVal,header,ci,row,new_row,eval_row)
    local c = header[ci]
    badVal.col_idx = ci
    local value = c(eval_row,row[ci])
    new_row[ci] = value
    eval_row[ci] = value.parsed
    eval_row[c.name] = value.parsed
    if ci == 1 then
        local row_key = new_row[1].evaluated
        if isBasic(row_key) then
            badVal.row_key = row_key
        else
            badVal(row_key, "row[1](primary key) must be a basic type: " ..
                tostring(row_key) .. " : ".. type(row_key))
        end
    end
end

-- Create an immutable TSV dataset. Returns the dataset
-- We assume that row[1] must be the primary key, and *not a number*, because the dataset
-- is addressed both by index and by the row primary key. If row[1] is a number, it is converted
-- to a string, to then be used as a row key.
-- options_extractor is a function that takes the column name, extract the options, if any,
-- and adds them in a table, after the "cleaned up" column name.
-- expr_eval, the expression evaluator, is a function that takes (context,expr) and returns
-- the evaluated expression, and an optional error message. "context" is mapped to "self" when
-- evaluating the expression.
-- parser_finder is a function that takes (badVal,col_type) and returns col_parser or nil on error
-- source_name is used in error messages
-- raw_tsv is a "raw tsv" structure, as created by file_util.stringToRawTSV()
-- badVal is a used to log errors
-- table_subscribers allows defining "callable" subscribers for specific columns.
-- transposed is a boolean, that indicates whether the TSV is 'transposed' (has an 'header column'
-- instead of an 'header row'). Defaults to false. If true, *or* if the source name ends with
-- .transposed.tsv we transpose the data in the output.
-- A column is a read-only table with fields: name, idx, type_spec, type, parser, options
-- The type_spec, which defaults to "string", can be an expression, and so must be evaluated.
-- The evaluated type_spec is stored in "type", and should still be a string.
-- If parser_finder cannot find a parser for "type", the parser will be nil.
-- The parser returns the parsed-value or nil if the value cannot be parsed.
-- If a line is either blank or a comment, it is left "as is", and not parsed into a "row".
-- The "value" of a cell in a row is a tuple: {value,evaluated,parsed} The tuple has a meta-table
-- that allows querying the components of the values by name too. 'value' is the original string
-- value, 'evaluated' is the original value, unless it was an expression, in which case the
-- expression is evaluated, and 'parsed' is the result of parsing the 'evaluated value'.
-- In other words, 'parsed' is usually the value you want.
-- As a convenience, the result is callable, with the line(no/key) and optional column(idx/name).
-- to get either the whole row or a single cell, if the column is specified.
local function processTSV(options_extractor, expr_eval, parser_finder, source_name, raw_tsv,
    badVal, table_subscribers, transposed)
    transposed = (transposed == true) or (type(source_name) == "string"
        and source_name:sub(-#TRANSPOSED_TSV_EXT) == TRANSPOSED_TSV_EXT)
    badVal.source_name = source_name
    badVal.line_no = 1
    badVal.row_key = nil
    badVal.col_name = ""
    badVal.col_idx = 0
    return error_reporting.withColType(badVal, '', function()
        badVal.transposed = transposed

        if not isRawTSV(raw_tsv) then
            badVal(nil, "isRawTSV() failed; bad or empty TSV: skipping this file!")
            badVal.col_types[#badVal.col_types] = nil
            return nil
        end
        assert((table_subscribers == nil) or (type(table_subscribers) == "table")
            or isCallable(table_subscribers),
        "table_subscribers should be a table or callable, but was "
            .. type(table_subscribers))

        if transposed then
            raw_tsv = transposeRawTSV(raw_tsv)
        end
        local dataset = {}
        local header = newHeader(options_extractor, expr_eval,
        parser_finder, source_name,raw_tsv[1],
        badVal, dataset, table_subscribers)
        if not header then
            badVal.col_types[#badVal.col_types] = nil
            return nil
        end
        dataset[1] = header
        local row_tostring = function (row)
            local tmp = {}
            for _,cell in ipairs(row) do
                tmp[#tmp+1] = cell.reformatted or ''
            end
            return table.concat(tmp, "\t")
        end
        -- Get the exploded_map from header metatable for lazy assembly
        local header_mt = getmetatable(header)
        local exploded_map = header_mt and header_mt.__exploded_map or {}
        local row_index = function(r,c)
            local col = header[c]
            if col then
                return r[col.idx]
            end
            -- Check if this is an exploded root name (e.g., "location" for "location.level")
            if exploded_map[c] then
                return assembleExplodedValue(r, exploded_map[c])
            end
            return nil
        end
        local row_opt_index = {__dataset=dataset, __tostring = row_tostring, __index=row_index}
        local opt_index = {
            __type = "tsv",
            __transposed = transposed,
            -- line can be either the line number or the line "primary key"
            -- col can be either the column index or the column name
            __call = function (d, line, col)
                if col == nil then
                    return d[line]
                end
                return d[line][col]
            end,
            __tostring = function(d)
                local lines = {}
                for _,r in ipairs(d) do
                    lines[#lines+1] = tostring(r)
                end
                local result = table.concat(lines, '\n')
                if transposed then
                    -- Identify __comment placeholder column indices before re-transposing
                    -- These are generated by transposeRawTSV for comment/blank lines
                    local comment_cols = {}
                    for i, col in ipairs(header) do
                        if col.name:match("^__comment%d+$") and col.type_spec == "comment" then
                            comment_cols[i] = true
                        end
                    end
                    -- Build raw TSV structure directly instead of parsing from string
                    -- This avoids issues with comment detection in stringToRawTSV
                    local raw = {}
                    for _, row in ipairs(d) do
                        if type(row) == "string" then
                            raw[#raw+1] = row
                        else
                            local cells = {}
                            for _, cell in ipairs(row) do
                                cells[#cells+1] = cell.reformatted or ''
                            end
                            raw[#raw+1] = cells
                        end
                    end
                    raw = raw_tsv_module.transposeRawTSV(raw)
                    -- Convert __comment placeholder rows back to comment strings
                    -- After transpose, column i becomes row i
                    for i, row in ipairs(raw) do
                        if comment_cols[i] and type(row) == "table" then
                            -- The original comment content is in column 2 (row[2])
                            raw[i] = row[2] or ""
                        end
                    end
                    result = raw_tsv_module.rawTSVToString(raw)
                    -- rawTSVToString adds trailing \n; remove for consistency
                    if result:sub(-1) == '\n' then
                        result = result:sub(1, -2)
                    end
                end
                return result
            end
        }
        local done_idx = nil
        for i=2,#raw_tsv do
            badVal.line_no = i
            local row = raw_tsv[i]
            if type(row) ~= "table" then
                -- Assume comment or empty line ...
                dataset[i] = row
            else
                -- In new_row, each cell is a table, with fields: {value,evaluated,parsed,reformatted}
                local new_row = {__idx=i}
                -- eval_row, OTOH, only contains tha parsed value, so you don't have to write something
                -- like "self.some_col.parsed"
                local eval_row = {__idx=i}
                -- In case we already have a bad value for the key, make sure that badVal.row_key is
                -- initialized with "some" value
                badVal.row_key = row[1]
                -- This loop enable processing row cells in order of dependencies
                done_idx = {}
                local done_count = 0
                while done_count < #header do
                    local progress = false
                    for ci = 1,#header do
                        if not done_idx[ci] and ci > #row
                            and not header[ci].type_spec:find("|nil", 1, true)
                            and header[ci].type_spec ~= "nil" then
                            -- Row is shorter than header and column is not nullable
                            badVal.col_name = header[ci].name
                            badVal.col_idx = ci
                            badVal.col_types[#badVal.col_types] = header[ci].type_spec
                            badVal(nil, "row has " .. #row .. " columns but header defines "
                                .. #header .. " -- column '" .. header[ci].name .. "' is missing")
                            new_row[ci] = readOnly({nil, nil, nil, ""}, cell_mt)
                            eval_row[ci] = nil
                            eval_row[header[ci].name] = nil
                            done_idx[ci] = true
                            done_count = done_count + 1
                            progress = true
                        elseif canProcessCell(header, done_idx, row[ci]) then
                            doCell(badVal,header,ci,row,new_row,
                                eval_row)
                            done_idx[ci] = true
                            done_count = done_count + 1
                            progress = true
                        end
                    end
                    assert(progress, "Infinite loop in processTSV! File: "..source_name
                        ..", Line: "..i)
                end
                -- We assume that row[1] must be the primary key
                -- We don't use "parsed", in case it's a number,
                -- because the dataset is addressed both by index
                -- and by the row primary key
                local pk = new_row[1].evaluated
                local ro = readOnly(new_row, row_opt_index)
                dataset[i] = ro
                if i > 1 and pk ~= nil and type(pk) ~= "table" then
                    pk = tostring(pk)
                    if opt_index[pk] ~= nil then
                        badVal.col_idx = 1
                        badVal.row_key = pk
                        badVal.col_name = header[1].name
                        badVal.col_types[#badVal.col_types] = header[1].type_spec
                        badVal(pk, "Duplicate primary key!")
                    else
                        opt_index[pk] = ro
                    end
                end
            end
        end
        return readOnly(dataset, opt_index)
    end, logger)
end

--- Default option extractor for TSV column headers.
--- Extracts options from column name suffixes (e.g., '!' for published columns).
--- @param col_name string The column name, possibly with option suffixes
--- @param options table Table to add extracted options to (modified in place)
--- @return string The column name with option suffixes removed
--- @error Throws if options is not a table
local function defaultOptionsExtractor(col_name, options)
    if type(options) ~= "table" then
        error("Column options must be a table, but was " .. type(options))
    end
    if type(col_name) == "string" then
        if col_name:sub(-1,-1) == '!' then
            col_name = col_name:sub(1,-2)
            -- Values in published columns are "published" to the environment, which is used for
            -- "computed" values. The name/primary-key of the row is used to reference the value.
            options.published = true
        end
    end
    return col_name
end

-- Cleans up Lua sandbox error messages by removing internal file paths and
-- [string "..."] notation, keeping only the meaningful error description.
-- Example input:  "C:/lua/.../sandbox.lua:170: [string \"return (x * 2)\"]:1: attempt to ..."
-- Example output: "attempt to perform arithmetic on a nil value (global 'x')"
local function sanitizeSandboxError(err)
    if type(err) ~= "string" then
        return tostring(err)
    end
    -- Remove sandbox file path prefix including Windows drive letter:
    -- e.g., "C:/lua/.../sandbox.lua:148: " or "./sandbox.lua:148: "
    local cleaned = err:gsub("[%a]?:?[^%s]*sandbox%.lua:%d+:%s*", "")
    -- Remove [string "return (...)"] prefix: '[string "return (expr)"]:1: '
    cleaned = cleaned:gsub('%[string "[^"]*"%]:%d+:%s*', "")
    -- Trim leading/trailing whitespace
    cleaned = cleaned:match("^%s*(.-)%s*$")
    if cleaned == "" then
        return err -- fallback to original if nothing left
    end
    return cleaned
end

--- Creates an expression evaluator for TSV cell expressions.
--- Expressions start with '=' and are evaluated in a sandboxed environment.
--- The context parameter becomes 'self' in the expression.
--- @param env table The base environment for expression evaluation
--- @param log table|nil Optional logger for error messages
--- @return function An evaluator function(context, expr) -> value, error_msg|nil
--- @error Throws if env is not a table
local function expressionEvaluatorGenerator(env, log)
    local te = type(env)
    if te ~= "table" then
        error("Expression evaluator environment must be a table, but was " .. te)
    end
    log = log or logger
    local mt = {
        __index = env,
    }
    local expr_eval = function (context,expr)
        if type(expr) == "string" and expr:sub(1,1) == '=' then
            local code = "return (" .. expr:sub(2) .. ")"
            local expr_env = setmetatable({self = context}, mt)
            -- Only use quota if supported (not supported on LuaJIT)
            local opt = {env = expr_env}
            if sandbox.quota_supported then
                opt.quota = EXPRESSION_MAX_OPERATIONS
            end
            -- Wrap sandbox.protect in pcall to catch compilation errors (e.g., syntax errors)
            local protect_ok, protected = pcall(sandbox.protect, code, opt)
            if not protect_ok then
                return nil, sanitizeSandboxError(protected)
            end
            local ok, result = pcall(protected)
            if not ok then
                return nil, sanitizeSandboxError(result)
            else
                return result
            end
        else
            -- Normal value; not an expression
            return expr
        end
    end
    return expr_eval
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    defaultOptionsExtractor=defaultOptionsExtractor,
    expressionEvaluatorGenerator=expressionEvaluatorGenerator,
    getVersion=getVersion,
    -- "Internal" API, only exported to it can be tested.
    -- Do not use directly; might change in the future
    internal = {
        canProcessCell=canProcessCell,
    },
    isExpression=isExpression,
    processTSV=processTSV,
    EXPRESSION_MAX_OPERATIONS=EXPRESSION_MAX_OPERATIONS,
    TRANSPOSED_TSV_EXT = TRANSPOSED_TSV_EXT,
}

-- Enables the module to be called as a function
local function apiCall(_, operation, ...)
    if operation == "version" then
        return VERSION
    elseif API[operation] then
        return API[operation](...)
    else
        error("Unknown operation: " .. tostring(operation), 2)
    end
end

return readOnly(API, {__tostring = apiToString, __call = apiCall, __type = NAME})
