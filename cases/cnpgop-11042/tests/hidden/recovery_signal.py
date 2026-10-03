#!/usr/bin/env python3
"""In-sandbox recovery evaluation: read the live cluster the way the corpus does.

WHY THIS EXISTS (do not replace it with hand-written kubectl probes)
-------------------------------------------------------------------
A case's ground truth is `telemetry/<slug>/signals.json`, confirmed[] entries
recording what each probe reads on the buggy build vs the fixed build. Those
probes are read by `diff_telemetry.recheck_confirmed()` -- the same code that
validates all 83 recorded snapshots -- and gate 3 (`signal_eval.py`) is the
host-side "does the candidate reproduce the fixed side" evaluator.

The obvious shortcut is to re-express each probe as a kubectl one-liner. It
does not work: 32 of the 87 confirmed entries are `log_sig`/`clog_sig` whose
targets are CLASSIFIER LABELS ("panic_previous", "rv_version_mismatch",
"dup_pgdata_volume"), not object fields. Re-deriving them means re-deriving
the classifiers -- a second implementation that drifts from the corpus it is
judging. So instead: snapshot the cluster with `capture_run.py` (portable,
kubectl-only, byte-compatible layout) and hand the snapshot to the corpus's
own reader.

Semantics
---------
  eval <slug> <capture_dir> <out.json>
      Read one snapshot; write the per-probe side for that snapshot. The GT is
      the shipped `hidden/telemetry/<slug>/signals.json` (see SWEOPS_TELEM).

  compare <pre.json> <post.json>
      rc 0  RECOVERED     post is on the fixed side for >=1 probe, never on the
                          buggy side, and at least one of those probes read
                          something OTHER than fixed before the deploy.
      rc 1  NOT_RECOVERED post still reads the buggy side, or no probe moved.
                          Includes VACUOUS (every credited probe already read
                          fixed before the deploy -- nothing was recovered),
                          and DARK (a probe that read off the fixed side before
                          the deploy has NO determinate reading after it --
                          2026-09-22: a probe going silent is not a repair).
      rc 2  nothing evaluable in post (no fix can be credited either way).

Both snapshots must be taken with the same `confirmed[]` order -- they are
index-aligned, which is what makes the pre/post comparison meaningful.
"""
import json
import os
import sys

HID = os.environ.get("SWEOPS_SIGLIB", "/tests/hidden")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HID)
# The shipped GT is hidden/telemetry/<slug>/signals.json (confirmed[] only, no
# recorded snapshots) -- so evaluate() finds no recorded "fixed" variant and
# grades purely candidate-vs-recorded-values, which is what we want here.
os.environ.setdefault("SWEOPS_TELEM", os.path.join(HID, "telemetry"))
import signal_eval as SE  # noqa: E402


def ev(slug, cap, out):
    rows, overall, detail = SE.evaluate(slug, cap)
    rec = {"case": slug, "capture": cap, "verdict": overall, "detail": detail,
           "probes": []}
    for r in rows:
        want = r.get("want") or {}
        wf, wb = SE.norm(want.get("fixed")), SE.norm(want.get("buggy"))
        side = SE.on_side(r.get("judge"), wf, wb, r.get("got"))
        rec["probes"].append({"kind": r.get("kind"), "target": r.get("target"),
                              "field": r.get("field"), "judge": r.get("judge"),
                              "want_fixed": wf, "want_buggy": wb,
                              "got": r.get("got"), "side": side,
                              "verdict": r.get("verdict")})
    with open(out, "w") as fh:
        json.dump(rec, fh, indent=1)
    return rec


def _readable(r):
    """A probe that yielded an actual reading (not 'the artifact was absent')."""
    return r["verdict"] not in ("UNEVALUABLE", "GT_INCONSISTENT")


