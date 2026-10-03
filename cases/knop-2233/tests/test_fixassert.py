#!/usr/bin/env python3
"""Source-fix floor judge for no_reg cases (hub contract).

In-sandbox reward must reflect that the agent actually REPAIRED the root cause,
not merely diagnosed it (a diagnosis-only trial otherwise scores 1.0 with the
operator still crashing). There is no offline *_test.go for no_reg cases, so we
grade the agent's emitted fix.diff statically: it must be non-empty AND contain
a real code change (added OR removed code line) inside a hunk touching the GT
root-cause file. Deep "does the cluster recover" validation runs off-platform
(host rebuild bridge); this is the honest in-sandbox floor.
"""
import os
import re
import pytest

FIX = os.environ.get("SWEOPS_FIX_PATH", "/sweops_out/fix.diff")
GT_FILE = "pkg/reconciler/common/transformers.go"          # root-cause file the fix must touch
CASE = "knop-2233"
RELAX = os.environ.get("SWEOPS_FIX_RELAX", "") == "anyfile"


def _norm(p):
    p = (p or "").strip().split("\t", 1)[0].strip()
    if not p or p == "/dev/null":
        return p
    p = re.sub(r"^(a|b)/", "", p)                 # git-style a/ b/ prefixes
    p = re.sub(r"^/operator-src-clean/", "", p)   # real-agent diff -ru old tree
    p = re.sub(r"^/operator-src/", "", p)         # real-agent diff -ru new tree
    return p.strip("/")


def _is_code(body):
    b = body.strip()
    if not b or len(b) < 3:
        return False
    if b.startswith("//") or b.startswith("/*") or b.startswith("*") \
       or b.startswith("#") or b.startswith("<!--") \
       or b.startswith(chr(34) * 3) or b.startswith(chr(39) * 3) \
       or b.startswith("--"):
        return False
    # a real code line carries an identifier / structure, not only punctuation
    return bool(re.search(r"[A-Za-z_]", b))


def _per_file(diff_text):
    """Parse a unified diff into {relpath: {code, delta}}.

    Tolerant of both git style (diff --git a/x b/x + ---/+++ a/b headers) and
    `diff -ruN /operator-src-clean/... /operator-src/...` (bare ---/+++ paths,
    no per-file separator). A file section is re-keyed on each ---/+++ header;
    every + or - body line under the current path counts toward delta, and
    toward code when it is a substantive (non-comment/whitespace) code line.
    """
    files = {}
    cur = None
    for raw in diff_text.splitlines():
        if raw.startswith("diff ") or raw.startswith("Index:"):
            # git/file-rename separator: register any operand paths so a rename
            # or deletion-only op (no +/- body) is still "touched"
            for tok in re.split(r"\s+", raw)[1:]:
                if tok.startswith("a/") or tok.startswith("b/"):
                    p = _norm(tok)
                    files.setdefault(p, {"code": 0, "delta": 0})
            cur = None
            continue
        if raw.startswith("+++ ") or raw.startswith("--- "):
            p = _norm(raw[4:])
            if p and p != "/dev/null":
                cur = p
                files.setdefault(p, {"code": 0, "delta": 0})
            continue
        if cur and len(raw) >= 1 and raw[0] in "+-" \
           and not raw.startswith("+++") and not raw.startswith("---"):
            body = raw[1:]
            files[cur]["delta"] += 1
            if _is_code(body):
                files[cur]["code"] += 1
    return files


def test_source_fix_floor():
    """fix.diff must exist, be non-empty, and edit code in the GT file.

    RELAX mode (SWEOPS_FIX_RELAX=anyfile, re-run from test.sh ONLY after the
    behavioural axis proved this very tree heals the fault, _RC=0): the GT
    file pin is dropped -- an equivalent fix landed in a different file is
    still a fix, and the floor's actual job (stop diagnosis-only / ops-only
    runs from scoring) is already discharged by "non-empty real code change
    somewhere" + the recovery proof. The floor stays strict on its own.
    """
    if not os.path.exists(FIX):
        pytest.fail(f"[sweops] {FIX} was not produced (agent made no source "
                    f"repair / did not emit fix.diff)")
    raw = open(FIX, encoding="utf-8", errors="replace").read()
    if not raw.strip():
        pytest.fail(f"[sweops] {FIX} is empty -- no source repair")
    files = _per_file(raw)
    if not files:
        pytest.fail("[sweops] fix.diff parses to no file changes")
    if RELAX:
        if any(st["code"] > 0 for st in files.values()):
            touched = [p for p, st in files.items() if st["code"] > 0]
            print(f"[sweops] fix floor (relaxed, recovery-verified): real "
                  f"code change in {sorted(touched)}")
            return
        pytest.fail("[sweops] relaxed floor: no substantive code change in "
                    "ANY file (comments/whitespace-only diff)")
    hit = [p for p in files if p == GT_FILE or p.endswith("/" + GT_FILE)
           or GT_FILE.endswith("/" + p)]
    if not hit:
        pytest.fail(f"[sweops] fix.diff does not touch the root-cause file "
                    f"{GT_FILE!r}; changed: {sorted(files)}")
    st = files[hit[0]]
    if st["delta"] == 0:
        pytest.fail(f"[sweops] {GT_FILE} hunk(s) have no +/- body lines "
                    f"(metadata-only/rename)")
    if st["code"] == 0:
        pytest.fail(f"[sweops] changes to {GT_FILE} are only comments/"
                    f"whitespace/blank -- no code edit")
    print(f"[sweops] fix floor OK: {GT_FILE} delta={st['delta']} "
          f"code={st['code']}")
