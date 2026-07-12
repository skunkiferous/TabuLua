-- glob_spec.lua
--
-- util/glob.lua: the path globs behind the manifest's asset_files / ignored_files.
-- The two rules worth pinning down are that `*` never crosses a "/" (so a glob is
-- about files, not about paths that happen to contain the right characters), and
-- that a glob with NO "/" matches by BASENAME at any depth — the gitignore rule,
-- and what "*.tmp.tsv" plainly means.

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local glob = require("util.glob")
local matches = glob.matches

describe("glob", function()
    describe("* stays inside one path segment", function()
        it("matches within a segment", function()
            assert.is_true(matches("Item*.tsv", "ItemFoo.tsv"))
            assert.is_true(matches("*.tsv", "Item.tsv"))
            assert.is_true(matches("data/*.tsv", "data/Item.tsv"))
        end)

        it("does NOT cross a directory separator", function()
            -- The bug a naive "* -> .*" translation gives you: data/*.tsv would
            -- swallow data/deep/Item.tsv, and an ignore glob would take out files
            -- the author never named.
            assert.is_false(matches("data/*.tsv", "data/deep/Item.tsv"))
            assert.is_false(matches("data/*", "data/deep/Item.tsv"))
        end)
    end)

    describe("** crosses segments, including none", function()
        it("matches any depth under a directory", function()
            assert.is_true(matches("scratch/**", "scratch/a.tsv"))
            assert.is_true(matches("scratch/**", "scratch/deep/b.tsv"))
            assert.is_true(matches("scratch/**", "scratch/very/deep/c.tsv"))
        end)

        it("matches zero segments", function()
            assert.is_true(matches("**/Item.tsv", "Item.tsv"))
            assert.is_true(matches("**/Item.tsv", "a/b/Item.tsv"))
        end)

        it("is anchored to the package root, not to any 'scratch' anywhere", function()
            assert.is_false(matches("scratch/**", "sub/scratch/a.tsv"))
        end)

        it("matches everything when alone", function()
            assert.is_true(matches("**", "a/b/c.tsv"))
            assert.is_true(matches("**", "x.md"))
        end)
    end)

    describe("a glob with no / matches the basename at any depth", function()
        it("catches the file wherever it sits", function()
            -- What a package author writing "*.tmp.tsv" means: a temp file is a
            -- temp file whatever directory it landed in.
            assert.is_true(matches("*.tmp.tsv", "x.tmp.tsv"))
            assert.is_true(matches("*.tmp.tsv", "sub/x.tmp.tsv"))
            assert.is_true(matches("*.tmp.tsv", "a/b/c/x.tmp.tsv"))
            assert.is_false(matches("*.tmp.tsv", "x.tsv"))
        end)

        it("still respects a leading path when one is given", function()
            -- With a "/" the glob is anchored, so it is NOT a basename match.
            assert.is_false(matches("./*.tmp.tsv", "sub/x.tmp.tsv"))
        end)
    end)

    describe("? and literals", function()
        it("matches exactly one character, inside a segment", function()
            assert.is_true(matches("Item?.tsv", "Item1.tsv"))
            assert.is_false(matches("Item?.tsv", "Item12.tsv"))
            assert.is_false(matches("a?b", "a/b"))
        end)

        it("treats Lua pattern magic as literal text", function()
            -- "." must not mean "any character", or "*.tsv" would match "Xtsv".
            assert.is_true(matches("a+b.tsv", "a+b.tsv"))
            assert.is_false(matches("a.tsv", "axtsv"))
        end)
    end)

    describe("normalization", function()
        it("is case-insensitive and separator-agnostic", function()
            assert.is_true(matches("Scratch/**", "scratch/A.TSV"))
            assert.is_true(matches("scratch\\*.tsv", "scratch/a.tsv"))
        end)
    end)

    describe("matcher", function()
        it("returns nil for no globs, so callers can skip the test entirely", function()
            assert.is_nil(glob.matcher(nil))
            assert.is_nil(glob.matcher({}))
        end)

        it("matches ANY of the globs", function()
            local m = glob.matcher({"*.tmp.tsv", "scratch/**"})
            assert.is_true(m("x.tmp.tsv"))
            assert.is_true(m("scratch/deep/y.tsv"))
            assert.is_false(m("Item.tsv"))
        end)
    end)
end)
