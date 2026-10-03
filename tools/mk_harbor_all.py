#!/usr/bin/env python3
"""mk_harbor_all.py -- emit ONE harbor job config that runs every case in the
hub in a single command.

Why: harbor's JobConfig takes a `tasks:` ARRAY and `n_concurrent_trials` is a
queue depth, so the whole dataset needs no fan-out wrapper script -- harbor
itself schedules them. This replaces the per-case mkjob.py + run_smoke18.sh /
fan_oracle.sh loop for the "run everything" use case.

    tasks: [{path: hub/<slug>/task}, ...]     # every slide of the dataset
    n_concurrent_trials: N                    # harbor's own queue

Per-case output dirs (hub/<slug>/runs/<kind>/out) are a JOB-level mount
(`environment.mounts`), not a per-task one, so a combined run cannot give each
case its own bind source. That is deliberate: the combined config is for
running the published dataset, where each task is self-contained and the agent
writes nothing that has to land back in the repo. Use mkjob.py per case when
you need per-case artifacts (the local oracle/LLM eval loops do).

Usage:
    python3 mk_harbor_all.py                    # -> hub/harbor-all.yaml (oracle)
    python3 mk_harbor_all.py --agent terminus-2 --model gpt-5.6-luna \
            --n-concurrent 2 --out hub/harbor-all-llm.yaml
    python3 mk_harbor_all.py --print-only       # show the resolved config

Then:
    harbor run -c hub/harbor-all.yaml
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

HUB = Path(os.environ.get("SWEOPS_HUB", "hub"))


def task_dirs(only: list[str] | None) -> list[Path]:
    dirs = sorted(d for d in HUB.glob("*/task") if (d / "task.toml").is_file())
    if only:
        want = set(only)
        dirs = [d for d in dirs if d.parent.name in want]
    return dirs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent", default="oracle",
                    help="oracle for the self-check, else a real agent")
    ap.add_argument("--model", default=None)
    ap.add_argument("--n-concurrent", type=int, default=2,
                    help="harbor's queue depth; keep ~2 given the per-env "
                         "2cpu/7g x2 service caps")
    ap.add_argument("--out", default=str(HUB / "harbor-all.yaml"))
    ap.add_argument("--job-name", default=None)
    ap.add_argument("--case", action="append",
                    help="restrict to these slugs (repeatable)")
    ap.add_argument("--print-only", action="store_true")
    a = ap.parse_args()

    dirs = task_dirs(a.case)
    if not dirs:
        sys.exit("[mkharbor] no hub/*/task directories found")

    name = a.job_name or ("sweops-all-smoke" if a.agent == "oracle"
                          else "sweops-all-llm")
    cfg = {
        "job_name": name,
        "jobs_dir": str(HUB / "_all" / "runs"),
        "n_concurrent_trials": a.n_concurrent,
        "agents": [{"name": a.agent} | ({"model_name": a.model} if a.model else {})],
        "tasks": [{"path": str(d)} for d in dirs],
    }
    text = json.dumps(cfg, indent=2) + "\n"

    if a.print_only:
        print(text, end="")
        return 0

    Path(a.out).write_text(text)
    print(f"[mkharbor] {len(dirs)} task(s) -> {a.out}")
    print(f"[mkharbor]   agent      {a.agent}"
          + (f" (model {a.model})" if a.model else ""))
    print(f"[mkharbor]   queue      {a.n_concurrent} concurrent trial(s)")
    print(f"[mkharbor]   jobs_dir   {cfg['jobs_dir']}")
    print(f"[mkharbor] run it:  harbor run -c {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
