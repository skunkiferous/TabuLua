-- Module name
local NAME = "format_report"

-- Module versioning
local semver = require("semver")

-- Module version
local VERSION = semver(0, 31, 0)

-- Returns the module version
local function getVersion()
    return tostring(VERSION)
end

local read_only = require("util.read_only")
local readOnly = read_only.readOnly

local type_wiring = require("wiring.type_wiring")
require("wiring.builtin_wiring")

local files_desc = require("loader.files_desc")
local manifest_info = require("loader.manifest_info")

--- The `--list-columns` report: the data format's full column/field inventory,
--- marked with what the loaded packages already declare.
---
--- It exists because an OPTIONAL column is undiscoverable by design. Nothing
--- warns about a column you have not written — it cannot, since most packages
--- use almost none of the dozen-plus feature columns and a warning per unused
--- column per Files.tsv on every load would be unusable noise. The consequence
--- is that a package written against an older release keeps working, silently,
--- while its author has no way to learn what the engine has since learned to
--- accept. Short of reading the whole CHANGELOG, there was no answer to "what
--- could I be declaring that I'm not?".
---
--- This report is that answer, and each column's `since` (type_wiring's
--- descriptorColumns declarations; manifest_info's MANIFEST_FIELD_SINCE) is what
--- lets it rank the unused ones newest-first — so "what's new since I last
--- looked?" is the first thing you read.
---
--- Diagnostic only: it prints, and never touches the exit code.

-- Collects one column/field row. Rendering is deferred to renderRows so the
-- `name:type` field can be padded to the widest declaration actually present —
-- a hard-coded width mangles the long ones (variant_groups' type spec alone runs
-- past 40 characters).
local function addRow(rows, used, total, name, ctype, since, note)
    rows[#rows + 1] = {
        decl = name .. ":" .. tostring(ctype),
        used = used, total = total, since = since, note = note,
    }
end

