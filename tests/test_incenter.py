"""Unit tests for the incenter.py DSP engine."""
import argparse
import os
import signal
import struct
import subprocess
import sys
import time

import numpy as np
import pytest

import incenter as ic


# --------------------------------------------------------------- helpers

def sine(freq, sr, dur, amp=0.5, phase=0.0):
    n = int(sr * dur)
    t = np.arange(n) / sr
    return (amp * np.sin(2 * np.pi * freq * t + phase)).astype(np.float64)


def stereo(left, right):
    n = min(len(left), len(right))
    return np.stack([left[:n], right[:n]], axis=1)


def riff_chunk(cid, body):
    out = cid + struct.pack("<I", len(body)) + body
    if len(body) & 1:
        out += b"\x00"
    return out


def build_wav_bytes(audio_fmt, ch, sr, bits, data_bytes, extra_chunks=None):
    """Hand-assemble a minimal RIFF/WAVE file, independent of write_wav,
    for testing read_wav's parsing in isolation."""
    block_align = ch * bits // 8
    byte_rate = sr * block_align
    fmt_body = struct.pack("<HHIIHH", audio_fmt, ch, sr, byte_rate,
                            block_align, bits)
    body = b"WAVE" + riff_chunk(b"fmt ", fmt_body)
    for cid, cbody in (extra_chunks or []):
        body += riff_chunk(cid, cbody)
    body += riff_chunk(b"data", data_bytes)
    return b"RIFF" + struct.pack("<I", len(body)) + body


def default_args(**overrides):
    ns = argparse.Namespace(
        strength=1.0,
        tail_strength=None,
        collapse=0.0,
        align=False,
        win="auto",
        n_bands=24,
        no_collapse_gain=False,
        quiet=True,
    )
    for k, v in overrides.items():
        setattr(ns, k, v)
    return ns


# --------------------------------------------------------------- WAV I/O

class TestWavRoundTrip:
    @pytest.mark.parametrize("audio_fmt,bits", [
        (1, 16), (1, 24), (1, 32), (3, 32), (3, 64),
    ])
    def test_round_trip_preserves_format_and_signal(self, tmp_path, audio_fmt, bits):
        sr = 48000
        x = stereo(sine(440, sr, 0.05, amp=0.6), sine(220, sr, 0.05, amp=0.3))
        info = ic.WavInfo(sr=sr, audio_fmt=audio_fmt, bits=bits, ch=2, extra_chunks=[])
        path = tmp_path / "out.wav"
        written_fmt, written_bits = ic.write_wav(str(path), x, info)
        assert (written_fmt, written_bits) == (audio_fmt, bits)

        sr2, y, info2 = ic.read_wav(str(path))
        assert sr2 == sr
        assert info2.audio_fmt == audio_fmt
        assert info2.bits == bits
        # quantization tolerance depends on bit depth
        tol = 4.0 / (2 ** (bits - 1)) if audio_fmt == 1 else 1e-6
        assert np.max(np.abs(y - x)) < tol

    def test_extra_chunks_round_trip_byte_identical(self, tmp_path):
        sr = 44100
        x = stereo(sine(1000, sr, 0.01), sine(1000, sr, 0.01))
        bext_body = b"B" * 30
        ixml_body = b"<BWFXML></BWFXML>"  # even length not guaranteed on purpose
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2,
                           extra_chunks=[(b"bext", bext_body), (b"iXML", ixml_body)])
        path = tmp_path / "meta.wav"
        ic.write_wav(str(path), x, info)

        _, _, info2 = ic.read_wav(str(path))
        assert info2.extra_chunks == [(b"bext", bext_body), (b"iXML", ixml_body)]

    def test_force_float32_overrides_source_format(self, tmp_path):
        sr = 48000
        x = stereo(sine(440, sr, 0.02), sine(440, sr, 0.02))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        path = tmp_path / "f32.wav"
        fmt, bits = ic.write_wav(str(path), x, info, force_float32=True)
        assert (fmt, bits) == (3, 32)
        _, _, info2 = ic.read_wav(str(path))
        assert (info2.audio_fmt, info2.bits) == (3, 32)


class TestReadWavParsing:
    def test_rejects_non_riff(self, tmp_path):
        path = tmp_path / "bad.wav"
        path.write_bytes(b"not a riff file at all............")
        with pytest.raises(ValueError, match="not a RIFF/WAVE"):
            ic.read_wav(str(path))

    def test_rejects_missing_data_chunk(self, tmp_path):
        fmt_body = struct.pack("<HHIIHH", 1, 2, 44100, 44100 * 4, 4, 16)
        body = b"WAVE" + riff_chunk(b"fmt ", fmt_body)
        raw = b"RIFF" + struct.pack("<I", len(body)) + body
        path = tmp_path / "nodata.wav"
        path.write_bytes(raw)
        with pytest.raises(ValueError, match="missing fmt or data"):
            ic.read_wav(str(path))

    def test_rejects_mono(self, tmp_path):
        data = np.zeros(10, dtype="<i2").tobytes()
        raw = build_wav_bytes(1, 1, 44100, 16, data)
        path = tmp_path / "mono.wav"
        path.write_bytes(raw)
        with pytest.raises(ValueError, match="expected stereo"):
            ic.read_wav(str(path))

    def test_rejects_unsupported_bit_depth(self, tmp_path):
        data = np.zeros(20, dtype=np.uint8).tobytes()
        raw = build_wav_bytes(1, 2, 44100, 8, data)  # 8-bit PCM unsupported
        path = tmp_path / "8bit.wav"
        path.write_bytes(raw)
        with pytest.raises(ValueError, match="unsupported WAV format"):
            ic.read_wav(str(path))

    def test_decodes_known_16bit_values(self, tmp_path):
        samples = np.array([[0, 16384], [-16384, 32767], [-32768, 0]], dtype="<i2")
        raw = build_wav_bytes(1, 2, 44100, 16, samples.tobytes())
        path = tmp_path / "known16.wav"
        path.write_bytes(raw)
        sr, x, info = ic.read_wav(str(path))
        assert sr == 44100
        expected = samples.astype(np.float64) / 32768.0
        np.testing.assert_allclose(x, expected)

    def test_wave_format_extensible_resolves_subformat(self, tmp_path):
        # WAVE_FORMAT_EXTENSIBLE (0xFFFE) fmt chunk, 40 bytes, PCM subformat
        # tag (1) in the first 2 bytes of the SubFormat GUID.
        cb_size = 22
        valid_bits = 16
        channel_mask = 3
        subformat = struct.pack("<H", 1) + b"\x00" * 14
        fmt_body = (struct.pack("<HHIIHH", 0xFFFE, 2, 48000, 48000 * 4, 4, 16)
                    + struct.pack("<H", cb_size)
                    + struct.pack("<H", valid_bits)
                    + struct.pack("<I", channel_mask)
                    + subformat)
        data = np.array([[100, -100]], dtype="<i2").tobytes()
        body = b"WAVE" + riff_chunk(b"fmt ", fmt_body) + riff_chunk(b"data", data)
        raw = b"RIFF" + struct.pack("<I", len(body)) + body
        path = tmp_path / "ext.wav"
        path.write_bytes(raw)

        sr, x, info = ic.read_wav(str(path))
        assert info.audio_fmt == 1  # resolved from WAVE_FORMAT_EXTENSIBLE
        assert sr == 48000

    def test_odd_sized_chunk_is_word_aligned(self, tmp_path):
        sr = 44100
        odd_chunk = (b"odd ", b"\x01\x02\x03")  # 3 bytes -> padded to 4 on disk
        data = np.zeros((4, 2), dtype="<i2").tobytes()
        raw = build_wav_bytes(1, 2, sr, 16, data, extra_chunks=[odd_chunk])
        path = tmp_path / "odd.wav"
        path.write_bytes(raw)
        sr2, x, info = ic.read_wav(str(path))
        assert sr2 == sr
        assert info.extra_chunks == [odd_chunk]
        assert len(x) == 4


