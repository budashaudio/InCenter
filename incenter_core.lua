-- incenter_core.lua - shared core for InCenter  [v0.9.0]
-- @noindex
--
-- InCenter - stereo re-centering for foley/field recordings
-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Budash Audio
--
-- This file is NOT a standalone REAPER action. It holds the REAPER-side
-- mechanics shared by the two front-ends:
--   * BudashAudio_InCenter.lua              (ReaImGui control panel)
--   * BudashAudio_InCenter (batch, no GUI).lua
-- Both do `local core = dofile(script_dir .. "/incenter_core.lua")` and
-- call into the table it returns. Keeping it in one place means a fix to
-- the process runner, the source-swap, or the Python finder happens once
-- instead of being copied between two files that then drift apart.

local core = {}

core.VERSION = "0.9.0"

-- Platform detection. reaper.GetOS() returns strings like "OSX64",
-- "macOS-arm64", "Win64", "Win32", "Other" (Linux). We only need to know
-- Windows vs POSIX (macOS/Linux behave the same for our shell needs).
core.IS_WIN = (reaper.GetOS() or ""):match("^Win") ~= nil
local SEP = core.IS_WIN and "\\" or "/"

-- Seed the RNG once, with something that differs between REAPER instances
-- and between launches within the same second, so tmp_path() names from
-- two running copies can't collide. time_precise() adds sub-second entropy
-- that os.time() alone (whole seconds) doesn't have.
math.randomseed(os.time() + math.floor((reaper.time_precise() or 0) * 1e6))

-- ---- small helpers ---------------------------------------------------

