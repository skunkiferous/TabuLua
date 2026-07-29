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

-- Only the two SQL literal writers are needed here (every metadata value is a
-- string, a small integer or NULL); escaping lives in ONE place, with the data
-- rows, so a name or a type_spec containing a quote is escaped identically.
local serialization = require("serde.serialization")
local serializeSQL = serialization.serializeSQL
local serializeTableNaturalJSON = serialization.serializeTableNaturalJSON

-- Lua base types
local BASE_TYPES = {"boolean", "integer", "number", "string", "table"}

-- Compound extension the model treats as ONE extension (see modelDatasetName).
local TRANSPOSED_EXT = ".transposed.tsv"

--- The embedded metadata table: name, sentinel, and version marker.
---
--- The wide-TSV header (`name:type[:default]`) cannot be rebuilt from the DDL
--- alone -- column names are sanitized (`stats.attack` -> `stats_attack`) and
--- SQL types are coarser than ours (`BIGINT` is `integer` AND `int64`; `TEXT`
--- is `string`, `table`, unions, ...) -- so the schema has to ride in the file.
--- A `--` comment would round-trip a FILE, but it is a lexeme every engine
--- discards on load, so the metadata is a real table the database keeps and
--- re-dumps. See TODO/sql_input_round_trip.md.
local METADATA_TABLE = "tabulua_schema"

--- Row 0 (the table-info row) carries sentinels rather than NULLs in
--- column_name / sql_name / type, so every row stays fully populated and the
--- primary key stays total. Angle brackets never appear in exported names.
local TABLE_ROW_SENTINEL = "<TABLE>"

--- Provenance, NOT a gate: TabuLua's own major.minor, as a STRING compared
--- component-wise ("0.15" vs "0.5" compares wrong as a float). Compatibility is
--- enforced structurally -- does the file carry the shape the reader needs? --
--- and this only sharpens the message when that fails.
local SCHEMA_VERSION = tostring(VERSION.major) .. "." .. tostring(VERSION.minor)

--- Upper bound on one `attributes` cell, enforced on READ.
---
--- The bag is a preserved payload, not a queryable field, and an unbounded one
--- in a file the reader does not control is an invitation. Generous for
--- descriptive metadata (labels, units, provenance) and nowhere near what a
--- data column carries.
local MAX_ATTRIBUTES_BYTES = 64 * 1024

--- The metadata table's DDL, emitted byte-identically at the top of EVERY
--- exported .sql. `IF NOT EXISTS` makes it a no-op in every file after the
--- first, so a whole export concatenated into one database creates it once and
--- each file then contributes its own rows. Every construct here works on
--- SQLite, MySQL and PostgreSQL (9.1+).
local METADATA_DDL = table.concat({
    'CREATE TABLE IF NOT EXISTS "' .. METADATA_TABLE .. '" (',
    '  "table_name"  TEXT    NOT NULL,',
    '  "column_name" TEXT    NOT NULL,   -- model name (stats.attack)',
    '  "sql_name"    TEXT    NOT NULL,   -- physical column in the data table',
    '  "position"    INTEGER NOT NULL,   -- 0 = table-info row; 1..N = column order',
    '  "type"        TEXT    NOT NULL,   -- type_spec (int64, {integer}, foo|nil)',
    '  "default"     TEXT,               -- NULL when the column had none',
    '  "attributes"  TEXT,               -- NULL, or a JSON object',
    '  PRIMARY KEY ("table_name","column_name"),',
    '  UNIQUE      ("table_name","position"),',
    '  UNIQUE      ("table_name","sql_name"));',
}, "\n")

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