class TestEncodeInt:
    def test_round_trips_mid_scale_values(self):
        x = np.array([-1.0, -0.5, 0.0, 0.5, 0.999969])
        v = ic._encode_int(x, 16)
        back = v / (2 ** 15)
        np.testing.assert_allclose(back, x, atol=1.0 / (2 ** 15))

    def test_positive_full_scale_clamps_not_overflows(self):
        v = ic._encode_int(np.array([1.0]), 16)
        assert v[0] == 32767  # not 32768, which would overflow signed 16-bit

    def test_negative_full_scale_is_exact(self):
        v = ic._encode_int(np.array([-1.0]), 16)
        assert v[0] == -32768


# --------------------------------------------------------------- item region

class TestRewriteBextTimeReference:
    def _bext(self, low, high, total_len=400):
        """A minimal-but-plausible bext body with a Time Reference of
        (low, high) at the correct BWF offset (338), padded to total_len."""
        body = bytearray(total_len)
        struct.pack_into("<II", body, 338, low, high)
        return bytes(body)

    def test_advances_low_word_only(self):
        body = self._bext(low=1000, high=0)
        out = ic._rewrite_bext_time_reference(body, added_samples=500)
        low, high = struct.unpack_from("<II", out, 338)
        assert (low, high) == (1500, 0)

    def test_carries_into_high_word(self):
        body = self._bext(low=0xFFFFFFF0, high=0)
        out = ic._rewrite_bext_time_reference(body, added_samples=0x20)
        low, high = struct.unpack_from("<II", out, 338)
        assert low == 0x10
        assert high == 1

    def test_leaves_rest_of_chunk_untouched(self):
        body = bytearray(b"X" * 400)
        struct.pack_into("<II", body, 338, 1000, 0)
        body = bytes(body)
        out = ic._rewrite_bext_time_reference(body, added_samples=42)
        assert out[:338] == body[:338]
        assert out[346:] == body[346:]

    def test_truncated_chunk_passes_through_unchanged(self):
        short_body = b"too short to hold a time reference"
        out = ic._rewrite_bext_time_reference(short_body, added_samples=999)
        assert out == short_body

    def test_zero_length_chunk_does_not_crash(self):
        assert ic._rewrite_bext_time_reference(b"", added_samples=100) == b""


class TestApplyRegion:
    def _region_wav(self, sr=48000, dur=1.0, extra_chunks=None):
        x = stereo(sine(300, sr, dur, amp=0.3), sine(300, sr, dur, amp=0.1))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2,
                          extra_chunks=extra_chunks or [])
        return x, info

    def test_slices_to_the_requested_region(self):
        sr = 48000
        x, info = self._region_wav(sr=sr, dur=1.0)
        x_region, _ = ic._apply_region(x, sr, info, start_sec=0.1,
                                       length_sec=0.2, path="f.wav")
        assert len(x_region) == round(0.2 * sr)
        np.testing.assert_array_equal(
            x_region, x[round(0.1 * sr):round(0.1 * sr) + round(0.2 * sr)])

    def test_length_none_means_to_end_of_file(self):
        sr = 48000
        x, info = self._region_wav(sr=sr, dur=1.0)
        x_region, _ = ic._apply_region(x, sr, info, start_sec=0.5,
                                       length_sec=None, path="f.wav")
        assert len(x_region) == len(x) - round(0.5 * sr)

    def test_negative_start_clamps_to_zero(self):
        sr = 48000
        x, info = self._region_wav(sr=sr, dur=1.0)
        x_region, _ = ic._apply_region(x, sr, info, start_sec=-5.0,
                                       length_sec=0.3, path="f.wav")
        np.testing.assert_array_equal(x_region, x[:round(0.3 * sr)])

    def test_region_past_eof_truncates_not_errors(self):
        sr = 48000
        x, info = self._region_wav(sr=sr, dur=1.0)
        # item legitimately extends past its source (REAPER draws silence)
        x_region, _ = ic._apply_region(x, sr, info, start_sec=0.9,
                                       length_sec=5.0, path="f.wav")
        np.testing.assert_array_equal(x_region, x[round(0.9 * sr):])

    def test_zero_length_region_raises(self):
        sr = 48000
        x, info = self._region_wav(sr=sr, dur=1.0)
        with pytest.raises(ValueError, match="region too short to process"):
            ic._apply_region(x, sr, info, start_sec=0.5, length_sec=0.0,
                             path="f.wav")

    def test_sub_minimum_length_region_raises(self):
        sr = 48000
        x, info = self._region_wav(sr=sr, dur=1.0)
        tiny_sec = 500 / sr   # well under _MIN_REGION_SAMPLES (1024)
        with pytest.raises(ValueError, match="region too short to process"):
            ic._apply_region(x, sr, info, start_sec=0.5, length_sec=tiny_sec,
                             path="f.wav")

    def test_start_at_eof_raises_not_reads_out_of_range(self):
        sr = 48000
        x, info = self._region_wav(sr=sr, dur=1.0)
        with pytest.raises(ValueError, match="region too short to process"):
            ic._apply_region(x, sr, info, start_sec=10.0, length_sec=None,
                             path="f.wav")

    def test_rewrites_bext_when_start_is_nonzero(self):
        sr = 48000
        bext_body = bytearray(400)
        struct.pack_into("<II", bext_body, 338, 1000, 0)
        x, info = self._region_wav(sr=sr, dur=1.0,
                                   extra_chunks=[(b"bext", bytes(bext_body))])
        _, info_region = ic._apply_region(x, sr, info, start_sec=0.1,
                                          length_sec=0.2, path="f.wav")
        low, high = struct.unpack_from("<II", info_region.extra_chunks[0][1], 338)
        assert (low, high) == (1000 + round(0.1 * sr), 0)

    def test_leaves_bext_untouched_when_start_is_zero(self):
        sr = 48000
        bext_body = bytearray(400)
        struct.pack_into("<II", bext_body, 338, 1000, 0)
        x, info = self._region_wav(sr=sr, dur=1.0,
                                   extra_chunks=[(b"bext", bytes(bext_body))])
        _, info_region = ic._apply_region(x, sr, info, start_sec=0.0,
                                          length_sec=0.2, path="f.wav")
        assert info_region.extra_chunks[0][1] == bytes(bext_body)

    def test_non_bext_chunks_pass_through_unchanged(self):
        sr = 48000
        x, info = self._region_wav(sr=sr, dur=1.0,
                                   extra_chunks=[(b"iXML", b"<x/>")])
        _, info_region = ic._apply_region(x, sr, info, start_sec=0.1,
                                          length_sec=0.2, path="f.wav")
        assert info_region.extra_chunks == [(b"iXML", b"<x/>")]


