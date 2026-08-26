# InCenter

A free, in-REAPER stereo re-centering tool for foley and field recordings
that came off a portable recorder with the stereo image pulled to one
side. It runs entirely inside your own REAPER session.

*by Budash Audio · v0.9.0 · MIT-licensed*

## What it does

- Estimates the stereo angle **per frequency band** (24 log-spaced bands)
  and rotates each band back to center — fixes the frequency-dependent
  tilt a plain L/R gain trim can't touch.
- Estimates it **separately for the attack and the tail** of each sound
  (onset detection on the energy envelope) and crossfades between the two
  corrections, since a foley hit's transient and its room tail often sit
  at different angles.
- Optional **inter-channel delay alignment** (GCC-PHAT, sub-sample
  precision) for spaced-mic (AB) recordings where part of the "wrong"
  image is really a timing offset, not a level one. The delay is measured
  on the loudest part of the file, so leading silence doesn't fool it.
- Optional **stereo width reduction**, applied last and independently of
  centering, with RMS-matched output level.
- **Keeps your format and metadata.** Output bit depth and sample rate
  match the input (16->16, 24->24, float->float), and BWF/bext timecode,
  iXML and other chunks are carried across so the corrected file drops
  back onto the timeline exactly where the original sat.

## Files

Everything installs together as one package:

- `BudashAudio_InCenter.lua` — the control panel (sliders). **This is the
  one to load.**
- `incenter_core.lua` — the REAPER-side mechanics the panel calls into
  (process runner, source-swap, Python finder). Not an action; don't
  load it directly.
- `incenter.py` — the DSP engine. Not an action; runs as a subprocess.
  Don't load it directly (see the warning below).

## Install

1. Install via ReaPack, or copy the whole folder anywhere inside your
   REAPER `Scripts` folder. Subfolders are fine — each script locates
   itself and its siblings automatically, no fixed path is baked in.
2. In REAPER: Actions -> Show action list -> New action -> Load ReaScript...
   and pick `BudashAudio_InCenter.lua`.
3. Requires the **ReaImGui** extension (Extensions -> ReaPack -> Browse
   packages -> search "ReaImGui").
4. Requires a system **Python 3** with `numpy`. If you don't already have
   it, follow **[INSTALL_Python.md](INSTALL_Python.md)** — a plain,
   step-by-step guide (no Python knowledge needed) for macOS, Windows and
   Linux. InCenter then auto-detects the interpreter — it actually tries
   `import numpy` in each candidate, so it won't pick a Python that's
   missing the library.

**Do not load `incenter.py` or `incenter_core.lua` as REAPER actions.**
They're dependencies, not standalone scripts. `incenter.py` only runs
correctly as a subprocess with CLI arguments; loading it directly runs it
under REAPER's own embedded Python, which can't import numpy and may
hang REAPER. Both carry an `@noindex` tag so ReaPack won't list them.

## Use

Select one or more stereo WAV items, open the InCenter panel, and set:

- **Attack / Tail strength** — how hard to pull each part back to center
  (0-1). Tail 0 leaves the room/reverb tail where it is.
- **Sound length** — leave on **Auto** to let it pick the analysis window
  from the detected sound length, or force a size for unusual material.
- **Align** — on for spaced mics (AB); off for coincident mics (XY/MS),
  which have no timing offset to fix.
- **Stereo width** — optional, narrows the image after centering.
- **Width only (skip centering)** — applies stereo width reduction
  without re-centering, for when you only want the narrowing.

Press **Process selected item(s)**. Each item's take is repointed at a
corrected file named `<name>_centered_<HHMMSS>.wav`, written to the
project's media folder (or next to the source if the project isn't saved).
The original source audio is never overwritten.

## Why it's built the way it is

A few non-obvious decisions, in case you're reading the source:

- **DSP runs in a subprocess, not in REAPER's embedded Python.** REAPER's
  built-in Python can't safely import numpy (it deadlocks via
  ctypes/libffi inside the embedded interpreter), so all processing shells
  out to your system Python via `reaper.ExecProcess` with a small wrapper
  script that captures the real exit code to a sidecar file.
- **One `incenter.py` process per batch, not per file.** `ExecProcess`
  blocks REAPER's UI thread until the worker exits, so N separate process
  launches would mean N back-to-back freezes instead of one - processing
  every unique source in a single `--batch` run keeps that down to one
  blocking call (and lets the panel wrap the whole run in a single Undo
  block). That's normal, not a hang; the panel shows "Processing..."
  first so you can see it started.
