"""Tests for ppg_hr — per-second heart rate from the WHOOP 5.0 v26 optical PPG buffer (issue #156).

Run: python3 -m unittest test_ppg_hr   (stdlib only; no bleak, no capture files — the frames below are
real consecutive v26 records captured from a worn WHOOP 5, with their v18 ground-truth HR.)
"""
import math
import sqlite3
import unittest

import ppg_hr
import decode_features


def _sine(bpm, secs=8, fs=24, amp=1000):
    f = bpm / 60.0
    return [int(amp * math.sin(2 * math.pi * f * (i / fs))) for i in range(secs * fs)]


# 8 consecutive 1-second v26 records (real, worn WHOOP 5), and the v18 HR at the same timestamps.
RUN_HEX = [
    "aa015000010035412f1a80c14a840104ad266a3d4a030023170300cbfdfefebd00a201ac01b0018b0147027f028202ad029402b6026202acffb6fde8fe050033015801090143016f0108028058583c6006000100b42e33e2",
    "aa015000010035412f1a80c24a840105ad266a3d4a030046330300e1011b024b0219024f0045fe69fe81ffb90049014d01f20059019c01c301d3011c02030227028a00c5fd87fda3fe7cff0004663c6006000100d7e94c45",
    "aa015000010035412f1a80c34a840106ad266a3d4a0300944303005f00760088001a0154018701ad01ce01ae017e0040fda2fceefddafed1ff55008aff19002400b3009900e200ea004c0100c7683c600600010017312292",
    "aa015000010035412f1a80c44a840107ad266a3d4a03007f49030072fce1fbc7fc6ffe7bffb5ff45ffa4ffd6ff5c007900e200ee0085003ffd98fb42fceffd9cffc2ff88ff98ff04005900004b3d3c6006000100b7543f9a",
    "aa015000010035412f1a80c54a840108ad266a3d4a03009a300300e100f000f1000bfe2cfb9dfb79fd73ffd2ff84fff3febaff0a007500b1001101c30080fee1fa19fb71fd07ff2800c9ff80c6393c600600010073634bbd",
    "aa015000010035412f1a80c64a840109ad266a3d4a03009c160300f8ff9600fb004f017d016501bbfee5fa7afb8afd2dff2e001800f2ff4e00af003d017901db01b3018000b0fc4afcccfd00af383c6006000100f7f0a233",
    "aa015000010035412f1a80c74a84010aad266a3d4a03007a0c0300cc00ea00c500fe00dd01ef0154029602bb026502e8ff79fd1dfef2ff36019e016c010a01b901de010602210234025502808c683c600600010068fb4f96",
    "aa015000010035412f1a80c84a84010bad266a3d4a0300da2c030071ffc7fda8fe150019011e01ee00ca003e019001bb010d02fb012202a900f4fd90fdc4fe4d009200e7008300bf00520100b9283c60060001002c8133fa",
]
RUN = [bytes.fromhex(h) for h in RUN_HEX]
V18_HR = [103, 102, 101, 100, 99, 100, 100, 101]   # measured HR at the same 8 timestamps


class EstimateHrTests(unittest.TestCase):
    def test_recovers_synthetic_rate(self):
        for bpm in (48, 60, 72, 100):
            est = ppg_hr.estimate_hr(_sine(bpm))
            self.assertIsNotNone(est, f"no estimate for {bpm} bpm")
            self.assertAlmostEqual(est[0], bpm, delta=4, msg=f"got {est[0]} for {bpm}")

    def test_picks_fundamental_not_subharmonic(self):
        # A pure sine autocorrelates just as strongly at 2x the period (half HR); the estimator must
        # return the fundamental (~100), never ~50.
        est = ppg_hr.estimate_hr(_sine(100))
        self.assertGreater(est[0], 85)

    def test_rejects_flat_signal(self):
        self.assertIsNone(ppg_hr.estimate_hr([512] * 192))

    def test_rejects_too_short(self):
        self.assertIsNone(ppg_hr.estimate_hr(_sine(60, secs=2)))


class V26RecordTests(unittest.TestCase):
    def test_parses_real_v26(self):
        rec = ppg_hr.v26_record(RUN[0])
        self.assertIsNotNone(rec)
        unix, channel, samples = rec
        self.assertEqual(len(samples), 24)
        self.assertEqual(unix, 1780919556)
        self.assertTrue(1 <= channel <= 26)

    def test_rejects_non_v26(self):
        # A 4.0 GET_BATTERY frame is not a v26 record.
        import whoop_frame as wf
        self.assertIsNone(ppg_hr.v26_record(wf.build_command_frame(wf.CMD_GET_BATTERY_LEVEL)))


class HrSeriesTests(unittest.TestCase):
    def test_matches_v18_ground_truth(self):
        records = [ppg_hr.v26_record(f) for f in RUN]
        series = ppg_hr.hr_series(records)
        self.assertGreaterEqual(len(series), 4)        # most of the 8 seconds resolve
        v18 = dict(zip([r[0] for r in records], V18_HR))
        errs = [abs(bpm - v18[t]) for t, bpm, _ in series if t in v18]
        median = sorted(errs)[len(errs) // 2]
        self.assertLess(median, 8.0, f"PPG-HR median error {median} bpm vs v18")


class DerivePpgHrTests(unittest.TestCase):
    def _db_with_ppg(self):
        con = sqlite3.connect(":memory:")
        decode_features.apply_schema(con)
        for f in RUN:
            unix, ch, samples = ppg_hr.v26_record(f)
            for i, v in enumerate(samples):
                con.execute("INSERT OR IGNORE INTO feat_ppg(device_id,unix,sample_idx,channel,value) "
                            "VALUES(1,?,?,?,?)", (unix, i, ch, v))
        con.commit()
        return con

    def test_fills_feat_second_ppg_hr(self):
        con = self._db_with_ppg()
        n = ppg_hr.derive_ppg_hr(con, 1)
        self.assertGreaterEqual(n, 4)
        rows = con.execute("SELECT ppg_hr FROM feat_second WHERE ppg_hr IS NOT NULL").fetchall()
        self.assertGreaterEqual(len(rows), 4)
        self.assertTrue(all(80 <= r[0] <= 120 for r in rows), "ppg_hr out of expected band")

    def test_idempotent(self):
        con = self._db_with_ppg()
        n1 = ppg_hr.derive_ppg_hr(con, 1)
        before = con.execute("SELECT COUNT(*) FROM feat_second").fetchone()[0]
        n2 = ppg_hr.derive_ppg_hr(con, 1)
        after = con.execute("SELECT COUNT(*) FROM feat_second").fetchone()[0]
        self.assertEqual(n1, n2)
        self.assertEqual(before, after)

    def test_never_overwrites_measured_hr(self):
        # A pre-existing v18 row with a measured hr must keep it; ppg_hr is a separate column.
        con = self._db_with_ppg()
        t = 1780919556
        con.execute("UPDATE feat_second SET hr=101 WHERE unix=?", (t,))
        con.execute("INSERT OR IGNORE INTO feat_second(device_id,unix,hr) VALUES(1,?,101)", (t,))
        con.commit()
        ppg_hr.derive_ppg_hr(con, 1)
        hr = con.execute("SELECT hr FROM feat_second WHERE unix=?", (t,)).fetchone()[0]
        self.assertEqual(hr, 101)


if __name__ == "__main__":
    unittest.main()
