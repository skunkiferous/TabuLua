-- package_preprocessor_spec.lua
-- End-to-end tests for tier-C package-scoped pre-processors
-- (TODO/mod_overrides.md §6, Phase 5): a child package declares
-- `preProcessors` in its manifest; they run AFTER tier-A/B patches and BEFORE
-- validators, mutating the merged-and-patched state. Write access is scoped to
-- files the package owns or has declared patches for. Cross-package ordering
-- follows package load order, refined by each spec's `requires`. Parent
-- file-level processors flagged `rerunAfterPatches` re-derive against the
-- patched data.

local busted = require("busted")
local assert = require("luassert")
local lfs = require("lfs")

local describe = busted.describe
local it = busted.it
local before_each = busted.before_each
local after_each = busted.after_each

local file_util = require("file_util")
local manifest_loader = require("manifest_loader")
local error_reporting = require("error_reporting")

local function path_join(...)
    return (table.concat({...}, "/"):gsub("//+", "/"))
end

local function mockBadVal(log_messages)
    local badVal = error_reporting.badValGen(function(_s, msg)
        table.insert(log_messages, msg)
    end)
    badVal.source_name = "test"
    badVal.line_no = 1
    return badVal
end

local MANIFEST_FILENAME = "Manifest.transposed.tsv"

local function colIdx(header, name)
    local col = header[name]
    return col and col.idx or nil
end

local function rowsByName(tsv_file)
    local header = tsv_file[1]
    local nameIdx = colIdx(header, "name")
    local byName = {}
    for i = 2, #tsv_file do
        local row = tsv_file[i]
        if type(row) == "table" then
            local n = row[nameIdx] and row[nameIdx].parsed
            if n ~= nil then byName[n] = row end
        end
    end
    return byName, header
end

local function readCell(row, header, colName)
    local idx = colIdx(header, colName)
    if not idx then return nil end
    local cell = row[idx]
    return cell and cell.parsed
end

local function findTsv(result, pattern)
    for fn, tsv in pairs(result.tsv_files) do
        if fn:match(pattern) then return tsv end
    end
    return nil
end

local function countDataRows(tsv)
    local n = 0
    for i = 2, #tsv do
        if type(tsv[i]) == "table" then n = n + 1 end
    end
    return n
end

