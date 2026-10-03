#!/usr/bin/env python3
"""Portable telemetry capture for a bridge (kind) cluster.

`collect_telemetry.capture()` is welded to the acto flow: it derives the
kubeconfig from `$HOME/.kube/kind-acto-<ns>-cluster-0`, resolves the node IP
from a container named `acto-<ns>-cluster-0-control-plane`, and exits the whole
process when its precheck fails. The resolution bridge owns its own cluster and
kubeconfig path, so gate 3 (signals) needs the same artifact layout without the
acto plumbing.

The layout produced here is byte-compatible with what `diff_telemetry.py`'s
evaluator reads, which is the whole point: `signal_eval.py` can then hand a
candidate capture to `recheck_confirmed()` -- the same code that validates the
83 recorded telemetry snapshots -- instead of a second, drifting
reimplementation of 18 probe kinds.

Read against a live cluster only: no writes, no deletes.

Usage:  python3 capture_run.py --kubeconfig K --out DIR [--label candidate]
Out:    DIR/{pods,sts,svc,pvc,deploy,secrets}.txt  restarts.txt  pods.json
        container_logs/  previous_logs/  cr.txt  cr_full/*.yaml
        obj_full/*.yaml  rbac/*.yaml  operator.log  events.txt  meta.json
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

SYS_NS_L = ("kube-system", "kube-public", "local-path-storage",
            "sweops-observability")
# pods named *operator*/*controller*/*manager* in these namespaces are NOT the
# operator under test: `kubectl -A` sorts by namespace and kube-system's
# kube-controller-manager / cert-manager sort before most business namespaces.
# 38 of 83 recorded variants were poisoned this way on 2026-09-01 (and 579 /
# <case> on 2026-09-09), so the filter is reproduced verbatim here.
SYS_NS = ("kube-system", "kube-public", "kube-federation",
          "local-path-storage", "sweops-observability", "cert-manager")


class Cap:
    def __init__(self, kubeconfig, out):
        self.k = ["kubectl", "--kubeconfig", str(kubeconfig)]
        self.out = Path(out)
        self.log = []

    def run(self, args, timeout=60):
        r = subprocess.run(self.k + args, capture_output=True, text=True,
                           timeout=timeout)
        return r.stdout or "", r

    def w(self, rel, text):
        p = self.out / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def note(self, *a):
        msg = " ".join(str(x) for x in a)
        self.log.append(msg)
        print("[cap]", msg, flush=True)

    # ---------------------------------------------------------------- precheck
    def precheck(self):
        """Business pods present, none mid-transition.

        Recorded, not enforced: the recovery predicate has already judged the
        run, and a capture that is skipped because a pod is Terminating leaves
        gate 3 with nothing to evaluate. The flags go into meta.json so a
        vacuous signal verdict can be traced back to an unstable snapshot.
        """
        r, _ = self.run(["get", "pods", "-A", "--no-headers"])
        biz, trans, names = 0, 0, []
        for line in (r or "").splitlines():
            cols = line.split()
            if len(cols) < 4:
                continue
            ns_, status = cols[0], cols[3]
            if ns_ in SYS_NS_L:
                continue
            biz += 1
            if status in ("Pending", "ContainerCreating", "Terminating"):
                trans += 1
                names.append(f"{ns_}/{cols[1]}({status})")
        return {"business_pods": biz, "transitional": trans,
                "transitional_names": names[:12]}

    # ---------------------------------------------------------------- capture
    def capture(self, label):
        self.out.mkdir(parents=True, exist_ok=True)
        pre = self.precheck()
        if pre["business_pods"] == 0:
            self.note("WARNING business pod=0 -- snapshot likely vacuous")
        if pre["transitional"]:
            self.note(f"WARNING {pre['transitional']} pod(s) mid-transition: "
                      + "; ".join(pre["transitional_names"][:6]))

        for res in ("pods", "sts", "svc", "pvc", "deploy", "secrets"):
            o, _ = self.run(["get", res, "-A", "-o", "wide"])
            self.w(f"{res}.txt", o or "(empty)\n")

        o, _ = self.run(["get", "pods", "-A", "-o", "jsonpath="
                         "{range .items[*]}{.metadata.namespace}{' '}{.metadata.name}{' '}"
                         "{range .status.containerStatuses[*]}{.name}={.restartCount} "
                         "{end}{'|'}{range .status.initContainerStatuses[*]}"
                         "{.name}={.restartCount} {end}{'\\n'}{end}"])
        self.w("restarts.txt", o or "(no pods)\n")

        o, _ = self.run(["get", "pods", "-A", "-o", "json"])
        self.w("pods.json", (o or "{}")[:1500000])

        # current container logs, business namespaces only
        pods, _ = self.run(["get", "pods", "-A", "-o", "jsonpath="
                            "{range .items[*]}{.metadata.namespace}{' '}"
                            "{.metadata.name}{' '}"
                            "{range .status.containerStatuses[*]}{.name} {end}"
                            "{'\\n'}{end}"])
        for line in pods.splitlines():
            parts = line.split()
            if len(parts) < 3 or parts[0] in SYS_NS_L:
                continue
            ns_, pod = parts[0], parts[1]
            for cont in parts[2:]:
                r = subprocess.run(self.k + ["logs", pod, "-n", ns_, "-c", cont,
                                             "--tail=300"],
                                   capture_output=True, text=True, timeout=120)
                if r.stdout.strip():
                    self.w(f"container_logs/{pod}-{cont}.log", r.stdout[-60000:])
        self.w("container_logs/README",
               "(business-ns containers --tail=300; system ns excluded)\n")

        # previous logs = crash scenes (restartCount>0 containers)
        n_prev = 0
        for line in pods.splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            ns_, pod = parts[0], parts[1]
            for cont in parts[2:]:
                r = subprocess.run(self.k + ["logs", pod, "-n", ns_, "-c", cont,
                                             "--previous", "--tail=300"],
                                   capture_output=True, text=True, timeout=120)
                if r.returncode == 0 and r.stdout.strip():
                    self.w(f"previous_logs/{pod}-{cont}.log", r.stdout[-100000:])
                    n_prev += 1
        if n_prev == 0:
            self.w("previous_logs/README", "(no container had previous logs)\n")

        # CRs, one yaml per CRD (diff_telemetry reads cr_full/<crd>.yaml)
        crds, _ = self.run(["get", "crds", "-o",
                            "jsonpath={.items[*].metadata.name}"])
        cr_lines = []
        for crd in (crds or "").split():
            o, _ = self.run(["get", crd, "-A", "-o", "jsonpath="
                             "{range .items[*]}{.metadata.name} "
                             "state={.status.state} phase={.status.phase} "
                             "ready={.status.ready} replicas={.status.replicas}"
                             "{'\\n'}{end}"])
            if o.strip():
                cr_lines.append(f"{crd}: {o.strip()}")
                full, _ = self.run(["get", crd, "-A", "-o", "yaml"])
                self.w(f"cr_full/{crd}.yaml", (full or "(empty)\n")[:150000])
        self.w("cr.txt", "\n".join(cr_lines) or "(no CR)\n")

        for res in ("sts", "svc", "deploy"):
            o, _ = self.run(["get", res, "-A", "-o", "yaml"])
            self.w(f"obj_full/{res}.yaml", (o or "(empty)\n")[:400000])

        for res in ("roles", "rolebindings", "clusterroles", "clusterrolebindings"):
            o, _ = self.run(["get", res, "-A", "-o", "yaml"])
            self.w(f"rbac/{res}.yaml", (o or "(empty)\n")[:400000])

        # operator log: first non-system pod whose name matches, same order of
        # iteration as the recorded corpus (namespace-sorted by kubectl -A)
        op_lines, _ = self.run(["get", "pods", "-A", "-o", "jsonpath="
                                "{range .items[*]}{.metadata.namespace}{' '}"
                                "{.metadata.name}{' '}"
                                "{.spec.containers[0].name}{'\\n'}{end}"])
        op = None
        for line in (op_lines or "").splitlines():
            if any(k in line.lower() for k in ("operator", "controller", "manager")):
                parts = line.split()
                if len(parts) < 3 or parts[0] in SYS_NS:
                    continue
                op = parts
                break
        if op:
            ns_, pod, cont = op
            r = subprocess.run(self.k + ["logs", pod, "-n", ns_, "-c", cont,
                                         "--tail=2000"],
                               capture_output=True, text=True, timeout=120)
            self.w("operator.log", (r.stdout or r.stderr)[-200000:])
            op_id = f"{ns_}/{pod}({cont})"
        else:
            self.w("operator.log", "(no operator pod found)\n")
            op_id = None

        o, _ = self.run(["get", "events", "-A", "--sort-by=.lastTimestamp"])
        self.w("events.txt", o or "(no events)\n")

        self.w("meta.json", json.dumps({
            "label": label,
            "captured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "operator_pod": op_id,
            "precheck": pre,
            "notes": self.log}, indent=1))
        self.note(f"captured to {self.out} (operator={op_id}, "
                  f"prev_logs={n_prev})")
        return pre


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kubeconfig", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--label", default="candidate")
    a = ap.parse_args()
    if not Path(a.kubeconfig).is_file():
        sys.exit(f"[cap] kubeconfig not found: {a.kubeconfig}")
    Cap(a.kubeconfig, a.out).capture(a.label)
    return 0


if __name__ == "__main__":
    sys.exit(main())
