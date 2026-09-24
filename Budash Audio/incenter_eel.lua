-- incenter_eel.lua - built-in (Python-free) DSP engine for InCenter  [v0.10.0]
-- @noindex
--
-- SPDX-License-Identifier: MIT
-- Copyright (c) 2026 Budash Audio
--
-- This file is NOT a standalone REAPER action. The control panel,
-- BudashAudio_InCenter.lua, loads it with dofile() when no usable Python
-- is found (or when FORCE_ENGINE = "eel") and calls M.run_batch(), which
-- has the same shape as core.run_batch in incenter_core.lua, so the panel's
-- apply / undo / status code is shared between the two engines.
--
-- This is the FALLBACK engine. incenter.py stays the primary, faster, fully
-- featured one. Differences, on purpose:
--   * no Align (the GCC-PHAT inter-channel delay estimate is not ported)
--   * always writes 32-bit float (the audio accessor doesn't expose the
--     source's bit depth)
--   * slower: roughly 4x realtime
--   * processes items at playrate 1.0 only (see M.check_take)
--
-- Architecture:
--   audio in                   -> CreateTakeAudioAccessor / GetAudioAccessorSamples
--   STFT / ISTFT (FFT)         -> reaper.array's native fft_real / ifft_real
--   per-bin, per-band hot loop -> EEL2, compiled from Lua via
--                                 reaper.ImGui_CreateFunctionFromEEL
--                                 (ReaImGui >= 0.8.5)
--
-- Ports recenter_bands's logic (band splitting, per-band angle + coherence
-- weight, attack/tail energy mask, weighted-median angle collapse,
-- confidence-shrunk per-band correction, crossfaded rotation) and the
-- separate stereo-width `collapse` operation.
--
-- The DSP cannot run under busted (EEL only executes inside REAPER); it is
-- verified by ear and by a phase-null against the Python engine, Align off.
--
-- REAPER 7.41 API findings this file depends on, each repeated at the call
-- site it affects:
--   * arr.fft_real(size, true): dot syntax, no self, no offset argument
--   * fft_real -> ifft_real has a gain of 2 x nperseg, compensated at ISTFT
--   * one packed array per EEL Function: separate array variables in one
--     Function alias each other on this build
--   * reaper.new_array() is not reliably zeroed; accumulators are zeroed
--     explicitly

local M = {}

-- ---- constants (mirrors incenter.py's defaults) -----------------------

local N_BANDS = 24
local F_LO = 50.0
local MAX_CORR_DEG = 30.0
local EPS = 1e-12
local MIN_REGION_SAMPLES = 1024

-- ---- small math/DSP helpers (Lua side) --------------------------------

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end

local function hann_periodic(n)
  local w = {}
  for i = 0, n - 1 do w[i + 1] = 0.5 - 0.5 * math.cos(2.0 * math.pi * i / n) end
  return w
end

-- Symmetric Hann, for the attack/tail smoothing kernel only - matches
-- incenter.py's use of np.hanning there (different from the STFT's own
-- periodic window; see incenter.py's _hann_periodic docstring for why
-- the two must not be confused).
local function hann_symmetric(n)
  local w = {}
  if n <= 1 then w[1] = 1.0; return w end
  for i = 0, n - 1 do w[i + 1] = 0.5 - 0.5 * math.cos(2.0 * math.pi * i / (n - 1)) end
  return w
end

-- Mirrors incenter.py's make_bands: geometric edges from F_LO to
-- Nyquist, everything below F_LO folded into the first band. Deliberately
-- EXCLUDES the Nyquist bin (k = nperseg/2) from every band, matching
-- incenter.py exactly (its `freq < edges[n_bands]` upper bound is a strict
-- "<", so a bin at exactly Nyquist passes through unrotated).
--
-- A requested band count is a CEILING, not a guarantee: at typical STFT
-- resolutions several of the lowest geometric slices are narrower than one
-- bin and capture nothing; Python's make_bands drops those empty slices
-- rather than emitting an empty band, which shifts every later band's
-- contents. Verified numerically against incenter.py (nperseg=2048,
-- sr=44100: 24 requested -> 23 actual, band 1 = bins [0,4)). Reproduced
-- here exactly, band-count shrinkage included - getting it wrong wouldn't
-- error, just silently rotate the wrong bins.
--
-- Returns 0-based bin-index bounds per band (band b covers bins
-- [lo[b], hi[b])) and the ACTUAL band count, which callers must use in
-- place of the requested `n_bands` for every downstream loop bound and
-- for w_ref's denominator (max(len(bands), 1) in incenter.py).
local function make_bands(nperseg, sr, n_bands, f_lo)
  local nyq_bin = nperseg // 2   -- excluded from all bands
  local nyq_hz = sr / 2.0
  local ratio = (nyq_hz / f_lo) ^ (1.0 / n_bands)
  local edges = { f_lo }
  for i = 2, n_bands + 1 do edges[i] = edges[i - 1] * ratio end

  local k = 0
  while k < nyq_bin and (k * sr / nperseg) < f_lo do k = k + 1 end
  local low_count = k   -- bins [0, low_count) are the f_lo fold

  local lo, hi = {}, {}
  local n_actual = 0
  local band_start = k
  for i = 1, n_bands do
    local upper = edges[i + 1]
    while k < nyq_bin and (k * sr / nperseg) < upper do k = k + 1 end
    if k > band_start then
      n_actual = n_actual + 1
      lo[n_actual] = band_start
      hi[n_actual] = k
      band_start = k
    end
  end
  if n_actual > 0 and low_count > 0 then lo[1] = 0 end
  return lo, hi, n_actual