-- Builds a manifest body (transposed TSV) for a package.
local function manifestBody(opts)
    local lines = {
        "package_id:package_id\t" .. opts.id,
        "name:string\t" .. (opts.name or opts.id),
        "version:version\t" .. (opts.version or "1.0.0"),
        "description:markdown\ttest package",
    }
    if opts.dependencies then
        lines[#lines + 1] = "dependencies:{{package_id,cmp_version}}|nil\t" .. opts.dependencies
    end
    if opts.load_after then
        lines[#lines + 1] = "load_after:{package_id}|nil\t" .. opts.load_after
    end
    if opts.preProcessors then
        lines[#lines + 1] = "preProcessors:{processor_spec}|nil\t" .. opts.preProcessors
    end
    return table.concat(lines, "\n") .. "\n"
end

-- Writes a package directory: manifest, files.tsv, and each data file.
local function writePackage(dir, manifest_opts, filesBody, dataFiles)
    assert(lfs.mkdir(dir))
    assert.is_true(file_util.writeFile(path_join(dir, MANIFEST_FILENAME),
        manifestBody(manifest_opts)))
    assert.is_true(file_util.writeFile(path_join(dir, "files.tsv"), filesBody))
    for name, body in pairs(dataFiles) do
        assert.is_true(file_util.writeFile(path_join(dir, name), body))
    end
end

local CORE_FILES =
    "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\tloadOrder:number\tdescription:text\n"
    .. "Item.tsv\tItem\t\t1\tItems\n"

-- Files.tsv body for a mod package declaring one patch file targeting core Item.tsv.
local function modFiles(patchFile)
    return "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
        .. "\tpatchOf:filepath|nil\tloadOrder:number\tdescription:text\n"
        .. patchFile .. "\tpatch\t\tItem.tsv\t2\tRow patch\n"
end

describe("tier-C package-scoped pre-processors", function()
    local temp_dir, log_messages, badVal

    before_each(function()
        local td = path_join(file_util.getSystemTempDir(),
            "pkgproc_" .. os.time() .. "_" .. math.random(1, 1e6))
        assert(lfs.mkdir(td))
        temp_dir = td
        log_messages = {}
        badVal = mockBadVal(log_messages)
        badVal.logger = error_reporting.nullLogger
    end)

    after_each(function()
        if temp_dir then
            local td = temp_dir
            temp_dir = nil
            file_util.deleteTempDir(td)
        end
    end)

    it("a child package processor mutates a parent file it has patched", function()
        local core = path_join(temp_dir, "core")
        writePackage(core, {id = "core.pkg"}, CORE_FILES, {
            ["Item.tsv"] = "name:name\ttrail:string|nil\n"
                .. "sword\t\n",
        })
        local mod = path_join(temp_dir, "mod")
        local proc = '"(function() local r = rowByKey(\'item.tsv\', \'sword\'); '
            .. 'setCell(r, \'trail\', (r.trail or \'\') .. \'X\'); return true end)()"'
        writePackage(mod, {
            id = "mod.x",
            dependencies = '{"core.pkg",">=1.0.0"}',
            load_after = '"core.pkg"',
            preProcessors = proc,
        }, modFiles("Patch.tsv"), {
            ["Patch.tsv"] = "name:name\tpatchOp:patch_op\ttrail:string|nil\n"
                .. "sword\tupdate\tbase\n",
        })

        local result = manifest_loader.processFiles({core, mod}, badVal)
        assert.is_not_nil(result)
        assert.is_true(result.validationPassed,
            "load should pass; log:\n" .. table.concat(log_messages, "\n"))
        local item = findTsv(result, "Item%.tsv$")
        local byName, header = rowsByName(item)
        -- Patch set trail="base", then the tier-C processor appended "X".
        assert.are.equal("baseX", readCell(byName.sword, header, "trail"))
    end)

    it("write scope is rejected for a parent file the package did not patch", function()
        -- Core ships two files; the mod patches only Item.tsv. A tier-C processor
        -- that tries to write Spell.tsv must be rejected.
        local core = path_join(temp_dir, "core")
        local coreFiles =
            "fileName:filepath\ttypeName:type_spec\tsuperType:super_type\tloadOrder:number\tdescription:text\n"
            .. "Item.tsv\tItem\t\t1\tItems\n"
            .. "Spell.tsv\tSpell\t\t1\tSpells\n"
        writePackage(core, {id = "core.pkg"}, coreFiles, {
            ["Item.tsv"] = "name:name\ttrail:string|nil\n" .. "sword\t\n",
            ["Spell.tsv"] = "name:name\tmana:uint|nil\n" .. "fireball\t10\n",
        })
        local mod = path_join(temp_dir, "mod")
        local proc = '"(function() local r = rowByKey(\'spell.tsv\', \'fireball\'); '
            .. 'setCell(r, \'mana\', 999); return true end)()"'
        writePackage(mod, {
            id = "mod.x",
            dependencies = '{"core.pkg",">=1.0.0"}',
            load_after = '"core.pkg"',
            preProcessors = proc,
        }, modFiles("Patch.tsv"), {
            ["Patch.tsv"] = "name:name\tpatchOp:patch_op\ttrail:string|nil\n"
                .. "sword\tupdate\tbase\n",
        })

        local result = manifest_loader.processFiles({core, mod}, badVal)
        assert.is_not_nil(result)
        assert.is_false(result.validationPassed)
        local joined = table.concat(log_messages, "\n")
        assert.is_true(joined:find("write scope", 1, true) ~= nil,
            "expected a write-scope error, got:\n" .. joined)
        -- The forbidden write did not take effect.
        local spell = findTsv(result, "Spell%.tsv$")
        local byName, header = rowsByName(spell)
        assert.are.equal(10, readCell(byName.fireball, header, "mana"))
    end)

    it("requires reorders tier-C processors against the natural load order", function()
        -- Two independent mods. The packages are passed alpha-before-zeta, so the
        -- natural load order would run alpha ('C') before zeta ('B') => "CB".
        -- mod.alpha requires mod.zeta, so the edge forces zeta to run first and the
        -- final trail is "BC" — proving the requires edge overrode load order.
        local core = path_join(temp_dir, "core")
        writePackage(core, {id = "core.pkg"}, CORE_FILES, {
            ["Item.tsv"] = "name:name\ttrail:string|nil\n" .. "sword\t\n",
        })
        local function appendProc(letter)
            return '"(function() local r = rowByKey(\'item.tsv\', \'sword\'); '
                .. 'setCell(r, \'trail\', (r.trail or \'\') .. \'' .. letter
                .. '\'); return true end)()"'
        end
        local zeta = path_join(temp_dir, "zeta")
        writePackage(zeta, {
            id = "mod.zeta",
            dependencies = '{"core.pkg",">=1.0.0"}',
            load_after = '"core.pkg"',
            preProcessors = appendProc("B"),
        }, modFiles("ZetaPatch.tsv"), {
            ["ZetaPatch.tsv"] = "name:name\tpatchOp:patch_op\ttrail:string|nil\n"
                .. "sword\tupdate\t\n",
        })
        local alpha = path_join(temp_dir, "alpha")
        local alphaProc = '{expr="(function() local r = rowByKey(\'item.tsv\', \'sword\'); '
            .. 'setCell(r, \'trail\', (r.trail or \'\') .. \'C\'); return true end)()",'
            .. 'requires={"mod.zeta"}}'
        writePackage(alpha, {
            id = "mod.alpha",
            dependencies = '{"core.pkg",">=1.0.0"}',
            load_after = '"core.pkg"',
            preProcessors = alphaProc,
        }, modFiles("AlphaPatch.tsv"), {
            ["AlphaPatch.tsv"] = "name:name\tpatchOp:patch_op\ttrail:string|nil\n"
                .. "sword\tupdate\t\n",
        })

        -- Pass alpha before zeta so the natural (input/load) order is alpha, zeta.
        local result = manifest_loader.processFiles({core, alpha, zeta}, badVal)
        assert.is_not_nil(result)
        assert.is_true(result.validationPassed,
            "load should pass; log:\n" .. table.concat(log_messages, "\n"))
        local item = findTsv(result, "Item%.tsv$")
        local byName, header = rowsByName(item)
        assert.are.equal("BC", readCell(byName.sword, header, "trail"))
    end)

    it("a cycle in requires is a hard error", function()
        local core = path_join(temp_dir, "core")
        writePackage(core, {id = "core.pkg"}, CORE_FILES, {
            ["Item.tsv"] = "name:name\ttrail:string|nil\n" .. "sword\t\n",
        })
        local function reqProc(letter, req)
            return '{expr="(function() local r = rowByKey(\'item.tsv\', \'sword\'); '
                .. 'setCell(r, \'trail\', (r.trail or \'\') .. \'' .. letter
                .. '\'); return true end)()",requires={"' .. req .. '"}}'
        end
        local a = path_join(temp_dir, "a")
        writePackage(a, {
            id = "mod.a",
            dependencies = '{"core.pkg",">=1.0.0"}',
            load_after = '"core.pkg"',
            preProcessors = reqProc("A", "mod.b"),
        }, modFiles("APatch.tsv"), {
            ["APatch.tsv"] = "name:name\tpatchOp:patch_op\ttrail:string|nil\n"
                .. "sword\tupdate\t\n",
        })
        local b = path_join(temp_dir, "b")
        writePackage(b, {
            id = "mod.b",
            dependencies = '{"core.pkg",">=1.0.0"}',
            load_after = '"core.pkg"',
            preProcessors = reqProc("B", "mod.a"),
        }, modFiles("BPatch.tsv"), {
            ["BPatch.tsv"] = "name:name\tpatchOp:patch_op\ttrail:string|nil\n"
                .. "sword\tupdate\t\n",
        })

        local result = manifest_loader.processFiles({core, a, b}, badVal)
        assert.is_not_nil(result)
        assert.is_false(result.validationPassed)
        local joined = table.concat(log_messages, "\n")
        assert.is_true(joined:find("cyclic", 1, true) ~= nil
            or joined:find("requires", 1, true) ~= nil,
            "expected a requires-cycle error, got:\n" .. joined)
    end)

    it("requiring an unloaded package warns but does not fail the load", function()
        local core = path_join(temp_dir, "core")
        writePackage(core, {id = "core.pkg"}, CORE_FILES, {
            ["Item.tsv"] = "name:name\ttrail:string|nil\n" .. "sword\t\n",
        })
        local mod = path_join(temp_dir, "mod")
        local proc = '{expr="(function() local r = rowByKey(\'item.tsv\', \'sword\'); '
            .. 'setCell(r, \'trail\', \'ok\'); return true end)()",'
            .. 'requires={"mod.notinstalled"}}'
        writePackage(mod, {
            id = "mod.x",
            dependencies = '{"core.pkg",">=1.0.0"}',
            load_after = '"core.pkg"',
            preProcessors = proc,
        }, modFiles("Patch.tsv"), {
            ["Patch.tsv"] = "name:name\tpatchOp:patch_op\ttrail:string|nil\n"
                .. "sword\tupdate\t\n",
        })

        local result = manifest_loader.processFiles({core, mod}, badVal)
        assert.is_not_nil(result)
        assert.is_true(result.validationPassed,
            "missing-require is a warning, not a failure; log:\n"
            .. table.concat(log_messages, "\n"))
        local item = findTsv(result, "Item%.tsv$")
        local byName, header = rowsByName(item)
        assert.are.equal("ok", readCell(byName.sword, header, "trail"))
    end)

    it("rerunAfterPatches re-derives a parent file processor over child-added rows", function()
        -- Core's Item.tsv has a file processor (rerunAfterPatches=true) that writes
        -- each row's `count` = number of rows. It runs once at load (count=1), then
        -- the mod adds a row via patch, then the rerun sets count=2 for every row.
        local core = path_join(temp_dir, "core")
        local coreFiles =
            "fileName:filepath\ttypeName:type_spec\tsuperType:super_type"
            .. "\tpreProcessors:{processor_spec}|nil\tloadOrder:number\tdescription:text\n"
            .. "Item.tsv\tItem\t\t"
            .. '{expr="(function() for _,r in ipairs(rows) do setCell(r, \'count\', #rows) end return true end)()",rerunAfterPatches=true}'
            .. "\t1\tItems\n"
        writePackage(core, {id = "core.pkg"}, coreFiles, {
            ["Item.tsv"] = "name:name\tcount:uint|nil\n" .. "sword\t\n",
        })
        local mod = path_join(temp_dir, "mod")
        writePackage(mod, {
            id = "mod.x",
            dependencies = '{"core.pkg",">=1.0.0"}',
            load_after = '"core.pkg"',
        }, modFiles("Patch.tsv"), {
            ["Patch.tsv"] = "name:name\tpatchOp:patch_op\tcount:uint|nil\n"
                .. "shield\tadd\t\n",
        })

        local result = manifest_loader.processFiles({core, mod}, badVal)
        assert.is_not_nil(result)
        assert.is_true(result.validationPassed,
            "load should pass; log:\n" .. table.concat(log_messages, "\n"))
        local item = findTsv(result, "Item%.tsv$")
        assert.are.equal(2, countDataRows(item))
        local byName, header = rowsByName(item)
        -- Both the original and the added row see the post-patch count.
        assert.are.equal(2, readCell(byName.sword, header, "count"))
        assert.are.equal(2, readCell(byName.shield, header, "count"))
    end)
end)
