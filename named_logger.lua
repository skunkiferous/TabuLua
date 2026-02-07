--- Named Logger Module
--- Provides named/categorized logging with standardized, fixed configuration.
--- Uses TSV format: timestamp\tlevel\t[name]\tmessage
--- Configuration via environment variables:
--- - NAMED_LOGGER_TYPE: "console" (default) or "file"
--- - NAMED_LOGGER_CONFIG: path to config file (default: "named_logger.conf")
--- Config file format: key=value pairs, supports "log_file" for file logger.
--- This module is intentionally not re-configurable at runtime.

local logging = require("logging")

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 5, 2)

-- Module name
local NAME = "named_logger"

-- Set default date-time pattern for logging
local TS_PATTERN = "%Y-%m-%d %H:%M:%S.%6q"
logging.defaultTimestampPattern(TS_PATTERN)

-- Set TSV log format (tab-separated: timestamp, level, message)
logging.defaultLogPatterns("%date\t%level\t%message\n")

-- Log level constants (from logging library)
local DEBUG = logging.DEBUG
local INFO = logging.INFO
local WARN = logging.WARN
local ERROR = logging.ERROR
local FATAL = logging.FATAL

-- Default Loglevel
local DEFAULT_LOG_LEVEL = INFO

-- We need file-system access
local lfs = require("lfs")

--- Prints an error message to stderr with timestamp.
--- Used internally when logging system itself encounters problems.
--- @param err string The error message to print
--- @side_effect Writes to stderr
local function printError(err)
    local now = os.date("%Y-%m-%d %H:%M:%S")..'.000000\t'
    io.stderr:write(now..err .. "\n")
end

--- Reads logger configuration from a file.
--- @param file_path string Path to the configuration file
--- @return table Configuration key-value pairs; empty table if file doesn't exist or is unreadable
--- @side_effect Logs error to stderr if file exists but cannot be read
local function readConfig(file_path)
    local config = {}
    if lfs.attributes(file_path, "mode") == "file" then
        local success, lines = pcall(io.lines, file_path)
        if success then
            for line in lines do
                local key, value = line:match("^(%w+)%s*=%s*(.+)$")
                if key and value then
                    config[key] = value
                end
            end
        else
            printError("ERROR\tError reading logging config file: " .. file_path)
        end
    end
    return config
end

--- Creates and returns the default logger based on environment configuration.
--- @return table A logger instance (console or file logger)
--- @side_effect Reads environment variables and config file; may log warnings to stderr
local function getDefaultLogger()
    local logger_type = os.getenv("NAMED_LOGGER_TYPE") or "console"
    local config_file = os.getenv("NAMED_LOGGER_CONFIG") or "named_logger.conf"
    local config = readConfig(config_file)

    if logger_type == "console" then
        require("logging.console")
        return logging.console()
    elseif logger_type == "file" then
        require("logging.file")
        local log_file = config.log_file or "application.log"
        return logging.file(log_file)
    else
        printError("WARN\tUnknown logger type. Defaulting to console logger.")
        require("logging.console")
        return logging.console()
    end
end

-- Use the configured logger as the default output
local defaultLogger = getDefaultLogger()

-- Valid log levels
local valid_levels = {
    [DEBUG] = true,
    [INFO] = true,
    [WARN] = true,
    [ERROR] = true,
    [FATAL] = true
}

--------------------------------------------------------------------------------
-- Logger Instance Class
-- Objects returned by getLogger() are instances of this class
--------------------------------------------------------------------------------

local LoggerInstance = {}
LoggerInstance.__index = LoggerInstance

--- Sets the minimum log level for this logger.
--- Messages below this level will be ignored.
--- @param level number One of DEBUG, INFO, WARN, ERROR, FATAL constants
function LoggerInstance:setLevel(level)
    self.__logger:setLevel(level)
end

--- Logs a message at the specified level.
--- @param level number One of DEBUG, INFO, WARN, ERROR, FATAL constants
--- @param message string The message to log
function LoggerInstance:log(level, message)
    self.__logger:log(level, message)
end

--- Logs a debug-level message.
--- @param message string The message to log
function LoggerInstance:debug(message)
    self.__logger:debug(message)
end

--- Logs an info-level message.
--- @param message string The message to log
function LoggerInstance:info(message)
    self.__logger:info(message)
end

--- Logs a warning-level message.
--- @param message string The message to log
function LoggerInstance:warn(message)
    self.__logger:warn(message)
end

--- Logs an error-level message.
--- @param message string The message to log
function LoggerInstance:error(message)
    self.__logger:error(message)
end

--- Logs a fatal-level message.
--- @param message string The message to log
function LoggerInstance:fatal(message)
    self.__logger:fatal(message)
end

--------------------------------------------------------------------------------
-- Module API Functions
--------------------------------------------------------------------------------

-- Weak loggers cache
local loggers = setmetatable({}, {__mode = "v"})

--- Returns a named logger instance, creating one if it doesn't exist.
--- Loggers are cached by name (weak references).
--- Log messages will be prefixed with [name] in the output.
--- @param name string The name/category for log messages
--- @return table A LoggerInstance with debug, info, warn, error, fatal methods
local function getLogger(name)
    -- TODO Validate name
    if loggers[name] then
        return loggers[name]
    end

    local logger = logging.new(function(self, level, message)
        if not valid_levels[level] then
            printError("WARN\tUnknown log level: " .. level .. ". Defaulting to " .. DEFAULT_LOG_LEVEL)
            level = DEFAULT_LOG_LEVEL
        end
        local formatted_message = string.format("[%s]\t%s", name, message)
        return defaultLogger:log(level, formatted_message)
    end)

    local namedLogger = setmetatable({
        -- Public: the logger name/category
        name = name,
        -- Private: the underlying logging library logger
        __logger = logger
    }, LoggerInstance)

    namedLogger:setLevel(DEFAULT_LOG_LEVEL)

    loggers[name] = namedLogger
    return namedLogger
end

--- Creates a new logger with a custom appender function.
--- Allows external code to create custom loggers without directly requiring "logging".
--- @param appender_fn function Appender function: function(self, level, message) -> boolean
--- @return table A logger object from the logging library
local function new(appender_fn)
    return logging.new(appender_fn)
end

--- Returns the module version as a string.
--- @return string The semantic version string (e.g., "0.1.0")
local function getVersion()
    return tostring(VERSION)
end

--------------------------------------------------------------------------------
-- Module Definition
--------------------------------------------------------------------------------

-- The public API of this module
local API = {
    -- Functions
    getLogger = getLogger,
    new = new,
    getVersion = getVersion,
    -- Log level constants
    DEBUG = DEBUG,
    INFO = INFO,
    WARN = WARN,
    ERROR = ERROR,
    FATAL = FATAL,
}

-- Metatable for the module itself
local mt = {
    __index = function(_, key)
        local value = API[key]
        if value == nil then
            error(string.format("Attempt to access undefined API member '%s'", key), 2)
        end
        return value
    end,
    __newindex = function(_, key, _)
        error("Attempt to modify read-only module: " .. key, 2)
    end,
    __tostring = function()
        return NAME .. " version " .. tostring(VERSION)
    end,
    __call = function(_, operation, ...)
        if operation == "version" then
            return VERSION
        elseif type(API[operation]) == "function" then
            return API[operation](...)
        else
            error("Unknown operation: " .. tostring(operation), 2)
        end
    end
}

-- Return the module with controlled access
return setmetatable({}, mt)