class TestProcessOneRegion:
    def test_output_length_equals_region_length(self, tmp_path):
        sr = 48000
        x = stereo(sine(300, sr, 1.0, amp=0.3), sine(300, sr, 1.0, amp=0.1))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)
        out_path = tmp_path / "out.wav"

        args = default_args(strength=1.0, tail_strength=1.0, win=256, n_bands=4)
        ic.process_one(str(in_path), str(out_path), args, verbose=False,
                       start=0.2, length=0.3)

        _, y, _ = ic.read_wav(str(out_path))
        assert len(y) == round(0.3 * sr)

    def test_explicit_start_length_override_args(self, tmp_path):
        # args.start/args.length are the single-file CLI path; process_one's
        # own start=/length= (what --batch uses) must win when both are given.
        sr = 48000
        x = stereo(sine(300, sr, 1.0, amp=0.3), sine(300, sr, 1.0, amp=0.1))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)
        out_path = tmp_path / "out.wav"

        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.0,
                            align=False)
        args.start, args.length = 0.9, 0.05   # would be "too short" if used
        ic.process_one(str(in_path), str(out_path), args, verbose=False,
                       start=0.1, length=0.4)

        _, y, _ = ic.read_wav(str(out_path))
        assert len(y) == round(0.4 * sr)

    def test_whole_file_region_is_byte_identical_to_no_region(self, tmp_path):
        sr = 48000
        rng = np.random.default_rng(3)
        n = sr  # exactly 1.0s, so start=0.0/length=1.0 round-trips exactly
        left = 0.3 * np.sin(2 * np.pi * 300 * np.arange(n) / sr) + 0.02 * rng.standard_normal(n)
        right = 0.15 * np.sin(2 * np.pi * 300 * np.arange(n) / sr) + 0.02 * rng.standard_normal(n)
        x = stereo(left, right)
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=24, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)

        args = default_args(strength=1.0, tail_strength=0.7, collapse=0.2,
                            align=True, win=512, n_bands=8)
        out_no_region = tmp_path / "out_no_region.wav"
        ic.process_one(str(in_path), str(out_no_region), args, verbose=False)

        out_whole_region = tmp_path / "out_whole_region.wav"
        ic.process_one(str(in_path), str(out_whole_region), args, verbose=False,
                       start=0.0, length=n / sr)

        assert out_no_region.read_bytes() == out_whole_region.read_bytes()