-- Renders collected rows into `lines`, aligned to the widest declaration. A row
-- with no `decl` is a literal separator/heading, emitted as-is.
local function renderRows(lines, rows)
    local width = 0
    for _, r in ipairs(rows) do
        if r.decl and #r.decl > width then width = #r.decl end
    end
    for _, r in ipairs(rows) do
        if not r.decl then
            lines[#lines + 1] = r.text
        else
            local line = string.format("   %s  %-" .. width .. "s  %-8s  %d/%d",
                r.used > 0 and "[x]" or "[ ]", r.decl, r.since or "-", r.used, r.total)
            if r.note then
                line = line .. "   (" .. r.note .. ")"
            end
            lines[#lines + 1] = line
        end
    end
end

-- Sorts unused entries newest-first: a `since` we know about beats one we don't
-- (an unversioned column predates tracking, so it is the least interesting), and
-- among known ones the higher version comes first. Ties break by name.
local function byNewest(a, b)
    if (a.since ~= nil) ~= (b.since ~= nil) then
        return a.since ~= nil
    end
    if a.since and b.since and a.since ~= b.since then
        local okA, sa = pcall(semver, a.since)
        local okB, sb = pcall(semver, b.since)
        if okA and okB and sa ~= sb then
            return sb < sa
        end
        return a.since > b.since
    end
    return a.name < b.name
end

--- Builds the report.
--- @param packages table|nil package_id -> manifest (result.packages)
--- @param joinMeta table|nil The loader's join metadata (needs .fn2Idx)
--- @return string The rendered report
local function report(packages, joinMeta)
    packages = packages or {}
    local fn2Idx = (joinMeta and joinMeta.fn2Idx) or {}
    -- The descriptors we loaded, and the packages we loaded: the denominators.
    local descriptors = {}
    for descFile in pairs(fn2Idx) do
        descriptors[#descriptors + 1] = descFile
    end
    table.sort(descriptors)
    local pkgList = {}
    for pid in pairs(packages) do
        pkgList[#pkgList + 1] = pid
    end
    table.sort(pkgList)

    local nDesc, nPkg = #descriptors, #pkgList
    local unused = {}

    local lines = {}
    local rows = {}

    -- Counts how many loaded Files.tsv declare `name`.
    local function declaredBy(name)
        local n = 0
        for _, descFile in ipairs(descriptors) do
            if fn2Idx[descFile][name] ~= nil then
                n = n + 1
            end
        end
        return n
    end

    rows[#rows + 1] = {text = ""}
    rows[#rows + 1] = {text = "=== Files.tsv columns (" .. nDesc .. " descriptor"
        .. (nDesc == 1 and "" or "s") .. " loaded) ==="}
    rows[#rows + 1] = {text = ""}
    rows[#rows + 1] = {text = "  -- core --"}
    for _, col in ipairs(files_desc.coreColumns()) do
        addRow(rows, declaredBy(col.name), nDesc, col.name, col.type, nil,
            col.status ~= "optional" and col.status or nil)
    end

    rows[#rows + 1] = {text = "  -- optional (feature columns) --"}
    -- descriptorColumns() is the registry's list, so a column contributed by a
    -- bootstrap-registered module appears here with no edit to this file.
    local optCols = {}
    for _, decl in ipairs(type_wiring.descriptorColumns()) do
        optCols[#optCols + 1] = decl
    end
    table.sort(optCols, function(a, b) return a.name < b.name end)
    for _, decl in ipairs(optCols) do
        local used = declaredBy(decl.name)
        addRow(rows, used, nDesc, decl.name, decl.type, decl.since)
        if used == 0 then
            unused[#unused + 1] = {name = decl.name, since = decl.since, where = "Files.tsv"}
        end
    end

    rows[#rows + 1] = {text = ""}
    rows[#rows + 1] = {text = "=== Manifest.transposed.tsv fields (" .. nPkg
        .. " package" .. (nPkg == 1 and "" or "s") .. " loaded) ==="}
    rows[#rows + 1] = {text = ""}
    for _, field in ipairs(manifest_info.manifestFields()) do
        -- A manifest field counts as USED when the loaded manifest carries a
        -- value for it. extractManifestFromTSV already nils out an empty list,
        -- so "column present but empty" reads as unused — which is the right
        -- answer to the question this report asks ("are you using the feature?").
        local used = 0
        for _, pid in ipairs(pkgList) do
            if packages[pid][field.name] ~= nil then
                used = used + 1
            end
        end
        addRow(rows, used, nPkg, field.name, field.type, field.since,
            field.required and "required" or nil)
        if used == 0 and not field.required then
            unused[#unused + 1] = {name = field.name, since = field.since,
                where = "manifest"}
        end
    end

    -- One width for BOTH tables, so the two read as one inventory.
    renderRows(lines, rows)

    lines[#lines + 1] = ""
    if #unused == 0 then
        lines[#lines + 1] = "Every optional column and field is in use. Nothing to adopt."
    else
        table.sort(unused, byNewest)
        lines[#lines + 1] = #unused .. " optional column"
            .. (#unused == 1 and "" or "s")
            .. "/field" .. (#unused == 1 and " is" or "s are")
            .. " available but unused. Newest first:"
        for i = 1, math.min(#unused, 5) do
            local u = unused[i]
            lines[#lines + 1] = "   " .. u.name .. " (" .. u.where .. ")"
                .. (u.since and ("   added in " .. u.since) or "")
        end
        if #unused > 5 then
            lines[#lines + 1] = "   ... and " .. (#unused - 5) .. " more (listed above)."
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "See documentation/DATA_FORMAT_README.md for what each one does,"
            .. " and documentation/CHANGELOG.md for the release that added it."
    end
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

-- Provides a tostring() function for the API
local function apiToString()
    return NAME .. " version " .. tostring(VERSION)
end

-- The public, versioned, API of this module
local API = {
    getVersion = getVersion,
    report = report,
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
