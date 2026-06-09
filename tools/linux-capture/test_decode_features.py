"""Tests for decode_features — schema, mapping, upserts, orchestrator.

Run: python3 -m unittest test_decode_features -v   (stdlib only; no bleak, no Swift).
"""
import json
import sqlite3
import unittest

import decode_features as df


def _conn():
    c = sqlite3.connect(":memory:")
    df.apply_schema(c)
    return c


class SchemaTests(unittest.TestCase):
    def test_creates_four_feature_tables(self):
        c = _conn()
        names = {r[0] for r in c.execute(
            "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
        self.assertTrue({"feat_second", "feat_rr", "feat_ppg", "feat_event"} <= names)

    def test_schema_is_idempotent(self):
        c = _conn()
        df.apply_schema(c)  # second apply must not raise
        self.assertTrue(True)


class RrStatsTests(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(df.rr_stats([]), (0, None, None))

    def test_single_interval_no_rmssd(self):
        n, mean, rmssd = df.rr_stats([600])
        self.assertEqual((n, mean), (1, 600.0))
        self.assertIsNone(rmssd)

    def test_mean_and_rmssd(self):
        # diffs: [10, -10] -> rmssd = sqrt((100+100)/2) = 10
        n, mean, rmssd = df.rr_stats([600, 610, 600])
        self.assertEqual(n, 3)
        self.assertAlmostEqual(mean, 603.3333, places=3)
        self.assertAlmostEqual(rmssd, 10.0, places=6)

    def test_drops_nonpositive(self):
        self.assertEqual(df.rr_stats([0, -5, 600]), (1, 600.0, None))


def _rec(inner_type, parsed, unix=1000, version=24, crc_ok=True, device_id=1):
    return {"device_id": device_id, "unix": unix, "inner_type": inner_type,
            "version": version, "crc_ok": crc_ok, "parsed": parsed}


class FeatureToRowsTests(unittest.TestCase):
    def test_historical_scalars(self):
        rec = _rec(47, {"heart_rate": 95, "rr_intervals": [600, 610],
                        "gravity_x": 0.1, "gravity_y": 0.2, "gravity_z": 0.9,
                        "spo2_red": 1234, "spo2_ir": 5678, "skin_temp_raw": 700,
                        "resp_rate_raw": 42})
        out = df.feature_to_rows(rec)
        s = out["second"]
        self.assertEqual((s["hr"], s["gx"], s["rr_count"], s["record_version"]), (95, 0.1, 2, 24))
        self.assertEqual(s["spo2_red"], 1234)
        # Skin temp: raw AS6221 register passes through; °C is its native raw/128 (700/128 = 5.46875).
        self.assertEqual(s["skin_temp_raw"], 700)
        self.assertAlmostEqual(s["skin_temp_c"], 5.46875)
        self.assertEqual(len(out["rr"]), 2)
        self.assertEqual(out["rr"][1], {"unix": 1000, "idx": 1, "rr_ms": 610})

    def test_skin_temp_absent_is_null(self):
        s = df.feature_to_rows(_rec(47, {"heart_rate": 95})).get("second")
        self.assertIsNone(s["skin_temp_raw"])
        self.assertIsNone(s["skin_temp_c"])

    def test_hr_zero_becomes_null(self):
        out = df.feature_to_rows(_rec(47, {"heart_rate": 0}))
        self.assertIsNone(out["second"]["hr"])

    def test_v26_ppg_rows(self):
        rec = _rec(47, {"ppg_waveform": [10, -20, 30], "ppg_channel": 65}, version=26)
        out = df.feature_to_rows(rec)
        self.assertEqual(len(out["ppg"]), 3)
        self.assertEqual(out["ppg"][0], {"unix": 1000, "sample_idx": 0, "channel": 65, "value": 10})

    def test_event_named(self):
        rec = _rec(48, {"event": "WRIST_ON", "event_timestamp": 1000, "extra": 7}, unix=None)
        out = df.feature_to_rows(rec)
        self.assertEqual(out["event"]["kind"], "WRIST_ON")
        self.assertIsNone(out["event"]["event_num"])
        self.assertEqual(out["event"]["unix"], 1000)
        self.assertEqual(json.loads(out["event"]["payload_json"]), {"extra": 7})

    def test_event_numeric(self):
        out = df.feature_to_rows(_rec(48, {"event": 123, "event_timestamp": 1000}, unix=None))
        self.assertEqual(out["event"]["kind"], "123")
        self.assertEqual(out["event"]["event_num"], 123)

    def test_crc_invalid_skipped(self):
        out = df.feature_to_rows(_rec(47, {"heart_rate": 95}, crc_ok=False))
        self.assertEqual(out, {"second": None, "rr": [], "ppg": [], "event": None})

    def test_no_unix_non_event_skipped(self):
        out = df.feature_to_rows(_rec(47, {"heart_rate": 95}, unix=None))
        self.assertIsNone(out["second"])

    def test_metadata_type_skipped(self):
        out = df.feature_to_rows(_rec(49, {"meta_type": 2}))
        self.assertEqual(out, {"second": None, "rr": [], "ppg": [], "event": None})


class ApplyRowsTests(unittest.TestCase):
    def test_inserts_all_tables(self):
        c = _conn()
        mapped = [
            df.feature_to_rows(_rec(47, {"heart_rate": 95, "rr_intervals": [600, 610]})),
            df.feature_to_rows(_rec(47, {"ppg_waveform": [1, 2], "ppg_channel": 65}, unix=1001, version=26)),
            df.feature_to_rows(_rec(48, {"event": "WRIST_ON", "event_timestamp": 1002}, unix=None)),
        ]
        df.apply_rows(c, 1, mapped)
        self.assertEqual(c.execute("SELECT hr FROM feat_second WHERE unix=1000").fetchone()[0], 95)
        self.assertEqual(c.execute("SELECT COUNT(*) FROM feat_rr").fetchone()[0], 2)
        self.assertEqual(c.execute("SELECT COUNT(*) FROM feat_ppg").fetchone()[0], 2)
        self.assertEqual(c.execute("SELECT kind FROM feat_event").fetchone()[0], "WRIST_ON")

    def test_idempotent(self):
        c = _conn()
        mapped = [df.feature_to_rows(_rec(47, {"heart_rate": 95, "rr_intervals": [600]}))]
        df.apply_rows(c, 1, mapped)
        df.apply_rows(c, 1, mapped)  # second time changes nothing
        self.assertEqual(c.execute("SELECT COUNT(*) FROM feat_second").fetchone()[0], 1)
        self.assertEqual(c.execute("SELECT COUNT(*) FROM feat_rr").fetchone()[0], 1)

    def test_coalesce_merges_partial_seconds(self):
        c = _conn()
        # scalar-only second, then ppg-only at SAME unix must not clobber hr.
        df.apply_rows(c, 1, [df.feature_to_rows(_rec(47, {"heart_rate": 88}, unix=1000))])
        df.apply_rows(c, 1, [df.feature_to_rows(_rec(47, {"gravity_x": 0.5}, unix=1000, version=18))])
        row = c.execute("SELECT hr, gx FROM feat_second WHERE unix=1000").fetchone()
        self.assertEqual(row[0], 88)     # preserved
        self.assertEqual(row[1], 0.5)    # merged in


def _decoded(fields, crcOK=True, family="whoop5"):
    return {"family": family, "char": "x", "ts_ms": 0, "hr": None,
            "frame": {"crcOK": crcOK, "seq": 1, "fields": fields}}


def _fld(name, value, cat):
    return {"name": name, "value": value, "cat": cat, "off": 0}


class NormalizeTests(unittest.TestCase):
    # src frame row shape from WhoopDB.frames_after: (id, hex, char, recv_ms, unix, hr, inner_type)
    def test_flattens_fields_dropping_envelope_and_raw(self):
        raw = _decoded([
            _fld("SOF", "0xAA", "frame"),
            _fld("heart_rate", 95, "hr"),
            _fld("gravity_x", 0.5, "accel"),
            _fld("unmapped optical (PPG/SpO2/skin-temp)", "[63 bytes]", "unknown"),
            _fld("hist_version", 18, "meta"),
        ])
        src = (5, "aa00", "fd4b0005", 1234, 1700000000, 95, 47)
        rec = df.normalize_decode_record(raw, src, device_id=1)
        self.assertEqual(rec["parsed"], {"heart_rate": 95, "gravity_x": 0.5, "hist_version": 18})
        self.assertEqual(rec["device_id"], 1)
        self.assertEqual(rec["unix"], 1700000000)
        self.assertEqual(rec["inner_type"], 47)
        self.assertEqual(rec["version"], 18)
        self.assertTrue(rec["crc_ok"])

    def test_crcOK_false(self):
        raw = _decoded([_fld("heart_rate", 90, "hr")], crcOK=False)
        src = (1, "aa", "c", 0, 100, None, 47)
        self.assertFalse(df.normalize_decode_record(raw, src, 1)["crc_ok"])

    def test_whoop4_version_defaults_to_24(self):
        raw = _decoded([_fld("heart_rate", 110, "hr")], family="whoop4")  # no hist_version field
        src = (1, "aa", "c", 0, 100, 110, 47)
        self.assertEqual(df.normalize_decode_record(raw, src, 1)["version"], 24)

    def test_unix_prefers_decoded_field_over_source_frame(self):
        # v26 frames have NULL unix in the frames row, but the decoder emits a unix field.
        raw = _decoded([_fld("unix", 1700000900, "time"),
                        _fld("ppg_waveform", [1, 2, 3], "ppg"),
                        _fld("hist_version", 26, "meta")])
        src = (9, "aa", "fd4b0005", 0, None, None, 47)   # source-frame unix is None
        rec = df.normalize_decode_record(raw, src, 1)
        self.assertEqual(rec["unix"], 1700000900)

    def test_unix_falls_back_to_source_when_decoder_lacks_it(self):
        raw = _decoded([_fld("event", "X", "event")])    # no unix field
        src = (1, "aa", "c", 0, 555, None, 48)
        self.assertEqual(df.normalize_decode_record(raw, src, 1)["unix"], 555)

    def test_missing_frame_is_empty_parsed_crc_true(self):
        src = (1, "aa", "c", 0, 100, None, 47)
        rec = df.normalize_decode_record({}, src, 1)
        self.assertEqual(rec["parsed"], {})
        self.assertTrue(rec["crc_ok"])
        self.assertIsNone(rec["version"])


def _dec_obj(fields, family="whoop4", crcOK=True):
    """A whoop-decode --json object stub (real shape: values live in frame.fields)."""
    return {"family": family, "char": "x", "ts_ms": 0, "hr": None,
            "frame": {"crcOK": crcOK, "seq": 1, "fields": fields}}


class _FakeDB:
    """Stand-in for WhoopDB: in-memory conn with the feature schema + the methods decode_new uses."""
    def __init__(self, frames):
        self.db = _conn()
        self._frames = frames     # (id, hex, char, recv_ms, unix, hr, inner_type)
        self._state = {}

    def state(self, did):
        return dict(self._state)

    def set_state(self, did, k, v):
        self._state[k] = v

    def frames_after(self, did, after_id):
        return [f for f in self._frames if f[0] > after_id]


class DecodeNewTests(unittest.TestCase):
    def _frames(self):
        return [
            (1, "aa", "6108", 10, 1000, 95, 47),
            (2, "bb", "6108", 11, 1001, 96, 47),
            (3, "cc", "6108", 12, None, None, 49),   # non-data inner_type -> skipped
        ]

    def _decoder(self, records):
        # one decoded object per input frame, in order (real fields-list shape)
        return [
            _dec_obj([_fld("heart_rate", 95, "hr")]),
            _dec_obj([_fld("heart_rate", 96, "hr")]),
            _dec_obj([_fld("meta_type", 3, "meta")]),
        ]

    def test_decodes_and_advances_cursor(self):
        fdb = _FakeDB(self._frames())
        res = df.decode_new(fdb, 1, decode_fn=self._decoder)
        self.assertEqual(res["frames"], 3)
        self.assertEqual(res["skipped"], 1)              # the inner_type-49 frame
        self.assertEqual(fdb.db.execute("SELECT COUNT(*) FROM feat_second").fetchone()[0], 2)
        self.assertEqual(fdb.state(1)["last_decoded_frame_id"], "3")

    def test_incremental_second_run_is_noop(self):
        fdb = _FakeDB(self._frames())
        df.decode_new(fdb, 1, decode_fn=self._decoder)
        res2 = df.decode_new(fdb, 1, decode_fn=self._decoder)
        self.assertEqual(res2["frames"], 0)              # cursor past all frames

    def test_full_redecodes_from_zero(self):
        fdb = _FakeDB(self._frames())
        df.decode_new(fdb, 1, decode_fn=self._decoder)
        res = df.decode_new(fdb, 1, full=True, decode_fn=self._decoder)
        self.assertEqual(res["frames"], 3)               # full ignores the cursor

    def test_decoder_count_mismatch_raises(self):
        fdb = _FakeDB(self._frames())   # 3 frames
        short = lambda records: [_dec_obj([_fld("heart_rate", 95, "hr")])]  # returns only 1
        with self.assertRaises(RuntimeError):
            df.decode_new(fdb, 1, decode_fn=short)
        # cursor must NOT have advanced
        self.assertNotIn("last_decoded_frame_id", fdb.state(1))


class RunWhoopDecodeTests(unittest.TestCase):
    def setUp(self):
        self._orig_run = df.subprocess.run

    def tearDown(self):
        df.subprocess.run = self._orig_run

    def _fake_run(self, returncode, stdout, stderr=""):
        class _R:
            pass
        r = _R()
        r.returncode, r.stdout, r.stderr = returncode, stdout, stderr
        df.subprocess.run = lambda *a, **k: r

    def test_parses_list_output(self):
        self._fake_run(0, '[{"family": "whoop4"}]')
        out = df.run_whoop_decode([{"hex": "aa", "char": "c", "ts_ms": 0, "hr": None}], binary="/x")
        self.assertEqual(out, [{"family": "whoop4"}])

    def test_dict_output_uses_frames_key(self):
        self._fake_run(0, '{"frames": [{"a": 1}]}')
        self.assertEqual(df.run_whoop_decode([{"hex": "aa"}], binary="/x"), [{"a": 1}])

    def test_nonzero_exit_raises(self):
        self._fake_run(2, "", "boom")
        with self.assertRaises(RuntimeError):
            df.run_whoop_decode([{"hex": "aa"}], binary="/x")


class FindWhoopDecodeTests(unittest.TestCase):
    def test_env_override_when_file_exists(self):
        import os, tempfile
        fd, p = tempfile.mkstemp()
        os.close(fd)
        self.addCleanup(os.remove, p)
        old = os.environ.get("WHOOP_DECODE")
        os.environ["WHOOP_DECODE"] = p
        try:
            self.assertEqual(df.find_whoop_decode(), p)
        finally:
            if old is None:
                os.environ.pop("WHOOP_DECODE", None)
            else:
                os.environ["WHOOP_DECODE"] = old

    def test_not_found_raises(self):
        import os
        old = os.environ.pop("WHOOP_DECODE", None)
        orig_exists, orig_which = df.os.path.exists, df.shutil.which
        df.os.path.exists = lambda p: False
        df.shutil.which = lambda n: None
        try:
            with self.assertRaises(FileNotFoundError):
                df.find_whoop_decode()
        finally:
            df.os.path.exists, df.shutil.which = orig_exists, orig_which
            if old is not None:
                os.environ["WHOOP_DECODE"] = old
