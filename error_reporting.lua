-- Module name
local NAME = "error_reporting"

-- Module logger
local named_logger = require("named_logger")
local logger = named_logger.getLogger(NAME)

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 4, 0)

-- Dependencies
local serialization = require("serialization")
local read_only = require("read_only")
local readOnly = read_only.readOnly

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

-- Meta-table for badVal callable table. We want some complex logic, to log when values are bad
-- But we don't want to repeat logic everywhere, where we check values. We use a table,
-- so we can set directly, the parameters that are required for logging. And we make it callable
-- so it is easiest to use.
-- As a special help for "transposed TSV models", we can set self.transposed to true
local badValMT = {
    -- Make badVal "detectable"
    __metatable = "badVal",
    -- Logs a bad value. Additional error info (error) is optional.
    __call = function (self, value, error)
        -- We keep a counter of errors, so "higher-up" code can detect if "lower-down" code
        -- encountered problems, by checking if the counter changed.
        self.errors = self.errors + 1
        -- If we know what type we were expecting for the value, we include that in the message.
        local prefix = ""
        -- We define a stack of col_types, because we always want to use the "first" (highest up)
        -- type for logging, because we come from a derived type to a parent type, but the log
        -- should always be about the derived type. The stack design allows parsers to ignore
        -- whether they are the first(top) parser or not.
        local ct = self.col_types[1]
        if ct ~= nil and ct ~= "" then
            if type(ct) == "table" then
                -- If the expected type of a value is a table, we must turn it into a string.
                ct = serialization.serializeTable(ct, false, {}, 0)
            end
            prefix = "Bad " .. ct .. " "
        end
        -- We might have information about the column name, and/or it's index. If we do,
        -- we include that too, in the message.
        local cn = self.col_name
        local ci = self.col_idx
        local rk = self.row_key
        local ln = self.line_no
        if self.transposed then
            ln = self.col_idx
            ci = self.line_no
        end
        local col = ""
        if cn ~= nil and cn ~= "" then
            if ci ~= nil and ci ~= 0 then
                col = cn .. ", col " .. ci
            else
                col = cn
            end
        elseif ci ~= nil and ci ~= 0 then
            col = tostring(ci)
        end
        -- Add the optional column info to the prefix
        prefix = prefix .. col
        if prefix ~= "" then
            prefix = prefix .. " in "
        end
        -- We must now convert the value to a string
        local tv = type(value)
        if tv == "table" then
            value = serialization.serializeTable(value, false, {}, 0)
        elseif tv == "function" then
            value = "function"
        else
            value = tostring(value)
        end
        -- Make sure the optional error is not nil
        error = error or ""
        if #error > 0 then
            -- If error is a table, we must also turn it into a string
            if type(error) == "table" then
                error = serialization.serializeTable(error, false, {}, 0)
            end
            -- The "custom error" message, comes at the end
            error = " (" .. error .. ")"
        end
        -- We check if we have the optional row key, which helps find quicker the location
        -- of the problem, then the line number alone.
        local row = ""
        if rk ~= nil and rk ~= "" then
            row = " (" .. rk .. ")"
        end
        -- We can finally build the message
        -- We assume the source_name and line_no are always available
        local msg = prefix .. self.source_name .. " on line " .. ln .. row .. ": '"
            .. value .. "'" .. error
        -- We need a way to debug badVal logging problems. The "secret" field "debug" is used for that.
        if self.debug then
            msg = tostring(self.debug) .. msg
        end
        -- We still need to decide where we actually log the message
        if self.log then
            self:log(msg)
        else
            (self.logger or logger):error(msg)
        end
    end
}

local function badValGenNoMT(log)
    return {
        source_name = "",
        line_no = 0,
        row_key = "",
        col_name = "",
        col_idx = 0,
        col_types = {},
        errors = 0,
        log = log,
        logger = logger,
    }
end

