-- readonly_spec.lua

-- Explicit requires for Busted functions and assertions
local busted = require("busted")
local assert = require("luassert")

-- Import the functions we'll use from busted
local describe = busted.describe
local it = busted.it

local read_only = require("read_only")

describe("read_only", function()
  describe("readOnly", function()
    it("should prevent modification of basic tables", function()
      local t = {a = 1, b = 2, c = 3}
      local ro = read_only.readOnly(t)

      assert.equals(1, ro.a)
      assert.equals(2, ro.b)
      assert.equals(3, ro.c)

      assert.has_error(function()
        ro.a = 10
      end, "attempt to update a read-only table")

      assert.has_error(function()
        ro.new_key = "value"
      end, "attempt to update a read-only table")
    end)

    it("should make nested tables read-only", function()
      local t = {
        a = 1,
        b = {
          x = 10,
          y = 20
        }
      }
      local ro = read_only.readOnly(t)

      assert.equals(10, ro.b.x)
      assert.equals(20, ro.b.y)

      assert.has_error(function()
        ro.b.x = 100
      end, "attempt to update a read-only table")
    end)

    it("should handle array-like tables", function()
      local t = {1, 2, 3, 4, 5}
      local ro = read_only.readOnly(t)

      assert.equals(5, #ro)
      assert.equals(1, ro[1])
      assert.equals(5, ro[5])

      assert.has_error(function()
        ro[1] = 10
      end, "attempt to update a read-only table")
    end)

    it("should work with custom metatables through opt_index", function()
      local t = {x = 1, y = 2}
      local opt_index = {
        __tostring = function(t) return "CustomTable" end,
        __call = function(t, x) return t.x + x end,
        __type = "custom_type"
      }

      local ro = read_only.readOnly(t, opt_index)

      assert.equals("CustomTable", tostring(ro))
      assert.equals(11, ro(10))  -- Should call __call metamethod (1 + 10)
      assert.equals("custom_type", getmetatable(ro))
    end)

    it("should prevent modifications through pairs/ipairs", function()
      local t = {a = 1, b = 2, c = {x = 10}}
      local ro = read_only.readOnly(t)

      -- Test pairs iteration
      for k, v in pairs(ro) do
        assert.has_error(function()
          ro[k] = 42
        end, "attempt to update a read-only table")
      end

      -- Test nested table through pairs
      for k, v in pairs(ro.c) do
        assert.has_error(function()
          ro.c[k] = v + 1
        end, "attempt to update a read-only table")
      end

      -- Test array part with ipairs
      local arr = {1, 2, 3}
      local ro_arr = read_only.readOnly(arr)
      for i, v in ipairs(ro_arr) do
        assert.has_error(function()
          ro_arr[i] = v + 1
        end, "attempt to update a read-only table")
      end
    end)

    it("should handle custom __index function in opt_index", function()
      local t = {x = 1}
      local opt_index = {
        __index = function(t, k)
          if k == "computed" then
            return t.x * 2
          end
        end
      }

      local ro = read_only.readOnly(t, opt_index)

      assert.equals(1, ro.x)
      assert.equals(2, ro.computed)  -- Should be computed via custom __index
      assert.is_nil(ro.nonexistent)
    end)

    it("should not wrap non-table values", function()
      local number = 42
      local string = "test"
      local boolean = true

      assert.equals(42, read_only.readOnly(number))
      assert.equals("test", read_only.readOnly(string))
      assert.equals(true, read_only.readOnly(boolean))
    end)

    it("should not re-wrap already read-only tables", function()
      local t = {x = 1}
      local ro1 = read_only.readOnly(t)
      local ro2 = read_only.readOnly(ro1)

      -- ro2 should be the same table as ro1
      assert.equals(ro1, ro2)
    end)

    it("should ensure length operator works correctly", function()
      local t = {1, 2, 3, 4, 5}
      local ro = read_only.readOnly(t)

      assert.equals(5, #t)
      assert.equals(5, #ro)
    end)

    it("should be aware that next() bypasses metamethods", function()
      local t = {a = {x = 1}}
      local ro = read_only.readOnly(t)

      -- But the wrapped access still works
      assert.has_error(function()
        ro.a.x = 3
      end, "attempt to update a read-only table")

      -- And accessing through pairs() still gives read-only values
      for k, v in pairs(ro) do
        assert.has_error(function()
          v.x = 4
        end, "attempt to update a read-only table")
      end

      -- next() bypasses metamethods and returns raw values
      local next_key, next_value = next(ro)

      -- This modification will work because next() returned the unwrapped table
      next_value.x = 2
    end)

    it("should return tables with existing metatables unchanged", function()
      -- Tables with metatables cannot be made read-only (they are returned as-is)
      local mt = {__index = function() return "default" end}
      local t = setmetatable({x = 1}, mt)

      local ro = read_only.readOnly(t)

      -- Should be the same table, not wrapped
      assert.equals(t, ro)
      -- The metatable is still the original one
      assert.equals(mt, getmetatable(ro))
      -- Can still be modified (since it wasn't wrapped)
      ro.x = 2
      assert.equals(2, ro.x)
    end)

    it("should handle nil input", function()
      local result = read_only.readOnly(nil)
      assert.is_nil(result)
    end)

    it("should handle function values inside wrapped tables", function()
      local function myFunc(x)
        return x * 2
      end

      local t = {
        fn = myFunc,
        nested = {
          innerFn = function(y) return y + 1 end
        }
      }

      local ro = read_only.readOnly(t)

      -- Functions should still be callable
      assert.equals(10, ro.fn(5))
      assert.equals(6, ro.nested.innerFn(5))

      -- The function values themselves are returned (functions are immutable)
      assert.equals("function", type(ro.fn))
      assert.equals("function", type(ro.nested.innerFn))

      -- Table is still read-only
      assert.has_error(function()
        ro.fn = function() end
      end, "attempt to update a read-only table")
    end)

    it("should handle empty opt_index table", function()
      local t = {x = 1, y = 2}
      local empty_opt_index = {}

      local ro = read_only.readOnly(t, empty_opt_index)

      -- Should still work like a normal read-only table
      assert.equals(1, ro.x)
      assert.equals(2, ro.y)

      -- Should still prevent modifications
      assert.has_error(function()
        ro.x = 10
      end, "attempt to update a read-only table")

      -- Standard read-only metatable should be used (not custom)
      assert.equals("read-only table", getmetatable(ro))
    end)
  end)

  describe("readOnlyTuple", function()
    it("should make tuple read-only", function()
      local t = {10, 20, 30}
      local ro = read_only.readOnlyTuple(t)

      assert.equals(10, ro[1])
      assert.equals(20, ro[2])
      assert.equals(30, ro[3])

      assert.has_error(function()
        ro[1] = 100
      end, "attempt to update a read-only table")
    end)

    it("should provide _<integer> aliases for tuple fields", function()
      local t = {10, 20, 30}
      local ro = read_only.readOnlyTuple(t)

      -- Access by index
      assert.equals(10, ro[1])
      assert.equals(20, ro[2])
      assert.equals(30, ro[3])

      -- Access by alias
      assert.equals(10, ro._1)
      assert.equals(20, ro._2)
      assert.equals(30, ro._3)
    end)

    it("should not allow _0 or negative aliases", function()
      local t = {10, 20, 30}
      local ro = read_only.readOnlyTuple(t)

      assert.is_nil(ro._0)
      assert.is_nil(ro["_-1"])
    end)

    it("should return nil for non-existent aliases", function()
      local t = {10, 20}
      local ro = read_only.readOnlyTuple(t)

      assert.is_nil(ro._3)
      assert.is_nil(ro._100)
      assert.is_nil(ro.foo)
      assert.is_nil(ro["_abc"])
    end)

    it("should have 'tuple' as metatable type", function()
      local t = {10, 20, 30}
      local ro = read_only.readOnlyTuple(t)

      assert.equals("tuple", getmetatable(ro))
    end)

    it("should make nested tables read-only", function()
      local t = {{1, 2}, {3, 4}}
      local ro = read_only.readOnlyTuple(t)

      assert.equals(1, ro[1][1])
      assert.equals(1, ro._1[1])

      assert.has_error(function()
        ro[1][1] = 100
      end, "attempt to update a read-only table")
    end)

    it("should preserve length operator", function()
      local t = {10, 20, 30, 40, 50}
      local ro = read_only.readOnlyTuple(t)

      assert.equals(5, #ro)
    end)

    it("should work with ipairs", function()
      local t = {10, 20, 30}
      local ro = read_only.readOnlyTuple(t)

      local sum = 0
      for _, v in ipairs(ro) do
        sum = sum + v
      end
      assert.equals(60, sum)
    end)

    it("should return error for non-table input", function()
      local result, err = read_only.readOnlyTuple("not a table")
      assert.is_nil(result)
      assert.equals("readOnlyTuple expects a table, got string", err)

      result, err = read_only.readOnlyTuple(123)
      assert.is_nil(result)
      assert.equals("readOnlyTuple expects a table, got number", err)
    end)

    describe("with validation", function()
      it("should accept valid tuples", function()
        local t = {10, 20, 30}
        local ro, err = read_only.readOnlyTuple(t, true)

        assert.is_nil(err)
        assert.equals(10, ro._1)
      end)

      it("should reject tables with non-integer keys", function()
        local t = {10, 20, foo = "bar"}
        local ro, err = read_only.readOnlyTuple(t, true)

        assert.is_nil(ro)
        assert.matches("non%-positive%-integer key", err)
      end)

      it("should reject tables with non-positive keys", function()
        local t = {[0] = 10, [1] = 20}
        local ro, err = read_only.readOnlyTuple(t, true)

        assert.is_nil(ro)
        assert.matches("non%-positive%-integer key", err)
      end)

      it("should reject tables with holes", function()
        local t = {[1] = 10, [3] = 30}
        local ro, err = read_only.readOnlyTuple(t, true)

        assert.is_nil(ro)
        assert.matches("hole at index 2", err)
      end)

      it("should accept empty tables", function()
        local t = {}
        local ro, err = read_only.readOnlyTuple(t, true)

        assert.is_nil(err)
        assert.equals(0, #ro)
      end)
    end)
  end)

  describe("unwrap", function()
    it("should unwrap read-only tables to original table", function()
      local t = {x = 1, y = 2}
      local ro = read_only.readOnly(t)

      local unwrapped = read_only.unwrap(ro)
      assert.equals(t, unwrapped)
    end)

    it("should unwrap read-only tuples to original table", function()
      local t = {10, 20, 30}
      local ro = read_only.readOnlyTuple(t)

      local unwrapped = read_only.unwrap(ro)
      assert.equals(t, unwrapped)
    end)

    it("should return non-read-only tables unchanged", function()
      local t = {x = 1, y = 2}
      local result = read_only.unwrap(t)
      assert.equals(t, result)
    end)

    it("should return non-table values unchanged", function()
      assert.equals(42, read_only.unwrap(42))
      assert.equals("hello", read_only.unwrap("hello"))
      assert.equals(true, read_only.unwrap(true))
      assert.is_nil(read_only.unwrap(nil))
    end)

    it("should allow modification of unwrapped table", function()
      local t = {x = 1}
      local ro = read_only.readOnly(t)

      -- Cannot modify through read-only proxy
      assert.has_error(function()
        ro.x = 10
      end, "attempt to update a read-only table")

      -- But can modify the unwrapped original
      local unwrapped = read_only.unwrap(ro)
      unwrapped.x = 10
      assert.equals(10, t.x)
      assert.equals(10, ro.x)  -- Change visible through proxy too
    end)
  end)

  describe("module API", function()
    describe("getVersion", function()
      it("should return a version string", function()
        local version = read_only.getVersion()
        assert.is_string(version)
        assert.matches("^%d+%.%d+%.%d+$", version)
      end)
    end)

    describe("callable API", function()
      it("should return version when called with 'version'", function()
        local version = read_only("version")
        assert.is_not_nil(version)
        -- Version is a semver object
        assert.are.equal(read_only.getVersion(), tostring(version))
      end)

      it("should call API functions when called with function name", function()
        local t = {a = 1, b = 2}
        local result = read_only("readOnly", t)
        assert.equals(1, result.a)
        assert.has_error(function()
          result.a = 10
        end, "attempt to update a read-only table")
      end)

      it("should error on unknown operation", function()
        assert.has_error(function()
          read_only("nonexistent_operation")
        end, "Unknown operation: nonexistent_operation")
      end)
    end)

    describe("__tostring", function()
      it("should return module name and version", function()
        local str = tostring(read_only)
        assert.is_string(str)
        assert.matches("^read_only version %d+%.%d+%.%d+$", str)
      end)
    end)
  end)
end)
