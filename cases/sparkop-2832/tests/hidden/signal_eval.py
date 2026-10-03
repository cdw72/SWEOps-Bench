#!/usr/bin/env python3
"""Gate 3: does the candidate run REPRODUCE the fixed side of the case's
recorded signals -- and not the buggy side?

A case's ground truth is `telemetry/<slug>/signals.json`, whose `confirmed[]`
entries each record what a probe reads on the buggy build vs the fixed build
(e.g. log_sig count 6 -> 0). Gate 2 asks "does the cluster recover"; gate 3 asks
the sharper question: "does the patched operator, replayed on a real cluster,
produce the SAME discriminating values the recorded fix produced".

The probe implementations are NOT re-written here. `diff_telemetry.
recheck_confirmed()` already knows how to read all 18 kinds out of a telemetry
directory, and it is the code that validates the 83 recorded snapshots; calling
it means gate 3 can never drift from the corpus it is checking against. The only
addition is the comparison: recheck asks "are the two variants still different",
this asks "is the candidate on the fixed side".

Before judging the candidate, each probe is first checked for GT
self-consistency: the RECORDED fixed snapshot is re-read and compared against
the RECORDED fixed value. If a probe's own snapshot disagrees with its own
recorded value, that probe cannot judge anything -- it is reported as
GT_INCONSISTENT and excluded, rather than silently failing a correct patch.

Inputs (one of):
  --artifacts DIR   a capture_run.py snapshot of the candidate cluster
  --snapshot DIR    any telemetry-style dir (e.g. telemetry/<slug>/fixed) --
                    used to self-test the evaluator without a live cluster

Verdicts, per probe:
  MATCH            candidate reads the recorded fixed value
  BUGGY_SIGNAL     candidate reads the recorded buggy value -> symptom remains
  MISMATCH         readable, but on neither recorded side
  UNEVALUABLE      the snapshot lacks the artifact the probe needs
  GT_INCONSISTENT  the recorded fixed snapshot itself disagrees with the
                   recorded fixed value -> GT defect, patch not blamed

Verdicts, overall:
  SIGNALS_OK / SIGNALS_BUGGY / SIGNALS_MISMATCH / SIGNALS_PARTIAL (some
  unevaluable) / SIGNALS_VACUOUS (nothing evaluable) / SIGNALS_NO_GT
  GT_INCONSISTENT probes are listed under detail.gt_defects either way.

Usage:  python3 signal_eval.py <slug> --artifacts DIR
Out:    <SWEOPS_SIGOUT>/signals-<slug>.json
"""
import argparse
import json
import os
import re
import shutil
import sys
import tempfile
import time
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# Probe-library root: the sandbox sets SWEOPS_SIGLIB (tests/hidden); the reader
# diff_telemetry.py travels alongside this file, so its own dir is the fallback.
sys.path.insert(0, os.environ.get("SWEOPS_SIGLIB", str(_HERE)))
import diff_telemetry as DT  # noqa: E402

# Both roots are overridable so the SAME evaluator can run inside a task
# sandbox (verifier phase), where the ground truth is a copied signals.json
# under tests/hidden/. Defaults are relative to this file.
TELEM = Path(os.environ.get("SWEOPS_TELEM", str(_HERE / "telemetry")))
OUT = Path(os.environ.get("SWEOPS_SIGOUT", str(_HERE / "verify")))

# present-value sentinels: the probe ran but the artifact it needs was missing
# or unusable. "The file was not collected" is not "the signal is absent".
UNREADABLE = ("(manual)", "(log无效)", "(no obj_full)", "(svc无)", "(cr无)",
              "(bad-target)", "(no control-plane ip)", "?", "(parse fail)",
              "(empty)", "(no pods)", "(无)")

NUM = re.compile(r"^-?\d+$")


def norm(v):
    """Recorded values mix ints and strings ("6" vs 6); compare on text."""
    if v is None:
        return ""
    return v.strip() if isinstance(v, str) else str(v)


def is_unreadable(v):
    s = norm(v)
    return s == "" or s in UNREADABLE or s.startswith("(drift")


def reads(want, got):
    """Does `got` read as the recorded value `want`?

    Exact equality covers counts and names. Recorded values for list-shaped
    probes (cr_conditions) hold just the condition of interest while the probe
    returns the whole `a=True;b=False;...` string, so a non-numeric want is also
    accepted as a token of got -- but only for non-numeric wants, otherwise
    "0" would match inside "10".

    Recorded event messages are TRUNCATED at capture time ('create Pod
    vmagent-vmagent-N-N ... invalid: spec.affinity...'), and the truncation
    marker is a literal ellipsis in the value. Treat it as a wildcard and match
    the fragments in order, so a recorded ellipsis does not read as "different
    message" on every live re-check.
    """
    w, g = norm(want), norm(got)
    if not w:
        return False
    if w == g:
        return True
    if NUM.match(w):
        return False
    for sep in ("…", "..."):
        if sep in w:
            frags = [f.strip() for f in w.split(sep) if f.strip()]
            pos = 0
            for f in frags:
                i = g.find(f, pos)
                if i < 0:
                    return False
                pos = i + len(f)
            return True
    return w in g