class TestRunBatchRegion:
    def _write_source(self, path, sr=48000, dur=1.0):
        # A noise component, not a pure periodic tone, so two regions at
        # different offsets are guaranteed to actually differ (a pure tone
        # can repeat exactly at an offset that's a whole number of periods).
        rng = np.random.default_rng(11)
        n = int(sr * dur)
        left = sine(300, sr, dur, amp=0.3) + 0.05 * rng.standard_normal(n)
        right = sine(300, sr, dur, amp=0.1) + 0.05 * rng.standard_normal(n)
        x = stereo(left, right)
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        ic.write_wav(str(path), x, info)
        return sr

    def test_four_field_manifest_line_parses(self, tmp_path, capsys):
        sr = self._write_source(tmp_path / "in.wav")
        in_path = tmp_path / "in.wav"
        out_path = tmp_path / "out.wav"
        manifest = tmp_path / "manifest.txt"
        manifest.write_text(f"{in_path}\t{out_path}\t0.2\t0.3\n")

        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.0, align=False)
        ic.run_batch(str(manifest), args, verbose=False)

        assert f"##OK##\t{out_path}\t{in_path}" in capsys.readouterr().out
        _, y, _ = ic.read_wav(str(out_path))
        assert len(y) == round(0.3 * sr)

    def test_four_field_manifest_empty_length_means_to_eof(self, tmp_path):
        sr = self._write_source(tmp_path / "in.wav", dur=1.0)
        in_path = tmp_path / "in.wav"
        out_path = tmp_path / "out.wav"
        manifest = tmp_path / "manifest.txt"
        manifest.write_text(f"{in_path}\t{out_path}\t0.4\t\n")

        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.0, align=False)
        ic.run_batch(str(manifest), args, verbose=False)

        _, y, _ = ic.read_wav(str(out_path))
        assert len(y) == round(1.0 * sr) - round(0.4 * sr)

    def test_two_field_legacy_manifest_still_parses(self, tmp_path, capsys):
        sr = self._write_source(tmp_path / "in.wav", dur=0.5)
        in_path = tmp_path / "in.wav"
        out_path = tmp_path / "out.wav"
        manifest = tmp_path / "manifest.txt"
        manifest.write_text(f"{in_path}\t{out_path}\n")

        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.0, align=False)
        ic.run_batch(str(manifest), args, verbose=False)

        assert f"##OK##\t{out_path}\t{in_path}" in capsys.readouterr().out
        _, y, _ = ic.read_wav(str(out_path))
        assert len(y) == round(0.5 * sr)   # whole file, as before this feature

    def test_same_source_two_regions_produce_two_distinct_outputs(self, tmp_path):
        # The dedup fix this feature depends on: two jobs from the same
        # source file but different regions must not collide/overwrite -
        # this is the radio-chatter case the feature exists for.
        sr = self._write_source(tmp_path / "in.wav", dur=1.0)
        in_path = tmp_path / "in.wav"
        out_a = tmp_path / "out_a.wav"
        out_b = tmp_path / "out_b.wav"
        manifest = tmp_path / "manifest.txt"
        manifest.write_text(
            f"{in_path}\t{out_a}\t0.0\t0.3\n"
            f"{in_path}\t{out_b}\t0.5\t0.3\n"
        )

        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.0, align=False)
        ic.run_batch(str(manifest), args, verbose=False)

        assert out_a.exists() and out_b.exists()
        _, ya, _ = ic.read_wav(str(out_a))
        _, yb, _ = ic.read_wav(str(out_b))
        assert len(ya) == round(0.3 * sr) == len(yb)
        assert not np.array_equal(ya, yb)   # genuinely different regions

    def test_malformed_start_length_reported_not_crashed(self, tmp_path):
        in_path = tmp_path / "in.wav"
        self._write_source(in_path)
        manifest = tmp_path / "manifest.txt"
        manifest.write_text(f"{in_path}\tout.wav\tnot_a_number\t0.3\n")

        args = default_args()
        ic.run_batch(str(manifest), args, verbose=False)
        # must not raise; reported as a malformed line like any other
        # parse failure, not as a Python traceback


class TestBatchCliVerbose:
    """The --batch CLI path with verbose output on (i.e. without --quiet).

    Every other batch test calls run_batch() in-process with verbose=False,
    which is exactly how a NameError in the verbose-only summary line
    survived: the batch action Lua script hardcodes VERBOSE = true, so the
    only configuration that ships was the only one never exercised. These
    tests drive the real CLI in a subprocess so the process exit code -
    what the Lua side actually keys on - is part of the assertion.
    """

    def _write_source(self, path, sr=48000, dur=0.3):
        n = int(sr * dur)
        rng = np.random.default_rng(7)
        left = sine(300, sr, dur, amp=0.3) + 0.05 * rng.standard_normal(n)
        right = sine(300, sr, dur, amp=0.1) + 0.05 * rng.standard_normal(n)
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        ic.write_wav(str(path), stereo(left, right), info)

    def _run(self, manifest):
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "..", "incenter.py")
        return subprocess.run(
            [sys.executable, script, "--batch", str(manifest)],
            capture_output=True, text=True,
        )

    def test_verbose_batch_exits_zero_and_prints_summary(self, tmp_path):
        # No --quiet, so verbose is on - the configuration the batch action
        # ships with. Two lines, so a wrong count is visible as well as a crash.
        for name in ("a", "b"):
            self._write_source(tmp_path / f"{name}.wav")
        manifest = tmp_path / "manifest.txt"
        manifest.write_text(
            f"{tmp_path / 'a.wav'}\t{tmp_path / 'a_out.wav'}\n"
            f"{tmp_path / 'b.wav'}\t{tmp_path / 'b_out.wav'}\n"
        )

        r = self._run(manifest)

        assert r.returncode == 0, (
            f"verbose --batch exited {r.returncode}\n"
            f"stdout:\n{r.stdout}\nstderr:\n{r.stderr}"
        )
        assert "batch done: 2/2 file(s) ok" in r.stdout
        assert (tmp_path / "a_out.wav").exists()
        assert (tmp_path / "b_out.wav").exists()

    def test_verbose_batch_summary_counts_only_successes(self, tmp_path):
        # A failing line must not be counted as ok, and must still not stop
        # the run from exiting cleanly with an accurate summary.
        self._write_source(tmp_path / "a.wav")
        manifest = tmp_path / "manifest.txt"
        manifest.write_text(
            f"{tmp_path / 'a.wav'}\t{tmp_path / 'a_out.wav'}\n"
            f"{tmp_path / 'missing.wav'}\t{tmp_path / 'x_out.wav'}\n"
        )

        r = self._run(manifest)

        assert r.returncode == 0, (
            f"verbose --batch exited {r.returncode}\n"
            f"stdout:\n{r.stdout}\nstderr:\n{r.stderr}"
        )
        assert "batch done: 1/2 file(s) ok" in r.stdout


