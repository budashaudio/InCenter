-- @description InCenter - stereo re-centering for field recordings and designed sound
-- @version 0.9.0
-- @author Budash Audio
-- @provides
--   incenter_core.lua
--   incenter.py
--   ../INSTALL_Python.md > INSTALL_Python.md
-- @about
--   # InCenter
--   Free, in-REAPER stereo re-centering for material whose stereo image
--   is pulled to one side - portable-recorder field captures, or
--   designed stereo assets (whooshes, blips, textures) built without
--   watching the stereo base. See README.md for details. Requires the
--   bundled incenter_core.lua + incenter.py and a system Python 3 with
--   numpy.
-- @link https://github.com/budashaudio/InCenter

-- BudashAudio_InCenter.lua - InCenter control panel  [v0.9.0]
--
-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Budash Audio
--
-- ReaImGui control panel: sliders instead of editing constants. All the
-- REAPER-side mechanics live in incenter_core.lua, kept separate on its
-- own merits (REAPER plumbing, not UI code). This file is the window and
-- the settings.

-- ---- user-editable settings ------------------------------------------
-- If auto-detection can't find your python3 (the one with numpy),
-- set its full path here, e.g. "/usr/local/bin/python3".
local PYTHON_OVERRIDE = ""
-- ----------------------------------------------------------------------

-- Prefer APIExists over touching the field directly (cleaner check that a
-- given API function is present in this REAPER build).
local function has_api(name)
  if reaper.APIExists then return reaper.APIExists(name) end
  return reaper[name] ~= nil
end

if not has_api('ImGui_CreateContext') then
  reaper.MB(
    "This script needs the ReaImGui extension.\n\n" ..
    "Install it via Extensions -> ReaPack -> Browse packages, " ..
    "search for 'ReaImGui', install, then restart REAPER.",
    "InCenter", 0)
  return
end

-- Re-running the action while the window is open shouldn't spawn a second
-- instance/context. set_action_options(1) relaunches (terminates the
-- previous instance) rather than stacking windows.
if reaper.set_action_options then reaper.set_action_options(1) end

-- Everything below runs inside init(), guarded by pcall at the bottom, so
-- a startup error shows a message box instead of the window silently
-- never appearing.
local function init()

local script_path = select(2, reaper.get_action_context())
local script_dir = script_path:match("^(.*)[/\\]") or "."

local core = dofile(script_dir .. "/incenter_core.lua")

-- Pin the ReaImGui API version this script was written against, via the
-- ReaTeam shim if present. Without this, a future ReaImGui that changes or
-- retires an API we use could break the window on a user's machine; the
-- shim keeps our old-style reaper.ImGui_* calls working. Best-effort: if
-- the shim file isn't installed, we just carry on with the live API.
local REAIMGUI_API_VERSION = "0.9"
do
  local shim = reaper.GetResourcePath() ..
    "/Scripts/ReaTeam Extensions/API/imgui.lua"
  if reaper.file_exists and reaper.file_exists(shim) then
    local ok, apply = pcall(dofile, shim)
    if ok and type(apply) == "function" then pcall(apply, REAIMGUI_API_VERSION) end
  end
end

-- ---- settings (persisted between sessions via ExtState) --------------
local EXT_SECTION = "incenter"   -- shared with incenter_core.lua's own ExtState reads

-- Window options: index 0 is Auto (let incenter.py pick from the detected
-- sound length); the rest map to explicit STFT sizes.
local WIN_VALUES = { "auto", 512, 1024, 2048, 4096 }
local WIN_LABELS_ZERO_SEP =
  "Auto (detect from clip)\0" ..
  "Very short (clicks, taps)\0" ..
  "Short (hits, impacts)\0" ..
  "Medium\0" ..
  "Long (sustained sounds)\0"

local function load_num(key, default)
  local raw = reaper.GetExtState(EXT_SECTION, key)
  local v = tonumber(raw)
  if v == nil then return default end
  return v
end

local function load_bool(key, default)
  local raw = reaper.GetExtState(EXT_SECTION, key)
  if raw == "" then return default end
  return raw == "1"
end