def on_side(judge, want_f, want_b, got):
    """Which recorded side does `got` land on -- 'fixed', 'buggy', or None?

    `count_zero` is a THRESHOLD judge, not an equality one: it says "the fixed
    build never emits this (0), the buggy build does (any number)". The recorded
    buggy count is just what happened to be observed at capture time (2, 4, 6,
    7 … all appear in the corpus), so a live replay that emits the signature 8
    times is on the BUGGY side -- demanding the literal 6 would fail every live
    re-check and call a plainly-still-broken build a MISMATCH.

    `match_fixed` (the value itself is the point) and `absent` keep equality /
    token semantics from reads().
    """
    want_f, want_b, got = norm(want_f), norm(want_b), norm(got)
    if (judge == "count_zero" and NUM.match(got) and NUM.match(want_f)
            and int(want_f) == 0 and int(got) > 0):
        return "buggy"
    on_f = reads(want_f, got)
    on_b = bool(want_b) and reads(want_b, got)
    # Ask BOTH sides before answering. reads() bottoms out in a SUBSTRING test
    # (`w in g`) so that a recorded message with a "…" still compares equal,
    # and that makes it wrong whenever one recorded value is a prefix of the
    # other -- which is the normal shape of a composite value. <case>'s
    # only probe is `ceph_details`, a `;`-joined health list:
    #   fixed = "MON_DISK_LOW;POOL_NO_REDUNDANCY"
    #   buggy = "MDS_INSUFFICIENT_STANDBY;MON_DISK_LOW;POOL_NO_REDUNDANCY"
    # A cluster reading EXACTLY the buggy value therefore also read as "fixed"
    # (the fixed string is its tail), and the pre-deploy check -- whose whole
    # job is to prove there is something left to repair -- called the seeded
    # fault "already fixed" and exited VACUOUS with a perfectly good fault in
    # front of it (2026-09-13; it also cost the post-deploy compare: the same
    # value would be credited `fixed` no matter which build was running).
    # When both sides read, only an EXACT match may pick one; otherwise this
    # probe cannot discriminate and says so (None) instead of guessing fixed.
    if on_f and not on_b:
        return "fixed"
    if on_b and not on_f:
        return "buggy"
    if on_f and on_b:
        if got == want_f and got != want_b:
            return "fixed"
        if got == want_b and got != want_f:
            return "buggy"
    return None


