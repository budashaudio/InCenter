-- @noindex
-- BudashAudio_InCenter (batch, no GUI).lua - InCenter batch action  [v0.9.0]
--
-- InCenter - stereo re-centering for foley/field recordings
-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Budash Audio
--
-- Rotates the stereo image of each selected item back to centre and
-- repoints the item at the corrected audio, in place, using whatever
-- settings are hardcoded below. No window - for a control panel with
-- sliders, use BudashAudio_InCenter.lua instead.
--
-- Needs incenter_core.lua and incenter.py sitting next to this file
-- (ReaPack installs all three together).

local script_path = select(2, reaper.get_action_context())
local script_dir = script_path:match("^(.*)[/\\]") or "."

-- ---- user-editable settings ------------------------------------------
local STRENGTH      = 1.0
local TAIL_STRENGTH = 1.0     -- 0 = leave tails untouched, 1 = correct like attacks
local COLLAPSE      = 0.0     -- stereo width, applied last: 0 = untouched, 1 = mono
local ALIGN         = true
local WIN           = "auto"  -- "auto", or a number (512/1024/2048/4096)
local WIDTH_ONLY    = false   -- true = force STRENGTH/TAIL_STRENGTH to 0 (width-only, faster: no STFT)
local VERBOSE       = true

-- If auto-detection can't find your python3 (the one with numpy+scipy),
-- set its full path here, e.g. "/usr/local/bin/python3".
local PYTHON_OVERRIDE = ""
-- ----------------------------------------------------------------------

local core = dofile(script_dir .. "/incenter_core.lua")

local function msg(s)
  reaper.ShowConsoleMsg(tostring(s) .. "\n")
end

-- Console output is easy to miss if the ReaScript console isn't open, so
-- anything serious enough to abort the whole run also gets a message box.
local function fail(title, lines)
  local text = table.concat(lines, "\n")
  msg(title .. "\n" .. text)
  reaper.MB(text, title, 0)
end

local function main()
  msg(string.format("InCenter %s - Budash Audio", core.VERSION))

  local dsp = script_dir .. "/incenter.py"
  if not core.file_exists(dsp) then
    fail("InCenter", {
      "incenter.py not found next to this script:",
      dsp,
      "",
      "Make sure incenter.py was copied into this same folder.",
    })
    return
  end

  local python, python_err = core.find_python(PYTHON_OVERRIDE)
  if not python then
    fail("InCenter", { "No usable Python 3 found.", "", python_err or "" })
    return
  end

  local n_sel = reaper.CountSelectedMediaItems(0)
  if n_sel == 0 then
    msg("InCenter: no items selected.")
    return
  end

  -- Phase 1: validate every selected item, collect distinct jobs. Each
  -- candidate is keyed by job_key (source + region), not by source path
  -- alone: two items trimmed from the same source to different regions
  -- are two different jobs, and must not collapse into one (the second
  -- would otherwise silently receive the first one's output - the
  -- radio-chatter case this whole feature exists for).
  local candidates, jobs, skip_lines = {}, {}, {}
  for i = 0, n_sel - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take, path, err = core.validate_item(item)
    if err then
      table.insert(skip_lines, "skip: " .. err)
    else
      local start_sec, length_sec = core.get_item_region(item, take)
      local job_key = core.make_job_key(path, start_sec, length_sec)
      table.insert(candidates, { item = item, take = take, path = path,
                                 job_key = job_key })
      jobs[job_key] = { src_path = path, start_sec = start_sec, length_sec = length_sec }
    end
  end

  if #candidates == 0 then
    for _, l in ipairs(skip_lines) do msg(l) end
    msg("InCenter: nothing to process.")
    return
  end

  local n_jobs = 0
  for _ in pairs(jobs) do n_jobs = n_jobs + 1 end

  -- Output goes to the project media folder, falling back to the source's
  -- own folder when the project isn't saved. All corrected files from one
  -- run share the same output directory (decided from the first source).
  local out_dir, used_project = core.output_dir(candidates[1].path)
  msg(string.format("InCenter: processing %d region(s) for %d item(s) -> %s%s",
    n_jobs, #candidates, out_dir,
    used_project and "  (project media folder)" or "  (next to source)"))

  -- Phase 2: one process launch for the whole batch.
  local opts = {
    strength = WIDTH_ONLY and 0.0 or STRENGTH,
    tail_strength = WIDTH_ONLY and 0.0 or TAIL_STRENGTH,
    collapse = COLLAPSE,
    align = ALIGN, win = WIN, verbose = VERBOSE,
  }
  local ok_map, err_map, output, diag_map = core.run_batch(python, dsp, jobs, opts, out_dir)
  diag_map = diag_map or {}

  if VERBOSE and output and output:match("%S") then
    msg(output)
  end

  -- Phase 3: apply results back to each item.
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  -- pcall the apply loop so an exception can't leave PreventUIRefresh stuck
  -- on (which makes REAPER look frozen). PreventUIRefresh(-1) always runs.
  local done = 0
  local apply_ok, apply_err = pcall(function()
    for _, c in ipairs(candidates) do
      local out_path = ok_map[c.job_key]
      if out_path then
        local applied, aerr = core.apply_result(c.item, c.take, out_path)
        if applied then
          msg("ok: " .. core.basename(c.path) .. " -> " .. core.basename(out_path))
          local payload = diag_map[c.job_key]
          local formatted = payload and core.format_diag(payload)
          if formatted then msg("   " .. formatted) end
          done = done + 1
        else
          table.insert(skip_lines, "skip: " .. core.basename(c.path) .. ": " .. aerr)
        end
      else
        table.insert(skip_lines, "skip: " .. core.basename(c.path) .. ": " ..
          (err_map[c.job_key] or "unknown batch error"))
      end
    end
  end)
  reaper.PreventUIRefresh(-1)
  if reaper.ClearPeakCache then pcall(reaper.ClearPeakCache) end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("InCenter selected items", -1)

  for _, l in ipairs(skip_lines) do msg(l) end
  if not apply_ok then
    fail("InCenter - error applying results", { tostring(apply_err) })
  end
  msg(string.format("InCenter: processed %d of %d item(s).", done, #candidates))
end

local ok, err = pcall(main)
if not ok then
  fail("InCenter - unexpected error", { tostring(err) })
end
