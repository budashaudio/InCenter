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
