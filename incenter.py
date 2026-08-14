#!/usr/bin/env python3
# @noindex
# This file is a support/dependency script, not a standalone REAPER
# action. Do not load it via Actions -> New action -> Load ReaScript.
# It's meant to be invoked as a subprocess (with CLI args) by
# incenter_ui.lua / incenter_items.lua, which sit next to it. Loading
# it directly in REAPER runs it under REAPER's own embedded Python,
# which cannot import numpy/scipy (see README.md) - at best you'll get
# "ModuleNotFoundError: No module named 'numpy'", at worst a full hang.
"""
InCenter - offline stereo re-centering tool (file-based). DSP engine
behind the InCenter REAPER scripts.

SPDX-License-Identifier: MIT
Copyright (c) 2026 Budash Audio

Fixes two things a plain rotation cannot:
  * frequency-dependent offset (off-axis mic response) -> per-band static rotation
  * inter-channel time offset (ITD)                    -> GCC-PHAT delay alignment

Correction is estimated separately for the attack and the tail of each
sound and crossfaded between the two, since a foley hit's transient and
its room tail often sit at different angles.

Alignment:
  --align   estimate and remove inter-channel delay before rotation
            (sub-sample precision; crucial when the image stays off-center
             no matter how much level correction you apply). The delay is
             measured on the loudest region of the file, not the start, so
             leading silence or handling noise doesn't throw it off.

Width:
  --collapse  reduce stereo width, applied LAST, after re-centering
              (0 = untouched, 1 = mono). Re-centering itself never changes
              width - it rotates the image. This is the separate, opt-in
              operation for narrowing it.

Output format matches the input (sample rate and bit depth) and is always
WAV. Metadata chunks (BWF/bext timecode, iXML, cue, etc.) are carried over
from the source. float32 output is used only as a fallback for sources
that cannot be decoded in their original bit depth.

Usage:
  python incenter.py in.wav out.wav --align
  python incenter.py in.wav out.wav --align --collapse 0.4
"""

import argparse
import struct
import sys

import numpy as np
from scipy.signal import stft, istft

__version__ = "0.9.0"

EPS = 1e-12


# ---------------------------------------------------------------- I/O
#
# We parse and write the RIFF/WAVE container ourselves instead of using
# scipy.io.wavfile, for two reasons:
#   1. scipy can't write 24-bit PCM at all, and warns (and historically
#      mis-handled) on 24-bit reads - which is the project's primary
#      source format. Doing it by hand lets input bit depth == output bit
#      depth (16->16, 24->24, float->float).
#   2. scipy silently drops every chunk except fmt/data, so BWF timecode
#      (bext), iXML, cue markers, etc. are lost. For field/foley material
#      that metadata is the difference between a file that drops back onto
#      the timeline at the right place and one that doesn't. We keep every
#      non-fmt/non-data chunk and write it back untouched.


class WavInfo:
    """Everything needed to write a file back in its original format,
    with its metadata intact."""
    __slots__ = ("sr", "audio_fmt", "bits", "ch", "extra_chunks")

    def __init__(self, sr, audio_fmt, bits, ch, extra_chunks):
        self.sr = sr
        self.audio_fmt = audio_fmt      # 1 = PCM int, 3 = IEEE float
        self.bits = bits
        self.ch = ch
        self.extra_chunks = extra_chunks  # ordered [(id_bytes, body_bytes), ...]


def read_wav(path):
    """Read a stereo WAV. Returns (sr, x_float64, info).

    x is float64 in [-1, 1], shape (n, 2). info is a WavInfo describing the
    original format and carrying every metadata chunk for write-back.
    """
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError(f"{path}: not a RIFF/WAVE file")

    fmt = None
    audio = None
    extra = []
    pos = 12
    n = len(data)
    while pos + 8 <= n:
        cid = data[pos:pos + 8][:4]
        csize = struct.unpack("<I", data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + csize]
        if cid == b"fmt ":
            fmt = body
        elif cid == b"data":
            audio = body
        else:
            extra.append((cid, body))
        pos += 8 + csize + (csize & 1)   # chunks are word-aligned

    if fmt is None or audio is None:
        raise ValueError(f"{path}: missing fmt or data chunk")

    audio_fmt, ch, sr, _byte_rate, _block_align, bits = struct.unpack(
        "<HHIIHH", fmt[:16])

    # WAVE_FORMAT_EXTENSIBLE: the real format tag lives in the subformat GUID
    if audio_fmt == 0xFFFE and len(fmt) >= 40:
        # first 2 bytes of the SubFormat GUID are the actual format tag
        audio_fmt = struct.unpack("<H", fmt[24:26])[0]

    if ch != 2:
        raise ValueError(f"{path}: expected stereo, got {ch} channel(s)")

    x = _decode_samples(audio, audio_fmt, bits, ch, path)
    info = WavInfo(sr=sr, audio_fmt=audio_fmt, bits=bits, ch=ch,
                   extra_chunks=extra)
    return sr, x, info


