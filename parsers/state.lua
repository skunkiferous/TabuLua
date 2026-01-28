-- parsers/state.lua
-- Shared state and registries for the parsers module
-- This module holds all mutable state that is shared across parser submodules

local M = {}

-- Module metadata
M.VERSION = require("semver")(0, 1, 0)
M.NAME = "parsers"

-- Logger instance
M.logger = require("named_logger").getLogger(M.NAME)

-- Are we currently still setting up the module?
-- Allows keyword parsers (nil, true, false) only during module initialization
M.settingUp = true

-- Forward references (will be filled in during initialization)
M.refs = {
    extendsOrRestrict = nil,
    getTypeKind = nil,
    tupleFieldTypes = nil,
    parse_type = nil,
    parseType = nil,
    percent = nil,
}

-- Matches "version comparator" strings
M.VALID_VERSION_COMPARATORS = {
    ["="]=true, ["=="]=true, [">"]=true, ["<"]=true, [">="]=true, ["<="]=true, ["~"]=true,
    ["^"]=true
}

-- Version Comparator Pattern
M.VERSION_CMP_PATTERN = "^([<>=~^]+)((%d+)%.(%d+)%.(%d+))$"

-- The main registry of parser functions
-- Maps name/type_spec -> parser function
M.PARSERS = {}

-- Maps the name of "type aliases" to the name / type specification of real types
M.ALIASES = {}
M.ALIASES["{}"] = "table"

-- Maps the name of a parser to the name of its parent parser, if any
M.EXTENDS = {}
M.EXTENDS["enum"] = "string"
M.EXTENDS["array"] = "table"
M.EXTENDS["map"] = "table"
M.EXTENDS["tuple"] = "table"
M.EXTENDS["record"] = "table"

-- Comparators for the parsers
M.COMPARATORS = {}

-- Set of parser to <true>, for parsers that are unions that allow nil (parsers of optional values)
M.nilUnions = {}

-- The name / type specification of parsers that never parse a value to a table
M.NEVER_TABLE = {}

-- The name / type specification of parsers whose parsed values are not strings, but are converted
-- to string when producing the reformatted output
M.FORCE_REFORMATTED_AS_STRING = {}

-- Table with all the valid "optional" type specs
M.OPTIONAL = {}

-- Set with all unknown types so far, so they are only logged once
M.UNKNOWN_TYPES = {}

-- Maps number parser names to their limits
M.NUMBER_LIMITS = {}

-- Maps a "string type" to its minimum length, if any
M.STR_MIN_LEN = {}
M.STR_MIN_LEN.string = 0
M.STR_MIN_LEN.enum = 0

-- Maps a "string type" to its maximum length, if any
M.STR_MAX_LEN = {}
M.STR_MAX_LEN.string = math.huge
M.STR_MAX_LEN.enum = math.huge

-- Maps a "string type" to its "regular expression", if any
M.STR_REGEX = {}

-- Since refs.extendsOrRestrict is a forward reference, and it gets defined quite far down,
-- it won't be set yet when the first call to extendsOrRestrictsType() is made.
-- So, we have to "cache" the "updates" to the different type "parameters".
M.TYPES_PARAMS_TODO = {}

-- Cache of array parsers
M.ARRAY_PARSERS = {}

-- Cache of map parsers
M.MAP_PARSERS = {}

-- Cache of tuple parsers
M.TUPLE_PARSERS = {}

-- Cache of union parsers
M.UNION_PARSERS = {}

-- We record the first union type, to generate a default value
M.UNION_FIRST_TYPE = {}

-- Cache of record parsers
M.RECORD_PARSERS = {}

-- All built-in parsers (populated after setup)
M.BUILT_IN = {}

return M