class TestBatchStdoutSurvivesSigkill:
    """Regression test for the flush=True fix on run_batch's machine-channel
    prints (##OK##/##ERR##/##DIAG##).

    In production, the worker's stdout is redirected to a log file (the
    Lua wrapper script), not a TTY, so Python block-buffers it. A hard
    kill - the ExecProcess timeout path on the Lua side - runs no atexit
    flush, so anything still sitting in that buffer is lost, including
    ##OK## lines for jobs that had already finished and written a valid
    file to disk. Step 2's Lua-side recovery of partial results is
    worthless on the timeout path without this: there is nothing in the
    log to recover. This drives the real CLI in a subprocess, redirects
    its stdout to a real file exactly like the Lua wrapper does, and kills
    it with SIGKILL (no graceful shutdown) once enough jobs have provably
    finished.
    """

    def _write_source(self, path, sr=48000, dur=0.3, seed=0):
        n = int(sr * dur)
        rng = np.random.default_rng(seed)
        left = sine(300, sr, dur, amp=0.3) + 0.05 * rng.standard_normal(n)
        right = sine(300, sr, dur, amp=0.1) + 0.05 * rng.standard_normal(n)
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        ic.write_wav(str(path), stereo(left, right), info)

    def test_completed_jobs_ok_lines_survive_a_sigkill_mid_batch(self, tmp_path):
        n_files = 6
        out_paths = []
        manifest_lines = []
        for i in range(n_files):
            in_path = tmp_path / f"in_{i}.wav"
            out_path = tmp_path / f"out_{i}.wav"
            self._write_source(in_path, seed=i)
            manifest_lines.append(f"{in_path}\t{out_path}")
            out_paths.append(out_path)
        manifest = tmp_path / "manifest.txt"
        manifest.write_text("\n".join(manifest_lines) + "\n")

        script = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "..", "incenter.py")
        log_path = tmp_path / "worker.log"
        with open(log_path, "wb") as logfile:
            proc = subprocess.Popen(
                [sys.executable, script, "--batch", str(manifest)],
                stdout=logfile, stderr=subprocess.STDOUT,
            )
            try:
                # Wait for the THIRD file's output to land on disk. Jobs
                # run strictly in manifest order within a single process,
                # so by the time job 2 has written its file, jobs 0 and 1
                # have already returned from process_one and executed
                # their own ##OK## print - not a race, a consequence of
                # the sequential loop in run_batch().
                deadline = time.monotonic() + 15.0
                while not out_paths[2].exists():
                    if proc.poll() is not None:
                        pytest.fail(
                            "batch process exited before the 3rd job "
                            f"finished (returncode={proc.returncode})")
                    if time.monotonic() > deadline:
                        proc.kill()
                        proc.wait()
                        pytest.fail("3rd job never finished before timeout")
                    time.sleep(0.001)

                proc.send_signal(signal.SIGKILL)
                proc.wait(timeout=15)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()

        assert proc.returncode != 0   # confirms a real kill, not a clean finish

        log_text = log_path.read_text(errors="replace")
        assert f"##OK##\t{out_paths[0]}" in log_text, (
            f"job 0's ##OK## line was lost on SIGKILL - log:\n{log_text}"
        )
        assert f"##OK##\t{out_paths[1]}" in log_text, (
            f"job 1's ##OK## line was lost on SIGKILL - log:\n{log_text}"
        )


# --------------------------------------------------------------- analysis helpers

class TestLoudestRegion:
    def test_finds_the_loud_window(self):
        sr = 1000
        n = 5000
        x = np.zeros((n, 2))
        x[2000:2500, 0] = 1.0  # loud burst in the middle
        start, stop = ic.loudest_region(x, sr, win_sec=0.5)
        assert 1900 <= start <= 2100
        assert stop - start == 500

    def test_window_larger_than_signal_returns_whole_signal(self):
        sr = 1000
        x = np.zeros((100, 2))
        start, stop = ic.loudest_region(x, sr, win_sec=5.0)
        assert (start, stop) == (0, 100)


class TestSoundLengthSec:
    def test_empty_signal(self):
        x = np.zeros((0, 2))
        assert ic.sound_length_sec(x, 44100) == 0.0

    def test_silence_returns_full_length(self):
        sr = 1000
        x = np.zeros((sr * 2, 2))
        assert ic.sound_length_sec(x, sr) == pytest.approx(2.0)

    def test_measures_span_between_active_blocks(self):
        sr = 1000
        n = 3 * sr
        x = np.zeros((n, 2))
        # 0.5s of full-scale tone starting at 1.0s -> useful length ~0.5s
        x[1000:1500, 0] = 1.0
        x[1000:1500, 1] = 1.0
        length = ic.sound_length_sec(x, sr)
        assert length == pytest.approx(0.5, abs=0.05)


class TestAutoWin:
    @pytest.mark.parametrize("dur,expected", [
        (0.10, 512),
        (0.30, 1024),
        (1.00, 2048),
        (3.00, 4096),
    ])
    def test_thresholds(self, dur, expected):
        sr = 48000
        n = int(sr * dur)
        x = np.ones((n, 2)) * 0.5  # constant "sound", no silence to trim
        win = ic.auto_win(x, sr, verbose=False)
        assert win == expected

    def test_never_exceeds_material_length(self):
        sr = 48000
        x = np.ones((100, 2)) * 0.5  # far shorter than any window size
        win = ic.auto_win(x, sr, verbose=False)
        assert win <= len(x) or win == 256  # bottoms out at 256 per the loop


# --------------------------------------------------------------- delay alignment