def read_values(slug, snap_dir, confirmed):
    """Probe readings for one snapshot, with the recorded buggy side alongside.

    recheck_confirmed(case, base, have, confirmed) hardcodes "buggy"/"fixed" in
    its judge math and reads <base>/<variant>/...; lay the recorded buggy corpus
    and the snapshot out under those two names so the untouched production
    evaluator can be reused verbatim.
    """
    tmp = Path(tempfile.mkdtemp(prefix=f"sig-{slug}-"))
    buggy_src = TELEM / slug / "buggy"
    try:
        if buggy_src.is_dir():
            os.symlink(buggy_src, tmp / "buggy")
        else:
            (tmp / "buggy").mkdir()
        os.symlink(Path(snap_dir).resolve(), tmp / "fixed")
        rows, _ = DT.recheck_confirmed(slug, str(tmp), ["buggy", "fixed"],
                                       confirmed)
        return rows
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def evaluate(slug, snap_dir):
    sj = TELEM / slug / "signals.json"
    if not sj.is_file():
        return [], "SIGNALS_NO_GT", {"error": f"no signals.json for {slug}"}
    sig = json.loads(sj.read_text())
    confirmed = sig.get("confirmed") or []
    if not confirmed:
        return [], "SIGNALS_NO_GT", {"error": "confirmed[] is empty"}

    rec_fixed = TELEM / slug / "fixed"
    try:
        gt = read_values(slug, rec_fixed, confirmed) if rec_fixed.is_dir() else None
        cand = (gt if Path(snap_dir).resolve() == rec_fixed.resolve() and gt
                else read_values(slug, snap_dir, confirmed))
    except Exception as e:  # a probe crash must not lose the other probes
        return [], "SIGNALS_EVAL_ERROR", {"error": f"{type(e).__name__}: {e}"}

    rows, defects, n = [], [], {v: 0 for v in
                                ("MATCH", "BUGGY_SIGNAL", "MISMATCH",
                                 "UNEVALUABLE", "GT_INCONSISTENT")}
    for i, (probe, rc) in enumerate(zip(confirmed, cand)):
        vals = probe.get("values") or {}
        want_f, want_b = norm(vals.get("fixed")), norm(vals.get("buggy"))
        got = rc["present"].get("fixed")
        got_b = rc["present"].get("buggy")

        # 1) can the GT be read off its own recorded snapshot?
        #    Order matters twice over:
        #      * a recorded "(无)" is a real value (the `absent` judge records
        #        "nothing here" as the fixed side), so equality is checked
        #        before the unreadable sentinels -- otherwise every absent-judge
        #        probe would look unevaluable.
        #      * drift_* probes recheck as "(drift)" by design: diff_telemetry
        #        computes them live in collect_signals, never from a snapshot.
        #        That is "no snapshot can read this probe", NOT "the GT is
        #        wrong", so it drops to UNEVALUABLE instead of blaming the GT.
        judge = probe.get("judge")
        gt_got = gt[i]["present"].get("fixed") if gt else None
        if gt is None:
            gt_unreadable = True
        elif on_side(judge, want_f, want_b, gt_got) == "fixed":
            gt_unreadable = False          # GT agrees with itself
        elif is_unreadable(gt_got):
            gt_unreadable = True           # probe not snapshot-readable at all
        else:
            gt_unreadable = False          # genuine GT defect, caught below
        gt_defect = (not gt_unreadable) and on_side(judge, want_f, want_b,
                                                    gt_got) != "fixed"

        side = on_side(judge, want_f, want_b, got)
        if gt_defect:
            verdict = "GT_INCONSISTENT"
            why = (f"recorded fixed snapshot reads {gt_got!r}, GT records "
                   f"{want_f!r} -- probe cannot judge")
            defects.append({"kind": probe.get("kind"), "target": probe.get("target"),
                            "field": probe.get("field"),
                            "want": want_f, "recorded_snapshot": norm(gt_got)})
        elif side == "fixed":
            verdict, why = "MATCH", "candidate reproduces the recorded fixed value"
        elif side == "buggy":
            verdict = "BUGGY_SIGNAL"
            why = (f"candidate reads the buggy side {got!r} "
                   f"(fixed side is {want_f!r}) -- symptom still present")
        elif is_unreadable(got):
            verdict = "UNEVALUABLE"
            why = f"probe is not readable from any snapshot: {got!r}"
        else:
            verdict, why = "MISMATCH", (
                f"candidate {got!r} is neither fixed {want_f!r} "
                f"nor buggy {want_b!r}")
        n[verdict] += 1
        rows.append({"kind": probe.get("kind"), "target": probe.get("target"),
                     "field": probe.get("field"), "judge": probe.get("judge"),
                     "want": {"buggy": want_b, "fixed": want_f},
                     "got": got, "buggy_snapshot": got_b,
                     "verdict": verdict, "why": why,
                     "gt_buggy_stale": bool(want_b and norm(got_b) != want_b
                                            and not is_unreadable(got_b))})

    if n["BUGGY_SIGNAL"]:
        overall = "SIGNALS_BUGGY"
    elif n["MISMATCH"]:
        overall = "SIGNALS_MISMATCH"
    elif n["MATCH"] and not n["UNEVALUABLE"]:
        overall = "SIGNALS_OK"
    elif n["MATCH"]:
        overall = "SIGNALS_PARTIAL"
    else:
        overall = "SIGNALS_VACUOUS"
    detail = {"n": n, "n_confirmed": len(confirmed),
              "recorded_variants": sig.get("variants"),
              "gt_defects": defects,
              "gt_buggy_stale": [r["target"] for r in rows if r["gt_buggy_stale"]]}
    return rows, overall, detail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("slug")
    ap.add_argument("--artifacts", default=None,
                    help="capture_run.py output dir (candidate cluster snapshot)")
    ap.add_argument("--snapshot", default=None,
                    help="evaluate an existing telemetry-style dir instead "
                         "(offline self-test, e.g. telemetry/<slug>/fixed)")
    ap.add_argument("--no-write", action="store_true")
    a = ap.parse_args()
    if not (a.artifacts or a.snapshot):
        sys.exit("[sig] need --artifacts or --snapshot")
    if a.artifacts and not Path(a.artifacts).is_dir():
        sys.exit(f"[sig] artifacts dir not found: {a.artifacts}")
    src = a.artifacts or a.snapshot
    rows, overall, detail = evaluate(a.slug, src)
    rec = {"case": a.slug, "source": src, "mode": "artifacts" if a.artifacts
           else "snapshot", "verdict": overall, "detail": detail,
           "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "probes": rows}
    if not a.no_write:
        vd = OUT
        vd.mkdir(parents=True, exist_ok=True)
        (vd / f"signals-{a.slug}.json").write_text(json.dumps(rec, indent=1))
    print(f"[sig] {a.slug}: {overall}  {detail.get('n', detail)}")
    for r in rows:
        mark = {"MATCH": "ok  ", "BUGGY_SIGNAL": "BUG ", "MISMATCH": "DIFF",
                "UNEVALUABLE": "n/a ", "GT_INCONSISTENT": "GT! "}[r["verdict"]]
        print(f"  {mark} {r['kind']:14s} {str(r['target'])[:42]:44s} "
              f"want={r['want']['fixed']!r} got={r['got']!r}")
    for d in detail.get("gt_defects", []):
        print(f"  GT defect: {d['kind']} {d['target']} field={d['field']} "
              f"GT={d['want']!r} snapshot={d['recorded_snapshot']!r}")
    return 0 if overall == "SIGNALS_OK" else 1


if __name__ == "__main__":
    sys.exit(main())