local strength      = load_num("strength", 1.0)
local tail_strength = load_num("tail_strength", 1.0)
-- Stereo Width and "Width only" are NOT persisted, unlike everything else
-- on this panel: they're occasional-use settings, easy to leave on from a
-- previous session and forget about, causing unexpected results next time.
-- Both always start at their default, regardless of ExtState.
local collapse      = 0.0
local win_idx       = math.floor(load_num("win_idx", 0))   -- 0 = Auto
local align         = load_bool("align", true)
local width_only    = false

local function save_settings()
  reaper.SetExtState(EXT_SECTION, "strength", tostring(strength), true)
  reaper.SetExtState(EXT_SECTION, "tail_strength", tostring(tail_strength), true)
  reaper.SetExtState(EXT_SECTION, "win_idx", tostring(win_idx), true)
  reaper.SetExtState(EXT_SECTION, "align", align and "1" or "0", true)
end

-- ---- processing ------------------------------------------------------

local status_lines = { "Ready. Select item(s) and press Process." }
local function set_status(lines) status_lines = lines end

-- The actual (blocking) work. Kept separate so the UI can paint a
-- "Processing..." status one frame *before* this runs - see request_process.
local function do_process()
  local dsp = script_dir .. "/incenter.py"
  if not core.file_exists(dsp) then
    set_status({ "ERROR: incenter.py not found next to this script:", dsp })
    return
  end

  local python, python_err = core.find_python(PYTHON_OVERRIDE)
  if not python then
    set_status({ "ERROR: no usable Python 3 found.", python_err or "" })
    return
  end

  local n_sel = reaper.CountSelectedMediaItems(0)
  if n_sel == 0 then
    set_status({ "No items selected." })
    return
  end

  -- Each candidate is keyed by job_key (source + region), not by source
  -- path alone: two items trimmed from the same source to different
  -- regions are two different jobs, and must not collapse into one
  -- (the second would otherwise silently receive the first one's
  -- output - the radio-chatter case this whole feature exists for).
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
    table.insert(skip_lines, 1, "Nothing to process.")
    set_status(skip_lines)
    return
  end

  local out_dir, used_project = core.output_dir(candidates[1].path)

  -- "Width only" forces the strength/tail_strength values sent to
  -- processing to 0, without touching the slider variables themselves -
  -- so the slider positions are preserved for when the box is unchecked.
  local opts = {
    strength = width_only and 0.0 or strength,
    tail_strength = width_only and 0.0 or tail_strength,
    collapse = collapse,
    align = align, win = WIN_VALUES[win_idx + 1] or "auto", verbose = false,
  }
  local ok_map, err_map, _output, diag_map = core.run_batch(python, dsp, jobs, opts, out_dir)
  diag_map = diag_map or {}

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local lines, done = {}, 0
  -- Guard the apply loop: an exception must not leave PreventUIRefresh on.
  local apply_ok, apply_err = pcall(function()
    for _, c in ipairs(candidates) do
      local out_path = ok_map[c.job_key]
      if out_path then
        local applied, aerr = core.apply_result(c.item, c.take, out_path)
        if applied then done = done + 1
        else lines[#lines + 1] = "skip: " .. core.basename(c.path) .. ": " .. aerr end
      else
        lines[#lines + 1] = "skip: " .. core.basename(c.path) .. ": " ..
          (err_map[c.job_key] or "unknown batch error")
      end
    end
  end)
  reaper.PreventUIRefresh(-1)
  if reaper.ClearPeakCache then pcall(reaper.ClearPeakCache) end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("InCenter selected items", -1)

  for _, l in ipairs(skip_lines) do table.insert(lines, l) end
  if not apply_ok then
    table.insert(lines, 1, "ERROR applying results: " .. tostring(apply_err))
  end
  table.insert(lines, 1, string.format("Processed %d of %d item(s)%s.",
    done, #candidates, used_project and " -> project media folder" or ""))

  -- What InCenter actually measured, even when it decided to do nothing -
  -- shown only for a single item. On a multi-item batch the per-file
  -- lines turn into a wall of text (confirmed in real testing - 7 items
  -- meant 7 stacked lines under the summary), so a multi-item run shows
  -- just the "Processed N of M" summary above with no per-file detail.
  -- Checked against #candidates (how many were queued), not how many
  -- diag lines happened to come back, since a batch could partially
  -- fail; skip: lines for errors stay visible regardless of count -
  -- those matter more with more items, not less.
  if #candidates == 1 then
    local payload = diag_map[candidates[1].job_key]
    local formatted = payload and core.format_diag(payload)
    if formatted then
      table.insert(lines, 2, formatted)
    end
  end

  set_status(lines)
end

-- Two-step so the window can show "Processing..." before the blocking run:
-- set the status, then defer the heavy call by one frame so ImGui paints
-- first. This is the "minimal" version of async - the UI still freezes
-- during ExecProcess (expected), but the user sees it started rather than
-- staring at a dead window.
local process_pending = false
local function request_process()
  set_status({ "Processing... (the window may freeze briefly)" })
  process_pending = true
end

-- ---- window ---------------------------------------------------------

-- Docking enabled so the panel can be docked into REAPER like any other
-- window. The user drags the title bar into a dock, or uses the right-click
-- title-bar menu below. The last dock id is remembered across sessions.
local DOCK_FLAG = reaper.ImGui_ConfigFlags_DockingEnable
  and reaper.ImGui_ConfigFlags_DockingEnable() or 0
local ctx = reaper.ImGui_CreateContext('InCenter', DOCK_FLAG)

-- Restore where it was last docked (0 = floating). Applied on the next
-- Begin via SetNextWindowDockID.
local dock_id = tonumber(reaper.GetExtState(EXT_SECTION, "dock_id")) or 0
local want_apply_dock = true   -- apply the remembered dock on first frame

-- Toolbar toggle: light the button while the window is open, clear on exit.
local _, _, sec_id, cmd_id = reaper.get_action_context()
if reaper.SetToggleCommandState then
  reaper.SetToggleCommandState(sec_id, cmd_id, 1)
  reaper.RefreshToolbar2(sec_id, cmd_id)
end
reaper.atexit(function()
  if reaper.SetToggleCommandState then
    reaper.SetToggleCommandState(sec_id, cmd_id, 0)
    reaper.RefreshToolbar2(sec_id, cmd_id)
  end
end)

-- dark, rounded look - exact values from the Claude Design mockup
local COL_WINDOW_BG    = 0x141613FF  -- panel background
local COL_FRAME_BG     = 0x1B1D1AFF  -- slider/dropdown/checkbox track
local COL_FRAME_HOVER  = 0x24261FFF
local COL_FRAME_ACTIVE = 0x2C2E27FF
local COL_TEXT         = 0xE8EAE6FF  -- slider value text
local COL_TITLE_TEXT   = 0xECEEECFF  -- panel title (used in the header)
local COL_HEADER       = 0x8A9089FF  -- uppercase section labels
local COL_LABEL        = 0x9AA199FF  -- "Strength" labels, log lines
local COL_ITEM_TEXT    = 0xC7CCC5FF  -- checkbox label, dropdown item text
local COL_ACCENT       = 0x3DDC84FF  -- green accent
local COL_ACCENT_HOVER = 0x4ADE80FF
local COL_ACCENT_ACT   = 0x22C55EFF
local COL_ON_ACCENT    = 0x0E1210FF  -- dark text/icon on top of the accent
local COL_WARN         = 0xD9A441FF  -- amber hint (comb-filter warning)
local COL_MUTED        = 0x6B716AFF  -- footer / version text
local COL_SEPARATOR    = 0xFFFFFF14  -- rgba(255,255,255,0.08)
local COL_BORDER       = 0xFFFFFF12  -- rgba(255,255,255,0.07)

local function push_style()
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowRounding(), 10)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(), 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 20, 20)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 10, 12)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 14, 10)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 1)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), COL_WINDOW_BG)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), COL_BORDER)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(), COL_WINDOW_BG)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(), COL_WINDOW_BG)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), COL_FRAME_BG)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), COL_FRAME_HOVER)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(), COL_FRAME_ACTIVE)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_TEXT)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(), COL_ACCENT)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(), COL_ACCENT)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(), COL_ACCENT_ACT)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), COL_ACCENT)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), COL_ACCENT_HOVER)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), COL_ACCENT_ACT)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Separator(), COL_SEPARATOR)
  -- 7 style vars, 15 style colors pushed above