- **Own WAV reader/writer instead of a library one.** scipy.io.wavfile
  (back when scipy was still a dependency) can't write 24-bit and drops
  metadata chunks; parsing the RIFF container directly lets input format
  == output format and preserves bext/iXML/cue/etc.
- **The old take source is never destroyed after a swap.** Destroying a
  `PCM_source` still shared between takes segfaults inside
  `SetActiveTake`. Leaving it alone leaks a little memory per run, which
  is the better trade.
- **Peaks are rebuilt with the 3-phase `PCM_Source_BuildPeaks` protocol**
  after every source swap — without it the waveform doesn't redraw.
- **REAPER-side mechanics live in `incenter_core.lua`, not inline in the
  panel.** The process runner, the source-swap, and the Python finder are
  REAPER plumbing, not UI code — that separation is worth keeping on its
  own merits, independent of how many scripts call into it.

## Known limitations

- **Metadata:** standard chunks (bext, iXML, cue, LIST, junk) are carried
  over; exotic vendor chunks should survive too, but only the common ones
  are tested.
- **Bit depth:** 16/24-bit int and 32/64-bit float are supported. A 24-bit
  source that can't be decoded cleanly falls back to 32-bit float output.
- **SECTION takes** (reversed or glued items) are skipped with a message —
  glue to a plain file first if you need to process one.
- **Item region:** processing is scoped to the item's trimmed region — an
  item covering the whole source file behaves as before, and a trimmed
  item is measured and corrected using only its own content.
- **Windows:** the macOS and Linux paths are the tested ones. Windows
  support is implemented but **experimental** — please report back if you
  run it there.

### What InCenter does not do

- It corrects a **static offset of the whole stereo scene**. It measures
  one angle per frequency band across the file and rotates each band back.
- It does **not** separate sources. It cannot tell a footstep from the
  street behind it, and it cannot move one and leave the other.
- On material where sources move across the stereo base, or where the
  scene is already symmetric, the measured offset will be near zero and
  **no correction is applied — this is the correct result, not a
  failure**. The status line after processing reports the measurement so
  you can see this for yourself.
- Movement of a source across the image is content, not a defect.

## Troubleshooting

- **Nothing happens / REAPER seems frozen:** first check you loaded
  `BudashAudio_InCenter.lua`, **not** `incenter.py` (the most common
  mistake).
- **"No Python 3 found":** if you don't have a Python 3 with numpy
  anywhere yet, install one — see [INSTALL_Python.md](INSTALL_Python.md).
  If you already do (a pyenv, conda, or other custom-prefix install) but
  InCenter still isn't finding it, that's because auto-detection only
  checks the usual install locations — set `PYTHON_OVERRIDE` near the
  top of `BudashAudio_InCenter.lua` to its full path instead.
- **The panel freezes while processing:** expected — `ExecProcess` blocks
  the main thread until the worker exits. Batching every selected item
  into one process launch keeps it as short as possible, but it isn't
  instant on long files.

## Running the tests

`tests/test_incenter.py` covers the Python DSP engine (`pytest`);
`tests/lua/incenter_core_spec.lua` covers the Lua core against a
fake `reaper` API (`busted`). These are developer-only checks, separate
from the runtime requirements above.

```
python3 -m pip install pytest
python3 -m pytest tests/

brew install lua luarocks   # macOS; use your platform's package manager
luarocks install busted
eval "$(luarocks path)"
busted tests/lua --lpath="tests/lua/?.lua"
```

## Requirements

- REAPER (developed on the portable macOS build, Apple Silicon)
- ReaImGui — for the control panel only
- Python 3 with `numpy`
- Stereo WAV sources (24-bit/48 kHz is the primary target; other stereo
  WAVs work too)

## Changelog

- **0.9.0** — First public release. Per-band attack/tail centering,
  GCC-PHAT alignment on the loudest region, auto window selection, and
  item-region processing (a trimmed item is measured and corrected using
  only its own region of the source file, so a long recording with
  several events at different stereo positions - e.g. radio chatter -
  doesn't get averaged into one measurement). A "Width only" checkbox
  applies stereo width reduction without re-centering. Diagnostic
  reporting of what was measured after each run, format- and
  metadata-preserving WAV I/O, output to the project media folder.
  Experimental Windows support.

## Credits & reporting

Built by Budash Audio. Bug reports and feedback are welcome — please
include your OS, REAPER version, and the text from the panel's status
line if it showed an error.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Budash Audio.

Product and company names mentioned may be trademarks of their respective
owners; InCenter is not affiliated with or endorsed by any of them.