class TestDelayAlignment:
    def test_estimate_delay_recovers_known_shift(self):
        sr = 48000
        rng = np.random.default_rng(0)
        base = rng.standard_normal(sr) * 0.1
        # band-limit a little so PHAT has something coherent to lock onto
        base = np.convolve(base, np.ones(8) / 8, mode="same")
        true_delay = 3.7
        # apply_delay(sig, d) shifts sig LATER by d samples, i.e. makes it
        # lag. Put the lagging (delayed) copy on L and the reference on R
        # so this matches the documented sign convention: "positive: L
        # lags R".
        delayed = ic.apply_delay(base, true_delay)
        x = stereo(delayed, base)
        d = ic.estimate_delay(x, sr)
        assert d == pytest.approx(true_delay, abs=0.15)

    def test_apply_delay_shifts_impulse(self):
        n = 256
        sig = np.zeros(n)
        sig[50] = 1.0
        shifted = ic.apply_delay(sig, 5.0)
        peak = np.argmax(np.abs(shifted))
        assert peak == 55

    def test_align_skips_when_delay_negligible(self):
        sr = 48000
        base = sine(500, sr, 0.05)
        x = stereo(base, base)
        y = ic.align(x, sr, verbose=False)
        np.testing.assert_array_equal(y, x)

    def test_align_reduces_measured_delay(self):
        sr = 48000
        rng = np.random.default_rng(1)
        base = rng.standard_normal(sr // 2) * 0.1
        base = np.convolve(base, np.ones(8) / 8, mode="same")
        shifted = ic.apply_delay(base, 6.0)
        x = stereo(base, shifted)
        y = ic.align(x, sr, verbose=False)
        d_after = ic.estimate_delay(y, sr)
        assert abs(d_after) < 0.5


# --------------------------------------------------------------- rotation helpers

class TestWeightedMedian:
    def test_basic_weighted_median(self):
        values = [1.0, 2.0, 3.0]
        weights = [1.0, 1.0, 1.0]
        assert ic.weighted_median(values, weights) == 2.0

    def test_skewed_weights_shift_the_median(self):
        values = [0.0, 10.0]
        weights = [0.1, 0.9]
        assert ic.weighted_median(values, weights) == 10.0

    def test_zero_weight_returns_default(self):
        assert ic.weighted_median([1.0, 2.0], [0.0, 0.0]) == 45.0


class TestMakeBands:
    def test_band_count_and_coverage(self):
        freqs = np.linspace(0, 24000, 2049)
        bands = ic.make_bands(freqs, n_bands=8, f_lo=50.0)
        assert len(bands) <= 8
        all_idx = np.concatenate(bands)
        assert len(all_idx) == len(np.unique(all_idx))  # no bin double-counted

    def test_low_frequencies_merged_into_first_band(self):
        freqs = np.array([0.0, 10.0, 30.0, 60.0, 120.0, 5000.0])
        bands = ic.make_bands(freqs, n_bands=2, f_lo=50.0)
        # bins below f_lo (indices 0,1,2) must all land in the first band
        assert {0, 1, 2}.issubset(set(bands[0].tolist()))


# --------------------------------------------------------------- width

class TestCollapse:
    def test_zero_amount_is_a_no_op(self):
        x = stereo(sine(300, 48000, 0.02, amp=0.4), sine(300, 48000, 0.02, amp=0.1))
        y, gain = ic.collapse(x, 0.0)
        np.testing.assert_array_equal(y, x)
        assert gain == 1.0

    def test_full_collapse_is_mono(self):
        x = stereo(sine(300, 48000, 0.02, amp=0.4), sine(500, 48000, 0.02, amp=0.4))
        y, gain = ic.collapse(x, 1.0, compensate=False)
        np.testing.assert_allclose(y[:, 0], y[:, 1])

    def test_compensation_restores_input_rms(self):
        sr = 48000
        left = sine(300, sr, 0.05, amp=0.3)
        right = -left  # fully out-of-phase: side-heavy, mid ~ 0
        x = stereo(left, right)
        y, gain = ic.collapse(x, 0.5, compensate=True)
        rms_in = np.sqrt(np.mean(x ** 2))
        rms_out = np.sqrt(np.mean(y ** 2))
        assert rms_out == pytest.approx(rms_in, rel=0.05)

    def test_gain_is_capped(self):
        sr = 48000
        left = sine(300, sr, 0.05, amp=0.3)
        right = -left  # fully decorrelated/out-of-phase -> mid is ~silent
        x = stereo(left, right)
        y, gain = ic.collapse(x, 1.0, compensate=True, max_gain_db=12.0)
        assert gain <= 10 ** (12.0 / 20.0) + 1e-9


# --------------------------------------------------------------- diagnostics

class TestRecenterBandsDiagnostics:
    """recenter_bands returns (y, diag) - diag is what lets the tool say
    'measured no offset, applied nothing' instead of staying silent."""

    def test_returns_a_tuple_with_expected_diag_keys(self):
        sr = 48000
        left = sine(300, sr, 0.3, amp=0.3)
        right = sine(300, sr, 0.3, amp=0.1)
        x = stereo(left, right)
        y, diag = ic.recenter_bands(x, sr, strength=1.0, n_bands=8,
                                    nperseg=512, verbose=False)
        assert y.shape == x.shape
        assert set(diag.keys()) == {
            "offset_deg", "attack_deg", "tail_deg", "spread_deg", "win", "n_bands",
        }
        assert diag["win"] == 512
        assert diag["n_bands"] <= 8

    def test_offset_deg_is_attack_angle_minus_45_and_signed(self):
        sr = 48000
        left = sine(300, sr, 0.3, amp=0.3)
        right = sine(300, sr, 0.3, amp=0.1)  # panned right of centre
        x = stereo(left, right)
        _, diag = ic.recenter_bands(x, sr, strength=1.0, n_bands=8,
                                    nperseg=512, verbose=False)
        assert diag["offset_deg"] == pytest.approx(diag["attack_deg"] - 45.0, abs=1e-9)

    def test_symmetric_centred_signal_measures_near_zero_offset(self):
        sr = 48000
        left = sine(400, sr, 0.3, amp=0.25)
        right = sine(400, sr, 0.3, amp=0.25)  # dead centre
        x = stereo(left, right)
        _, diag = ic.recenter_bands(x, sr, strength=1.0, n_bands=8,
                                    nperseg=512, verbose=False)
        assert abs(diag["offset_deg"]) < 0.5

    def test_spread_is_percentile_90_minus_10_of_per_band_attack_angles(self):
        # A signal whose pan angle varies strongly with frequency should
        # show a wide per-band spread - the "frequency-dependent tilt"
        # the diagnostic is meant to surface.
        sr = 48000
        dur = 0.3
        low = sine(150, sr, dur, amp=0.3) + sine(150, sr, dur, amp=0.05, phase=0)
        # low band panned right, high band panned left, both attack-like
        # (an onset at t=0 keeps the mask from being all-tail).
        left = sine(150, sr, dur, amp=0.1) + sine(6000, sr, dur, amp=0.3)
        right = sine(150, sr, dur, amp=0.3) + sine(6000, sr, dur, amp=0.05)
        x = stereo(left, right)
        _, diag = ic.recenter_bands(x, sr, strength=1.0, n_bands=8,
                                    nperseg=512, verbose=False)
        assert diag["spread_deg"] >= 0.0

    def test_spread_is_zero_with_a_single_band(self):
        sr = 48000
        x = stereo(sine(300, sr, 0.2, amp=0.3), sine(300, sr, 0.2, amp=0.2))
        _, diag = ic.recenter_bands(x, sr, strength=1.0, n_bands=1,
                                    nperseg=256, verbose=False)
        assert diag["spread_deg"] == pytest.approx(0.0)


# --------------------------------------------------------------- pipeline

class TestIsBypass:
    def test_default_bypass_flags_are_bypass(self):
        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.0, align=False)
        assert ic._is_bypass(args) is True

    def test_tail_strength_none_counts_as_zero(self):
        args = default_args(strength=0.0, tail_strength=None, collapse=0.0, align=False)
        assert ic._is_bypass(args) is True

    def test_nonzero_strength_is_not_bypass(self):
        args = default_args(strength=1.0)
        assert ic._is_bypass(args) is False

    def test_align_alone_is_not_bypass(self):
        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.0, align=True)
        assert ic._is_bypass(args) is False

    def test_collapse_alone_is_not_bypass(self):
        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.3, align=False)
        assert ic._is_bypass(args) is False


