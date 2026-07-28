-- Module name
local NAME = "sql_schema"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 33, 0)

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

--- Returns the module version as a string.
--- @return string
local function getVersion()
    return tostring(VERSION)
end

-- ============================================================
-- sql_schema -- the DDL half of the SQL format, as a LEAF module
--
-- Everything here maps the TabuLua column model onto SQL declarations:
-- the column-name sanitizer, the type mapping, and the CREATE TABLE /
-- INSERT preamble each exported .sql file starts with.
--
-- It lives apart from serde/exporter.lua because .sql is becoming an INPUT
-- format too (TODO/sql_input_round_trip.md), so a content-pipeline
-- transcoder needs this rule set to READ a file. The exporter requires
-- content.content_pipeline, so a transcoder requiring the exporter back
-- would risk a partially-initialized module -- hence a leaf both sides can
-- require. Nothing here requires the exporter, the importer, or the
-- content pipeline; keep it that way.
-- ============================================================

local logger = require("infra.named_logger").getLogger(NAME)

local file_util = require("infra.file_util")
local splitPath = file_util.splitPath

local parsers = require("parsers")
local extendsOrRestrict = parsers.extendsOrRestrict
local unionTypes = parsers.unionTypes

-- Lua base types
local BASE_TYPES = {"boolean", "integer", "number", "string", "table"}

--- A fresh "our types" -> SQL types cache, seeded with the base mappings.
---
--- Returned per export rather than shared, because colToSQL EXTENDS it with
--- every new column type it resolves (keyed "type:optional"), and a cache
--- outliving one export would carry another run's user types.
--- @return table The seeded type cache
local function newTypeCache()
    return {
        ["string"] = "TEXT",
        ["number"] = "REAL",
        ["integer"] = "BIGINT",
        ["boolean"] = "SMALLINT", -- BOOLEAN is not available everywhere, so use SMALLINT with values 0/1
        ["table"] = "TEXT", -- tables are encoded as JSON, and therefore become strings
    }
end

--- The SQL-safe form of a column name.
---
--- Exploded columns use dot and bracket notation (`stats.attack`,
--- `materials[1]`, `prices[iron]=`), none of which is legal unquoted in SQL, so
--- they become underscores. Exposed because a tool comparing exports against
--- the model (export_tester) has to apply the same rule to know that
--- `stats.attack` and `stats_attack` are the same column.
--- @param name string The model column name
--- @return string The SQL-safe column name
local function sqlColumnName(name, siblings)
    local base, isValue = name, false
    if name:sub(-1) == "=" then
        base = name:sub(1, -2)
        isValue = true
    end
    local sanitized = (base:gsub("[%.%[%]%=]", "_"):gsub("_+$", ""))
    -- An exploded MAP contributes two model columns per slot -- the key
    -- `prices[iron]` and the value `prices[iron]=` -- which sanitize to the
    -- SAME name once the trailing `=`-turned-`_` is stripped. SQLite refuses
    -- the table outright ("duplicate column name"), so the pair is suffixed
    -- _k / _v. Both sides are suffixed, not just one: `prices_iron` next to
    -- `prices_iron_v` reads like two unrelated columns, and a bare trailing
    -- underscore reads like a typo.
    --
    -- Only a genuine PAIR is suffixed. An exploded array element is a lone
    -- `materials[1]` with no `materials[1]=` beside it, and keeps its plain
    -- name -- which is why this needs the sibling names, not just its own.
    if isValue then
        return sanitized .. "_v"
    end
    if siblings and siblings[name .. "="] then
        return sanitized .. "_k"
    end
    return sanitized
end

--- Builds the sibling-name lookup sqlColumnName needs, from model column names.
--- @param names table Sequence of model column names
--- @return table Set of those names
local function sqlColumnNameSet(names)
    local set = {}
    for _, n in ipairs(names) do
        set[n] = true
    end
    return set
end

