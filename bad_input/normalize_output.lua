-- normalize_output.lua
-- Normalizes reformatter output for repeatable comparison:
-- 1. Strips timestamps (YYYY-MM-DD HH:MM:SS.NNNNNN -> TS)
-- 2. Normalizes temp directory paths to {DIR}
-- 3. Normalizes path separators to /
-- 4. Strips trailing whitespace
-- 5. Removes empty trailing lines
--
-- Usage: lua54 normalize_output.lua [--temp-dir=PATH] [input_file] [output_file]
-- If no input_file, reads from stdin. If no output_file, writes to stdout.

local temp_dir = nil
local input_file = nil
local output_file = nil

for _, a in ipairs(arg or {}) do
    local td = a:match("^%-%-temp%-dir=(.+)$")
    if td then
        -- Normalize the temp dir path: forward slashes, no trailing slash
        temp_dir = td:gsub("\\", "/"):gsub("/$", "")
    elseif not input_file then
        input_file = a
    else
        output_file = a
    end
end

local input_h = input_file and assert(io.open(input_file, "r")) or io.stdin
local output_h = output_file and assert(io.open(output_file, "w")) or io.stdout

-- Pre-compute the escaped temp_dir pattern once
local escaped_temp_dir = nil
if temp_dir then
    escaped_temp_dir = temp_dir:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

local lines = {}
for raw_line in input_h:lines() do
    -- Strip timestamp (YYYY-MM-DD HH:MM:SS.NNNNNN at start of line)
    local normalized = raw_line:gsub("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%.%d+", "TS")
    -- Normalize path separators to forward slashes
    normalized = normalized:gsub("\\", "/")
    -- Replace temp directory with {DIR}
    if escaped_temp_dir then
        normalized = normalized:gsub(escaped_temp_dir, "{DIR}")
    end
    -- Normalize Lua executable name at start of line (varies by platform/invocation:
    -- "lua54:", "lua5.4:", "C:/path/to/lua54.exe:", etc.)
    normalized = normalized:gsub("^[%w%./:-]*lua[%d%.]*[%.exe]*:", "LUA:")
    -- Strip trailing whitespace
    normalized = normalized:gsub("%s+$", "")
    lines[#lines + 1] = normalized
end

-- Remove empty trailing lines
while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
end

-- Sort lines to ensure deterministic output.
-- Lua table iteration order is not guaranteed, so messages like
-- "Content of X has changed" may appear in different order between runs.
table.sort(lines)

for _, out_line in ipairs(lines) do
    output_h:write(out_line .. "\n")
end

if input_h ~= io.stdin then input_h:close() end
if output_h ~= io.stdout then output_h:close() end
