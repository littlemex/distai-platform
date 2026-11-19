"""Black-box tests for score.py, derived from the interface contract only.

Run with the standard library alone:

    python3 -m unittest discover -s examples/inference/_shared/scorer -p 'test_*.py'

Every test runs score.py as a subprocess with the documented CLI:

    score.py --records PATH --planned-requests INT --gpu-count INT
             --ttft-ms FLOAT --tpot-or-gap-ms FLOAT --out PATH

and reads only the documented output JSON keys. Percentile assertions are
written so that any standard quantile method (nearest-rank, linear
interpolation, numpy's default) passes: either the distribution has one
distinct value, or the assertion brackets the result between the two order
statistics every method lands between.

Per-request timing fields. The contract says goodput_per_gpu's interval
spans "from the first scheduled send time to the last response's
completion time", but does not name the per-record fields score.py reads
those times from. Every fixture record therefore carries the same instant
under each plausible name (TIME_FIELDS below), all mutually consistent:
actual send == scheduled send, and completion == send + ttft + sum(itls)
== send + latency. An implementation that reads any one of them, or derives
completion from ttft and itls, sees the same numbers. If the contract later
names the fields, narrow TIME_FIELDS to them.
"""

import json
import math
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCORE_PY = os.path.join(HERE, "score.py")

REQUIRED_KEYS = {
    "planned_requests",
    "successful_requests",
    "failed_requests",
    "no_tokens_generated",
    "joint_attainment_share",
    "goodput_per_gpu",
    "ttft_ms",
    "longest_gap_ms",
}
PERCENTILE_KEYS = {"p50", "p90", "p99"}

# Names under which each fixture record carries its send and completion
# instants (seconds). See the module docstring.
SEND_FIELDS = ("scheduled_send_time", "send_time", "start_time")
COMPLETION_FIELDS = ("completion_time", "end_time", "finish_time")


def rec(send, ttft, itls, success=True):
    """One per-request record in the shape the contract describes.

    ttft and itls are in seconds; send is an absolute instant in seconds.
    """
    itls = list(itls)
    latency = ttft + sum(itls)
    output_len = len(itls) + 1 if success else 0
    r = {
        "ttft": ttft,
        "itls": itls,
        "success": success,
        "output_len": output_len,
        "generated_text": "x" * output_len,
        "latency": latency,
        "error": "" if success else "synthetic failure",
    }
    for f in SEND_FIELDS:
        r[f] = send
    for f in COMPLETION_FIELDS:
        r[f] = send + latency
    return r