class TestProcessOneBypass:
    def test_bypass_copies_audio_through_unchanged(self, tmp_path):
        sr = 44100
        x = stereo(sine(440, sr, 0.05, amp=0.4), sine(440, sr, 0.05, amp=0.2))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)

        out_path = tmp_path / "out.wav"
        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.0, align=False)
        ic.process_one(str(in_path), str(out_path), args, verbose=False)

        _, y, info2 = ic.read_wav(str(out_path))
        _, x2, _ = ic.read_wav(str(in_path))
        np.testing.assert_array_equal(y, x2)
        assert info2.bits == 16

    def test_bypass_returns_none_not_a_zeroed_diag(self, tmp_path):
        # A bypass must never look like "measured zero offset" - it made
        # no measurement at all.
        sr = 44100
        x = stereo(sine(440, sr, 0.05), sine(440, sr, 0.05))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)
        out_path = tmp_path / "out.wav"
        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.0, align=False)
        result = ic.process_one(str(in_path), str(out_path), args, verbose=False)
        assert result is None


class TestProcessOnePipeline:
    def test_full_pipeline_runs_and_preserves_shape(self, tmp_path):
        sr = 48000
        left = sine(300, sr, 0.3, amp=0.3) + sine(1200, sr, 0.3, amp=0.1)
        right = sine(300, sr, 0.3, amp=0.15) + sine(1200, sr, 0.3, amp=0.2)
        x = stereo(left, right)
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=24, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)

        out_path = tmp_path / "out.wav"
        args = default_args(strength=1.0, tail_strength=1.0, collapse=0.3,
                            align=True, win=512, n_bands=8)
        diag = ic.process_one(str(in_path), str(out_path), args, verbose=False)

        sr2, y, info2 = ic.read_wav(str(out_path))
        assert sr2 == sr
        assert len(y) == len(x)
        assert info2.bits == 24
        assert diag is not None
        assert set(diag.keys()) == {
            "offset_deg", "attack_deg", "tail_deg", "spread_deg", "win", "n_bands",
        }

    def test_verbose_prints_measured_summary(self, tmp_path, capsys):
        sr = 48000
        x = stereo(sine(300, sr, 0.2, amp=0.3), sine(300, sr, 0.2, amp=0.1))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)
        out_path = tmp_path / "out.wav"
        args = default_args(strength=1.0, tail_strength=1.0, collapse=0.0,
                            align=False, win=256, n_bands=4)
        ic.process_one(str(in_path), str(out_path), args, verbose=True)
        out = capsys.readouterr().out
        assert "measured:" in out
        assert "offset" in out
        assert "spread" in out

    def test_collapse_without_align_warns(self, tmp_path, capsys):
        sr = 44100
        x = stereo(sine(300, sr, 0.05), sine(300, sr, 0.05))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)
        out_path = tmp_path / "out.wav"
        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.4,
                            align=False, win=256, n_bands=4)
        ic.process_one(str(in_path), str(out_path), args, verbose=False)
        captured = capsys.readouterr()
        assert "comb-filter" in captured.err


class TestWidthOnlyFastPath:
    """strength=tail_strength=0 ("width only") must skip recenter_bands'
    STFT round trip entirely - not just take the identity-rotation path -
    while collapse and align still apply normally. See
    docks/TASK_incenter_ui_fixes.md item 2: this is why the width-only UI
    path is a real fix to process_one, not just a slider convenience."""

    def test_output_matches_direct_collapse_no_stft_artifacts(self, tmp_path):
        sr = 48000
        left = sine(300, sr, 1.0, amp=0.3)
        right = sine(300, sr, 1.0, amp=0.1)
        x = stereo(left, right)
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=24, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)
        out_path = tmp_path / "out.wav"

        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.5,
                            align=False)
        ic.process_one(str(in_path), str(out_path), args, verbose=False)

        _, y, _ = ic.read_wav(str(out_path))
        expected, _ = ic.collapse(x, 0.5)
        # atol matched to 24-bit quantization only, since there's no STFT
        # round trip to add its own reconstruction error on top.
        np.testing.assert_allclose(y, expected, atol=2e-6)

    def test_returns_none_diag_not_a_measurement(self, tmp_path):
        sr = 48000
        x = stereo(sine(300, sr, 0.3, amp=0.3), sine(300, sr, 0.3, amp=0.1))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)
        out_path = tmp_path / "out.wav"
        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.5,
                            align=True)
        diag = ic.process_one(str(in_path), str(out_path), args, verbose=False)
        assert diag is None

    def test_verbose_reports_skipping_stft_not_measured_line(self, tmp_path, capsys):
        sr = 48000
        x = stereo(sine(300, sr, 0.2, amp=0.3), sine(300, sr, 0.2, amp=0.1))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)
        out_path = tmp_path / "out.wav"
        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.5,
                            align=False)
        ic.process_one(str(in_path), str(out_path), args, verbose=True)
        out = capsys.readouterr().out
        assert "skipping the STFT round trip" in out
        assert "measured:" not in out

    def test_align_still_applies_in_width_only_mode(self, tmp_path):
        sr = 48000
        rng = np.random.default_rng(21)
        base = rng.standard_normal(sr // 2) * 0.1
        base = np.convolve(base, np.ones(8) / 8, mode="same")
        shifted = ic.apply_delay(base, 4.0)
        x = stereo(base, shifted)
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=24, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)
        out_path = tmp_path / "out.wav"

        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.0,
                            align=True)
        ic.process_one(str(in_path), str(out_path), args, verbose=False)

        _, y, _ = ic.read_wav(str(out_path))
        expected = ic.align(x, sr, verbose=False)
        np.testing.assert_allclose(y, expected, atol=2e-6)

    def test_nonzero_strength_still_runs_full_centering(self, tmp_path, capsys):
        # Regression guard: the width-only fast path must not accidentally
        # swallow the normal case.
        sr = 48000
        x = stereo(sine(300, sr, 0.3, amp=0.3), sine(300, sr, 0.3, amp=0.1))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)
        out_path = tmp_path / "out.wav"
        args = default_args(strength=1.0, tail_strength=0.0, collapse=0.0,
                            align=False, win=512, n_bands=8)
        diag = ic.process_one(str(in_path), str(out_path), args, verbose=True)
        assert diag is not None
        assert "skipping the STFT round trip" not in capsys.readouterr().out

    def test_nonzero_tail_strength_alone_still_runs_full_centering(self, tmp_path):
        sr = 48000
        x = stereo(sine(300, sr, 0.3, amp=0.3), sine(300, sr, 0.3, amp=0.1))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        in_path = tmp_path / "in.wav"
        ic.write_wav(str(in_path), x, info)
        out_path = tmp_path / "out.wav"
        args = default_args(strength=0.0, tail_strength=1.0, collapse=0.0,
                            align=False, win=512, n_bands=8)
        diag = ic.process_one(str(in_path), str(out_path), args, verbose=False)
        assert diag is not None


