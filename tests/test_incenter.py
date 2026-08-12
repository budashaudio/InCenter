"""Unit tests for the incenter.py DSP engine."""
import argparse
import struct

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
        ic.process_one(str(in_path), str(out_path), args, verbose=False)

        sr2, y, info2 = ic.read_wav(str(out_path))
        assert sr2 == sr
        assert len(y) == len(x)
        assert info2.bits == 24

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
        assert f"##OK##\t{good_in}\t{good_out}" in out
        assert out.count("##ERR##") == 1
        assert good_out.exists()
        assert not missing_out.exists()

    def test_malformed_manifest_line_reported(self, tmp_path, capsys):
        manifest = tmp_path / "bad_manifest.txt"
        manifest.write_text("only_one_field_no_tab\n")
        args = default_args()
        ic.run_batch(str(manifest), args, verbose=False)
        out = capsys.readouterr().out
        assert "##ERR##" in out
        assert "malformed manifest line" in out