--- Creates a "bad value" logger for reporting parsing/validation errors.
--- The returned object is callable: badVal(value, error_msg) logs an error.
--- Configure via fields before calling:
--- - source_name: string - The data source name (e.g., file path)
--- - line_no: integer - Current line number
--- - row_key: string - Primary key of current row (for better error location)
--- - col_name: string - Current column name
--- - col_idx: integer - Current column index
--- - col_types: table - Stack of type names (push/pop with withColType)
--- - transposed: boolean - If true, swaps line_no and col_idx in output
--- - errors: integer - Count of errors logged (auto-incremented)
--- - log: function|nil - Custom logging function, or nil to use logger:error
--- - logger: table - Logger instance (default: module logger)
--- @param log function|nil Optional custom logging function
--- @return table A callable badVal instance with __metatable="badVal"
--- @side_effect Increments errors field when called
local function badValGen(log)
    return setmetatable(badValGenNoMT(log), badValMT)
end

-- A "null" logger that logs nothing (except fatal)
local nullLogger = named_logger.new(function(self, level, message)
    -- Discard message and return true to indicate success
    return true
end)

-- Meta-table for nullBadVal callable table.
local nullBadValMT = {
    -- Make badVal "detectable"
    __metatable = "badVal",
    -- Logs a bad value. Additional error info (error) is optional.
    __call = function (self, value, error)
        -- Count errors even though we don't log them
        -- Some validation code doesn't want to log, but needs to know
        -- if a value is bad
        self.errors = self.errors + 1
    end
}

-- A "null" badVal() that logs nothing
local nullBadVal = setmetatable(badValGenNoMT(nullLogger), nullBadValMT)

--- Executes a function with a temporary col_type pushed onto badVal.col_types.
--- Ensures the type is removed and logger restored even if fn errors.
--- @param badVal table A badVal instance (must have __metatable="badVal")
--- @param colType string The column type to push onto col_types stack
--- @param fn function The function to execute
--- @param opt_logger table|nil Optional temporary logger to use during fn
--- @return any Whatever fn returns
--- @error Re-raises any error from fn after cleanup
local function withColType(badVal, colType, fn, opt_logger)
    if type(badVal) ~= "table" or getmetatable(badVal) ~= "badVal" then
        error("withColType: badVal must be a badVal instance", 2)
    end
    if type(fn) ~= "function" then
        error("withColType: fn must be a function", 2)
    end
    local old_logger = badVal.logger
    if opt_logger then
        badVal.logger = opt_logger
    end
    badVal.col_types[#badVal.col_types + 1] = colType
    local results = table.pack(pcall(fn))
    badVal.col_types[#badVal.col_types] = nil
    if opt_logger then
        badVal.logger = old_logger
    end
    if not results[1] then
        error(results[2], 0)
    end
    return table.unpack(results, 2, results.n)
end

--- Debugging helper: prints the current call stack with local variables.
--- @param out_fn function|nil Function to receive output string; defaults to print()
--- @side_effect Calls out_fn (or print) with the stack trace
local function dumpStack(out_fn)
    local lines = {}
    local level = 1
    while true do
        local info = debug.getinfo(level, "Sln")  -- get function info
        if not info then break end

        -- Build the line information
        local src = info.short_src or "?"
        local name = info.name or "?"
        local line = info.currentline or -1
        lines[#lines+1] = string.format("[%d] %s:%d in function '%s'\n", level, src, line, name)

        -- Get and print local variables
        local i = 1
        while true do
            local name, value = debug.getlocal(level, i)
            if not name then break end
            lines[#lines+1] = string.format("\tlocal '%s' = %s", name, tostring(value))
            i = i + 1
        end

        level = level + 1
    end
    local msg = table.concat(lines)
    if out_fn then
        out_fn(msg)
    else
        print(msg)
    end
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    badValGen=badValGen,
    dumpStack=dumpStack,
    getVersion=getVersion,
    nullBadVal=nullBadVal,
    nullLogger=nullLogger,
    withColType=withColType,
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
