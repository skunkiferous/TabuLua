-- compression_spec.lua

local busted = require("busted")
local assert = require("luassert")

local describe = busted.describe
local it = busted.it

local compression = require("compression")

-- A real gzip stream (system `gzip -cn`) of "id\tvalue\nitem1\t42\nitem2\t100\n".
local REAL_GZIP =
  "\031\139\008\000\000\000\000\000\000\003\203\076\225\044\075\204\041\077" ..
  "\229\202\044\073\205\053\228\052\049\002\051\140\056\013\013\012\184\000" ..
  "\089\077\045\070\028\000\000\000"
local REAL_GZIP_PLAIN = "id\tvalue\nitem1\t42\nitem2\t100\n"

describe("compression", function()
  describe("getVersion", function()
    it("returns a version string", function()
      assert.is_truthy(compression.getVersion():match("%d+%.%d+%.%d+"))
    end)
  end)

  describe("isSupported", function()
    it("reports gzip decompression as supported (libdeflate installed)", function()
      assert.is_true(compression.isSupported("gzip", "decompress"))
    end)

    it("reports gzip compression as supported (libdeflate installed)", function()
      assert.is_true(compression.isSupported("gzip", "compress"))
    end)

    it("reports an unknown format as unsupported", function()
      assert.is_false(compression.isSupported("zstd", "decompress"))
    end)
  end)

  describe("decompress (gzip)", function()
    it("inflates a real gzip stream", function()
      local data, err = compression.decompress("gzip", REAL_GZIP)
      assert.is_nil(err)
      assert.equals(REAL_GZIP_PLAIN, data)
    end)

    it("rejects output over maxBytes (bomb cap) without inflating", function()
      -- REAL_GZIP expands to 29 bytes; a 5-byte cap trips the ISIZE pre-check.
      local data, err = compression.decompress("gzip", REAL_GZIP, 5)
      assert.is_nil(data)
      assert.matches("exceeds", err)
    end)

    it("honours a maxBytes large enough for the payload", function()
      local data = compression.decompress("gzip", REAL_GZIP, 1024)
      assert.equals(REAL_GZIP_PLAIN, data)
    end)

    it("fails on a corrupt stream", function()
      local corrupt = string.char(0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03)
        .. ("\255"):rep(20)
      local data, err = compression.decompress("gzip", corrupt)
      assert.is_nil(data)
      assert.is_string(err)
    end)

    it("returns an error for an unknown format", function()
      local data, err = compression.decompress("brotli", "whatever")
      assert.is_nil(data)
      assert.matches("no decompress provider", err)
    end)
  end)

  describe("compress (gzip)", function()
    it("produces a stream with the gzip magic and deflate method", function()
      local gz = compression.compress("gzip", REAL_GZIP_PLAIN)
      assert.is_string(gz)
      assert.equals(0x1f, gz:byte(1))
      assert.equals(0x8b, gz:byte(2))
      assert.equals(0x08, gz:byte(3))   -- CM = deflate
    end)

    it("round-trips through our own gunzip provider", function()
      local original = "id\tvalue\nitem1\t42\nitem2\t100\n"
      local gz = compression.compress("gzip", original)
      local back, err = compression.decompress("gzip", gz)
      assert.is_nil(err)
      assert.equals(original, back)
    end)

    it("round-trips an empty string", function()
      local gz = compression.compress("gzip", "")
      assert.equals("", compression.decompress("gzip", gz))
    end)

    it("round-trips binary data containing NULs and high bytes", function()
      local original = string.char(0, 255, 10, 13, 0, 1, 2, 254):rep(500)
      local gz = compression.compress("gzip", original)
      assert.equals(original, compression.decompress("gzip", gz))
    end)

    it("writes the correct ISIZE (original length mod 2^32) in the trailer", function()
      local original = ("x"):rep(1234)
      local gz = compression.compress("gzip", original)
      local n = #gz
      local isize = gz:byte(n - 3) + gz:byte(n - 2) * 256
        + gz:byte(n - 1) * 65536 + gz:byte(n) * 16777216
      assert.equals(1234, isize)
    end)

    it("honours the deflate level option", function()
      local original = ("ab"):rep(2000)
      local back = compression.decompress("gzip", compression.compress("gzip", original, {level = 9}))
      assert.equals(original, back)
    end)

    it("rejects a non-string input", function()
      local data, err = compression.compress("gzip", 42)
      assert.is_nil(data)
      assert.is_string(err)
    end)

    it("returns an error for an unknown format", function()
      local data, err = compression.compress("brotli", "whatever")
      assert.is_nil(data)
      assert.matches("no compress provider", err)
    end)
  end)

  -- The heart of the "optionally supported" design: a codec whose dependency
  -- cannot be loaded degrades to "not supported" rather than blowing up, and a
  -- pipeline that never uses it is unaffected.
  describe("provider resolution", function()
    it("uses a provider whose loader returns an operation function", function()
      compression.registerProvider("test_ok", "decompress", function()
        return function(bytes, _maxBytes) return "decoded:" .. bytes end
      end)
      assert.is_true(compression.isSupported("test_ok", "decompress"))
      assert.equals("decoded:abc", compression.decompress("test_ok", "abc"))
    end)

    it("treats a missing dependency as unsupported (loader returns nil, reason)", function()
      compression.registerProvider("test_missing", "decompress", function()
        return nil, "pretend-rock is not installed"
      end)
      assert.is_false(compression.isSupported("test_missing", "decompress"))
      local data, err = compression.decompress("test_missing", "x")
      assert.is_nil(data)
      assert.matches("pretend%-rock is not installed", err)
    end)

    it("treats a loader that raises as unsupported (graceful)", function()
      compression.registerProvider("test_raise", "decompress", function()
        error("boom while loading")
      end)
      assert.is_false(compression.isSupported("test_raise", "decompress"))
      local data, err = compression.decompress("test_raise", "x")
      assert.is_nil(data)
      assert.is_string(err)
    end)

    it("loads each provider at most once and caches the result", function()
      local calls = 0
      compression.registerProvider("test_count", "decompress", function()
        calls = calls + 1
        return function(b) return b end
      end)
      compression.decompress("test_count", "a")
      compression.isSupported("test_count", "decompress")
      compression.decompress("test_count", "b")
      assert.equals(1, calls)
    end)

    it("validates registerProvider arguments", function()
      assert.has_error(function() compression.registerProvider("", "decompress", function() end) end)
      assert.has_error(function() compression.registerProvider("x", "sideways", function() end) end)
      assert.has_error(function() compression.registerProvider("x", "decompress", "nope") end)
    end)
  end)
end)