function core.file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- Shell quoting, per platform.
-- POSIX: single quotes are safe against $, backticks, backslashes, spaces.
--   The '\'' idiom closes the quote, inserts an escaped literal quote,
--   reopens. Double-quoting would still let the shell expand $VAR / `cmd`.
-- Windows (cmd.exe): single quotes are literal characters, not quoting;
--   arguments are wrapped in double quotes instead. A literal double quote
--   inside is escaped as "" (cmd's convention). Paths with % are left as-is
--   here (see run_worker for how the .bat avoids delayed expansion).
function core.shell_quote(s)
  s = tostring(s)
  if core.IS_WIN then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function core.split_ext(path)
  -- Accept both separators so this works on Windows paths too.
  local dir, base = path:match("^(.*[/\\])([^/\\]*)$")
  if not dir then dir = ""; base = path end
  local name, ext = base:match("^(.*)(%.[^.]*)$")
  if not name then name = base; ext = "" end
  return dir, name, ext
end

-- basename that understands both separators (used for status messages).
function core.basename(path)
  return path:match("[^/\\]*$") or path
end

-- The Lua binding for some source getters has changed shape across REAPER
-- versions: older builds take an output buffer, newer ones return the
-- string directly. Try both shapes.
function core.source_string(fn, src)
  local ok, value = pcall(fn, src, "")
  if ok and type(value) == "string" then return value end
  ok, value = pcall(fn, src)
  if ok and type(value) == "string" then return value end
  return ""
end

function core.tmp_path(suffix)
  local base = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP")
    or (core.IS_WIN and (os.getenv("USERPROFILE") or "C:\\Temp") or "/tmp")
  if base:sub(-1) ~= "/" and base:sub(-1) ~= "\\" then base = base .. SEP end
  return base .. "incenter_" .. tostring(os.time()) .. "_" ..
    tostring(math.random(100000, 999999)) .. (suffix or "")
end

-- ---- python discovery (with ExtState cache) --------------------------

local EXT_SECTION = "incenter"   -- shared across both front-ends

-- Candidate interpreters, per platform. On POSIX these are absolute paths.
-- On Windows we include both the "py" launcher and a bare "python", which
-- resolve via PATH rather than a fixed location (Windows Python installs
-- land in wildly different per-user AppData paths, so hardcoding them is
-- futile - the launcher is the reliable entry point). These PATH-resolved
-- entries are tried by *running* them, not by checking a file exists.
local PYTHON_CANDIDATES
if core.IS_WIN then
  PYTHON_CANDIDATES = {
    "py -3",          -- Python launcher, newest 3.x (PATH-resolved)
    "python",         -- whatever "python" is on PATH
    "python3",
  }
else
  PYTHON_CANDIDATES = {
    "/opt/homebrew/bin/python3",                                       -- Homebrew, Apple Silicon
    "/usr/local/bin/python3",                                          -- Homebrew, Intel
    "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",  -- python.org installer
    "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
    "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
    "/usr/bin/python3",                                                -- system Python
  }
end

local DEVNULL = core.IS_WIN and "NUL" or "/dev/null"

-- Is this interpreter usable (has numpy+scipy)? On POSIX `path` is an
-- absolute file we can stat first; on Windows some candidates are launcher
-- commands ("py -3") resolved via PATH, so we skip the file check there and
-- just try to run them. The import test is the real gate either way.
function core.python_has_deps(path)
  if not core.IS_WIN and not core.file_exists(path) then return false end
  -- `path` may be a command with args (e.g. "py -3"); don't quote it whole.
  local runner = core.IS_WIN and path or core.shell_quote(path)
  local cmd = runner .. ' -c "import numpy, scipy" >' .. DEVNULL .. ' 2>&1'
  if core.IS_WIN then cmd = "cmd /c " .. cmd end
  local result = os.execute(cmd)
  return result == true or result == 0
end

-- pip install hint, platform-appropriate. --break-system-packages is a
-- Homebrew/Linux thing; on Windows plain pip is fine.
local function pip_hint(py)
  if core.IS_WIN then
    return py .. " -m pip install numpy scipy"
  end
  return core.shell_quote(py) .. " -m pip install numpy scipy --break-system-packages"
end

-- Find a working python3, preferring (in order):
--   1. an explicit override the caller passes in (PYTHON_OVERRIDE)
--   2. a previously cached working path in ExtState
--   3. the candidate list, probed for numpy+scipy
-- The cache turns a multi-second probe on every launch into a single
-- import check of one path. A stale/broken cached path falls through to
-- a fresh scan. Returns path, nil on success or nil, error_message.
-- Find a working Python. The expensive part - actually launching Python to
-- `import numpy, scipy` - is the ~same cost as a small DSP run, so we pay it
-- as rarely as possible:
--   * A cached path from a previous successful run is TRUSTED without
--     re-probing. That's the fast path hit on every normal Process press.
--     If the cached interpreter has since broken, the worker run fails and
--     run_batch clears the cache, so the next press re-scans.
--   * An override is probed once, only when it's different from what's
--     already cached (i.e. the user just changed it), then cached.
--   * A full candidate scan (each probed) happens only when there's no
--     usable cache at all - typically just the very first run.
-- This removes the second scipy import that used to run before every batch.
function core.find_python(override)
  local cached = reaper.GetExtState(EXT_SECTION, "python_path")

  if override and override ~= "" then
    -- Already validated and cached this exact override? Trust it.
    if override == cached then return override end
    -- Newly entered override: validate once, then cache.
    local looks_like_path = override:match("[/\\]") ~= nil
    if (not core.IS_WIN or looks_like_path) and not core.file_exists(override) then
      return nil, "The Python path you set doesn't exist:\n" .. override
    end
    if not core.python_has_deps(override) then
      return nil, "That Python has no numpy/scipy:\n" .. override ..
        "\n\nInstall with:\n" .. pip_hint(override)
    end
    reaper.SetExtState(EXT_SECTION, "python_path", override, true)
    return override
  end

  -- Trust a non-empty cache without re-probing (the fast path).
  if cached ~= "" then
    return cached
  end

  -- No cache: scan candidates, probing each, and cache the first that works.
  for _, path in ipairs(PYTHON_CANDIDATES) do
    if core.python_has_deps(path) then
      reaper.SetExtState(EXT_SECTION, "python_path", path, true)
      return path
    end
  end

  return nil, "Found no Python 3 with numpy+scipy in the usual places.\n\n" ..
    "Install them, e.g.:\n  " ..
    (core.IS_WIN and "py -3 -m pip install numpy scipy"
                 or "python3 -m pip install numpy scipy --break-system-packages") ..
    "\n\nor set PYTHON_OVERRIDE near the top of the batch script to the " ..
    "interpreter that has them (see INSTALL_Python.md)."
end

-- Forget the cached interpreter (call after a run fails, so the next
-- attempt re-scans instead of reusing a path that may have broken).
function core.clear_python_cache()
  reaper.DeleteExtState(EXT_SECTION, "python_path", true)
end

-- ---- peak building ---------------------------------------------------

-- Swapping a take's source does not refresh the waveform: the new file has
-- no peak cache yet, and REAPER won't start building one for a source a
-- script created. Without this the item keeps drawing the old audio.
--
-- 0 starts the build, 1 runs it, 2 finishes. The run loop is bounded so a
-- build that never reports completion can't hang the action, and every
-- call is guarded because the binding returns void on some versions.
function core.build_peaks(source)
  if not reaper.PCM_Source_BuildPeaks then return end
  pcall(reaper.PCM_Source_BuildPeaks, source, 0)
  for _ = 1, 1000 do
    local ok, running = pcall(reaper.PCM_Source_BuildPeaks, source, 1)
    if not ok or running == nil or running == 0 then break end
  end
  pcall(reaper.PCM_Source_BuildPeaks, source, 2)
end

-- ---- worker process --------------------------------------------------

-- Run a command via reaper.ExecProcess (REAPER's own process API, not
-- io.popen) with the real exit code delivered through a sidecar file.
--
-- We write a wrapper script and run that, rather than the command directly,
-- so we can capture both the output and the true exit code portably. On
-- POSIX it's a /bin/sh script; on Windows a .bat run through cmd. REAPER's
-- ExecProcess does NOT translate path separators, so everything here is
-- built with the platform separator already.
--
-- NOTE: ExecProcess blocks REAPER's main thread until the process exits or
-- timeout_ms elapses - the UI won't redraw during this call. Expected.
-- Returns ok(boolean), output(string).
function core.run_worker(args, timeout_ms)
  -- The first arg is the interpreter. On Windows it may be a launcher
  -- command with its own switch ("py -3") rather than a quotable path, so
  -- it's passed through verbatim; every other arg (paths, flags) is quoted.
  -- On POSIX the interpreter is a real path and gets quoted like the rest.
  local quoted = {}
  for i, a in ipairs(args) do
    if i == 1 and core.IS_WIN and a:match("%s") and not a:match("[/\\]") then
      quoted[i] = a                       -- launcher command, e.g. py -3
    else
      quoted[i] = core.shell_quote(a)
    end
  end
  local cmd = table.concat(quoted, " ")

  local out_log = core.tmp_path(".log")
  local exit_file = core.tmp_path(".exit")

  local wrapper_path, wrapper, exec_target
  if core.IS_WIN then
    -- Windows batch: disable echo, run, then write %errorlevel% to the
    -- sidecar. Redirection uses > / 2>&1 the same as sh. cmd expands
    -- %errorlevel% at execution time on its own line, which is reliable.
    wrapper_path = core.tmp_path(".bat")
    wrapper = "@echo off\r\n" ..
      cmd .. " > " .. core.shell_quote(out_log) .. " 2>&1\r\n" ..
      "echo %errorlevel% > " .. core.shell_quote(exit_file) .. "\r\n"
    -- ExecProcess needs cmd to interpret the .bat; quote the path for spaces.
    exec_target = 'cmd /c ' .. core.shell_quote(wrapper_path)
  else
    wrapper_path = core.tmp_path(".sh")
    wrapper = string.format(
      "#!/bin/sh\n%s > %s 2>&1\necho $? > %s\n",
      cmd, core.shell_quote(out_log), core.shell_quote(exit_file))
    exec_target = wrapper_path
  end

  local f = io.open(wrapper_path, "w")
  if not f then return false, "could not write worker wrapper script" end
  f:write(wrapper)
  f:close()
  if not core.IS_WIN then
    os.execute("chmod +x " .. core.shell_quote(wrapper_path))
  end

  reaper.ExecProcess(exec_target, timeout_ms or 60000)

  local ok = false
  local ef = io.open(exit_file, "r")
  if ef then
    local code = ef:read("*a")
    ef:close()
    -- trim whitespace/newlines the echo added, then compare
    ok = (tonumber((code or ""):match("%-?%d+")) == 0)
  end

  local output = ""
  local lf = io.open(out_log, "r")
  if lf then
    output = lf:read("*a") or ""
    lf:close()
  end

  os.remove(wrapper_path)
  os.remove(out_log)
  os.remove(exit_file)

  return ok, output
end

-- Parses the "##OK##\tin\tout" / "##ERR##\tin\tmessage" lines incenter.py
-- prints per file in --batch mode. Returns two tables keyed by input path.
function core.parse_batch_output(output)
  local ok_map, err_map = {}, {}
  for line in (output or ""):gmatch("[^\n]+") do
    local tag, in_path, rest = line:match("^(##%a+##)\t([^\t]+)\t(.*)$")
    if tag == "##OK##" then
      ok_map[in_path] = rest
    elseif tag == "##ERR##" then
      err_map[in_path] = rest
    end
  end
  return ok_map, err_map
end

-- ---- output location -------------------------------------------------

-- Where corrected files are written. Preference: the project's own media
-- directory (GetProjectPathEx), so results land in the project's audio
-- folder rather than scattered next to sources (which may be on read-only
-- library drives). Falls back to the source's own folder when there is no
-- saved project path. Returns dir_with_trailing_slash, used_project(bool).
function core.output_dir(src_path)
  local ok, proj_path = pcall(reaper.GetProjectPathEx, 0, "")
  if ok and type(proj_path) == "string" and proj_path ~= "" then
    if proj_path:sub(-1) ~= "/" and proj_path:sub(-1) ~= "\\" then
      proj_path = proj_path .. "/"
    end
    return proj_path, true
  end
  local dir = core.split_ext(src_path)
  return dir, false
end

-- Build <name>_centered_<HHMMSS>[_n].wav in `out_dir`, deduplicated
-- against files already there. Suffix is always _centered (output is
-- always WAV, so the extension is forced to .wav).
function core.make_out_path(src_path, out_dir, stamp)
  local _, name = core.split_ext(src_path)
  local out_path = out_dir .. name .. "_centered_" .. stamp .. ".wav"
  local n = 1
  while core.file_exists(out_path) do
    n = n + 1
    out_path = out_dir .. name .. "_centered_" .. stamp .. "_" .. n .. ".wav"
  end
  return out_path
end

-- ---- item validation & result application ----------------------------

-- Checks whether an item can be processed at all, without touching DSP.
-- Returns take, path, nil on success, or nil, nil, reason on a skip.
function core.validate_item(item)
  local take = reaper.GetActiveTake(item)
  if not take then return nil, nil, "no active take" end
  if reaper.TakeIsMIDI(take) then return nil, nil, "MIDI take" end

  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil, nil, "no source" end

  local kind = core.source_string(reaper.GetMediaSourceType, src)
  if kind == "SECTION" then
    return nil, nil, "reversed or glued take (SECTION source) - skipped"
  end

  local path = core.source_string(reaper.GetMediaSourceFileName, src)
  if path == "" or not core.file_exists(path) then
    return nil, nil, "source file not readable"
  end
  if not path:lower():match("%.wav$") then return nil, nil, "not a wav file" end
  if reaper.GetMediaSourceNumChannels(src) ~= 2 then return nil, nil, "not stereo" end

  return take, path, nil
end

-- Repoints an already-validated item's take at a corrected file. Position,
-- length, trim, fades, envelopes and track are all untouched; only the
-- audio behind the item changes. The old PCM_source is deliberately not
-- destroyed - destroying one still shared between takes segfaults inside
-- SetActiveTake; a small leak per run is the better trade.
-- ValidatePtr2 guards against the item/take having been deleted by the
-- user during processing. Returns true or false, error_message.
function core.apply_result(item, take, out_path)
  if reaper.ValidatePtr2 then
    if not reaper.ValidatePtr2(0, item, "MediaItem*") then
      return false, "item no longer exists"
    end
    if not reaper.ValidatePtr2(0, take, "MediaItem_Take*") then
      return false, "take no longer exists"
    end
  end
  local new_source = reaper.PCM_Source_CreateFromFile(out_path)
  if not new_source then return false, "could not open the corrected file" end
  reaper.SetMediaItemTake_Source(take, new_source)
  core.build_peaks(new_source)
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", core.basename(out_path), true)
  reaper.UpdateItemInProject(item)
  return true
end

-- ---- batch runner ----------------------------------------------------

-- Runs incenter.py once for every unique path in `paths` (a path->true
-- set). One process launch for the whole batch instead of one per file:
-- scipy's ~2s import is paid once, and the UI (ExecProcess blocks the main
-- thread) freezes for one run instead of N back-to-back.
--   python       : interpreter path
--   dsp          : full path to incenter.py
--   paths        : set { [src_path]=true, ... }
--   opts         : { strength, tail_strength, collapse, align(bool),
--                    win("auto" or number), verbose(bool) }
--   out_dir      : directory to write corrected files into
-- Returns ok_map (src->out_path), err_map (src->message), output(string).
function core.run_batch(python, dsp, paths, opts, out_dir)
  local stamp = os.date("%H%M%S")
  local manifest_lines, out_for = {}, {}
  local n = 0
  for path in pairs(paths) do
    local out_path = core.make_out_path(path, out_dir, stamp)
    out_for[path] = out_path
    table.insert(manifest_lines, path .. "\t" .. out_path)
    n = n + 1
  end

  local manifest_path = core.tmp_path(".manifest.txt")
  local mf = io.open(manifest_path, "w")
  if not mf then
    local err_map = {}
    for path in pairs(paths) do err_map[path] = "could not write batch manifest" end
    return {}, err_map, ""
  end
  mf:write(table.concat(manifest_lines, "\n") .. "\n")
  mf:close()

  local args = {
    python, dsp, "--batch", manifest_path,
    "--strength", tostring(opts.strength),
    "--tail-strength", tostring(opts.tail_strength),
    "--win", tostring(opts.win or "auto"),
  }
  if opts.collapse and opts.collapse > 0.0 then
    table.insert(args, "--collapse"); table.insert(args, tostring(opts.collapse))
  end
  if opts.align then table.insert(args, "--align") end
  if not opts.verbose then table.insert(args, "--quiet") end

  -- One process now covers every file, so the timeout must cover the whole
  -- run, not one file.
  local timeout_ms = math.max(60000, n * 30000)
  local ok, output = core.run_worker(args, timeout_ms)
  os.remove(manifest_path)

  if not ok then
    local last_line = (output or ""):match("([^\n]*)\n?$") or ""
    local err_map = {}
    for path in pairs(paths) do
      err_map[path] = "batch worker error: " ..
        (last_line ~= "" and last_line or "unknown")
    end
    -- A failed run may mean a stale cached interpreter; force a re-scan next time.
    core.clear_python_cache()
    return {}, err_map, output or ""
  end

  local ok_map, err_map = core.parse_batch_output(output or "")
  -- Anything neither confirmed ok nor explicitly erred (killed mid-batch)
  -- counts as failed rather than silently skipped.
  for path in pairs(paths) do
    if not ok_map[path] and not err_map[path] then
      err_map[path] = "no result reported (worker may have been interrupted)"
    end
  end
  return ok_map, err_map, output or ""
end

return core