--- The MODEL's name for this dataset, which can differ from the SQL table name.
---
--- `Manifest.transposed.tsv` is one dataset called `Manifest`, but its SQL
--- table is `Manifest.transposed` (sqlTableName strips one extension, and the
--- table must be named after the file it round-trips to). The model peels
--- `.transposed.tsv` as a single compound extension -- the same rule
--- loader/files_desc.lua applies when it checks a typeName against its file
--- name -- so the two names legitimately diverge, and the reader cannot
--- recompute one from the other. Hence it rides in the file, on row 0.
--- @param header table The header, whose __source is preferred
--- @param fileInfo table|nil {hasDataRows, sourceName} from the export loop
--- @return string The model dataset name
local function modelDatasetName(header, fileInfo)
    local source_path = splitPath(
        header.__source or (fileInfo and fileInfo.sourceName) or "")
    local file = source_path[#source_path] or "unknown"
    if file:sub(-#TRANSPOSED_EXT) == TRANSPOSED_EXT then
        return file:sub(1, -#TRANSPOSED_EXT - 1)
    end
    return file:match("^(.*)%.[^%.]+$") or file
end

--- The columns this file's data table actually has, described once.
---
--- The DDL and the tabulua_schema rows are BOTH built from this list, so they
--- cannot drift: "the metadata describes exactly the physical columns" is the
--- invariant the reader checks, and building the two from separate loops is
--- how you break it. (The retired `-- tabulua-types:` comment did exactly
--- that -- it walked the whole header, so it listed comment columns the
--- CREATE TABLE had already dropped.)
---
--- @param header table The model header
--- @param export_cols table|nil Export loop's column selection; nil = all
--- @return table Sequence of {col, name, sqlName, typeSpec, default, isRoot}
local function exportedColumns(header, export_cols)
    local siblings = headerSiblings(header)
    local entries = {}
    local function add(col, name, sqlName, typeSpec, isRoot)
        entries[#entries + 1] = {
            col = col,
            name = name,
            sqlName = sqlName,
            -- NOT NULL in the metadata table, so it must never be empty.
            -- type_spec is the DECLARED spec (`Rarity`, `{name}`, `http|nil`),
            -- which is what the header line has to be rebuilt from; col.type is
            -- the resolved fallback for a synthetic header that carries no
            -- spec.
            typeSpec = typeSpec or col and (col.type_spec or col.type) or "string",
            default = col and col.default_expr or nil,
            isRoot = isRoot or false,
        }
    end
    if export_cols then
        for _, ec in ipairs(export_cols) do
            local col = header[ec.col_idx]
            if ec.is_root then
                -- A collapsed exploded group (--collapse-exploded): one TEXT
                -- column holding the whole composite, named for the root. Its
                -- spec is the one the collapsed TSV header would carry.
                add(col, ec.root_name, ec.root_name,
                    ec.structure and ec.structure.type_spec, true)
            else
                add(col, col.name, sqlColumnName(col.name, siblings))
            end
        end
    else
        for _, col in ipairs(header) do
            add(col, col.name, sqlColumnName(col.name, siblings))
        end
    end
    return entries
end

--- The self-describing metadata block that opens every exported .sql file.
---
--- Self-contained per file (importing one table means reading one file) AND
--- non-conflicting when concatenated (loading a whole export into one database
--- creates the table once, and each file contributes its own rows). The
--- DELETE-before-INSERT is what makes a reload idempotent, portably -- there is
--- no `INSERT OR REPLACE` / `ON CONFLICT` spelling common to SQLite, MySQL and
--- PostgreSQL.
--- @param tableName string The SQL table name these rows describe
--- @param modelName string The model's own name for the dataset
--- @param entries table exportedColumns() output
--- @return string The block, newline-terminated
local function metadataSQL(tableName, modelName, entries)
    local rows = {}
    -- Was this written with --collapse-exploded? Each exploded group is one TEXT
    -- column holding the whole composite, so the file describes a DIFFERENT
    -- shape from the source TSV it came from -- one `stats` column, not
    -- `stats.attack` and `stats.defense`. The metadata describes that collapsed
    -- shape accurately (it is built from the same list as the DDL), so nothing
    -- about the file is self-contradicting and a reader cannot tell from the
    -- counts. It is therefore stated outright, and the sql:* transcoders refuse
    -- on it rather than quietly loading a model whose header is spelled
    -- differently from the author's source (TODO/sql_input_round_trip.md OQ1).
    local collapsed = nil
    for _, e in ipairs(entries) do
        if e.isRoot then
            collapsed = true
            break
        end
    end
    -- Row 0 is the table itself: sentinels in the three NOT NULL name/type
    -- columns, and the only attributes v1 defines -- the version marker and the
    -- model name. The bag is TEXT holding JSON by convention, never a JSON
    -- column type (SQLite has none), and is written with the NATURAL JSON
    -- serializer whatever --data the export uses: the metadata must not change
    -- shape with the cell encoding, or the reader would need to know which one
    -- wrote it. That serializer sorts its keys, so the bag is deterministic.
    rows[1] = "  (" .. table.concat({
        serializeSQL(tableName),
        serializeSQL(TABLE_ROW_SENTINEL),
        serializeSQL(TABLE_ROW_SENTINEL),
        "0",
        serializeSQL(TABLE_ROW_SENTINEL),
        "NULL",
        serializeSQL(serializeTableNaturalJSON({
            tabulua = {version = SCHEMA_VERSION, model_name = modelName,
                collapsed = collapsed},
        }, false)),
    }, ",") .. ")"
    for i, e in ipairs(entries) do
        rows[#rows + 1] = "  (" .. table.concat({
            serializeSQL(tableName),
            serializeSQL(e.name),
            serializeSQL(e.sqlName),
            tostring(i),
            serializeSQL(e.typeSpec),
            serializeSQL(e.default),
            -- v1 defines no per-column attribute. A key is added with its first
            -- real use case, bumping the minor version.
            "NULL",
        }, ",") .. ")"
    end
    return table.concat({
        METADATA_DDL,
        'DELETE FROM "' .. METADATA_TABLE .. '" WHERE "table_name" = '
            .. serializeSQL(tableName) .. ";",
        'INSERT INTO "' .. METADATA_TABLE .. '" VALUES',
        table.concat(rows, ",\n") .. ";",
    }, "\n") .. "\n"
end

-- Builds the SQL CREATE TABLE statement followed by the INSERT statement
-- export_cols: optional array of {col_idx, is_root, root_name, structure} for collapsed column export
-- fileInfo: optional {hasDataRows, sourceName} from the export loop. A JOINED or
--   TRANSFORMED header is built during export and carries neither __source nor
--   __dataset, so without this Item and Files came out as CREATE TABLE
--   "unknown" with their INSERT commented out -- files no SQL engine could run.
local function createTableInsertSQL(sql_types, header, export_cols, fileInfo)
    local bareName = sqlTableName(header, fileInfo)
    local tableName = '"' .. bareName .. '"'
    local siblings = headerSiblings(header)
    local entries = exportedColumns(header, export_cols)

    -- The file describes itself in a real TABLE, not a `--` comment. The
    -- comment form (`-- tabulua-types: {...}`) round-tripped a FILE but was
    -- discarded the moment the file was loaded into a database, carried no
    -- default and no SQL-name mapping, and -- because it walked the whole
    -- header rather than the exported columns -- listed comment columns the
    -- CREATE TABLE had already dropped.
    local result = metadataSQL(bareName, modelDatasetName(header, fileInfo),
        entries)

    result = result .. "CREATE TABLE " .. tableName .. " "
    local sep = "(\n  "

    for i, e in ipairs(entries) do
        if e.isRoot then
            -- Collapsed column: use root_name and TEXT type (serialized JSON/XML/etc)
            local colDef = '"' .. e.sqlName .. '" TEXT NOT NULL'
            if i == 1 then
                colDef = colDef .. " PRIMARY KEY"
            end
            result = result .. sep .. colDef
        else
            result = result .. sep .. colToSQL(sql_types, e.col, siblings)
        end
        sep = ",\n  "
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
    modelDatasetName = modelDatasetName,
    exportedColumns = exportedColumns,
    metadataSQL = metadataSQL,
    createTableInsertSQL = createTableInsertSQL,
    -- Shared with the READER (serde/importer.lua), which must spell the table
    -- name, the row-0 sentinel and the version marker exactly as the writer did
    METADATA_TABLE = METADATA_TABLE,
    TABLE_ROW_SENTINEL = TABLE_ROW_SENTINEL,
    SCHEMA_VERSION = SCHEMA_VERSION,
    MAX_ATTRIBUTES_BYTES = MAX_ATTRIBUTES_BYTES,
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