-- The same lookup, taken straight from a header's columns.
local function headerSiblings(header)
    local names = {}
    for _, col in ipairs(header) do
        if col.name then
            names[#names + 1] = col.name
        end
    end
    return sqlColumnNameSet(names)
end

-- Converts TSV column model to SQL column string
-- siblings: set of the table's model column names, so an exploded map's
--   key/value pair can be told apart from a lone array element (sqlColumnName)
local function colToSQL(sql_types, col, siblings)
    local colType = col.type
    local optional = false
    local key = colType .. ":" .. tostring(optional)
    local sqlType = sql_types[key]
    if sqlType == nil then
        if colType:sub(-4) == "|nil" then
            optional = true
            colType = colType:sub(1,-5)
        end
        -- Check for bytes types first (map to BLOB)
        if (colType == "hexbytes") or extendsOrRestrict(colType, "hexbytes")
            or (colType == "base64bytes") or extendsOrRestrict(colType, "base64bytes") then
            sqlType = optional and "BLOB" or "BLOB NOT NULL"
        -- int64 must be pinned BEFORE the BASE_TYPES scan below. It extends
        -- "number" now, so that scan would map it to REAL -- silently narrowing
        -- a 64-bit id to a double, the exact loss the type exists to prevent.
        -- BIGINT is exact for the whole int64 range (SQLite gives it INTEGER
        -- affinity, a 64-bit signed integer) and pairs with the bare literal
        -- serializeSQL emits. Both halves moved together; either alone would be
        -- a type mismatch against this column.
        elseif (colType == "int64") or extendsOrRestrict(colType, "int64") then
            sqlType = optional and "BIGINT" or "BIGINT NOT NULL"
        else
            for _, b in ipairs(BASE_TYPES) do
                if (colType == b) or extendsOrRestrict(colType, b) then
                    sqlType = sql_types[b]
                    if not optional and not sqlType:find("NOT NULL") then
                        sqlType = sqlType .. " NOT NULL"
                    end
                    break
                end
            end
        end
        -- Try union types: e.g. integer|string, or aliases resolving to unions like super_type -> type_spec|nil
        if sqlType == nil then
            local uTypes = unionTypes(colType)
            if uTypes then
                local hasTable = false
                for _, ut in ipairs(uTypes) do
                    if ut == "nil" then
                        optional = true
                    elseif ut == "table" or extendsOrRestrict(ut, "table") then
                        hasTable = true
                    end
                end
                -- Union of basic types: all values serialized as strings -> TEXT
                -- Union containing a table type: same as table column type (JSON-encoded TEXT)
                sqlType = sql_types[hasTable and "table" or "string"]
                if not optional and not sqlType:find("NOT NULL") then
                    sqlType = sqlType .. " NOT NULL"
                end
            end
        end
        if sqlType == nil then
            logger:error("Unknown column type: " .. colType.." for column " .. col.name)
            sqlType = "TEXT"
        end
        sql_types[key] = sqlType
        logger:info("Mapping column type " .. col.type .. " to SQL type " .. sqlType)
    end
    local result = '"' .. sqlColumnName(col.name, siblings) .. '" ' .. sqlType
    if col.idx == 1 then
        result = result .. " PRIMARY KEY"
    end
    return result
end

--- The SQL table name for a file, from its source path.
---
--- The basename without extension, exactly as the CREATE TABLE spells it, so
--- a reader can match a data table back to the file it came from.
--- @param header table The header, whose __source is preferred
--- @param fileInfo table|nil {hasDataRows, sourceName} from the export loop
--- @return string The bare (unquoted) table name
local function sqlTableName(header, fileInfo)
    local source_path = splitPath(
        header.__source or (fileInfo and fileInfo.sourceName) or "")
    local file = source_path[#source_path] or "unknown"
    return file:match("^(.*)%.[^%.]+$") or file
end

-- Builds the SQL CREATE TABLE statement followed by the INSERT statement
-- export_cols: optional array of {col_idx, is_root, root_name, structure} for collapsed column export
-- fileInfo: optional {hasDataRows, sourceName} from the export loop. A JOINED or
--   TRANSFORMED header is built during export and carries neither __source nor
--   __dataset, so without this Item and Files came out as CREATE TABLE
--   "unknown" with their INSERT commented out -- files no SQL engine could run.
local function createTableInsertSQL(sql_types, header, export_cols, fileInfo)
    local tableName = '"' .. sqlTableName(header, fileInfo) .. '"'
    -- Self-describing type line, so the file can be re-imported on its own.
    --
    -- SQL declares a bytes column BLOB and says nothing more, but the model
    -- value behind it is TEXT: hex digits for hexbytes, base64 for
    -- base64bytes. Those are indistinguishable from the BLOB alone, so without
    -- this the importer cannot reconstruct the original value. A `--` comment
    -- is ignored by every SQL engine, and a file lacking it still imports (the
    -- importer falls back), so old exports keep working.
    local typeParts = {}
    for _, col in ipairs(header) do
        if col.name and col.type_spec then
            typeParts[#typeParts + 1] = string.format("%q:%q",
                col.name, col.type_spec)
        end
    end
    local result = ""
    if #typeParts > 0 then
        result = "-- tabulua-types: {" .. table.concat(typeParts, ",") .. "}\n"
    end
    result = result .. "CREATE TABLE " .. tableName .. " "
    local sep = "(\n  "
    local is_first = true

    local siblings = headerSiblings(header)

    if export_cols then
        -- Use export_cols to determine columns (handles collapsed exploded columns)
        for _, ec in ipairs(export_cols) do
            local col = header[ec.col_idx]
            if ec.is_root then
                -- Collapsed column: use root_name and TEXT type (serialized JSON/XML/etc)
                local colDef = '"' .. ec.root_name .. '" TEXT NOT NULL'
                if is_first then
                    colDef = colDef .. " PRIMARY KEY"
                end
                result = result .. sep .. colDef
            else
                result = result .. sep .. colToSQL(sql_types, col, siblings)
            end
            sep = ",\n  "
            is_first = false
        end
    else
        -- Original behavior: iterate all columns
        for _, col in ipairs(header) do
            result = result .. sep .. colToSQL(sql_types, col, siblings)
            sep = ",\n  "
        end
    end

    result = result .. ")"
    -- Does this file have any DATA row (row 1 is the header)?
    --
    -- Scanned with pairs, not # or ipairs: a dataset with a stripped comment
    -- row is HOLED, and both of those stop at the first hole. MEASURED: Item
    -- and Files -- the two tutorial files with comment rows -- were declared
    -- empty despite having data, so the INSERT was emitted as a COMMENT and
    -- every data row followed it as a bare "(...)" tuple. The result was not
    -- valid SQL at all ("near \"(\": syntax error" from sqlite3), and nothing
    -- caught it: our own parseSQLContent finds the "VALUES" text without
    -- noticing it sits inside a comment, so the round-trip test passed.
    local not_empty
    if fileInfo ~= nil then
        not_empty = fileInfo.hasDataRows
    else
        -- No caller-supplied info (direct callers, and the specs): fall back to
        -- the header's own dataset.
        local dataset = header.__dataset or {}
        not_empty = false
        for i, row in pairs(dataset) do
            if type(i) == "number" and i > 1 and type(row) == "table" then
                not_empty = true
                break
            end
        end
    end
    if not_empty then
        result = result .. ";\n"
        result = result .. "INSERT INTO " .. tableName .. " "
    else
        result = result .. "\n--"
    end
    return result
end

-- ============================================================
-- Module API
-- ============================================================

local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

local API = {
    getVersion = getVersion,
    newTypeCache = newTypeCache,
    sqlColumnName = sqlColumnName,
    sqlColumnNameSet = sqlColumnNameSet,
    headerSiblings = headerSiblings,
    colToSQL = colToSQL,
    sqlTableName = sqlTableName,
    createTableInsertSQL = createTableInsertSQL,
}

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
