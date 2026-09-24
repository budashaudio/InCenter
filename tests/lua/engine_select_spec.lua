-- engine_select_spec.lua - engine selection (Python vs the built-in EEL
-- fallback), run with `busted` against a fake `reaper` API. Covers only the
-- plain-Lua decision logic; the EEL DSP itself can't run outside REAPER.

local helper = require("spec_helper")
local load_core = helper.load_core

local EEL_PATH = (debug.getinfo(1, "S").source:match("^@(.*/)") or "./")
  .. "../../Budash Audio/incenter_eel.lua"

describe("core.select_engine", function()
  local function core_with_python(found_path)
    local core = load_core()
    core.python_has_deps = function(p) return p == found_path end
    return core
  end

  describe("auto (FORCE_ENGINE = nil)", function()
    it("uses Python when a Python with numpy is found", function()
      local core = core_with_python("/usr/bin/python3")
      local sel = core.select_engine{ has_eel_api = true }
      assert.equal("python", sel.engine)
      assert.equal("/usr/bin/python3", sel.python)
      assert.is_false(sel.forced)
    end)

    it("uses Python even when the EEL API is missing", function()
      local core = core_with_python("/usr/bin/python3")
      local sel = core.select_engine{ has_eel_api = false }
      assert.equal("python", sel.engine)
    end)

    it("uses a cached Python path without probing", function()
      local core = load_core()
      _G.reaper.SetExtState("incenter", "python_path", "/cached/python3")
      core.python_has_deps = function() error("should not be probed") end
      local sel = core.select_engine{ has_eel_api = true }
      assert.equal("python", sel.engine)
      assert.equal("/cached/python3", sel.python)
    end)

    it("falls back to EEL when no Python is found", function()
      local core = core_with_python(nil)
      local sel = core.select_engine{ has_eel_api = true }
      assert.equal("eel", sel.engine)
      assert.is_false(sel.forced)
      assert.is_nil(sel.python)
      -- says why Python was passed over, for the panel / support
      assert.is_string(sel.python_error)
    end)

    it("falls back to EEL when a PYTHON_OVERRIDE is unusable", function()
      local core = load_core()
      core.python_has_deps = function() return false end
      local sel = core.select_engine{ python_override = "/nope/python3", has_eel_api = true }
      assert.equal("eel", sel.engine)
      assert.matches("doesn't exist", sel.python_error)
    end)

    it("errors with one message naming both options when neither engine is available", function()
      local core = core_with_python(nil)
      local sel, err = core.select_engine{ has_eel_api = false }
      assert.is_nil(sel)
      assert.matches("Python 3 with numpy", err)
      assert.matches("ReaImGui 0.8.5", err)
    end)
  end)

  describe('FORCE_ENGINE = "python"', function()
    it("uses Python when found", function()
      local core = core_with_python("/usr/bin/python3")
      local sel = core.select_engine{ force = "python", has_eel_api = true }
      assert.equal("python", sel.engine)
      assert.is_true(sel.forced)
    end)

    it("errors, without falling back to EEL, when Python is not found", function()
      local core = core_with_python(nil)
      local sel, err = core.select_engine{ force = "python", has_eel_api = true }
      assert.is_nil(sel)
      assert.matches("numpy", err)
    end)
  end)

  describe('FORCE_ENGINE = "eel"', function()
    it("uses EEL even though Python is available, without probing for it", function()
      local core = load_core()
      core.python_has_deps = function() error("should not be probed") end
      core.find_python = function() error("should not be called") end
      local sel = core.select_engine{ force = "eel", has_eel_api = true }
      assert.equal("eel", sel.engine)
      assert.is_true(sel.forced)
    end)

    it("errors with an update-ReaImGui message when the EEL API is missing", function()
      local core = core_with_python("/usr/bin/python3")
      local sel, err = core.select_engine{ force = "eel", has_eel_api = false }
      assert.is_nil(sel)
      assert.matches("ReaImGui 0.8.5", err)
    end)
  end)

  describe("bad FORCE_ENGINE values", function()
    it("rejects an unknown string", function()
      local core = core_with_python("/usr/bin/python3")
      local sel, err = core.select_engine{ force = "numpy", has_eel_api = true }
      assert.is_nil(sel)
      assert.matches("FORCE_ENGINE", err)
    end)

    it("treats an empty string like nil (auto)", function()
      local core = core_with_python("/usr/bin/python3")
      local sel = core.select_engine{ force = "", has_eel_api = true }
      assert.equal("python", sel.engine)
    end)
  end)
end)

describe("incenter_eel (orchestration only; the DSP runs in REAPER)", function()
  local function load_eel(overrides)
    local core, fake = load_core(overrides)
    local eel = assert(loadfile(EEL_PATH))()
    return eel, core, fake
  end

  describe("check_take", function()
    it("accepts playrate 1.0", function()
      local eel = load_eel{ GetMediaItemTakeInfo_Value = function() return 1.0 end }
      assert.is_nil(eel.check_take({}))
    end)

    it("refuses any other playrate with a clear reason", function()
      local eel = load_eel{ GetMediaItemTakeInfo_Value = function() return 2.0 end }
      assert.matches("playrate is not 1.0", eel.check_take({}))
    end)
  end)

  describe("run_batch", function()
    it("turns a failure in one job into that job's error, not a crash", function()
      -- No GetMediaItemTake_Source in the fake: process_take raises.
      local eel, core = load_eel()
      local jobs = { k1 = { src_path = "/tmp/a.wav", take = {} } }
      local ok_map, err_map, output, diag_map = eel.run_batch(core, jobs, {
        strength = 1.0, tail_strength = 1.0, collapse = 0.0, win = "auto" }, "/tmp/")
      assert.same({}, ok_map)
      assert.is_string(err_map.k1)
      assert.equal("", output)
      assert.same({}, diag_map)
    end)

    it("reports 'not stereo' for a non-stereo take, via the same err_map", function()
      local eel, core = load_eel{
        GetMediaItemTake_Source = function() return {} end,
        GetMediaSourceNumChannels = function() return 1 end,
      }
      local _, err_map = eel.run_batch(core, { k1 = { src_path = "/tmp/a.wav", take = {} } },
        { strength = 1.0, tail_strength = 1.0, collapse = 0.0, win = "auto" }, "/tmp/")
      assert.matches("not stereo", err_map.k1)
    end)
  end)
end)
