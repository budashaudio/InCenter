# Experiments

Record of ideas that were prototyped, measured, and either shelved or
shipped, kept separate from the main history so a "we tried this, here's
why not" doesn't get lost when the branch that held the code is deleted.

## Coherence-gated correction (shelved, not shipped)

**Branch:** `experiment/coherence-lock` (deleted after this was written).
**Status:** negative result. Idea not physically disproven, but shelved.

**The idea:** `recenter_bands` estimates one static rotation per band
over the whole file. On material where a compact source moves across the
stereo base, or sits over a symmetric ambience bed, the measured offset
averages out to ~0 and the correction is a no-op — correctly, but it
can't separate "pull the footsteps to centre" from "leave the street
behind them wide." Inter-channel coherence is high for a compact source
and low for a diffuse field, so the prototype tried gating the
per-frame, per-band correction by coherence: rotate coherent cells,
leave incoherent ones alone.

**What was tested:** a real field-recording pack — footsteps and voice
over café and street ambience beds at two levels, a diffuse-fan control,
a room-tone noise-floor reference, and three car/truck pass-bys — run
through the prototype at two window sizes and two gate strengths.

**What was found:**

- Inter-channel coherence contrast between a compact source and a
  diffuse bed is statistically present. On a clean single street
  recording, correctly windowed, median contrast measured ~0.2. Across
  the broader, more varied test pack it was weaker and inconsistent
  (mean 0.04–0.06, max 0.12, no file crossed the 0.15 "the gate has
  something to work with" bar) — the effect is real but doesn't hold up
  as a general-purpose signal.
- A phase-inverted null test (processed vs. original, summed) confirms
  the gate is close to inaudible on most material: residual level -11
  to -17 dB below the source, i.e. clearly present but subtle. One file
  showed the residual concentrated in a narrow high-frequency band, but
  that wasn't consistent across the set.
- **Exception:** on a car pass-by, the null test barely cancelled at all
  (-0.8 dB — essentially the full correction, not a null), matching a
  measured ~35% narrowing of the pass-by's stereo width end to end. So
  the gate is not uniformly inert — on at least one real-world case it
  produces a real, audible change, just not the source-vs-bed separation
  it was meant to produce.
- No false positives: the diffuse-field control and the noise-floor
  reference both measured ~0 contrast throughout.

**Conclusion:** coherence contrast between a compact source and a
diffuse bed exists, but not reliably enough, and not in the way needed,
to deliver actual source-vs-bed separation — the gate is inaudible on
most material and does something unintended (a width change, not a
recentring) on at least one case that isn't the thing it was built to
fix. Shelved rather than shipped. The branch's code (the
`--experimental-lock` flag, the coherence-contrast reporting, the
gating logic in `recenter_bands`) never reached `main`.

## Time-varying axis pull (shelved, not shipped)

**Branch:** `experiment/moving-axis` (deleted after this was written).
**Status:** negative result. Idea not physically disproven, but shelved.

**The idea:** unlike coherence-lock, this didn't try to separate a
source from a bed. `recenter_bands` collapses the per-frame angle to one
weighted median over the whole file, so a source that walks left→right
averages to ~centre and the correction is ~zero — correctly measuring
"no static offset," but unable to do anything about a source that swings
across the base while it's playing. The prototype pulled every frame's
angle toward a fixed anchor (default 45°, centre) independently, per
frame: `corr = K * (anchor - ang)`, clipped and rate-limited. Because the
anchor is fixed rather than derived from the signal, this corrects a
static offset and a moving excursion in one operation — a symmetric walk
can't average itself into a no-op, since it's never averaged.

**What was tested:** the same field-recording pack as coherence-lock,
prioritizing moving-footstep takes with no bed, static-voice takes as a
control, quiet-bed variants of the moving takes, and three car/truck
pass-bys as an adversarial check, at two window sizes and two pull
strengths.

**What was found:**

- The synthetic sanity check passed cleanly: a tone swept 15°→75° over
  2 s collapsed from 23.9° to 0° excursion at K=1.0 (fully stapled to
  the anchor, as designed), and a static off-centre control showed zero
  excursion both before and after — no wobble introduced, just
  recentred in mean position. The mechanism itself is implemented
  correctly.
- **Disqualifying finding, on real material:** the control failed, in
  the wrong direction. `voice_offcenter_dry`, `voice_window_dry`, and
  `voice_door_dry` — static-voice takes that existed specifically to
  prove the tool leaves non-moving sources alone — showed 23–43%
  excursion reduction. `steps_to_offcenter_dry`, the primary target
  case (an actual walk across the base), showed only 2.0%. The tool
  squashes static material harder than the moving material it was built
  for.
