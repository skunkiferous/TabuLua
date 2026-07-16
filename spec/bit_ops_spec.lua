-- bit_ops_spec.lua
-- Cross-version 32-bit bitwise primitives (util/bit_ops.lua). The point of
-- the module is that these answers are IDENTICAL on Lua 5.3+ (native
-- operators) and LuaJIT (bit library), always in the unsigned [0, 2^32)
-- range — so the assertions below are version-independent by design.

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local bit_ops = require("util.bit_ops")

describe("bit_ops", function()
  describe("band", function()
    it("should mask bits", function()
      assert.equals(0x0F, bit_ops.band(0xFF, 0x0F))
      assert.equals(0, bit_ops.band(0xF0, 0x0F))
      assert.equals(0xFFFFFFFF, bit_ops.band(0xFFFFFFFF, 0xFFFFFFFF))
    end)
  end)

  describe("bor", function()
    it("should combine bits", function()
      assert.equals(0xFF, bit_ops.bor(0xF0, 0x0F))
      assert.equals(0x0F, bit_ops.bor(0x0F, 0x0F))
    end)
  end)

  describe("bxor", function()
    it("should toggle bits", function()
      assert.equals(0xFF, bit_ops.bxor(0xF0, 0x0F))
      assert.equals(0, bit_ops.bxor(0xAA, 0xAA))
    end)

    it("should stay unsigned when the high bit is set", function()
      -- On LuaJIT the raw bit library answers a NEGATIVE number here;
      -- the module contract normalizes to [0, 2^32)
      assert.equals(0xFFFFFFFF, bit_ops.bxor(0, 0xFFFFFFFF))
      assert.equals(0x80000000, bit_ops.bxor(0x7FFFFFFF, 0xFFFFFFFF))
      assert.equals(0x12345678, bit_ops.bxor(bit_ops.bxor(0x12345678, 0xEDB88320), 0xEDB88320))
    end)
  end)

  describe("shifts", function()
    it("should shift left within 32 bits", function()
      assert.equals(2, bit_ops.lshift(1, 1))
      assert.equals(0x80000000, bit_ops.lshift(1, 31))
    end)

    it("should shift right logically (zero-fill)", function()
      assert.equals(1, bit_ops.rshift(2, 1))
      assert.equals(1, bit_ops.rshift(0x80000000, 31))
      assert.equals(0x00EDB883, bit_ops.rshift(0xEDB88320, 8))
    end)
  end)

  describe("CRC-32 building blocks", function()
    it("should compute the canonical CRC-32 check value", function()
      -- The exact kernel content/compression.lua's crc32 runs, against the
      -- canonical "123456789" check value 0xCBF43926 (IEEE 802.3)
      local band, bxor, rshift = bit_ops.band, bit_ops.bxor, bit_ops.rshift
      local t = {}
      for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
          if band(c, 1) ~= 0 then
            c = bxor(0xEDB88320, rshift(c, 1))
          else
            c = rshift(c, 1)
          end
        end
        t[i] = c
      end
      local s = "123456789"
      local crc = 0xFFFFFFFF
      for i = 1, #s do
        crc = bxor(rshift(crc, 8), t[band(bxor(crc, s:byte(i)), 0xFF)])
      end
      assert.equals(0xCBF43926, bxor(crc, 0xFFFFFFFF))
    end)
  end)

  describe("module API", function()
    it("should return a version string", function()
      local version = bit_ops.getVersion()
      assert.is_string(version)
      assert.matches("^%d+%.%d+%.%d+$", version)
    end)
  end)
end)