end

-- Weighted median, same algorithm as incenter.py's weighted_median:
-- sort by value, cumulative weight, first value whose cumsum crosses
-- 50% of total weight. Falls back to 45.0 (centre) when total weight is
-- ~0, matching the Python fallback exactly.
local function weighted_median(values, weights)
  local n = #values
  local idx = {}
  for i = 1, n do idx[i] = i end
  table.sort(idx, function(a, b) return values[a] < values[b] end)
  local total = 0.0
  for i = 1, n do total = total + weights[i] end
  if total < EPS then return 45.0 end
  local cw = 0.0
  local half = 0.5 * total
  for _, i in ipairs(idx) do
    cw = cw + weights[i]
    if cw >= half then return values[i] end
  end
  return values[idx[n]]
end

-- Mirrors incenter.py's sound_length_sec: 10ms-block energy envelope,
-- span between the first and last block within floor_db of the peak.
local function sound_length_sec(l, r, n, sr, floor_db)
  floor_db = floor_db or 40.0
  if n == 0 then return 0.0 end
  local block = math.max(1, math.floor(sr * 0.01))
  local nb = n // block
  if nb < 1 then return n / sr end
  local e = {}
  local peak = 0.0
  for b = 0, nb - 1 do
    local sum = 0.0
    local base = b * block
    for i = 1, block do
      local lv, rv = l[base + i], r[base + i]
      sum = sum + lv * lv + rv * rv
    end
    local avg = sum / block
    e[b + 1] = avg
    if avg > peak then peak = avg end
  end
  if peak <= EPS then return n / sr end
  local thresh = peak * (10.0 ^ (-floor_db / 10.0))
  local first, last = nil, nil
  for i = 1, nb do
    if e[i] >= thresh then
      if not first then first = i end
      last = i
    end
  end
  if not first then return n / sr end
  return (last - first + 1) * block / sr
end

-- Mirrors incenter.py's auto_win thresholds exactly.
local function auto_win(length_sec, n)
  local win
  if length_sec < 0.15 then win = 512
  elseif length_sec < 0.6 then win = 1024
  elseif length_sec < 2.5 then win = 2048
  else win = 4096 end
  while win > n and win > 256 do win = win // 2 end
  return win
end

-- ---- WAV writer -------------------------------------------------------