def pre_state(p_p):
    """rc 0 = there is something to recover, 2 = the cluster already reads fixed.

    Called while the SEEDED buggy operator is still running. If every readable
    probe already sits on the fixed side there is nothing for the agent's
    operator to repair, and any later "recovered" verdict would be vacuous.
    """
    pre = json.load(open(p_p))
    fixed = [r for r in pre["probes"] if r["side"] == "fixed"]
    off = [r for r in pre["probes"] if _readable(r) and r["side"] != "fixed"]
    for r in pre["probes"]:
        print(f"[rec]   pre {str(r['side'] or '-'):6s} "
              f"{r['kind']:14s} {str(r['target'])[:40]:42s} got={r['got']!r}",
              file=sys.stderr)
    if not off:
        print(f"[rec] {len(fixed)} probe(s) already read the fixed side and "
              f"none reads otherwise", file=sys.stderr)
        return 2
    print(f"[rec] pre-deploy: {len(off)} of {len(pre['probes'])} probe(s) "
          f"still off the fixed side ({len(fixed)} already fixed)")
    return 0


def compare(pre_p, post_p):
    pre = json.load(open(pre_p))
    post = json.load(open(post_p))
    a, b = pre["probes"], post["probes"]
    if len(a) != len(b):
        print(f"[rec] probe list changed between captures "
              f"({len(a)} -> {len(b)})", file=sys.stderr)
        return 2
    fixed = [i for i, r in enumerate(b) if r["side"] == "fixed"]
    buggy = [i for i, r in enumerate(b) if r["side"] == "buggy"]
    moved = [i for i in fixed if a[i]["side"] != "fixed"]
    for i in fixed:
        print(f"[rec]   fixed  {b[i]['kind']:14s} {str(b[i]['target'])[:40]:42s}"
              f" pre={a[i]['got']!r} -> post={b[i]['got']!r}"
              f"{'  (MOVED)' if i in moved else '  (already fixed before)'}",
              file=sys.stderr)
    for i in buggy:
        print(f"[rec]   BUGGY  {b[i]['kind']:14s} {str(b[i]['target'])[:40]:42s}"
              f" post={b[i]['got']!r} (want {b[i]['want_fixed']!r})",
              file=sys.stderr)
    if not any(_readable(r) for r in b):
        print("[rec] no probe is readable from the post-deploy snapshot "
              "-- cannot credit a fix", file=sys.stderr)
        return 2
    if buggy:
        print(f"[rec] NOT RECOVERED: {len(buggy)} probe(s) still read the "
              f"buggy side", file=sys.stderr)
        return 1
    # [2026-09-22 用户拍板] 判不出边(side=None)的探针**不许被两个方向都忽略**。
    #   旧行为下它既不进 fixed 也不进 buggy ⇒ 注入前**判得出坏边**、注入后读不出来的
    #   那一条(往往正是故障的**后果探针**)**凭空消失**,REC 照样给绿。
    #   <case> k=1 实证:末轮反馈快照里 app pod 仍是 Pending /
    #   CreateContainerConfigError,而 pod_status 探针读数从 "/(无)" 变成判不出
    #   ⇒ 只凭 event_msg(FailedCreate 消失,因为失败**换了形态**而不是修好)判
    #   RECOVERED。新规则:注入前**读到 buggy 边**的探针,注入后必须判得出边
    #   (落在 fixed);判不出 = 不许给绿。
    #   ★ 只认 pre side == "buggy"(确定判出坏边):注入前就判不出的探针是**两只
    #     相位都不投**的死探针(语料里 recorded 值陈旧,如 <case> 的
    #     pod_status 记的是 0/1/Pending、实测 0/2/Pending),把它算进来等于因为
    #     "仪器坏了"判 agent 没修好 —— 那是案子侧该修的探针,不该让 REC 假红
    #     (用户旧口径:高假阳的门比没有门更坏)。
    off_pre = [i for i, r in enumerate(a) if r["side"] == "buggy"]
    dark = [i for i in off_pre if b[i]["side"] not in ("fixed", "buggy")]
    if dark:
        print(f"[rec] NOT RECOVERED: {len(dark)} probe(s) read the BUGGY side "
              f"before the deploy and have NO determinate reading after it -- a "
              f"probe going silent is not evidence of a repair", file=sys.stderr)
        for i in dark:
            print(f"[rec]   DARK   {b[i]['kind']:14s} {str(b[i]['target'])[:40]:42s}"
                  f" pre={a[i]['got']!r} -> post={b[i]['got']!r} "
                  f"(pre side={a[i]['side'] or '-'}, post side={b[i]['side'] or '-'})",
                  file=sys.stderr)
        return 1
    if not fixed:
        print(f"[rec] NOT RECOVERED: no probe reads the fixed side after the "
              f"deploy ({sum(_readable(r) for r in b)} probe(s) readable)",
              file=sys.stderr)
        return 1
    if not moved:
        print("[rec] VACUOUS: every probe that reads fixed also read fixed "
              "BEFORE the agent's operator was deployed -- nothing was "
              "recovered", file=sys.stderr)
        return 1
    # ★ O-32 丙(2026-09-24):**分母说真话**。
    #   旧写法 `{len(moved)}/{len(b)}` 把**注入前就健康**的探针也算进分母 ⇒
    #   「1 条真移动 + 1 条本来就健康」被写成 `1/2`,判词看着更「半」,其实是
    #   分母错了(实测 <case> `/rec] RECOVERED: 1/2 probe(s) moved`)。分母
    #   应当是**注入前确实读到 buggy 侧**的探针数(`off_pre`,也是 DARK 门与
    #   VACUOUS 门用的同一个集合)。
    #   同时把两类「弱证据」点名(它们**照旧计分**,不改任何判定,只是不许被
    #   混进"真翻面"那一栏冒充):
    #     · (already fixed before):注入前后都判 fixed —— 不是移动,不构成证据;
    #     · 注入前**判不出边**(side=None)而注入后判 fixed:算 moved(现状不改),
    #       但它比"buggy→fixed"弱 —— 仪器此前读不出来,可能只是它自己醒了。
    #   末一条**没有**改成"不算 moved":那会改变 REC 极性(多一批红),用户没拍
    #   过这条口径 ⇒ 只出声、不擅自动判据。存疑留在这里,别静默。
    _from_buggy = [i for i in moved if a[i]["side"] == "buggy"]
    _from_dark = [i for i in moved if a[i]["side"] not in ("buggy", "fixed")]
    _both_fixed = [i for i in fixed if i not in moved]
    if off_pre:
        print(f"[rec] RECOVERED: {len(_from_buggy)}/{len(off_pre)} probe(s) that read "
              f"the buggy side before the deploy now read the fixed side; "
              f"{len(buggy)} still buggy")
    else:
        # 一条注入前读到 buggy 侧的探针都没有(全是"本来就健康"或"注入前就判不出"
        # 的)⇒ 没有可以除的分母。别印 `0/0`(那种分母会被读成"全过"),把实情
        # 直说:这次绿只来自**没读到 buggy 的**那些探针。
        print(f"[rec] RECOVERED: {len(_from_buggy)} probe(s) moved to the fixed side, "
              f"but **no probe read the buggy side before the deploy** "
              f"(no denominator); {len(buggy)} still buggy")
    if _both_fixed:
        print(f"[rec]   ({len(_both_fixed)} probe(s) read the fixed side on BOTH "
              f"sides -- not evidence of a repair, excluded from the denominator)")
    if _from_dark:
        print(f"[rec]   ⚠ {len(_from_dark)} mover(s) had NO determinate reading "
              f"before the deploy -- counted as moved, but weaker evidence than a "
              f"buggy->fixed flip", file=sys.stderr)
    return 0


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "eval":
        ev(sys.argv[2], sys.argv[3], sys.argv[4])
        return 0
    if len(sys.argv) >= 2 and sys.argv[1] == "pre":
        return pre_state(sys.argv[2])
    if len(sys.argv) >= 2 and sys.argv[1] == "compare":
        return compare(sys.argv[2], sys.argv[3])
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main())
