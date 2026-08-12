-- spec_helper.lua - loads incenter_core.lua against a fake `reaper` API so
-- it can be unit-tested outside REAPER itself.

local CORE_PATH = (debug.getinfo(1, "S").source:match("^@(.*/)") or "./")
  .. "../../incenter_core.lua"

-- Builds a fresh fake reaper table. Each spec gets its own instance (and its
-- own ExtState store) so tests can't leak state into one another.
local function new_reaper(overrides)
  local ext_state = {}

  local r = {
    GetOS = function() return "OSX64" end,
    time_precise = function() return os.clock() end,

    GetExtState = function(section, key)
      return (ext_state[section] and ext_state[section][key]) or ""
    end,
    SetExtState = function(section, key, value)
      ext_state[section] = ext_state[section] or {}
      ext_state[section][key] = value
    end,
    DeleteExtState = function(section, key)
      if ext_state[section] then ext_state[section][key] = nil end
    end,

    -- Actually runs the wrapper script via the real OS, so run_worker's
    -- shell-quoting / sidecar-file machinery gets exercised for real.
    ExecProcess = function(cmd, _timeout_ms)
      os.execute(cmd)
    end,

    GetProjectPathEx = function(_proj, _buf) return "" end,
  }

  for k, v in pairs(overrides or {}) do r[k] = v end
  r.__ext_state = ext_state
  return r
end

-- Loads a fresh copy of the core module with the given reaper overrides.
-- Returns core, fake_reaper.
local function load_core(overrides)
  local fake = new_reaper(overrides)
  _G.reaper = fake
  local chunk = assert(loadfile(CORE_PATH))
  local core = chunk()
  return core, fake
end

return { load_core = load_core, new_reaper = new_reaper }