-- Always 32-bit float: the accessor hands back float samples and doesn't
-- expose the source's bit depth, so there is nothing to match.
local function write_wav_float32(path, ch, sr, interleaved, nframes)
  local data_bytes = nframes * ch * 4
  local f = io.open(path, "wb")
  if not f then return false, "could not open " .. path .. " for writing" end
  f:write(string.pack("<c4I4c4", "RIFF", 36 + data_bytes, "WAVE"))
  f:write(string.pack("<c4I4I2I2I4I4I2I2",
    "fmt ", 16, 3, ch, math.floor(sr), math.floor(sr) * ch * 4, ch * 4, 32))
  f:write(string.pack("<c4I4", "data", data_bytes))
  local total = nframes * ch
  local chunk, CHUNK_SIZE = {}, 8192
  for i = 1, total do
    chunk[#chunk + 1] = string.pack("<f", interleaved[i] or 0.0)
    if #chunk >= CHUNK_SIZE then f:write(table.concat(chunk)); chunk = {} end
  end
  if #chunk > 0 then f:write(table.concat(chunk)) end
  f:close()
  return true
end

-- ---- EEL programs (the per-bin, per-band hot loop) --------------------
--
-- ONE PACKED ARRAY PER FUNCTION. On this REAPER build (7.41), separate
-- named array variables inside one EEL Function alias each other: ang/w,
-- fl/fr and band_lo/band_hi each independently showed it (fl and fr became
-- exactly identical after rotation; band_lo and band_hi read the same
-- garbage). So everything array-shaped lives in a single array, "mem", at
-- offsets computed and baked into the source when it is generated (they
-- depend on nperseg / n_bands, which vary per item). With one array name
-- in play there is nothing left to alias with.
--
-- mem layout (0-based EEL offsets):
--   GATHER: [0, batch*nperseg)=fl  [batch*nperseg, 2*batch*nperseg)=fr
--           then band_lo (n_bands), band_hi (n_bands),
--           ang (batch*n_bands), w (batch*n_bands)
--   ROTATE: same fl/fr/band_lo/band_hi layout, then c_att, c_tail
--           (n_bands each, the final per-band corrections), mask (batch)
--
-- Within one frame, bin k's (real, imag) pair lives at positions (2k, 2k+1)
-- relative to that channel's own offset - EXCEPT bin 0 (DC), real-only at
-- position 0 (position 1 in that slot is actually the Nyquist bin's real
-- value, per reaper.array's packed real-FFT layout; Nyquist is never
-- touched, matching incenter.py's make_bands).
--
-- BATCH_FRAMES: how many frames one Execute() handles. One Execute per
-- frame means thousands of Lua<->REAPER round trips on a long file, which
-- measured as minutes of "REAPER not responding"; batching cuts the call
-- count by this factor. 32 keeps `mem` near 2*32*4096 elements at the
-- largest window - deliberately not "the whole file", which is what
-- aliased in an earlier design (whether that was purely the multi-array
-- issue or partly a size ceiling was never separated out).
local BATCH_FRAMES = 32

-- Returns (source_string, offsets_table, mem_size). `batch` is the
-- ALLOCATED batch size; the actual number of frames in a call (smaller
-- only for the last batch) is passed at runtime via the "nf" scalar.
local function make_gather_eel(nperseg, n_bands, batch)
  local FR = batch * nperseg
  local BLO = 2 * batch * nperseg
  local BHI = BLO + n_bands
  local ANG = BHI + n_bands
  local W = ANG + batch * n_bands
  local size = W + batch * n_bands
  local src = string.format([[
u = 0;
loop(nf,
  frame_base = u * %d;
  ang_base = u * %d;
  b = 0;
  loop(%d,
    lo = mem[%d + b];
    hi = mem[%d + b];
    el = 0; er = 0; cross_re = 0; cross_im = 0;
    k = lo;
    while (k < hi) (
      (k == 0) ? (
        lre = mem[frame_base]; lim = 0;
        rre = mem[%d + frame_base]; rim = 0;
      ) : (
        pos = frame_base + k*2;
        lre = mem[pos]; lim = mem[pos+1];
        rre = mem[%d + pos]; rim = mem[%d + pos + 1];
      );
      el += lre*lre + lim*lim;
      er += rre*rre + rim*rim;
      cross_re += lre*rre + lim*rim;
      cross_im += lim*rre - lre*rim;
      k += 1;
    );
    cross_mag = sqrt(cross_re*cross_re + cross_im*cross_im);
    coh = cross_mag / (sqrt(el*er) + 0.0000000001);
    mem[%d + ang_base + b] = atan2(sqrt(er), sqrt(el)) * 57.29577951308232;
    mem[%d + ang_base + b] = (el + er) * coh * coh;
    b += 1;
  );
  u += 1;
);
]], nperseg, n_bands, n_bands, BLO, BHI, FR, FR, FR, ANG, W)
  return src, { fr = FR, band_lo = BLO, band_hi = BHI, ang = ANG, w = W }, size
end

local function make_rotate_eel(nperseg, n_bands, batch)
  local FR = batch * nperseg
  local BLO = 2 * batch * nperseg
  local BHI = BLO + n_bands
  local CATT = BHI + n_bands
  local CTAIL = CATT + n_bands
  local MASK = CTAIL + n_bands
  local size = MASK + batch
  local src = string.format([[
u = 0;
loop(nf,
  frame_base = u * %d;
  mask_val = mem[%d + u];
  b = 0;
  loop(%d,
    lo = mem[%d + b];
    hi = mem[%d + b];
    corr = mem[%d + b] * mask_val + mem[%d + b] * (1 - mask_val);
    th = corr * 0.017453292519943295;
    c = cos(th); s = sin(th);
    k = lo;
    while (k < hi) (
      (k == 0) ? (
        lre = mem[frame_base]; rre = mem[%d + frame_base];
        mem[frame_base] = c*lre - s*rre;
        mem[%d + frame_base] = s*lre + c*rre;
      ) : (
        pos = frame_base + k*2;
        lre = mem[pos]; lim = mem[pos+1];
        rre = mem[%d + pos]; rim = mem[%d + pos + 1];
        mem[pos] = c*lre - s*rre;
        mem[pos+1] = c*lim - s*rim;
        mem[%d + pos] = s*lre + c*rre;
        mem[%d + pos + 1] = s*lim + c*rim;
      );
      k += 1;
    );
    b += 1;
  );
  u += 1;
);
]], nperseg, MASK, n_bands, BLO, BHI, CATT, CTAIL, FR, FR, FR, FR, FR, FR)
  return src, { fr = FR, band_lo = BLO, band_hi = BHI, c_att = CATT, c_tail = CTAIL, mask = MASK }, size
end

-- ---- take checks ------------------------------------------------------

-- Extra, engine-specific check on top of core.validate_item. Returns nil if
-- the take can be processed, or a reason string.
--
-- Playrate must be 1.0. The audio accessor returns the take's PLAYBACK
-- timeline (already playrate-adjusted), not the raw source region that
-- incenter.py cuts using D_STARTOFFS and D_LENGTH * D_PLAYRATE. Processing
-- such an item here would bake the rate into the corrected file, which the
-- Python engine does not do - so it is refused rather than made to differ.
--
-- Reversed takes are refused by core.validate_item (any SECTION source):
-- the accessor returns a reversed source forward-oriented, silently, so
-- processing one here would correct it backwards with no error.
function M.check_take(take)
  local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1.0
  if math.abs(rate - 1.0) > 1e-9 then
    return "playrate is not 1.0 - the built-in engine can't process it " ..
      "(set the rate to 1.0, or glue the item first)"
  end
  return nil
end

-- ---- main processing --------------------------------------------------

-- Processes one take and writes the result to out_path. opts: { strength,
-- tail_strength, collapse, win ("auto" or number) }. Returns true, payload
-- (a ##DIAG##-style string for core.format_diag, or nil when no centering
-- ran) or false, message.
local function process_take(take, opts, out_path)
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return false, "no source" end

  local ch = reaper.GetMediaSourceNumChannels(src)
  if ch ~= 2 then return false, "not stereo (" .. tostring(ch) .. " channel(s))" end
  local src_sr = reaper.GetMediaSourceSampleRate(src)

  local acc = reaper.CreateTakeAudioAccessor(take)
  if not acc then return false, "CreateTakeAudioAccessor failed" end
  local t0 = reaper.GetAudioAccessorStartTime(acc)
  local t1 = reaper.GetAudioAccessorEndTime(acc)
  local n = math.floor((t1 - t0) * src_sr + 0.5)
  if n < MIN_REGION_SAMPLES then
    reaper.DestroyAudioAccessor(acc)
    return false, "region too short to process (" .. tostring(n) .. " samples)"
  end

  -- Read in fixed-size blocks: one reaper.new_array(n * ch) for a
  -- multi-minute file exceeds reaper.array's size limit ("invalid size").
  -- l/r (deinterleaved, whole-file) are plain Lua tables - only
  -- reaper.array crosses the EEL boundary, and Lua tables have no
  -- comparable ceiling.
  local BLOCK_SAMPLES = 65536
  local block_buf = reaper.new_array(BLOCK_SAMPLES * ch)
  local l, r = {}, {}
  local read_pos = 0
  local read_ok = true
  while read_pos < n do
    local this_block = math.min(BLOCK_SAMPLES, n - read_pos)
    local got = reaper.GetAudioAccessorSamples(
      acc, src_sr, ch, t0 + read_pos / src_sr, this_block, block_buf)
    if got ~= 1 then
      read_ok = false
      break
    end
    for i = 1, this_block do
      l[read_pos + i] = block_buf[(i - 1) * ch + 1]
      r[read_pos + i] = block_buf[(i - 1) * ch + 2]
    end
    read_pos = read_pos + this_block
  end
  reaper.DestroyAudioAccessor(acc)
  if not read_ok then return false, "GetAudioAccessorSamples failed mid-read" end

  local strength = opts.strength
  local tail_strength = opts.tail_strength
  local needs_centering = (strength ~= 0.0) or (tail_strength ~= 0.0)

  local out_l, out_r, sr = l, r, src_sr
  local payload = nil

  if needs_centering then
    local length_sec = sound_length_sec(l, r, n, src_sr, 40.0)
    local nperseg = (opts.win == "auto") and auto_win(length_sec, n) or math.min(opts.win, n)
    if nperseg < 4 then
      return false, "region too short for the requested window"
    end
    local noverlap = nperseg * 3 // 4
    local hop = nperseg - noverlap
    local win = hann_periodic(nperseg)

    -- Zero-pad like incenter.py's _stft: `ext` samples of silence at
    -- both ends (centres the first window on sample 0), then pad the
    -- tail to a whole number of hops.
    local ext = nperseg // 2
    local padded_len = n + 2 * ext
    local nadd = (-(padded_len - nperseg)) % hop
    padded_len = padded_len + nadd
    local n_frames = (padded_len - nperseg) // hop + 1

    local l_ext, r_ext = {}, {}
    for i = 1, padded_len do l_ext[i] = 0.0; r_ext[i] = 0.0 end
    for i = 1, n do l_ext[ext + i] = l[i]; r_ext[ext + i] = r[i] end

    -- fl_all/fr_all: the whole file's packed spectra, frame-major. Plain
    -- Lua tables, not reaper.array (n_frames*nperseg can exceed the array
    -- size limit); they only ever cross the EEL boundary in BATCH_FRAMES
    -- slices. Also collects e_fr, the per-frame broadband energy via
    -- Parseval (sum of a windowed frame's squared samples equals the sum
    -- of its FFT bin energies up to a constant scale, which the dB-RISE
    -- onset test below is invariant to).
    local fl_all = {}
    local fr_all = {}
    local e_fr = {}
    -- reaper.new_array() is not reliably zeroed. These are fully
    -- overwritten before every use, so that's fine; accumulators are
    -- zeroed explicitly wherever one is used.
    local fbuf_l, fbuf_r = reaper.new_array(nperseg), reaper.new_array(nperseg)
    for f = 0, n_frames - 1 do
      local pos = f * hop
      local esum = 0.0
      for i = 1, nperseg do
        local wl = l_ext[pos + i] * win[i]
        local wr = r_ext[pos + i] * win[i]
        fbuf_l[i] = wl
        fbuf_r[i] = wr
        esum = esum + wl * wl + wr * wr
      end
      e_fr[f + 1] = esum
      -- CALL SHAPE (REAPER 7.41): reaper.array methods are closures already
      -- bound to their instance - `arr.fft_real(size, true)`, NOT
      -- `arr:fft_real(...)` (colon sugar passes the array itself as the
      -- first real parameter and raises "bad self"). Pass only
      -- (size, permute): an explicit offset argument, even 0, is itself
      -- rejected here ("destoffs out of range").
      fbuf_l.fft_real(nperseg, true)
      fbuf_r.fft_real(nperseg, true)
      local base = f * nperseg
      for i = 1, nperseg do
        fl_all[base + i] = fbuf_l[i]
        fr_all[base + i] = fbuf_r[i]
      end
    end

    -- ---- attack/tail soft mask (onset detection), matching
    -- recenter_bands: >4dB per-hop rise starts a ~60ms attack window,
    -- smoothed by a ~30ms Hann kernel into a soft crossfade. A signal too
    -- short for the smoothing kernel collapses to attack-only, same as
    -- incenter.py.
    local hop_s = hop / sr
    local db = {}
    local max_db = -1e30
    for i = 1, n_frames do
      local d = 10.0 * math.log(e_fr[i] + EPS, 10)
      db[i] = d
      if d > max_db then max_db = d end
    end
    for i = 1, n_frames do if db[i] < max_db - 80.0 then db[i] = max_db - 80.0 end end

    local n_att = math.max(1, math.floor(0.06 / hop_s + 0.5))
    local n_smooth = math.max(3, math.floor(0.03 / hop_s + 0.5))
    if n_smooth % 2 == 0 then n_smooth = n_smooth + 1 end

    local mask = {}
    local collapsed = n_smooth > n_frames
    if collapsed then
      for i = 1, n_frames do mask[i] = 1.0 end
    else
      local hard = {}
      for i = 1, n_frames do hard[i] = 0.0 end
      for i = 2, n_frames do
        if db[i] - db[i - 1] > 4.0 then
          for j = i, math.min(n_frames, i + n_att - 1) do hard[j] = 1.0 end
        end
      end
      -- frame 1's "rise" is prepend(db[0]) in Python's np.diff, i.e.
      -- always 0 - never an onset by construction, nothing to do here.
      local kern_full = hann_symmetric(n_smooth + 2)
      local kern = {}
      local ksum = 0.0
      for i = 2, n_smooth + 1 do kern[#kern + 1] = kern_full[i]; ksum = ksum + kern_full[i] end
      if ksum <= EPS then kern = { 1.0 }; ksum = 1.0 end
      for i = 1, #kern do kern[i] = kern[i] / ksum end
      local half = (#kern - 1) // 2
      for i = 1, n_frames do
        local acc = 0.0
        for k = 1, #kern do
          local idx = i + (k - 1 - half)
          if idx >= 1 and idx <= n_frames then acc = acc + hard[idx] * kern[k] end
        end
        mask[i] = clamp(acc, 0.0, 1.0)
      end
    end

    -- ---- band edges. n_bands is the ACTUAL band count (see make_bands),
    -- can be less than N_BANDS; every loop below uses it.
    local band_lo, band_hi, n_bands = make_bands(nperseg, sr, N_BANDS, F_LO)

    -- ---- gather pass: per-band angle + coherence weight, per frame.
    local g_src, g_off, g_size = make_gather_eel(nperseg, n_bands, BATCH_FRAMES)
    local gather_fn = reaper.ImGui_CreateFunctionFromEEL(g_src)
    local gmem = reaper.new_array(g_size)
    for b = 1, n_bands do
      gmem[g_off.band_lo + b] = band_lo[b]
      gmem[g_off.band_hi + b] = band_hi[b]
    end

    local ang_by_band, w_by_band = {}, {}
    for b = 1, n_bands do ang_by_band[b] = {}; w_by_band[b] = {} end
    local ang_all, w_att_all, w_tail_all = {}, {}, {}
    local sum_w_all = 0.0

    for batch_start = 0, n_frames - 1, BATCH_FRAMES do
      local nf = math.min(BATCH_FRAMES, n_frames - batch_start)
      for u = 0, nf - 1 do
        local f = batch_start + u
        local base = f * nperseg
        local ubase = u * nperseg
        -- Manual copy loop on purpose: {reaper.array}.copy() from a plain
        -- Lua table is documented but was pathologically slow live on this
        -- build (a 20s file took 4+ minutes vs ~20s with this loop).
        for i = 1, nperseg do
          gmem[ubase + i] = fl_all[base + i]
          gmem[g_off.fr + ubase + i] = fr_all[base + i]
        end
      end
      reaper.ImGui_Function_SetValue(gather_fn, "nf", nf)
      reaper.ImGui_Function_SetValue_Array(gather_fn, "mem", gmem)
      reaper.ImGui_Function_Execute(gather_fn)
      reaper.ImGui_Function_GetValue_Array(gather_fn, "mem", gmem)
      for u = 0, nf - 1 do
        local f = batch_start + u
        local ang_base = u * n_bands
        for b = 1, n_bands do
          local a, w = gmem[g_off.ang + ang_base + b], gmem[g_off.w + ang_base + b]
          -- SANITY CLAMP: with er, el >= 0, atan2(sqrt(er), sqrt(el)) in
          -- degrees is mathematically within [0, 90]. Anything outside
          -- that (or NaN) is corruption, most likely a degenerate
          -- atan2(0, 0) on a zero-padded edge frame. Treated as "no data"
          -- (angle 45, weight 0), the same convention weighted_median's
          -- own fallback uses.
          if a ~= a or a < 0.0 or a > 90.0 then a = 45.0; w = 0.0 end
          ang_by_band[b][f + 1] = a
          w_by_band[b][f + 1] = w
          sum_w_all = sum_w_all + w
          ang_all[#ang_all + 1] = a
          w_att_all[#w_att_all + 1] = w * mask[f + 1]
          w_tail_all[#w_tail_all + 1] = w * (1.0 - mask[f + 1])
        end
      end
    end

    local a_att_bb = weighted_median(ang_all, w_att_all)
    local a_tail_bb = collapsed and a_att_bb or weighted_median(ang_all, w_tail_all)
    local w_ref = 0.15 * sum_w_all / math.max(n_bands, 1)

    -- Per-band final corrections, computed once (Lua-side) after seeing
    -- every frame's gather pass.
    local c_att_by_band, c_tail_by_band = {}, {}
    local att_vals = {}
    for b = 1, n_bands do
      local ang_b, w_b = ang_by_band[b], w_by_band[b]
      local wa_sum, wt_sum = 0.0, 0.0
      local wa_att, wa_tail = {}, {}
      for f = 1, n_frames do
        wa_att[f] = w_b[f] * mask[f]
        wa_tail[f] = w_b[f] * (1.0 - mask[f])
        wa_sum = wa_sum + wa_att[f]
        wt_sum = wt_sum + wa_tail[f]
      end

      local a_att = weighted_median(ang_b, wa_att)
      local la = wa_sum / (wa_sum + w_ref)
      a_att = la * a_att + (1.0 - la) * a_att_bb
      att_vals[b] = a_att

      local a_tail
      if collapsed then
        a_tail = a_att
      else
        a_tail = weighted_median(ang_b, wa_tail)
        local lt = wt_sum / (wt_sum + w_ref)
        a_tail = lt * a_tail + (1.0 - lt) * a_tail_bb
      end

      c_att_by_band[b] = clamp(strength * (45.0 - a_att), -MAX_CORR_DEG, MAX_CORR_DEG)
      c_tail_by_band[b] = clamp(tail_strength * (45.0 - a_tail), -MAX_CORR_DEG, MAX_CORR_DEG)
    end

    -- ---- rotate pass: same single-packed-array approach.
    local r_src, r_off, r_size = make_rotate_eel(nperseg, n_bands, BATCH_FRAMES)
    local rotate_fn = reaper.ImGui_CreateFunctionFromEEL(r_src)
    local rmem = reaper.new_array(r_size)
    for b = 1, n_bands do
      rmem[r_off.band_lo + b] = band_lo[b]
      rmem[r_off.band_hi + b] = band_hi[b]
      rmem[r_off.c_att + b] = c_att_by_band[b]
      rmem[r_off.c_tail + b] = c_tail_by_band[b]
    end

    for batch_start = 0, n_frames - 1, BATCH_FRAMES do
      local nf = math.min(BATCH_FRAMES, n_frames - batch_start)
      for u = 0, nf - 1 do
        local f = batch_start + u
        local base = f * nperseg
        local ubase = u * nperseg
        for i = 1, nperseg do
          rmem[ubase + i] = fl_all[base + i]
          rmem[r_off.fr + ubase + i] = fr_all[base + i]
        end
        rmem[r_off.mask + u + 1] = mask[f + 1]
      end
      reaper.ImGui_Function_SetValue(rotate_fn, "nf", nf)
      reaper.ImGui_Function_SetValue_Array(rotate_fn, "mem", rmem)
      reaper.ImGui_Function_Execute(rotate_fn)
      reaper.ImGui_Function_GetValue_Array(rotate_fn, "mem", rmem)
      for u = 0, nf - 1 do
        local f = batch_start + u
        local base = f * nperseg
        local ubase = u * nperseg
        for i = 1, nperseg do
          fl_all[base + i] = rmem[ubase + i]
          fr_all[base + i] = rmem[r_off.fr + ubase + i]
        end
      end
    end

    table.sort(att_vals)
    local function pct(t, p)
      local n2 = #t
      if n2 == 0 then return 0.0 end
      local idx = 1 + p * (n2 - 1) / 100.0
      local lo_i, hi_i = math.floor(idx), math.ceil(idx)
      if lo_i < 1 then lo_i = 1 end
      if hi_i > n2 then hi_i = n2 end
      return t[lo_i] + (t[hi_i] - t[lo_i]) * (idx - lo_i)
    end
    local spread_deg = (#att_vals > 0) and (pct(att_vals, 90) - pct(att_vals, 10)) or 0.0
    -- Same key=value payload incenter.py prints on its ##DIAG## lines, so
    -- core.format_diag formats both engines' measurements identically.
    payload = string.format("offset=%+.2f;attack=%.2f;tail=%.2f;spread=%.2f;win=%d;bands=%d",
      a_att_bb - 45.0, a_att_bb, a_tail_bb, spread_deg, nperseg, n_bands)

    -- ---- ISTFT: per-frame ifft_real + overlap-add, matching
    -- incenter.py's _istft (same window-squared normalization, same `ext`
    -- de-padding at both ends).
    --
    -- FFT_GAIN: on this build the fft_real -> ifft_real round trip is NOT
    -- unit gain but exactly 2 x nperseg (measured with an impulse: 32x for
    -- a 16-sample test). It is a per-bin constant, so rotation doesn't
    -- change it and it is compensated once, below. Getting it wrong is not
    -- a subtle level error: at nperseg=4096 it is an 8192x gain.
    local FFT_GAIN = 2.0 * nperseg
    -- Accumulators: plain Lua tables (padded_len can exceed reaper.array's
    -- size limit), explicitly zeroed. reaper.new_array() is not reliably
    -- zeroed, and a fresh Lua table's entries are nil, not 0.0 - either
    -- way an unzeroed += accumulator produced values around 1e300 here.
    local out_l_ext = {}
    local out_r_ext = {}
    for i = 1, padded_len do out_l_ext[i] = 0.0; out_r_ext[i] = 0.0 end
    local norm = {}
    for i = 1, padded_len do norm[i] = 0.0 end
    local ibuf_l, ibuf_r = reaper.new_array(nperseg), reaper.new_array(nperseg)
    for f = 0, n_frames - 1 do
      local base = f * nperseg
      -- Manual copy loop, not .copy(): see the gather pass.
      for i = 1, nperseg do
        ibuf_l[i] = fl_all[base + i]
        ibuf_r[i] = fr_all[base + i]
      end
      ibuf_l.ifft_real(nperseg, true)   -- same call shape as fft_real above
      ibuf_r.ifft_real(nperseg, true)
      local pos = f * hop
      for i = 1, nperseg do
        local wv = win[i]
        out_l_ext[pos + i] = out_l_ext[pos + i] + ibuf_l[i] * wv
        out_r_ext[pos + i] = out_r_ext[pos + i] + ibuf_r[i] * wv
        norm[pos + i] = norm[pos + i] + wv * wv
      end
    end

    out_l, out_r = {}, {}
    for i = 1, n do
      local nv = norm[ext + i]
      local dv = (nv > 1e-10) and nv or 1.0
      out_l[i] = out_l_ext[ext + i] / dv / FFT_GAIN
      out_r[i] = out_r_ext[ext + i] / dv / FFT_GAIN
    end
  end

  -- ---- stereo width (collapse), last, on already-centred audio -------
  local amount = clamp(opts.collapse or 0.0, 0.0, 1.0)
  if amount > 0.0 then
    local rms_in_sum, rms_out_sum = 0.0, 0.0
    local side_scale = 1.0 - amount
    local new_l, new_r = {}, {}
    for i = 1, n do
      local lv, rv = out_l[i], out_r[i]
      rms_in_sum = rms_in_sum + lv * lv + rv * rv
      local m = 0.5 * (lv + rv)
      local s = 0.5 * (lv - rv) * side_scale
      local nl, nr = m + s, m - s
      new_l[i] = nl; new_r[i] = nr
      rms_out_sum = rms_out_sum + nl * nl + nr * nr
    end
    local rms_in = math.sqrt(rms_in_sum / math.max(n * 2, 1))
    local rms_out = math.sqrt(rms_out_sum / math.max(n * 2, 1))
    local gain = 1.0
    if rms_in > EPS and rms_out > EPS then
      gain = math.min(rms_in / rms_out, 10.0 ^ (12.0 / 20.0))
    end
    for i = 1, n do out_l[i] = new_l[i] * gain; out_r[i] = new_r[i] * gain end
  end

  -- ---- interleave + write ---------------------------------------------
  local interleaved = {}
  for i = 1, n do
    interleaved[(i - 1) * ch + 1] = out_l[i]
    interleaved[(i - 1) * ch + 2] = out_r[i]
  end
  local wok, werr = write_wav_float32(out_path, ch, sr, interleaved, n)
  if not wok then return false, "could not write output: " .. tostring(werr) end

  return true, payload
end

-- ---- batch runner -----------------------------------------------------

-- Same contract as core.run_batch, minus the Python plumbing:
--   core     : the incenter_core module (make_out_path, file_exists)
--   jobs     : { [job_key] = { src_path, start_sec, length_sec, take } }
--              `take` is the first candidate's take for that job - the
--              accessor reads a take, not a file path. start_sec /
--              length_sec are not used: at playrate 1.0 the accessor's
--              span already IS that region (see check_take).
--   opts     : { strength, tail_strength, collapse, win } (align is
--              ignored: not available in this engine)
--   out_dir  : directory to write corrected files into
-- Returns ok_map (job_key->out_path), err_map (job_key->message), output
-- (always ""), diag_map (job_key->##DIAG## payload), like core.run_batch.
-- Output naming goes through core.make_out_path, so files land in the same
-- place, with the same names, as the Python engine's.
function M.run_batch(core, jobs, opts, out_dir)
  local stamp = os.date("%H%M%S")
  local ok_map, err_map, diag_map, allocated = {}, {}, {}, {}
  for job_key, job in pairs(jobs) do
    local out_path = core.make_out_path(job.src_path, out_dir, stamp, allocated)
    allocated[out_path] = true
    -- pcall: a Lua error in one item (array allocation failure, a bad EEL
    -- compile) must fail that item, not the whole batch.
    local ok, res, payload = pcall(process_take, job.take, opts, out_path)
    if not ok then
      err_map[job_key] = tostring(res)
    elseif res then
      ok_map[job_key] = out_path
      diag_map[job_key] = payload
    else
      err_map[job_key] = payload   -- process_take's message
    end
  end
  return ok_map, err_map, "", diag_map
end

return M