end

local function pop_style()
  reaper.ImGui_PopStyleColor(ctx, 15)
  reaper.ImGui_PopStyleVar(ctx, 7)
end

local function colored_text(text, color)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), color)
  reaper.ImGui_Text(ctx, text)
  reaper.ImGui_PopStyleColor(ctx)
end

local function section_header(text) colored_text(text, COL_HEADER) end

local function draw_footer()
  reaper.ImGui_Dummy(ctx, 0, 2)
  colored_text("Budash Audio  -  v" .. core.VERSION, COL_MUTED)
end

local function loop()
  push_style()

  -- Apply the remembered dock id once, on the first frame after launch.
  if want_apply_dock and reaper.ImGui_SetNextWindowDockID then
    reaper.ImGui_SetNextWindowDockID(ctx, dock_id)
    want_apply_dock = false
  end

  local floating = (dock_id == 0)

  -- No longer requesting WindowFlags_AlwaysAutoResize here (it used to be
  -- applied while floating). It wasn't doing its job: every slider/combo/
  -- button below has no explicit width, so they fill whatever width the
  -- window currently has rather than asking for one - there is no tight
  -- "content size" for auto-resize to converge on. In practice that made
  -- it sticky, not auto-fitting: a frame where the window happened to be
  -- wider (a drag, a wider wrapped warning line) got baked back in as
  -- next frame's "content size", so the window neither settled at a
  -- minimal size nor stopped a manual drag - which is what was actually
  -- observed (wider than content, dead space at the bottom) and is also
  -- why dragging it into a bad shape was possible at all despite the
  -- flag being set. It would also now fight SetNextWindowSizeConstraints
  -- below (both try to own the size every frame). The constraints plus
  -- the FirstUseEver default below replace it and do the job it was
  -- meant to.

  -- Default size (365x825, measured against the panel's actual rendered
  -- content, not a guess) on a fresh install only - Cond_FirstUseEver is
  -- a no-op once ImGui's own ini has ever recorded a size for this
  -- window, so an existing user's remembered size is untouched. Skipped
  -- while docked: the dock decides the size there, same reasoning as the
  -- resize constraints below.
  if floating and reaper.ImGui_SetNextWindowSize and reaper.ImGui_Cond_FirstUseEver then
    reaper.ImGui_SetNextWindowSize(ctx, 365, 825, reaper.ImGui_Cond_FirstUseEver())
  end

  -- Keep the panel a narrow vertical column: wide enough that the
  -- longest control label doesn't clip, narrow enough that there's no
  -- reason to stretch it across a monitor. Height stays generous - the
  -- status area can grow past the fixed controls' height with skip:
  -- lines on a multi-item batch, and this must never fight that.
  -- Docked: same as above, the dock owns the size, so skip this too.
  if floating and reaper.ImGui_SetNextWindowSizeConstraints then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, 300, 600, 600, 100000)
  end

  local visible, open = reaper.ImGui_Begin(ctx, 'InCenter', true, 0)

  -- Track dock changes and remember them across sessions.
  if reaper.ImGui_GetWindowDockID then
    local cur = reaper.ImGui_GetWindowDockID(ctx)
    if cur ~= dock_id then
      dock_id = cur
      reaper.SetExtState(EXT_SECTION, "dock_id", tostring(dock_id), true)
    end
  end

  if visible then
    local changed

    -- Right-click the title bar for a Dock/Undock toggle (in addition to
    -- dragging the title bar into a dock).
    if reaper.ImGui_BeginPopupContextItem and
       reaper.ImGui_BeginPopupContextItem(ctx, "titlebar_menu") then
      local is_docked = reaper.ImGui_IsWindowDocked and reaper.ImGui_IsWindowDocked(ctx)
      if reaper.ImGui_MenuItem(ctx, is_docked and "Undock" or "Dock to last position") then
        if is_docked then
          dock_id = 0
        else
          -- -1 asks REAPER to dock in the last-used docker
          dock_id = -1
        end
        reaper.SetExtState(EXT_SECTION, "dock_id", tostring(dock_id), true)
        want_apply_dock = true
      end
      reaper.ImGui_EndPopup(ctx)
    end

    section_header("ATTACK CORRECTION")
    changed, strength = reaper.ImGui_SliderDouble(ctx, "##attack", strength, 0.0, 1.0, "%.2f")
    if changed then save_settings() end
    reaper.ImGui_SameLine(ctx)
    colored_text("Strength", COL_LABEL)

    reaper.ImGui_Spacing(ctx)
    section_header("TAIL CORRECTION  (0 = leave the room/reverb tail untouched)")
    changed, tail_strength = reaper.ImGui_SliderDouble(ctx, "##tail", tail_strength, 0.0, 1.0, "%.2f")
    if changed then save_settings() end
    reaper.ImGui_SameLine(ctx)
    colored_text("Strength", COL_LABEL)

    reaper.ImGui_Spacing(ctx)
    section_header("SOUND LENGTH  (Auto picks it from the clip)")
    changed, win_idx = reaper.ImGui_Combo(ctx, "##win", win_idx, WIN_LABELS_ZERO_SEP)
    if changed then save_settings() end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_ITEM_TEXT)
    changed, align = reaper.ImGui_Checkbox(ctx, "Align (fixes a tiny left/right timing offset)", align)
    reaper.ImGui_PopStyleColor(ctx)
    if changed then save_settings() end

    reaper.ImGui_Spacing(ctx)
    section_header("STEREO WIDTH  (0 = leave the image as wide as it is)")
    changed, collapse = reaper.ImGui_SliderDouble(ctx, "##collapse", collapse, 0.0, 1.0, "%.2f")
    if changed then save_settings() end
    reaper.ImGui_SameLine(ctx)
    colored_text(collapse >= 1.0 and "Mono" or "Narrow", COL_LABEL)

    if collapse > 0.0 and not align then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_WARN)
      reaper.ImGui_TextWrapped(ctx,
        "Narrowing without Align can comb-filter if the channels are " ..
        "time-offset. Turn Align on for spaced mics (AB); leave it off " ..
        "for coincident ones (XY, MS).")
      reaper.ImGui_PopStyleColor(ctx)
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_ITEM_TEXT)
    changed, width_only = reaper.ImGui_Checkbox(ctx, "Width only (skip centering)", width_only)
    reaper.ImGui_PopStyleColor(ctx)
    if changed then save_settings() end
    colored_text("Applies width only, without re-centering.", COL_LABEL)

    reaper.ImGui_Dummy(ctx, 0, 4)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 0, 4)

    local n_sel = reaper.CountSelectedMediaItems(0)
    section_header(string.format("%d ITEM(S) SELECTED", n_sel))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_ON_ACCENT)
    if reaper.ImGui_Button(ctx, "Process selected item(s)", -1, 44) then
      request_process()
    end
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_Dummy(ctx, 0, 4)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 0, 4)

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), COL_LABEL)
    for _, line in ipairs(status_lines) do
      reaper.ImGui_TextWrapped(ctx, line)
    end
    reaper.ImGui_PopStyleColor(ctx)

    draw_footer()

    reaper.ImGui_End(ctx)
  end

  pop_style()

  -- Run the deferred work AFTER this frame has been submitted, so the
  -- "Processing..." status the button set is visible before we block.
  if process_pending then
    process_pending = false
    local ok, err = pcall(do_process)
    if not ok then set_status({ "ERROR: " .. tostring(err) }) end
  end

  if open then
    reaper.defer(loop)
  elseif reaper.ImGui_DestroyContext then
    reaper.ImGui_DestroyContext(ctx)
  end
end

reaper.defer(loop)

end -- init()

local ok, err = pcall(init)
if not ok then
  reaper.MB("InCenter failed to start:\n\n" .. tostring(err),
    "InCenter - unexpected error", 0)
end