def _decode_samples(raw, audio_fmt, bits, ch, path):
    if audio_fmt == 1 and bits == 24:
        b = np.frombuffer(raw, dtype=np.uint8)
        b = b[:(len(b) // 3) * 3].reshape(-1, 3)
        v = (b[:, 0].astype(np.int32)
             | (b[:, 1].astype(np.int32) << 8)
             | (b[:, 2].astype(np.int32) << 16))
        v = v - ((v & 0x800000) << 1)          # sign-extend 24 -> 32
        return v.reshape(-1, ch).astype(np.float64) / (2.0 ** 23)
    if audio_fmt == 1 and bits == 16:
        v = np.frombuffer(raw, dtype="<i2").reshape(-1, ch)
        return v.astype(np.float64) / 32768.0
    if audio_fmt == 1 and bits == 32:
        v = np.frombuffer(raw, dtype="<i4").reshape(-1, ch)
        return v.astype(np.float64) / 2147483648.0
    if audio_fmt == 3 and bits == 32:
        return np.frombuffer(raw, dtype="<f4").reshape(-1, ch).astype(np.float64)
    if audio_fmt == 3 and bits == 64:
        return np.frombuffer(raw, dtype="<f8").reshape(-1, ch).astype(np.float64)
    raise ValueError(f"{path}: unsupported WAV format "
                     f"(format tag {audio_fmt}, {bits}-bit)")


def _encode_int(x, bits):
    """Quantize float [-1, 1] to signed `bits`-bit integers.

    Uses the SAME scale as decoding (2**(bits-1)) so that decode->encode is
    an exact round trip - decoding divides by 2**(bits-1), so encoding must
    multiply by the same value, not by 2**(bits-1)-1. The only value that
    would overflow is exactly +1.0 (-> +full-scale), so it's clamped to the
    top code. This keeps a bypass byte-identical and makes A/B honest.
    """
    full = 2 ** (bits - 1)
    v = np.round(x * full)
    v = np.clip(v, -full, full - 1)
    return v


def _encode_samples(x, audio_fmt, bits):
    # Integer formats are clipped inside _encode_int (at the scaled-integer
    # level, which is equivalent to clipping x first). Float formats must
    # NOT be clipped here - _finalize_and_write relies on float output
    # keeping an over-0dBFS peak untouched, only warning about it.
    if audio_fmt == 1 and bits == 24:
        v = _encode_int(x, 24).astype(np.int32)
        u = (v & 0xFFFFFF).reshape(-1)
        out = np.empty((u.size, 3), dtype=np.uint8)
        out[:, 0] = u & 0xFF
        out[:, 1] = (u >> 8) & 0xFF
        out[:, 2] = (u >> 16) & 0xFF
        return out.tobytes()
    if audio_fmt == 1 and bits == 16:
        return _encode_int(x, 16).astype("<i2").tobytes()
    if audio_fmt == 1 and bits == 32:
        return _encode_int(x, 32).astype("<i4").tobytes()
    if audio_fmt == 3 and bits == 32:
        return x.astype("<f4").tobytes()
    if audio_fmt == 3 and bits == 64:
        return x.astype("<f8").tobytes()
    raise ValueError(f"cannot encode format tag {audio_fmt}, {bits}-bit")


def _riff_chunk(cid, body):
    out = cid + struct.pack("<I", len(body)) + body
    if len(body) & 1:
        out += b"\x00"                          # pad to even length
    return out


def write_wav(path, x, info, force_float32=False):
    """Write x (float64, shape (n, 2)) back to a WAV in info's original
    format, carrying over info's metadata chunks. If force_float32 is set,
    output is written as 32-bit float regardless of the source (fallback).
    Returns the (audio_fmt, bits) actually written.
    """
    audio_fmt, bits = info.audio_fmt, info.bits
    if force_float32:
        audio_fmt, bits = 3, 32

    audio_bytes = _encode_samples(x, audio_fmt, bits)

    ch = 2
    block_align = ch * bits // 8
    byte_rate = info.sr * block_align
    fmt_body = struct.pack("<HHIIHH", audio_fmt, ch, info.sr,
                           byte_rate, block_align, bits)

    body = b"WAVE"
    body += _riff_chunk(b"fmt ", fmt_body)
    for cid, cbody in info.extra_chunks:       # bext, iXML, cue, LIST, junk...
        body += _riff_chunk(cid, cbody)
    body += _riff_chunk(b"data", audio_bytes)

    riff = b"RIFF" + struct.pack("<I", len(body)) + body
    with open(path, "wb") as f:
        f.write(riff)
    return audio_fmt, bits


# ---------------------------------------------------------------- item region
#
# A long source file can hold several separate events at different stereo
# positions (e.g. radio chatter). Processing the whole file averages the
# angle across all of them, so trimming an item to one event and pressing
# Process previously did nothing - the one line the user selected was
# drowned in the file-wide average. --start/--length (seconds) let a
# caller (the REAPER front-ends, or the CLI directly) process only the
# item's region: read, correct, and write only that slice, independent of
# whatever else is in the source file.

_MIN_REGION_SAMPLES = 1024   # ~21ms at 48kHz; below this there's nothing to analyze


def _rewrite_bext_time_reference(body, added_samples):
    """Advances a bext chunk's Time Reference (BWF spec: a 64-bit sample
    count at byte offset 338 in the chunk body, low 32 bits then high 32
    bits, both little-endian) by added_samples.

    A region cut from partway through a file starts later than the
    original did, so the old time reference would place the corrected
    clip at the wrong point on a BWF-aware timeline - exactly the
    property carrying metadata through was meant to protect. Returns the
    body unchanged if it's too short to safely contain the field (a
    truncated/nonstandard bext must pass through, not crash).
    """
    OFFSET = 338
    if len(body) < OFFSET + 8:
        return body
    low, high = struct.unpack_from("<II", body, OFFSET)
    original = low | (high << 32)
    new_ref = (original + added_samples) & 0xFFFFFFFFFFFFFFFF
    out = bytearray(body)
    struct.pack_into("<II", out, OFFSET,
                     new_ref & 0xFFFFFFFF, (new_ref >> 32) & 0xFFFFFFFF)
    return bytes(out)


def _apply_region(x, sr, info, start_sec, length_sec, path):
    """Slices x to the requested region (seconds) and, if the region
    doesn't start at sample 0, rewrites the bext time reference to match.
    Returns (x_region, info_region).

    Defensive: a negative start clamps to 0; a region extending past
    end-of-file truncates to the file's actual length rather than
    reading out of range - an item can legitimately extend past its
    source (REAPER draws silence there), so this must never error, only
    truncate. Raises ValueError if the resulting region is empty or
    shorter than _MIN_REGION_SAMPLES.
    """
    n = len(x)
    start_samp = min(int(round(max(0.0, start_sec) * sr)), n)
    if length_sec is None:
        end_samp = n
    else:
        end_samp = start_samp + int(round(max(0.0, length_sec) * sr))
    end_samp = min(end_samp, n)

    if end_samp - start_samp < _MIN_REGION_SAMPLES:
        raise ValueError(
            f"{path}: region too short to process "
            f"({end_samp - start_samp} samples, need at least {_MIN_REGION_SAMPLES})")

    x_region = x[start_samp:end_samp]

    extra_chunks = info.extra_chunks
    if start_samp > 0:
        extra_chunks = [
            (cid, _rewrite_bext_time_reference(cbody, start_samp))
            if cid == b"bext" else (cid, cbody)
            for cid, cbody in extra_chunks
        ]
    info_region = WavInfo(sr=info.sr, audio_fmt=info.audio_fmt, bits=info.bits,
                          ch=info.ch, extra_chunks=extra_chunks)
    return x_region, info_region


# ---------------------------------------------------------------- analysis helpers

def loudest_region(x, sr, win_sec=3.0):
    """Return (start, stop) sample indices of the loudest win_sec-long
    window, by summed stereo energy. Used to focus delay estimation on
    real signal instead of leading silence / handling noise.
    """
    n = len(x)
    win = min(n, max(1, int(sr * win_sec)))
    if win >= n:
        return 0, n
    energy = x[:, 0] ** 2 + x[:, 1] ** 2
    csum = np.cumsum(energy)
    # windowed energy sum over every start position
    wsum = csum[win:] - csum[:-win]
    start = int(np.argmax(wsum))
    return start, start + win


def sound_length_sec(x, sr, floor_db=40.0):
    """Estimate the length of the *useful* sound (excluding leading/trailing
    near-silence), in seconds. Used to auto-pick the STFT window size.

    Envelope is taken in short blocks; anything within floor_db of the peak
    block counts as 'sound'. The span from the first to the last such block
    is the useful length.
    """
    n = len(x)
    if n == 0:
        return 0.0
    block = max(1, int(sr * 0.01))            # 10 ms blocks
    energy = x[:, 0] ** 2 + x[:, 1] ** 2
    nb = n // block
    if nb < 1:
        return n / sr
    e = energy[:nb * block].reshape(nb, block).mean(axis=1)
    peak = e.max()
    if peak <= EPS:
        return n / sr
    thresh = peak * (10.0 ** (-floor_db / 10.0))
    active = np.where(e >= thresh)[0]
    if len(active) == 0:
        return n / sr
    span_blocks = active[-1] - active[0] + 1
    return span_blocks * block / sr


def auto_win(x, sr, verbose=True):
    """Pick an STFT window size from the useful sound length.

    Thresholds are deliberately coarse - the window only needs to be in the
    right ballpark for the band analysis, not exact:
        < 0.15 s  -> 512   (clicks, taps)
        < 0.6 s   -> 1024  (foley hits)
        < 2.5 s   -> 2048  (medium)
        else      -> 4096  (sustained / atmospheres)
    """
    length = sound_length_sec(x, sr)
    if length < 0.15:
        win = 512
    elif length < 0.6:
        win = 1024
    elif length < 2.5:
        win = 2048
    else:
        win = 4096
    # never let the window exceed the material itself
    while win > len(x) and win > 256:
        win //= 2
    if verbose:
        print(f"auto window: useful length ~{length:.2f} s -> STFT window {win}")
    return win


# ---------------------------------------------------------------- delay alignment

def estimate_delay(x, sr, max_ms=2.0):
    """Inter-channel delay in samples (positive: L lags R). GCC-PHAT,
    sub-sample precision.

    The delay is estimated on the loudest region of the file (see
    loudest_region), not the start: for a static recorder position the L/R
    offset doesn't drift over the file, and measuring on real signal avoids
    locking onto whatever noise happens to sit in leading silence.
    """
    a, b = loudest_region(x, sr)
    L, R = x[a:b, 0], x[a:b, 1]
    n = 1 << int(np.ceil(np.log2(len(L) * 2)))
    FL = np.fft.rfft(L, n)
    FR = np.fft.rfft(R, n)
    cross = FL * np.conj(FR)
    cross /= (np.abs(cross) + EPS)          # PHAT weighting
    cc = np.fft.irfft(cross, n)
    max_lag = int(sr * max_ms / 1000.0)
    lags = np.concatenate([np.arange(0, max_lag + 1), np.arange(-max_lag, 0)])
    vals = np.concatenate([cc[:max_lag + 1], cc[-max_lag:]])
    k = np.argmax(vals)
    lag = lags[k]
    # parabolic interpolation for sub-sample precision
    if 0 < k < len(vals) - 1:
        y0, y1, y2 = vals[k - 1], vals[k], vals[k + 1]
        denom = (y0 - 2 * y1 + y2)
        if abs(denom) > EPS:
            lag = lag + 0.5 * (y0 - y2) / denom
    return float(lag)


def apply_delay(sig, delay_samples):
    """Delay a 1-D signal by a fractional number of samples (FFT phase ramp)."""
    n = len(sig)
    nfft = 1 << int(np.ceil(np.log2(n + abs(int(delay_samples)) + 2)))
    F = np.fft.rfft(sig, nfft)
    freqs = np.arange(len(F)) / nfft
    F *= np.exp(-2j * np.pi * freqs * delay_samples)
    return np.fft.irfft(F, nfft)[:n]


def align(x, sr, verbose=True):
    d = estimate_delay(x, sr)
    if verbose:
        print(f"inter-channel delay: {d / sr * 1000.0:+.3f} ms "
              f"({d:+.2f} samples, positive = L lags R)")
    if abs(d) < 0.05:
        if verbose:
            print("delay negligible, skipping alignment")
        return x
    y = x.copy()
    if d > 0:
        y[:, 1] = apply_delay(x[:, 1], d)    # L lags: delay R to meet it
    else:
        y[:, 0] = apply_delay(x[:, 0], -d)   # R lags: delay L to meet it
    return y


# ---------------------------------------------------------------- rotation helpers

def weighted_median(values, weights):
    order = np.argsort(values)
    v, w = np.asarray(values)[order], np.asarray(weights)[order]
    cw = np.cumsum(w)
    if cw[-1] < EPS:
        return 45.0
    return float(v[np.searchsorted(cw, 0.5 * cw[-1])])


def make_bands(freqs, n_bands, f_lo=50.0):
    edges = np.geomspace(f_lo, freqs[-1], n_bands + 1)
    bands = []
    for i in range(n_bands):
        idx = np.where((freqs >= edges[i]) & (freqs < edges[i + 1]))[0]
        if len(idx):
            bands.append(idx)
    low = np.where(freqs < f_lo)[0]
    if len(low) and bands:
        bands[0] = np.concatenate([low, bands[0]])
    return bands


# ---------------------------------------------------------------- width

def collapse(x, amount, compensate=True, max_gain_db=12.0):
    """Reduce stereo width by scaling the side signal.

    0 = untouched, 1 = mono. This is deliberately NOT part of re-centering:
    rotation moves the image, this narrows it. Applied last in the chain so
    it acts on already-centred, already-time-aligned audio - collapsing a
    time-offset pair is what produces comb filtering.

    Discarding the side signal removes real energy, so the result gets
    quieter - a lot on decorrelated material, barely at all on a coherent
    centred source. With compensate=True the output RMS is matched back to
    the input, which is what makes an A/B honest. The boost is capped so a
    nearly-silent or pathologically wide input cannot blow up.

    Returns (y, gain) where gain is the linear factor applied (1.0 = none).
    """
    amount = float(np.clip(amount, 0.0, 1.0))
    if amount <= 0.0:
        return x, 1.0
    m = 0.5 * (x[:, 0] + x[:, 1])
    s = 0.5 * (x[:, 0] - x[:, 1]) * (1.0 - amount)
    y = np.stack([m + s, m - s], axis=1)

    gain = 1.0
    if compensate:
        rms_in = np.sqrt(np.mean(x ** 2))
        rms_out = np.sqrt(np.mean(y ** 2))
        if rms_in > EPS and rms_out > EPS:
            gain = min(rms_in / rms_out, 10.0 ** (max_gain_db / 20.0))
            y = y * gain
    return y, gain


# ---------------------------------------------------------------- global (robust)

# ---------------------------------------------------------------- bands (static per band)

def recenter_bands(x, sr, strength, n_bands=24, nperseg=4096,
                   max_corr_deg=30.0, tail_strength=None, verbose=True):
    """Static per-band rotation, estimated separately for attacks and tails.

    Frames are softly classified attack/tail by broadband energy envelope;
    each band gets two angles (attack-weighted, tail-weighted) and the
    correction crossfades between them frame by frame.

    Returns (y, diag). diag is a plain dict reporting what was measured -
    offset_deg/attack_deg/tail_deg/spread_deg/win/n_bands - so a caller can
    tell "measured no offset, applied nothing" apart from "broken", even
    when the correction itself is a no-op. See process_one/run_batch for
    how it reaches the user.
    """
    if tail_strength is None:
        tail_strength = strength
    noverlap = nperseg * 3 // 4
    f, _, ZL = stft(x[:, 0], sr, nperseg=nperseg, noverlap=noverlap)
    _, _, ZR = stft(x[:, 1], sr, nperseg=nperseg, noverlap=noverlap)
    bands = make_bands(f, n_bands)
    n_frames = ZL.shape[1]

    # --- soft attack/tail mask: attack = frames right after an energy onset
    e_fr = np.sum(np.abs(ZL) ** 2 + np.abs(ZR) ** 2, axis=0)
    db = 10.0 * np.log10(e_fr + EPS)
    db = np.maximum(db, np.max(db) - 80.0)
    rise = np.diff(db, prepend=db[0])
    onset = rise > 4.0                       # energy jumped > 4 dB per hop
    hop_s = (nperseg - noverlap) / sr
    n_att = max(1, int(round(0.06 / hop_s)))  # attack window ~60 ms
    mask = np.zeros(n_frames)
    for i in np.where(onset)[0]:
        mask[i:i + n_att] = 1.0              # 1=attack, 0=tail

    # Smooth the hard 1/0 mask into a soft crossfade so the correction
    # ramps between the attack angle and the tail angle over a few frames
    # instead of switching abruptly (an abrupt switch rotates the image by
    # a jump at every onset boundary - audible as a click/seam, especially
    # at Attack=1 / Tail=0). A ~30 ms Hann kernel gives a gentle ramp.
    # NOTE: np.hanning(n) is zero at both ends, so a real smoothing kernel
    # needs its interior; np.hanning(3) = [0,1,0] is a no-op (this used to
    # be the bug that left the mask hard).
    n_smooth = max(3, int(round(0.03 / hop_s)) | 1)   # odd, >=3
    k = np.hanning(n_smooth + 2)[1:-1]                 # drop the zero ends
    if k.sum() <= EPS:
        k = np.ones(1)
    mask = np.convolve(mask, k / k.sum(), mode="same")
    mask = np.clip(mask, 0.0, 1.0)

    # broadband reference angles (used to stabilize weak bands)
    ang_all, w_all = [], []
    for idx in bands:
        l, r = ZL[idx, :], ZR[idx, :]
        el = np.sum(np.abs(l) ** 2, axis=0)
        er = np.sum(np.abs(r) ** 2, axis=0)
        cross = np.abs(np.sum(l * np.conj(r), axis=0))
        coh = cross / (np.sqrt(el * er) + EPS)
        ang_all.append(np.degrees(np.arctan2(np.sqrt(er), np.sqrt(el))))
        w_all.append((el + er) * coh ** 2)
    ang_all = np.concatenate(ang_all)
    w_all = np.concatenate(w_all)
    mask_rep = np.tile(mask, len(bands))
    a_att_bb = weighted_median(ang_all, w_all * mask_rep)
    a_tail_bb = weighted_median(ang_all, w_all * (1.0 - mask_rep))
    w_ref = 0.15 * np.sum(w_all) / max(len(bands), 1)

    if verbose:
        print(f"broadband: attack {a_att_bb:.1f}d  tail {a_tail_bb:.1f}d")
        print(f"{'band':>4}  {'freq range':>16}  {'attack':>7}  {'tail':>7}")
    att_vals = []
    for bi, idx in enumerate(bands):
        l, r = ZL[idx, :], ZR[idx, :]
        el = np.sum(np.abs(l) ** 2, axis=0)
        er = np.sum(np.abs(r) ** 2, axis=0)
        cross = np.abs(np.sum(l * np.conj(r), axis=0))
        e = el + er
        coh = cross / (np.sqrt(el * er) + EPS)
        ang = np.degrees(np.arctan2(np.sqrt(er), np.sqrt(el)))
        w = e * coh ** 2

        wa, wt = np.sum(w * mask), np.sum(w * (1.0 - mask))
        a_att = weighted_median(ang, w * mask)
        a_tail = weighted_median(ang, w * (1.0 - mask))
        # confidence shrinkage: weak bands lean on the broadband estimate
        la = wa / (wa + w_ref)
        lt = wt / (wt + w_ref)
        a_att = la * a_att + (1.0 - la) * a_att_bb
        a_tail = lt * a_tail + (1.0 - lt) * a_tail_bb
        att_vals.append(a_att)

        c_att = np.clip(strength * (45.0 - a_att), -max_corr_deg, max_corr_deg)
        c_tail = np.clip(tail_strength * (45.0 - a_tail),
                         -max_corr_deg, max_corr_deg)
        corr = c_att * mask + c_tail * (1.0 - mask)      # per frame
        th = np.radians(corr)
        c, s = np.cos(th), np.sin(th)
        ZL[idx, :], ZR[idx, :] = (c[None, :] * l - s[None, :] * r,
                                  s[None, :] * l + c[None, :] * r)
        if verbose:
            print(f"{bi:>4}  {f[idx[0]]:>7.0f}-{f[idx[-1]]:>6.0f} Hz  "
                  f"{a_att:>6.1f}d  {a_tail:>6.1f}d")

    _, yl = istft(ZL, sr, nperseg=nperseg, noverlap=noverlap)
    _, yr = istft(ZR, sr, nperseg=nperseg, noverlap=noverlap)
    n = min(len(yl), len(x))
    y = np.stack([yl[:n], yr[:n]], axis=1)
    if n < len(x):
        y = np.pad(y, ((0, len(x) - n), (0, 0)))

    # spread_deg: 90th-10th percentile spread of the per-band attack angles
    # (percentiles rather than min/max so one junk band can't dominate) -
    # the frequency-dependent tilt that per-band correction has to work
    # with, and that a plain L/R gain trim cannot fix.
    spread_deg = (float(np.percentile(att_vals, 90) - np.percentile(att_vals, 10))
                 if att_vals else 0.0)
    diag = {
        "offset_deg": float(a_att_bb - 45.0),
        "attack_deg": float(a_att_bb),
        "tail_deg": float(a_tail_bb),
        "spread_deg": spread_deg,
        "win": int(nperseg),
        "n_bands": int(len(bands)),
    }
    return y, diag


# ---------------------------------------------------------------- main

def _is_bypass(args):
    """True when no operation is requested: nothing to do but copy the
    audio through. Align is a no-op to bypass only if it's off - when it's
    on we still want to measure/report even if strengths are zero."""
    return (args.strength == 0.0
            and (args.tail_strength in (None, 0.0))
            and args.collapse == 0.0
            and not args.align)


def process_one(in_path, out_path, args, verbose, start=None, length=None):
    """Run the full pipeline (align -> recenter -> collapse -> normalize ->
    write) for a single file. Raises ValueError on bad input, same as
    read_wav always has.

    start/length (seconds) restrict processing to a region of the source -
    see _apply_region. When both are omitted/default (start None or 0.0,
    length None), falls back to args.start/args.length; if those are also
    absent or default, the whole file is processed exactly as before this
    existed. Explicit start/length here are what --batch uses, since a
    region is a per-line property, not a global one args can carry for an
    entire batch run.

    Returns the diag dict from recenter_bands (see there), or None
    whenever no centering ran - the bypass path, or a request with no
    centering effect (strength and tail_strength both 0, e.g. "width
    only") even if align/collapse still apply. Either way, no centering
    means no measurement, and that must never be mistaken for a
    measurement of zero offset.
    """
    sr, x, info = read_wav(in_path)
    v = verbose

    start_sec = start if start is not None else getattr(args, "start", 0.0) or 0.0
    length_sec = length if length is not None else getattr(args, "length", None)
    if start_sec > 0.0 or length_sec is not None:
        x, info = _apply_region(x, sr, info, start_sec, length_sec, in_path)

    if v:
        fmt_name = "float" if info.audio_fmt == 3 else "PCM"
        print(f"input: {sr} Hz, {info.bits}-bit {fmt_name}, "
              f"{len(x)} frames ({len(x)/sr:.2f} s)")
        if info.extra_chunks:
            names = ", ".join(c[0].decode("latin-1").strip() for c in info.extra_chunks)
            print(f"metadata chunks carried over: {names}")

    # Bypass: no operation requested. Re-encode straight through in the
    # original format (still honouring format==format and metadata), rather
    # than running an STFT round trip that would only add reconstruction
    # error for no benefit.
    if _is_bypass(args):
        if v:
            print("bypass: no correction requested, copying audio through")
        _finalize_and_write(out_path, x, info, args, v)
        return None

    if args.align:
        x = align(x, sr, verbose=v)

    # No centering requested (strength and tail_strength both 0 - e.g.
    # "width only", with collapse and/or align still active): skip
    # recenter_bands entirely rather than running a full STFT/ISTFT round
    # trip to apply a rotation of exactly 0 degrees. Faster, and avoids
    # reconstruction error where no correction happens anyway. Collapse,
    # if requested, still applies below - it works directly on the
    # time-domain signal and needs no STFT of its own.
    needs_centering = args.strength != 0.0 or args.tail_strength not in (None, 0.0)
    if needs_centering:
        # Resolve the STFT window: explicit integer, or auto-detected from
        # the useful sound length.
        win = auto_win(x, sr, verbose=v) if args.win == "auto" else int(args.win)

        y, diag = recenter_bands(x, sr, args.strength, n_bands=args.n_bands,
                                 nperseg=win,
                                 tail_strength=args.tail_strength, verbose=v)
        if v:
            print(f"measured: offset {diag['offset_deg']:+.2f}d "
                  f"(attack {diag['attack_deg']:.2f}d / tail {diag['tail_deg']:.2f}d), "
                  f"per-band spread {diag['spread_deg']:.2f}d, window {diag['win']}")
    else:
        y, diag = x, None
        if v:
            print("width only: no centering requested, skipping the STFT round trip")

    # Width reduction comes last, on already-centred audio.
    if args.collapse > 0.0:
        if not args.align:
            print("warning: --collapse without --align - if the channels are "
                  "time-offset, narrowing will comb-filter", file=sys.stderr)
        y, g = collapse(y, args.collapse,
                        compensate=not args.no_collapse_gain)
        if v:
            print(f"collapse: side signal scaled by "
                  f"{1.0 - min(args.collapse, 1.0):.2f} "
                  f"({args.collapse:.2f} towards mono)")
            if g != 1.0:
                print(f"collapse: level compensated {20*np.log10(g):+.2f} dB")

    _finalize_and_write(out_path, y, info, args, v)
    return diag


def _finalize_and_write(out_path, y, info, args, v):
    """Peak handling + write, shared by the normal and bypass paths.

    For integer outputs a peak over full-scale would wrap/clip, so we
    normalize and say so. For float32 output there's no clipping ceiling,
    so we leave the level alone (normalizing would silently undo the
    collapse RMS match and make an honest A/B impossible) and only warn.
    """
    peak = float(np.max(np.abs(y))) if y.size else 0.0
    is_float_out = (info.audio_fmt == 3)

    if peak > 1.0:
        if is_float_out:
            if v:
                print(f"note: peak is {20*np.log10(peak):.2f} dBFS (over 0); "
                      f"left as-is (float output, no clipping)")
        else:
            y = y / peak
            if v:
                print(f"note: output normalized (peak was "
                      f"{20*np.log10(peak):.2f} dBFS)")
                if args.collapse > 0.0 and not args.no_collapse_gain:
                    print("note: normalization pulled the level back down; the "
                          "compensated level did not fit")

    fmt, bits = write_wav(out_path, y, info)
    if v:
        fmt_name = "float" if fmt == 3 else "PCM"
        print(f"written: {out_path}  ({info.sr} Hz, {bits}-bit {fmt_name})")


def run_batch(manifest_path, args, verbose):
    """Process every line in the manifest within this single process. This
    is the point of --batch: scipy/numpy import is the dominant fixed cost
    per process launch (roughly 2s regardless of file length), so
    processing N files in one launch instead of N launches turns that Nx
    cost into a 1x cost. Per-line outcome is printed with a ##OK##/##ERR##
    prefix so a caller (e.g. the REAPER Lua side) can parse results even
    with --verbose chatter interleaved.

    Each line is 'in_path<TAB>out_path' (start=0.0, length=to end of file)
    or 'in_path<TAB>out_path<TAB>start<TAB>length' (both seconds; an empty
    length field means to end of file), so two items trimmed from the same
    source to different regions are two distinct jobs, not a duplicate.
    The 2-field form is still accepted so older callers don't break.

    The key printed in ##OK##/##ERR##/##DIAG## is out_path, not in_path:
    unlike in_path, out_path is guaranteed unique per job (the caller must
    give every job its own output path), so it's what a caller with
    multiple regions from the same source file needs to tell its jobs
    apart.
    """
    with open(manifest_path, "r", encoding="utf-8") as f:
        lines = [line.rstrip("\n").split("\t") for line in f if line.strip()]

    ok_count = 0
    for line_no, parts in enumerate(lines, 1):
        start_sec, length_sec = 0.0, None
        if len(parts) == 2:
            in_path, out_path = parts
        elif len(parts) == 4:
            in_path, out_path, start_str, length_str = parts
            try:
                start_sec = float(start_str)
                length_sec = float(length_str) if length_str != "" else None
            except ValueError:
                print(f"##ERR##\t(line {line_no})\tmalformed manifest line")
                continue
        else:
            print(f"##ERR##\t(line {line_no})\tmalformed manifest line")
            continue
        try:
            diag = process_one(in_path, out_path, args, verbose,
                               start=start_sec, length=length_sec)
            if diag is not None:
                payload = (
                    f"offset={diag['offset_deg']:+.2f};"
                    f"attack={diag['attack_deg']:.2f};"
                    f"tail={diag['tail_deg']:.2f};"
                    f"spread={diag['spread_deg']:.2f};"
                    f"win={diag['win']};"
                    f"bands={diag['n_bands']}"
                )
                # Machine channel the Lua side parses - always printed,
                # regardless of --quiet (which only suppresses human chatter).
                print(f"##DIAG##\t{out_path}\t{payload}")
            print(f"##OK##\t{out_path}\t{in_path}")
            ok_count += 1
        except Exception as e:
            print(f"##ERR##\t{out_path}\t{e}")

    if verbose:
        print(f"batch done: {ok_count}/{len(pairs)} file(s) ok")


def main():
    ap = argparse.ArgumentParser(
        description="InCenter - offline stereo re-centering (Budash Audio)")
    ap.add_argument("--version", action="version",
                    version=f"InCenter {__version__} - Budash Audio")
    ap.add_argument("infile", nargs="?",
                    help="input WAV (omit when using --batch)")
    ap.add_argument("outfile", nargs="?",
                    help="output WAV (omit when using --batch)")
    ap.add_argument("--batch", metavar="MANIFEST",
                    help="process every 'in<TAB>out' pair listed in this "
                         "file within a single process launch, instead of "
                         "infile/outfile")
    ap.add_argument("--align", action="store_true",
                    help="estimate and remove inter-channel time delay first "
                         "(measured on the loudest region of the file)")
    ap.add_argument("--strength", type=float, default=1.0,
                    help="attack correction amount, 0..1 (default: 1.0)")
    ap.add_argument("--tail-strength", type=float, default=None,
                    help="separate correction amount for tails "
                         "(default: same as --strength; 0 = leave tails alone)")
    ap.add_argument("--collapse", type=float, default=0.0,
                    help="stereo width reduction, applied last: "
                         "0 = untouched (default), 1 = mono")
    ap.add_argument("--no-collapse-gain", action="store_true",
                    help="do not RMS-match the level after --collapse "
                         "(narrowing otherwise makes the signal quieter)")
    ap.add_argument("--bands", type=int, default=24, dest="n_bands")
    ap.add_argument("--win", default="auto",
                    help="STFT window size in samples, or 'auto' (default) to "
                         "pick it from the detected sound length")
    ap.add_argument("--start", type=float, default=0.0,
                    help="start of the region to process, in seconds "
                         "(default: 0.0 = start of file). Ignored with --batch, "
                         "where start/length are per manifest line instead")
    ap.add_argument("--length", type=float, default=None,
                    help="length of the region to process, in seconds "
                         "(default: to end of file). Ignored with --batch")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    v = not args.quiet

    # --win: "auto" (default) or an explicit integer. Auto-detection of the
    # actual window happens per-file in process_one, since it depends on the
    # audio; here we just validate and normalize the argument.
    if isinstance(args.win, str) and args.win.lower() == "auto":
        args.win = "auto"
    else:
        try:
            args.win = int(args.win)
        except (TypeError, ValueError):
            ap.error("--win must be an integer or 'auto'")

    if args.batch:
        run_batch(args.batch, args, v)
        return

    if not args.infile or not args.outfile:
        ap.error("infile/outfile are required unless --batch is given")

    process_one(args.infile, args.outfile, args, v)


if __name__ == "__main__":
    try:
        main()
    except ValueError as e:
        print(f"error: {e}")
        sys.exit(1)
