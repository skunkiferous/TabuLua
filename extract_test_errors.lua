#!/usr/bin/env lua
-- extract_test_errors.lua
-- Extracts failed test information from TAP format test output

local function extract_errors(input_file, output_file)
    local input = io.open(input_file, "r")
    if not input then
        io.stderr:write("Error: Could not open input file: " .. input_file .. "\n")
        return false
    end

    local output = io.open(output_file, "w")
    if not output then
        io.stderr:write("Error: Could not open output file: " .. output_file .. "\n")
        input:close()
        return false
    end

    local in_error_block = false
    local error_lines = {}
    local total_tests = 0
    local failed_tests = 0
    local passed_tests = 0

    for line in input:lines() do
        if in_error_block then
            -- Continue collecting error details (lines starting with #)
            if line:match("^#") then
                table.insert(error_lines, line)
            elseif line:match("^%s*$") then
                -- Empty line might end error block, but keep it
                table.insert(error_lines, line)
            elseif line:match("^ok %d+") or line:match("^not ok %d+") or line:match("^%d+%.%.%d+") then
                -- New test or test plan line ends error block
                in_error_block = false
                table.insert(error_lines, "") -- Add separator
                passed_tests = passed_tests + (line:match("^ok %d+") and 1 or 0)
                if line:match("^not ok %d+") then
                    failed_tests = failed_tests + 1
                    in_error_block = true
                    table.insert(error_lines, line)
                end
            else
                -- Unknown line in error block, keep it
                table.insert(error_lines, line)
            end
        -- Count test results
        elseif line:match("^ok %d+") then
            passed_tests = passed_tests + 1
        elseif line:match("^not ok %d+") then
            failed_tests = failed_tests + 1
            in_error_block = true
            table.insert(error_lines, line)
        elseif line:match("^%d+%.%.%d+") then
            -- Test plan line (e.g., "1..503")
            local match = line:match("^%d+%.%.(%d+)")
            if match then
                total_tests = tonumber(match) or 0
            end
        end
    end

    input:close()

    -- Write summary header
    output:write(string.format("=" .. string.rep("=", 78) .. "\n"))
    output:write(string.format("TEST RESULTS SUMMARY\n"))
    output:write(string.format("=" .. string.rep("=", 78) .. "\n"))
    output:write(string.format("Total Tests: %d\n", total_tests))
    output:write(string.format("Passed: %d\n", passed_tests))
    output:write(string.format("Failed: %d\n", failed_tests))
    output:write(string.format("=" .. string.rep("=", 78) .. "\n\n"))

    -- Write all error details
    if failed_tests > 0 then
        output:write("FAILED TESTS:\n\n")
        for _, line in ipairs(error_lines) do
            output:write(line .. "\n")
        end
    else
        output:write("All tests passed!\n")
    end

    output:close()

    return true, failed_tests, passed_tests, total_tests
end

-- Main execution
local input_file = arg[1] or "test_results.txt"
local output_file = arg[2] or "test_errors.txt"

local success, failed, passed, total = extract_errors(input_file, output_file)

if success then
    print(string.format("Test results extracted to: %s", output_file))
    print(string.format("Total: %d | Passed: %d | Failed: %d", total or 0, passed or 0, failed or 0))

    -- Return exit code based on test results
    if failed and failed > 0 then
        os.exit(1)
    else
        os.exit(0)
    end
else
    os.exit(2)
end