class ScoreTestBase(unittest.TestCase):
    def setUp(self):
        self.assertTrue(
            os.path.isfile(SCORE_PY),
            f"score.py not found at {SCORE_PY} (interface contract path "
            "examples/inference/_shared/scorer/score.py)",
        )
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def run_score(self, records_text, planned, gpus=1, ttft_ms=1000.0, gap_ms=200.0):
        """Run score.py; returns (CompletedProcess, parsed output or None)."""
        records_path = os.path.join(self.tmp, "records.json")
        out_path = os.path.join(self.tmp, "summary.json")
        with open(records_path, "w", encoding="utf-8") as f:
            f.write(records_text)
        proc = subprocess.run(
            [
                sys.executable,
                SCORE_PY,
                "--records", records_path,
                "--planned-requests", str(planned),
                "--gpu-count", str(gpus),
                "--ttft-ms", str(ttft_ms),
                "--tpot-or-gap-ms", str(gap_ms),
                "--out", out_path,
            ],
            capture_output=True,
            text=True,
            timeout=120,
        )
        out = None
        if proc.returncode == 0 and os.path.isfile(out_path):
            with open(out_path, encoding="utf-8") as f:
                out = json.load(f)
        return proc, out

    def score(self, records, planned, **kw):
        proc, out = self.run_score(json.dumps(records), planned, **kw)
        self.assertEqual(
            proc.returncode, 0,
            f"score.py exited {proc.returncode} on a well-formed input\n"
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        self.assertIsNotNone(out, "score.py exited 0 but wrote no --out file")
        missing = REQUIRED_KEYS - set(out)
        self.assertFalse(missing, f"output JSON is missing keys: {sorted(missing)}")
        for dist in ("ttft_ms", "longest_gap_ms"):
            self.assertIsInstance(out[dist], dict, f"{dist} must be an object")
            m = PERCENTILE_KEYS - set(out[dist])
            self.assertFalse(m, f"{dist} is missing {sorted(m)}")
        return out

    def assertPercentilesAll(self, dist, value, msg=""):
        for k in sorted(PERCENTILE_KEYS):
            self.assertIsNotNone(dist[k], f"{k} is null {msg}")
            self.assertAlmostEqual(dist[k], value, places=6, msg=f"{k} {msg}")

    def assertBetween(self, value, lo, hi, msg=""):
        self.assertIsNotNone(value, msg)
        self.assertGreaterEqual(value, lo - 1e-9, msg)
        self.assertLessEqual(value, hi + 1e-9, msg)


class TestLongestGap(ScoreTestBase):
    """(a) longest_gap_ms is max(itls) * 1000 per request."""

    def test_single_request_longest_gap_is_max_not_mean(self):
        # mean(itls) = 0.1, max(itls) = 0.5: only max * 1000 gives 500.
        out = self.score([rec(0.0, 0.2, [0.05, 0.05, 0.5, 0.05, 0.05, 0.1])], planned=1, gap_ms=10000)
        self.assertPercentilesAll(out["longest_gap_ms"], 500.0, "(single request, max(itls)=0.5 s)")
        self.assertPercentilesAll(out["ttft_ms"], 200.0, "(single request, ttft=0.2 s)")

    def test_mixed_batch(self):
        # Longest gaps (ms), sorted: 30, 60, 90, 120, 900.
        records = [
            rec(0.0, 0.10, [0.01, 0.03, 0.02]),        # 30
            rec(0.5, 0.20, [0.06]),                    # 60
            rec(1.0, 0.30, [0.09, 0.01, 0.01, 0.01]),  # 90
            rec(1.5, 0.40, [0.02, 0.12]),              # 120
            rec(2.0, 0.50, [0.01, 0.90, 0.01]),        # 900
        ]
        out = self.score(records, planned=5, gap_ms=10000)
        g = out["longest_gap_ms"]
        # Odd n: every common method puts p50 on the middle order statistic.
        self.assertAlmostEqual(g["p50"], 90.0, places=6)
        self.assertBetween(g["p90"], 120.0, 900.0, "p90 must lie between the 4th and 5th order statistics")
        self.assertBetween(g["p99"], 120.0, 900.0, "p99 must lie between the 4th and 5th order statistics")
        self.assertGreater(g["p99"], 800.0, "p99 of [30,60,90,120,900] is near 900 under any method")
        self.assertLessEqual(g["p50"], g["p90"])
        self.assertLessEqual(g["p90"], g["p99"])
        t = out["ttft_ms"]
        self.assertAlmostEqual(t["p50"], 300.0, places=6)
        self.assertBetween(t["p99"], 400.0, 500.0)
        self.assertEqual(out["successful_requests"], 5)
        self.assertEqual(out["failed_requests"], 0)
        self.assertEqual(out["no_tokens_generated"], 0)
        self.assertEqual(out["planned_requests"], 5)

    def test_joint_slo_uses_longest_gap_and_ttft_together(self):
        # SLO: ttft <= 250 ms AND longest gap <= 100 ms.
        records = [
            rec(0.0, 0.10, [0.05, 0.05]),   # attains
            rec(1.0, 0.20, [0.05, 0.15]),   # gap 150 > 100: fails (mean gap 100 would pass)
            rec(2.0, 0.30, [0.01]),         # ttft 300 > 250: fails
            rec(3.0, 0.25, [0.10]),         # boundary: ttft 250, gap 100 (<=): attains
        ]
        out = self.score(records, planned=4, ttft_ms=250, gap_ms=100)
        self.assertAlmostEqual(out["joint_attainment_share"], 0.5, places=9)


class TestNoTokensGenerated(ScoreTestBase):
    """(b) an empty itls list goes to no_tokens_generated, not into the gap distribution."""

    def test_empty_itls_counted_separately(self):
        records = [
            rec(0.0, 0.10, [0.10, 0.10]),  # gap 100
            rec(1.0, 0.10, [0.10]),        # gap 100
            rec(2.0, 0.10, []),            # no inter-token gap at all
        ]
        out = self.score(records, planned=3, gap_ms=10000)
        self.assertEqual(out["no_tokens_generated"], 1)
        # Must not crash and must not count it as a gap; the next test uses
        # a fixture where a 0 ms entry would visibly move p50.
        self.assertPercentilesAll(out["longest_gap_ms"], 100.0, "(empty itls must not enter as 0)")

    def test_empty_itls_not_zero_in_distribution(self):
        records = [rec(0.0, 0.1, [0.2])] + [rec(1.0 + i, 0.1, []) for i in range(4)]
        out = self.score(records, planned=5, gap_ms=10000)
        self.assertEqual(out["no_tokens_generated"], 4)
        # With four 0 ms entries, p50 would be 0; it must stay 200.
        self.assertPercentilesAll(out["longest_gap_ms"], 200.0, "(empty itls must not enter as 0)")

    def test_only_empty_itls_does_not_crash(self):
        out = self.score([rec(0.0, 0.1, []), rec(1.0, 0.1, [])], planned=2)
        self.assertEqual(out["no_tokens_generated"], 2)
        for k in PERCENTILE_KEYS:
            v = out["longest_gap_ms"][k]
            self.assertTrue(
                v is None or (isinstance(v, float) and math.isnan(v)),
                f"longest_gap_ms.{k} with no gaps at all must be null (or NaN), got {v!r}, not a fabricated 0",
            )


class TestFailedRequests(ScoreTestBase):
    """(c) success: false is counted in failed_requests and excluded elsewhere."""

    def test_failed_excluded_from_numerator_and_distributions(self):
        records = [
            rec(0.0, 0.10, [0.05]),                      # attains
            rec(1.0, 0.10, [0.05]),                      # attains
            rec(2.0, 0.10, [0.05], success=False),       # would attain, but failed
            rec(3.0, 50.0, [9.0, 9.0], success=False),   # huge, failed
        ]
        out = self.score(records, planned=4, ttft_ms=1000, gap_ms=200)
        self.assertEqual(out["failed_requests"], 2)
        self.assertEqual(out["successful_requests"], 2)
        # Numerator 2 (not 3), denominator 4 (planned).
        self.assertAlmostEqual(out["joint_attainment_share"], 0.5, places=9)
        # The 50 s ttft and 9 s gap must not reach any percentile.
        self.assertPercentilesAll(out["ttft_ms"], 100.0, "(failed records must be excluded)")
        self.assertPercentilesAll(out["longest_gap_ms"], 50.0, "(failed records must be excluded)")

    def test_all_failed(self):
        records = [rec(float(i), 0.1, [0.05], success=False) for i in range(3)]
        out = self.score(records, planned=3)
        self.assertEqual(out["failed_requests"], 3)
        self.assertEqual(out["successful_requests"], 0)
        self.assertEqual(out["joint_attainment_share"], 0.0)


class TestPlannedDenominator(ScoreTestBase):
    """(d) the attainment denominator is --planned-requests, not len(records)."""

    def test_denominator_is_planned_requests(self):
        records = [
            rec(0.0, 0.1, [0.05]),   # attains
            rec(1.0, 0.1, [0.05]),   # attains
            rec(2.0, 5.0, [0.05]),   # ttft fails
            rec(3.0, 0.1, [0.90]),   # gap fails
        ]
        out = self.score(records, planned=10, ttft_ms=1000, gap_ms=200)
        self.assertEqual(out["planned_requests"], 10)
        # 2 / 10 = 0.2; 2 / len(records) would be 0.5.
        self.assertAlmostEqual(out["joint_attainment_share"], 0.2, places=9)
        self.assertNotAlmostEqual(out["joint_attainment_share"], 0.5, places=6)


class TestGoodputDrain(ScoreTestBase):
    """(e) goodput_per_gpu's interval runs to the last completion, including drain."""

    def test_interval_includes_drain(self):
        base = 1000.0
        # Sends at base+0..3. Each of the first three completes 0.5 s after
        # its send; the last one streams 69 tokens at 0.1 s each after a
        # 0.1 s ttft, so it completes at base + 3 + 7.0 = base + 10.
        records = [
            rec(base + 0.0, 0.1, [0.1, 0.1, 0.1, 0.1]),
            rec(base + 1.0, 0.1, [0.1, 0.1, 0.1, 0.1]),
            rec(base + 2.0, 0.1, [0.1, 0.1, 0.1, 0.1]),
            rec(base + 3.0, 0.1, [0.1] * 69),
        ]
        # Sanity of the fixture itself.
        self.assertAlmostEqual(records[3]["completion_time"], base + 10.0, places=9)
        out = self.score(records, planned=4, gpus=2, ttft_ms=1000, gap_ms=200)
        self.assertAlmostEqual(out["joint_attainment_share"], 1.0, places=9)
        # Drain-inclusive: 4 / (2 * (base+10 - base)) = 0.2.
        # Send window only: 4 / (2 * 3) = 0.667. Send window plus the first
        # responses only: 4 / (2 * 3.5) = 0.571.
        self.assertAlmostEqual(out["goodput_per_gpu"], 0.2, places=6)

    def test_goodput_counts_only_jointly_attaining(self):
        base = 50.0
        records = [
            rec(base + 0.0, 0.1, [0.1]),   # attains
            rec(base + 1.0, 3.0, [0.1]),   # ttft fails; completes at base + 4.1
            rec(base + 2.0, 0.1, [0.1]),   # attains
        ]
        out = self.score(records, planned=3, gpus=1, ttft_ms=1000, gap_ms=200)
        # 2 attaining / (1 GPU * 4.1 s). The non-attaining request still
        # bounds the interval (it is the last response to finish).
        self.assertAlmostEqual(out["goodput_per_gpu"], 2.0 / 4.1, places=6)

    def test_goodput_divides_by_gpu_count(self):
        records = [rec(0.0, 0.1, [0.1]), rec(1.0, 0.1, [0.1])]  # interval 0 .. 1.2
        one = self.score(records, planned=2, gpus=1)["goodput_per_gpu"]
        eight = self.score(records, planned=2, gpus=8)["goodput_per_gpu"]
        self.assertAlmostEqual(one, 2.0 / 1.2, places=6)
        self.assertAlmostEqual(eight, one / 8.0, places=9)


class TestMalformedInput(ScoreTestBase):
    """(f) malformed input exits 1 with one stderr line, never a traceback."""

    def assertCleanFailure(self, text, what):
        proc, _ = self.run_score(text, planned=1)
        self.assertEqual(proc.returncode, 1, f"{what}: expected exit 1, got {proc.returncode}\nstderr:\n{proc.stderr}")
        self.assertNotIn("Traceback", proc.stderr, f"{what}: stderr contains a Python traceback")
        lines = [ln for ln in proc.stderr.splitlines() if ln.strip()]
        self.assertEqual(len(lines), 1, f"{what}: expected exactly one stderr line, got {len(lines)}:\n{proc.stderr}")
        self.assertFalse(
            os.path.exists(os.path.join(self.tmp, "summary.json")),
            f"{what}: a summary must not be written for an invalid input",
        )

    def test_truncated_json(self):
        good = json.dumps([rec(0.0, 0.1, [0.1]), rec(1.0, 0.1, [0.1])])
        self.assertCleanFailure(good[: len(good) // 2], "truncated JSON")

    def test_not_json(self):
        self.assertCleanFailure("this is not json\n", "non-JSON text")

    def test_empty_file(self):
        self.assertCleanFailure("", "empty file")

    def test_record_missing_required_field(self):
        r = rec(0.0, 0.1, [0.1])
        del r["itls"]
        self.assertCleanFailure(json.dumps([r]), "record without itls")

    def test_wrong_type_for_itls(self):
        r = rec(0.0, 0.1, [0.1])
        r["itls"] = "0.1,0.2"
        self.assertCleanFailure(json.dumps([r]), "itls is a string, not a list")


if __name__ == "__main__":
    unittest.main()