- **Why, and why it isn't a tuning problem:** a real voice does not have
  a stable per-frame stereo angle. Formant changes, room reflections,
  breath, and small head movements make the angle jitter frame to
  frame, and that jitter is indistinguishable from genuine spatial
  movement under an excursion metric. A continuously-sounding static
  source therefore accumulates more measured excursion than footsteps,
  which have silence between hits. No threshold or rate-limiter setting
  separates these two phenomena, because the distinguishing information
  isn't present in the L/R energy distribution the analysis sees.
- Secondary anomaly: `auto_slow_passby` showed excursion *increasing* by
  71.6% (3.4°→5.8°) — likely a rate-limiter artifact on an already-narrow
  swing, a further sign the mechanism is unstable at small excursions.
- `win=512` spot checks tracked the `win=1024` numbers within a few
  points, so window size is not driving the result.

**Conclusion:** shelved, not merged — same category as coherence-lock.
The idea isn't physically absurd, but the signal doesn't carry the
distinction the algorithm needs. The branch's code (the
`--experimental-axis` flag, the excursion reporting, the anchor-pull
logic in `recenter_bands`) never reached `main`.

## Both experiments hit the same wall

Coherence-lock could not distinguish a compact source from a diffuse
bed. Moving-axis could not distinguish spatial movement from natural
per-frame variability. These read like different failures, but they're
the same one: both analyses only ever see how energy is distributed
between L and R, frame by frame and band by band. Neither *what kind of
thing* is making the sound nor *why* its angle is changing is present in
that distribution — a footstep's silence-between-hits and a held vowel's
formant drift look identical to the analysis if they happen to move the
angle by a similar amount. The scene cannot be reconstructed from
L/R energy alone. Worth stating explicitly so neither idea gets
re-proposed later in a new costume without first answering: where would
the missing information come from this time?

## Python warm-up on panel open (not implemented)

**Branch:** `experiment/python-warmup` (deleted after this was written).
**Status:** hypothesis disproven at the measurement step. Nothing built.

**What was proposed:** the first Process press of a session takes
noticeably longer than later ones — Nikita measures roughly 4 seconds.
The suspected cause was a cold OS disk cache for `scipy`'s dozens of
compiled extension modules: first import reads them from disk, later
ones hit the page cache. The proposed fix was a fire-and-forget
background process, kicked off when the GUI panel opens, that does
nothing but `import numpy, scipy` and exit — warming the page cache
before the user presses Process.

**The measurement that disproved it** (macOS, Apple Silicon, cache
purged via `sudo purge` immediately before each cold number):

- Cold `import numpy, scipy`: 0.230s. Warm (immediately after): 0.162s,
  then 0.149s. Gap: ~0.08s.
- A full warm end-to-end run through `incenter.py` directly (subprocess
  spawn + import + align + recenter_bands + write, small single-item
  file): ~0.7s (0.720s, 0.693s across two runs).
- The exact wrapper-script mechanism `core.run_worker` uses (write a
  `.sh` wrapper, `chmod +x`, execute, read exit-code/output sidecar
  files) added a further ~0.35s over the direct invocation (1.054s vs.
  0.72s) - a real, measurable cost, but still nowhere near 4s on its
  own.

Even in the best case - eliminating the import cost entirely - the
recoverable amount is a few tenths of a second out of the ~4 seconds
actually observed. The import is not where the time goes.

**Conclusion:** not worth implementing. Not because it wouldn't work -
the mechanism is straightforward and would warm the cache exactly as
designed - but because the thing it warms was never the bottleneck.
Building it would have shipped real code (a new `core` helper, a
GUI-load-time hook, ExtState-cache-aware gating) to shave a fraction of
a second off a four-second problem.

**Where the ~4 seconds likely goes instead** (untested hypotheses for
whoever picks this up next - all on the REAPER/Lua side, which is why a
Python-only measurement couldn't see them):

- `core.find_python` running a full candidate scan when the ExtState
  cache is empty - each candidate is probed by actually launching it,
  not just checking it exists.
- `core.build_peaks` rebuilding the waveform after the source swap.
- `ExecProcess` overhead itself, on top of the ~0.35s wrapper-script
  write/chmod/execute/sidecar-file cycle measured above.
- First-time ReaImGui context creation and window paint.

**What would settle it:** timing instrumentation inside the Lua
front-end around each phase (`find_python`, `run_batch`, the apply
loop, `build_peaks`) during a real REAPER session - the four seconds
happen somewhere a shell-level Python measurement can't reach. The
branch's code (nothing was written beyond the measurement scripts, none
of which were committed) never reached `main`.