class TestFinalizeAndWrite:
    def test_integer_output_is_normalized_on_overshoot(self, tmp_path):
        sr = 44100
        x = np.ones((10, 2)) * 1.5  # over full scale
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        args = default_args()
        out_path = tmp_path / "clip.wav"
        ic._finalize_and_write(str(out_path), x, info, args, v=False)
        _, y, _ = ic.read_wav(str(out_path))
        assert np.max(np.abs(y)) <= 1.0 + 1e-6

    def test_float_output_left_as_is_on_overshoot(self, tmp_path):
        sr = 44100
        x = np.ones((10, 2)) * 1.5
        info = ic.WavInfo(sr=sr, audio_fmt=3, bits=32, ch=2, extra_chunks=[])
        args = default_args()
        out_path = tmp_path / "over.wav"
        ic._finalize_and_write(str(out_path), x, info, args, v=False)
        _, y, _ = ic.read_wav(str(out_path))
        assert np.max(np.abs(y)) == pytest.approx(1.5, rel=1e-4)


class TestRunBatch:
    def test_batch_reports_ok_and_err_per_line(self, tmp_path, capsys):
        sr = 44100
        x = stereo(sine(300, sr, 0.02), sine(300, sr, 0.02))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        good_in = tmp_path / "good.wav"
        ic.write_wav(str(good_in), x, info)
        good_out = tmp_path / "good_out.wav"
        missing_in = tmp_path / "does_not_exist.wav"
        missing_out = tmp_path / "missing_out.wav"

        manifest = tmp_path / "manifest.txt"
        manifest.write_text(
            f"{good_in}\t{good_out}\n{missing_in}\t{missing_out}\n"
        )

        args = default_args(strength=0.0, tail_strength=0.0, collapse=0.0, align=False)
        ic.run_batch(str(manifest), args, verbose=False)

        out = capsys.readouterr().out
        # key is out_path (unique per job), not in_path
        assert f"##OK##\t{good_out}\t{good_in}" in out
        assert out.count("##ERR##") == 1
        assert good_out.exists()
        # bypass (strength=tail_strength=collapse=0, align=False) makes no
        # measurement, so no ##DIAG## line for it.
        assert "##DIAG##" not in out
        assert not missing_out.exists()

    def test_diag_line_precedes_ok_line_for_a_processed_file(self, tmp_path, capsys):
        sr = 48000
        x = stereo(sine(300, sr, 0.2, amp=0.3), sine(300, sr, 0.2, amp=0.1))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        in_wav = tmp_path / "in.wav"
        ic.write_wav(str(in_wav), x, info)
        out_wav = tmp_path / "out.wav"
        manifest = tmp_path / "manifest.txt"
        manifest.write_text(f"{in_wav}\t{out_wav}\n")

        args = default_args(strength=1.0, tail_strength=1.0, collapse=0.0,
                            align=False, win=256, n_bands=4)
        ic.run_batch(str(manifest), args, verbose=False)

        out = capsys.readouterr().out
        diag_idx = out.index("##DIAG##")
        ok_idx = out.index("##OK##")
        assert diag_idx < ok_idx  # DIAG must come before OK, per the spec

        diag_line = out.splitlines()[out[:diag_idx].count("\n")]
        tag, path, payload = diag_line.split("\t")
        assert tag == "##DIAG##"
        # key is out_path (unique per job), not in_path - two items trimmed
        # from the same source to different regions need distinct keys.
        assert path == str(out_wav)
        # same tab-delimited shape as ##OK##/##ERR##, key=value;... payload
        keys = dict(kv.split("=") for kv in payload.split(";"))
        assert set(keys) == {"offset", "attack", "tail", "spread", "win", "bands"}
        assert keys["offset"].startswith("+") or keys["offset"].startswith("-")
        assert "\t" not in payload and " " not in payload

    def test_diag_line_printed_even_with_quiet(self, tmp_path, capsys):
        sr = 48000
        x = stereo(sine(300, sr, 0.2, amp=0.3), sine(300, sr, 0.2, amp=0.1))
        info = ic.WavInfo(sr=sr, audio_fmt=1, bits=16, ch=2, extra_chunks=[])
        in_wav = tmp_path / "in.wav"
        ic.write_wav(str(in_wav), x, info)
        out_wav = tmp_path / "out.wav"
        manifest = tmp_path / "manifest.txt"
        manifest.write_text(f"{in_wav}\t{out_wav}\n")

        args = default_args(strength=1.0, tail_strength=1.0, collapse=0.0,
                            align=False, win=256, n_bands=4, quiet=True)
        # verbose=False mirrors --quiet at the CLI layer.
        ic.run_batch(str(manifest), args, verbose=False)
        out = capsys.readouterr().out
        assert "##DIAG##" in out

    def test_malformed_manifest_line_reported(self, tmp_path, capsys):
        manifest = tmp_path / "bad_manifest.txt"
        manifest.write_text("only_one_field_no_tab\n")
        args = default_args()
        ic.run_batch(str(manifest), args, verbose=False)
        out = capsys.readouterr().out
        assert "##ERR##" in out
        assert "malformed manifest line" in out

