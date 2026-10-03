#!/usr/bin/env bash
# [judge-v2] content-salted repack tag; restart accounting scoped to the current
# ReplicaSet. Stamped so poll metrics can layer judge-v1 rows apart from v2.
# In-sandbox RECOVERY judge (deploy + heal), driven by hidden/recovery.json.
#
# The task tells the agent the cluster is read-only, so the graded verifier is
# the only thing allowed to touch it. It answers the question the host bridge
# used to answer: does the AGENT'S SOURCE actually repair the fault once it is
# deployed?
#
#   1. build the agent's /operator-src with the family's own build recipe
#   2. repack the seed's buggy-operator image tar with the new binary (there is
#      no docker daemon in here, so a python helper appends a layer)
#   3. ctr images import into every k3s containerd the seed used (all of them
#      on a multi-node env -- a worker's store is its own)
#   4. roll the operator Deployment onto the new tag
#   5. ACTIVITY PRE-CONDITION: the operator must come up and stay up, no crash
#      loop. A tree that "fixes" the fault by dying makes the symptom vanish
#      while being strictly worse -- the fault_verify vacuous-pass family.
#   6. is the fault actually gone? Two ways to ask, chosen by the case config:
#
#        signals mode (default, every case that has a recorded ground truth)
#          run capture_run.py on the live cluster and hand the snapshot to the
#          corpus's OWN reader (diff_telemetry.recheck_confirmed via
#          signal_eval), i.e. the same code that validates the recorded
#          telemetry -- instead of a second, drifting reimplementation of the
#          probes. 32 of the confirmed discriminators are log signatures whose
#          targets are CLASSIFIER LABELS, not object fields; re-deriving those
#          by hand would mean re-deriving the classifiers.
#
#        probes mode (fallback, explicit kubectl argv in recovery.json)
#
#      Either way the reading is taken BEFORE the deploy too: a cluster that
#      already reads "fixed" makes the recovery claim vacuous (same failure
#      family as the fault_verify MISSes).
#
# rc=0 iff 1-6 all hold. rc=0 is never awarded for "the fault is gone because
# nothing runs any more".
set -uo pipefail
HID=/tests/hidden
PY=/opt/sweops-venv/bin/python
[ -x "$PY" ] || PY=python3
# the corpus reader + a pure-python yaml (diff_telemetry imports it lazily for
# the drift_* probes) travel in tests/hidden/
export PYTHONPATH="$HID:$HID/pyshim${PYTHONPATH:+:$PYTHONPATH}"
export SWEOPS_SIGLIB="$HID"
export SWEOPS_TELEM="$HID/telemetry"
CFG="$HID/recovery.json"
[ -f "$CFG" ] || { echo "[recovery] no recovery.json -- N/A" >&2; exit 0; }

WORK=/tmp/rec
rm -rf "$WORK"; mkdir -p "$WORK"
SRC=/operator-src
[ -f "$SRC/go.mod" ] || { echo "[recovery] no source tree at $SRC" >&2; exit 2; }
KUBECONFIG="${KUBECONFIG:-/kube/config}"
KCTL=(kubectl --kubeconfig "$KUBECONFIG")
# ★ 2026-09-20:**环境根本连不上 ⇒ 退出码 3**,而不是让它一路失败成"普通 rc=1"。
#   真案 <case> k=1(2026-09-20 00:54):k3s 容器死了,判官在**集群已消失之后**
#   才跑,于是
#       Unable to connect to the server: dial tcp: lookup k3s on 127.0.0.11:53 …
#       [recovery] operator Deployment vm/operator not found in the seeded cluster
#   ⇒ 六轴里 DEP=1 / REC=1 —— 而**账本上看不出这是环境事故**,只像"agent 没修好"。
#   那一场 agent 其实把根因那行守卫改对了(RCA/FIX/REG 三轴全过)。
#   3 是**独立的出口**:reward 仍是 0(没验证通过),但下游分得出
#   "没验"与"验了没过"—— 本仓最忌的就是把这两件事记成一个数。
if ! "${KCTL[@]}" get ns >/dev/null 2>&1; then
  echo "[recovery] ENV-UNREACHABLE: kubectl 连不上集群 —— 本次判定的 DEP/REC 不成立," \
       "请勿读成 'agent 没修好' (exit 3)" >&2
  exit 3
fi

# ★ O-32 甲(2026-09-24):**没交源码修复,不许判「恢复成功」**。
#   REC 问的是「把 agent 交的源码部署上去,故障消失了吗」,它的**输入前提**是
#   agent 真的交了一份源码修复。而全 hub 只读 fix.diff 的地方是 test_fixassert.py
#   (FIX 轴),`REC = RC ∧ REG` 里**没有 FIX** ⇒ 空修复/没交修复的场次照样能拿
#   REC=0(绿)。实证:`<case>` k=1(`/sweops_out/fix.diff` 压根不存在而 REC=0)、
#   `<case>` `20260924-092429`(0 字节,与 O-29 的空真叠在一起)。
#
#   谁置的位:驱动侧只对 **agent 道** 传 `SWEOPS_REQUIRE_FIX_DIFF=1`
#   (oracle/mock 道不传 —— 它们的空 diff 是另一条账:oracle 参考解的
#   merge/cherry-pick 缺陷)。中途反馈探针那条路走自己的 env 串 ⇒ 天然不置位。
#   exit **1** 而不是 3:3 是「没验」(环境不可达),这一条是**验了、没过**(REC=1);
#   也用 1 而不是 2,免得被读成「源码树都没有」(那是 build 那一关)。
#   位置在 ENV-UNREACHABLE **之后**:集群都连不上时,「这次判定不成立」是更准的
#   结论,别把它记成「agent 没交修复」。
#   读的是**容器里**的 `/sweops_out/fix.diff`(与 test_fixassert 同一个文件、
#   同一个时刻),不走宿主侧的产物收集 ⇒ 不受采集竞态影响。
if [ "${SWEOPS_REQUIRE_FIX_DIFF:-0}" = "1" ]; then
  _FIXREQ="${SWEOPS_FIX_PATH:-/sweops_out/fix.diff}"
  if [ ! -s "$_FIXREQ" ] || [ -z "$(tr -d '[:space:]' < "$_FIXREQ" 2>/dev/null)" ]; then
    echo "[recovery] FAIL: no source repair submitted -- ${_FIXREQ} is missing or" \
         "empty, so there is nothing to deploy and no recovery to credit" >&2
    exit 1
  fi
fi
CTR_ADDR=/run/k3s/containerd/containerd.sock
# Multi-node (N3) envs give every k3s AGENT its own containerd: same socket
# path inside the agent, different store, and no mirror pointing at the
# server. The env mounts each worker store back into this container as
# /run/k3s/ctr-w<N>/containerd.sock, and seed.py imports the case's tars into
# EVERY one of them (cfg["ctr_sockets"]) -- for exactly this reason: a pod
# scheduled onto a worker pulls from the internet, which is fine for a public
# image and ImagePullBackOff for a locally-built tag.
#
# An import the judge makes must fan out the same way. It did not: the
# repacked operator tag landed only in the SERVER's store, so the roll worked
# only while the scheduler happened to keep the operator on the server.
# <case> (2026-09-13) is the receipt -- the operator came up fine on
# `k3s`, then its own `rook-ceph-detect-version` Job landed on
# k3s-worker-2 and pulled `docker.io/rook/ceph:recfixed-<case>` ->
# "NotFound", the CephCluster never passed its version check, and the
# `cr_state cephblockpools` probe read `Progressing` for all 900s. The pool
# looked stuck; the only thing missing was a layer in a worker's store.
# Single-node envs have no ctr-w* mount at all, so the list is exactly
# [CTR_ADDR] and behaviour is byte-identical to before.
CTR_SOCKS=("$CTR_ADDR")
for _s in /run/k3s/ctr-w*/containerd.sock; do
  [ -e "$_s" ] || continue
  CTR_SOCKS+=("$_s")
done
unset _s
ctr_import_all() {   # ctr_import_all <tar> [label]
  # Explicit timeout: sh-less `ctr images import` unpacks every layer into the
  # content store and both tars here are hundreds of MB (seed.py carries the
  # same note after losing a 40-minute smoke to a 30s default).
  #
  # ★ Retry the FAST failures, and keep ctr's own words (2026-09-21, <case>).
  #   This is the one step here that is not a property of the agent's fix: it
  #   talks to containerd while containerd is unpacking those same hundreds of
  #   MB for the rest of this round. <case> k=1 died on `rc=2 /
  #   failed_at=import` **8.2s in** -- every other probe in that round burned
  #   its own 810s timeout -- and the judge could say nothing about why,
  #   because `2>&1` threw ctr's error text away. A flake here is scored as
  #   DEP+REC red, i.e. "the agent did not deploy / did not heal". Hence: two
  #   retries, plus the reason on the final failure.
  #
  #   The retry is GATED on the attempt having failed *fast* (<=120s). A slow
  #   failure is a different beast -- a 600s `timeout` kill (rc=124) or a
  #   near-timeout means retrying only triples the wall clock, so those do not
  #   retry. Worst case added cost is therefore ~2*120s, never 3*600s.
  #
  #   Wording is load-bearing and must not change: recovery_stages.sh reads
  #   `[recovery] imported <label> into <sock>` as the positive evidence for
  #   BOTH pack_ok and import_ok, and the call site's `[recovery] ctr import
  #   failed` as the FAIL key for the import stage. The retry prints its own
  #   lines, which match neither table; ctr's stderr is prefixed so it cannot
  #   collide with any of the judge's own markers.
  local tar=$1 label=${2:-image} s attempt rc t0 dt why err="$WORK/ctr-import.err"
  for s in "${CTR_SOCKS[@]}"; do
    attempt=0
    while [ "$attempt" -lt 3 ]; do
      attempt=$((attempt + 1))
      rc=0
      t0=$(date +%s)
      timeout 600 ctr --address "$s" images import "$tar" >/dev/null 2>"$err" || rc=$?
      dt=$(( $(date +%s) - t0 ))
      [ "$rc" -eq 0 ] && break
      # Three different give-up reasons; rc/dt/attempt are printed either way,
      # `why` is only the one-line summary so nobody has to re-derive them.
      why="slow failure (${dt}s), not retried"
      [ "$attempt" -ge 3 ] && why="3 fast attempts, all failed"
      [ "$rc" -eq 124 ] && why="timeout kill after ${dt}s, not retried"
      if [ "$rc" -eq 124 ] || [ "$dt" -gt 120 ] || [ "$attempt" -ge 3 ]; then
        echo "[recovery] FAILED to import $label into $s (rc=$rc after" \
             "${dt}s, attempt $attempt of 3: $why)" >&2
        sed 's/^/  ctr: /' "$err" 2>/dev/null | tail -n 6 >&2
        return 1
      fi
      echo "[recovery] import of $label into $s failed fast (rc=$rc in ${dt}s);" \
           "retrying in $((attempt * 5))s (attempt $((attempt + 1)) of 3)" >&2
      sleep $((attempt * 5))
    done
    echo "[recovery] imported $label into $s" >&2
  done
}

# dump the cfg into shell-sourceable form: one "K=V" per line, V shell-quoted
"$PY" - "$CFG" "$WORK/rearm.args" "$WORK/manifests.list" > "$WORK/cfg.env" <<'PY'
import json, shlex, sys
d = json.load(open(sys.argv[1]))
# optional re-arm: argv lists replayed against the cluster AFTER the roll (5c)
with open(sys.argv[2], "w") as fh:
    for argv in d.get("rearm") or []:
        fh.write("\t".join(str(x) for x in argv) + "\n")
print("REARM_N=%d" % len(d.get("rearm") or []))
print("REARM_SETTLE=%d" % int(d.get("rearm_settle", 30)))
# ★ O-29 (2026-09-24): a re-arm whose shape is not an argv list -- a bash recipe
# shipped in tests/hidden/ (`rearm_script`) and run as
#     bash <hidden>/<rearm_script> <kubeconfig> [args...]
# i.e. the SAME calling convention the seed's own trigger scripts already use
# (triggers/<slug>.sh <kubeconfig> [ns] [cr]); REARM_ARGS is appended after the
# kubeconfig. Needed because the re-arm for a trigger-created fault is a loop
# with precondition waits, not a fixed sequence of kubectl calls (5c).
print("REARM_SCRIPT=" + shlex.quote(str(d.get("rearm_script") or "")))
print("REARM_ARGS=" + shlex.quote(
    " ".join(str(x) for x in (d.get("rearm_args") or []))))
# optional: empty the event store before every post capture (6b) -- only for a
# fault whose Warning is re-emitted by a controller OUTSIDE the operator pod
print("CLEAR_EACH_PROBE=%d" % (1 if d.get("clear_events_each_probe") else 0))
# how long a vacuous pre-deploy reading may wait for the fault to materialise
print("PRE_WAIT=%d" % int(d.get("pre_wait", 300)))
# optional: point the operator's PRE-ROLL image reference at the candidate build
# (4a). Only for a case whose fix is carried by a manifest that is FROZEN -- one
# the operator created before the roll and can neither update (immutable pod
# template) nor re-create (its own guard refuses). Opt-in: every other case is
# byte-for-byte unaffected.
print("RETAG_OP=%d" % (1 if d.get("retag_operator") else 0))
# optional manifest-side fix: repo-relative paths of the agent's OWN manifests,
# re-applied to the cluster after the roll (4c). One path per line; k8s repo
# paths are space-free by construction.
with open(sys.argv[3], "w") as fh:
    for m in d.get("manifests") or []:
        fh.write(str(m) + "\n")
print("MANIFEST_N=%d" % len(d.get("manifests") or []))
op = d["operator"]
print("SLUG=" + shlex.quote(d.get("slug", "")))
print("BUILD=" + shlex.quote(" ".join(shlex.quote(x) for x in op["build"])))
print("BUILD_CWD=" + shlex.quote(op.get("cwd", "")))
print("DEPLOY=" + shlex.quote(op["deploy"]))
print("COPIES=" + shlex.quote(" ".join(f"{s}={t}" for s, t in op["copy"])))
print("SETTLE=%d" % int(d.get("settle", 120)))
print("BUDGET=%d" % int(d.get("budget", 900)))
print("MAX_RESTARTS=%d" % int(d.get("max_restarts", 2)))
print("RETRY=%d" % int(d.get("retry", 45)))
print("MODE=" + shlex.quote("probes" if d.get("probes") else "signals"))
# optional workload image: the pods a fix has to reach when it does NOT live in
# the operator Deployment (see step 4b). Tokens are space-joined WITHOUT quoting
# -- step 4b re-splits them with `read -r -a`, which honours IFS only. Every
# token of a workload argv (kubectl flags, jsonpath, the patch body) is
# space-free, so this is exact; a token that needed quotes would have to bring
# its own encoding.
w = d.get("workload_image") or {}
print("WLOAD_N=%d" % (1 if w else 0))
print("WLOAD_PROBE=" + shlex.quote(" ".join(w.get("probe") or [])))
print("WLOAD_COPY=" + shlex.quote(w.get("copy") or ""))
print("WLOAD_PATCH=" + shlex.quote(" ".join(w.get("patch") or [])))
print("WLOAD_RESTART=" + shlex.quote(" ".join(w.get("restart") or [])))
print("WLOAD_SETTLE=%d" % int(w.get("settle", 60)))
PY
. "$WORK/cfg.env"

probe_read() {  # probe_read <argv...> -> stdout, diagnostics on empty
  local out
  out=$("${KCTL[@]}" "$@" 2>"$WORK/kubectl.err")
  if [ -z "$out" ] && [ -s "$WORK/kubectl.err" ]; then
    echo "[recovery]   (kubectl: $(head -1 "$WORK/kubectl.err"))" >&2
  fi
  printf '%s' "$out"
}

probe_ok() {  # probe_ok <got> <want> -> 0 when the reading is the wanted one
  # A leading `!` in `want` means the value must be ABSENT. jsonpath renders a
  # missing field as the empty string, so a criterion whose fixed side is "the
  # thing is gone" (an empty list, a dropped condition) has no positive string
  # to match -- signals mode gets its (无)/(absent) sentinels from
  # diff_telemetry, and this is the probes-mode equivalent.
  # Substring-anchored like the positive case: `!<sentinel>` fails on any reading
  # that still carries the sentinel name, pass or fail elsewhere.
  case "$2" in
    '!'*) case "$1" in *"${2#!}"*) return 1;; *) return 0;; esac;;
    *)    case "$1" in *"$2"*) return 0;; *) return 1;; esac;;
  esac
}

dump_diag() {
  # A recovery that never lands must say WHY. Without this, every such case
  # costs another full 20-minute smoke just to look -- and the harness collects
  # no cluster logs afterwards (<case> 23:47 and <case> 00:51 were
  # both diagnosed blind). The operator's own log comes first: it is exactly
  # what the fix changed.
  echo "[recovery] ---- diagnostics ($NS) ----" >&2
  for po in $("${KCTL[@]}" -n "$NS" get pods -o \
        jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null); do
    case "$po" in "$DEP"-*) ;; *) continue;; esac
    echo "[recovery] operator log $po (tail 40):" >&2
    "${KCTL[@]}" -n "$NS" logs "$po" --all-containers --tail=40 2>&1 \
      | sed 's/^/    /' >&2 || true
  done
  echo "[recovery] objects:" >&2
  for k in sts deploy pod job; do
    "${KCTL[@]}" -n "$NS" get "$k" -o wide 2>/dev/null | sed 's/^/    /' >&2 || true
  done
  echo "[recovery] events (tail 15):" >&2
  "${KCTL[@]}" -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null \
    | tail -15 | sed 's/^/    /' >&2 || true
}

# 0. locate the seed's operator image + container name ------------------------
# Read live off the Deployment instead of a per-case table: the image string
# that is actually running is the one the /images tar must carry, and the
# container to repoint is the one that runs it.
NS=${DEPLOY%%/*}; DEP=${DEPLOY##*/}
"${KCTL[@]}" -n "$NS" get deploy "$DEP" -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\t"}{.image}{"\t"}{.command[0]}{"\n"}{end}' \
  > "$WORK/containers.tsv" 2>/dev/null
[ -s "$WORK/containers.tsv" ] || {
  echo "[recovery] operator Deployment $DEPLOY not found in the seeded cluster" >&2
  exit 2; }
BASE_IMG=""
STORE_SEEN=""
while IFS=$'\t' read -r cname cimg cexec; do
  [ -n "${cimg:-}" ] || continue
  for t in /images/*.tar; do
    [ -f "$t" ] || continue
    if "$PY" - "$t" "$cimg" <<'PY'
import json, sys, tarfile
try:
    m = json.load(tarfile.open(sys.argv[1]).extractfile("manifest.json"))
    sys.exit(0 if sys.argv[2] in (m[0].get("RepoTags") or []) else 1)
except Exception:
    sys.exit(1)
PY
    then BASE_IMG=$t; CTR_NAME=$cname; CUR_IMG=$cimg; CEXEC=$cexec; break 2; fi
  done
  # (b) no shipped tar carries it: this env pulls the operator from a registry
  #     at seed time. That is the 8 cases whose environment/images/ is empty and
  #     whose seed-config carries an image_rewrites entry mapping the srcbuggy
  #     tag onto a published one -- <case>/705, <case>/1863/283/292/
  #     297, <case> (found 2026-09-12; <case> died on it at 23:54).
  #     Export the RUNNING image out of containerd instead of giving up: a
  #     strictly better base than a shipped tar, because by construction it is
  #     the very image the cluster is running. Both namespaces are tried --
  #     images the CRI pulled live in k8s.io, images imported by hand land in
  #     the default one, and k3s resolves either for the kubelet.
  #     Ask the store which of ITS names is this image instead of exporting
  #     under the Deployment's spelling: the CRI qualifies short names before
  #     pulling, so `k8ssandra/cass-operator:v1.22.1` comes to rest as
  #     `docker.io/k8ssandra/cass-operator:v1.22.1`, and `ctr` resolves names
  #     VERBATIM -- the unqualified export silently matched nothing, which made
  #     this whole branch a no-op: not one case ever printed "exported ... out
  #     of containerd" between 2026-09-12 (when it was written) and <case>
  #     reaching it on 2026-09-13 and dying at step 0 with "neither in /images
  #     nor in the containerd store" while its operator pod was plainly running.
  #     Matched on the tail, anchored so the tag has to agree too; `$cimg`
  #     itself is tried first in case the store does hold the bare name.
  # ... and read it out of EVERY store, not just the server's: an image the
  # CRI pulled live sits in the store of the node that ran the pod, which on a
  # multi-node env is whatever the scheduler picked (CTR_SOCKS at the top).
  for ctrsock in "${CTR_SOCKS[@]}"; do
  for nsi in "" k8s.io; do
    # STORE_HIT = 这个 store **自己列出来的**名单里有没有这个名字。注意列表里那个
    # `"$cimg"` 首选项是**无条件**试的 ⇒ 它不能算"store 里有"(否则下面 bail 那句
    # 就会恒说"导出失败",等于把话术修成了假事实 —— 夹具反向对照实测到过)。
    STORE_HIT=$(ctr --address "$ctrsock" ${nsi:+--namespace "$nsi"} \
                  images ls -q 2>/dev/null \
                  | grep -E "(^|/)${cimg}\$" || true)
    for stored in "$cimg" $STORE_HIT; do
      [ -n "$stored" ] || continue
      if [ -n "$STORE_HIT" ]; then STORE_SEEN=1; fi
      if ctr --address "$ctrsock" ${nsi:+--namespace "$nsi"} images export \
           "$WORK/base.tar" "$stored" >/dev/null 2>&1 && [ -s "$WORK/base.tar" ]; then
        echo "[recovery] exported $stored out of containerd${nsi:+ (ns $nsi)} ($ctrsock)" >&2
        # CUR_IMG must be the name that exists in the store: it is the base the
        # repack reads back, and NEW_TAG's qualification below keys off it.
        BASE_IMG="$WORK/base.tar"; CTR_NAME=$cname; CUR_IMG=$stored; CEXEC=$cexec; break 4
      fi
    done
  done
  done
  # ★ 2026-09-22:**算子已经被我们自己滚成 repack 标签** ⇒ 底包用种子里那张。
  #   中途反馈探针(poll_feedback.deploy_probe)跑的就是本脚本一次完整恢复;
  #   它先滚一次,Deployment 的镜像就变成 `<repo>:recfixed-<slug>-<hash>`,判官
  #   本体最后再来一次时第 0 步读到的正是这个标签 —— 既不在 /images(种子只发
  #   srcbuggy 那张),也常常已不在 store 里 ⇒ 4 秒 exit 2 ⇒ DEP=1,而这是**我们
  #   自己造成的状态**。实测 <case> 2026-09-22 16:57(全库 rc=2 的六轮里
  #   唯一一例非 agent 过错;同案反馈探针 n=3..7 全是"一进脚本就 4 秒死",同一签名)。
  #   底包换回**同一仓库路径**的种子 tar:repack 重建的就是源码那一层,新标签由
  #   下面的 SRC_HASH 现算 ⇒ 树没变 ⇒ 标签与在跑的一致(set image 是 no-op,但
  #   集群里跑的**正是这棵树**,判官照常进 settle/验证,不做假);树变了 ⇒ 新标签
  #   ⇒ 真滚动。**只对 `:recfixed-` 前缀生效**:镜像真丢了的案子照旧 exit 2。
  case "$cimg" in
    *:recfixed-*)
      for t in /images/*.tar; do
        [ -f "$t" ] || continue
        if "$PY" - "$t" "${cimg%:*}" <<'PYF'
import json, sys, tarfile
try:
    m = json.load(tarfile.open(sys.argv[1]).extractfile("manifest.json"))
    repo = sys.argv[2]
    sys.exit(0 if [x for x in (m[0].get("RepoTags") or [])
                   if x.rsplit(":", 1)[0] == repo] else 1)
except Exception:
    sys.exit(1)
PYF
        then BASE_IMG=$t; CTR_NAME=$cname; CUR_IMG=$cimg; CEXEC=$cexec
             echo "[recovery] base = $t (same repo as the live repack tag" \
                  " $cimg; an earlier pass already rolled the Deployment," \
                  " so the SEED image is the base)" >&2
             break 2; fi
      done;;
  esac
done < "$WORK/containers.tsv"
[ -n "$BASE_IMG" ] || {
  echo "[recovery] the operator's image ($(cut -f2 "$WORK/containers.tsv" \
      | tr '\n' ' ')) is neither in /images nor in the containerd store" \
      "${STORE_SEEN:+(the store DID list a matching name -- export itself failed)}" >&2
  exit 2; }

# Where the rebuilt binary has to land is not a property of the source tree, it
# is what THIS container executes -- and the recipe in recovery_machines.json was
# authored from each family's upstream Dockerfile, which for cloudnative-pg
# disagrees with the manifest that is actually deployed: the recipe copies to
# /operator/manager_amd64 while the Deployment says `command: [/manager]`. The
# repack then succeeds, the roll succeeds, the operator is healthy -- running the
# OLD buggy binary -- and the fault can never clear. <case> spent its whole
# 900 s budget reading the buggy side on 2026-09-13 00:51 for exactly this.
# So: when the container declares a plain absolute command, that path wins. Shell
# wrappers and containers with no command (image ENTRYPOINT) keep the recipe.
case "${CEXEC:-}" in
  /*) case "$(basename "$CEXEC")" in
        sh|bash|ash|env|tini) ;;
        *) NEW_TGT=$CEXEC;;
      esac;;
esac
if [ -n "${NEW_TGT:-}" ]; then
  NEW_COPIES=""
  for pair in $COPIES; do
    src=${pair%%=*}; dst=${pair#*=}
    case "$dst" in /*) dst=$NEW_TGT;; esac
    NEW_COPIES="$NEW_COPIES $src=$dst"
  done
  COPIES=${NEW_COPIES# }
  echo "[recovery] copy destination -> $NEW_TGT (what the Deployment runs)" >&2
fi
# same repo, new tag: the tar is repacked against the tag the Deployment will
# be repointed at, and the seed's other images keep the tags they came with
#
# [judge-v2] The tag carries a hash of the SOURCE TREE. It used to be a pure
# function of the slug ("<slug>"), i.e. identical for every attempt in a case:
# a second recovery then ran `set image` onto the tag the Deployment was already
# running, which is a spec no-op, so the freshly built binary never executed and
# the case scored as if the repair had failed. Salting by CONTENT (not by
# attempt number) keeps both properties: a changed tree always yields a new tag
# and therefore a real roll, while an unchanged tree reuses the imported image
# instead of accumulating one per attempt (disk is the scarce resource here and
# k3s GC drops imported images under pressure).
SRC_HASH=$( (cd "$SRC" && find . -type f -not -path './.git/*' -print0 \
             | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12) 2>/dev/null )
[ -n "$SRC_HASH" ] || SRC_HASH=nohash
NEW_TAG="${CUR_IMG%:*}:recfixed-${SLUG:-x}-${SRC_HASH}"

# Qualify the name -- containerd stores the repacked tag VERBATIM.
# recovery_repack.py names the image with the OCI annotation
# io.containerd.image.name, and containerd honours that as written; a
# `docker save` tar is different, its docker-style RepoTags get normalized to
# docker.io/.... So an unqualified operator image lands in the store as
# "percona/x:recfixed-slug" while the CRI looks up
# "docker.io/percona/x:recfixed-slug" -- a name that is simply not there, and
# the rolled pod sits in ImagePullBackOff until the roll times out.
# <case> burned its whole roll budget on this on 2026-09-13; the tell was
# its own `ctr images ls -q` line printing the tag WITHOUT the docker.io/
# prefix while every seed image above it had one. <case> died at the same
# step. ghcr.io/... and quay.io/... are already qualified and pass straight
# through -- which is exactly why the three cases that did pass are the three
# that use them.
case "$NEW_TAG" in
  */*)  # has an org/ repo path: a registry host iff the FIRST component has a
        # dot, a port, or is localhost (docker's own rule)
        case "${NEW_TAG%%/*}" in
          *.*|*:*|localhost) ;;
          *) NEW_TAG="docker.io/$NEW_TAG";;
        esac;;
  *)    NEW_TAG="docker.io/library/$NEW_TAG";;   # bare name -> docker's library
esac
echo "[recovery] operator $DEPLOY container=$CTR_NAME image=$CUR_IMG" >&2
echo "[recovery] repacked tag $NEW_TAG (fully qualified for the CRI)" >&2

# 1. build ------------------------------------------------------------------
echo "[recovery] build: ${BUILD_CWD:+cd $BUILD_CWD && }$BUILD" >&2
( cd "$SRC/${BUILD_CWD:-.}" \
  && eval "GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local CGO_ENABLED=0 $BUILD" ) 2>&1 | tail -8
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
  echo "[recovery] agent tree does not build -- nothing to deploy" >&2
  exit 2
fi

# ---- reading the fault, two ways ------------------------------------------
want_probes=0
if [ "$MODE" = signals ]; then
  cap_and_eval() {  # cap_and_eval <tag> <out.json> -> writes capture + json
    local tag=$1 out=$2
    rm -rf "$WORK/cap-$tag"
    "$PY" "$HID/capture_run.py" --kubeconfig "$KUBECONFIG" \
      --out "$WORK/cap-$tag" --label "$tag" >&2 || return 2
    "$PY" "$HID/recovery_signal.py" eval "$SLUG" "$WORK/cap-$tag" "$out" >&2 \
      || return 2
    return 0
  }
  # 1b. pre-deploy reading (vacuous-pass guard) -----------------------------
  # The seeded buggy operator is still running here; at least one probe must
  # still be off the fixed side, or there is nothing to recover.
  # "Not yet" is not "never": a fault whose visible symptom is a WORKLOAD
  # object (<case>'s extra `test-cluster-rs0-4` pod, stuck
  # Init:Blocked) only appears once the buggy operator has reconciled far
  # enough -- its capture raced the workload's creation on 2026-09-13 (rs0-0
  # itself was still Pending), every probe read the fixed side, and the judge
  # graded a live fault VACUOUS. So a vacuous reading retries until the fault
  # shows or PRE_WAIT (cfg `pre_wait`, default 300 s) runs out; only then is
  # the case declared unrecoverable-by-criteria. Strictly a rescue: a case
  # whose fault never materialises stays vacuous, whatever the window.
  # 1b-pre. handed-in pre-deploy capture (optional, 2026-09-19) --------------
  # The driver takes this reading at the moment the fault became observable --
  # before ANY agent session ran, hence before the feedback round
  # (poll_feedback.deploy_probe -> test_recovery_stages.sh) rolled the agent's
  # tree into the cluster and healed the fault. Reading it HERE instead, as this
  # script used to, is what made a GOOD repair ungradeable: the deploy happens
  # mid-session, the fault is already gone by the time the judge starts, this
  # pre-deploy read says "already fixed" -> VACUOUS -> rc=1 -> REC=1, and the
  # FIX relax (whose precondition is rc==0) can never fire. <case> round 1
  # is the receipt (18:06 fix.diff = the GT hunk, 18:09 feedback deploy healed,
  # 18:18 VACUOUS). Net effect: the better the agent repaired, the more reliably
  # the judge refused to score it.
  # pre.json is not merely a guard -- it is the baseline compare() diffs against
  # ("moved = a probe that was NOT fixed before and IS fixed after"), so the fix
  # is to move WHEN it is taken, never to skip it.
  # Absent / unusable => fall through to the live read below: byte-identical to
  # the behaviour before this change.
  pre_done=0
  pre_src="${SWEOPS_PRE_CAPTURE:-}"
  if [ -n "$pre_src" ] && [ -f "$pre_src/.complete" ] && [ -d "$pre_src/cap" ]; then
    rm -rf "$WORK/cap-pre"
    cp -a "$pre_src/cap" "$WORK/cap-pre"
    if "$PY" "$HID/recovery_signal.py" eval "$SLUG" "$WORK/cap-pre" \
         "$WORK/pre.json" >&2 \
       && "$PY" "$HID/recovery_signal.py" pre "$WORK/pre.json" >&2; then
      echo "[recovery] pre-deploy reading taken from the driver's capture \
(fault-observable moment, before any agent tree entered the cluster)" >&2
      pre_done=1
    else
      echo "[recovery] handed-in pre-capture is unusable -- falling back to a \
live read" >&2
    fi
  fi
  if [ "$pre_done" != 1 ]; then
  pre_deadline=$(( $(date +%s) + ${PRE_WAIT:-300} ))
  while :; do
    if ! cap_and_eval pre "$WORK/pre.json"; then
      echo "[recovery] pre-deploy capture failed -- cannot grade" >&2
      exit 2
    fi
    if "$PY" "$HID/recovery_signal.py" pre "$WORK/pre.json" >&2; then
      break
    fi
    if [ "$(date +%s)" -ge "$pre_deadline" ]; then
      echo "[recovery] VACUOUS: every probe already reads the fixed-side \
value before the agent's operator was deployed -- nothing to recover" >&2
      exit 1
    fi
    echo "[recovery] fault not visible yet (workload still converging under \
the buggy operator); re-reading in 45s" >&2
    sleep 45
  done
  fi
else
  # Same late-read problem as 1b-pre, in the other mode: by the time this runs,
  # the feedback round may already have rolled the agent's tree in and healed
  # the fault, so every probe reads the fixed side and pre_clean stays 1 ->
  # spurious VACUOUS. The driver recorded these same probes at the
  # fault-observable moment; when that record is present, use its readings.
  # Whether a reading IS the wanted one is still decided here by probe_ok (with
  # its `!`-absent semantics) -- the driver moves readings, never verdicts.
  # Absent => live read, byte-identical to the behaviour before this change.
  # ★ 2026-09-20 修:probe 清单**无条件生成**。
  #   原来这段 heredoc 只写在下面的 else 支里,于是当驱动侧的 pre-capture 存在
  #   (标准路径!)时它**从没被创建** —— 而第三节 probes 模式的收尾循环
  #   `done < "$WORK/probes.tsv"` 读一个不存在的文件时,循环体**一次都不执行**,
  #   `ok` 保持初值 1,于是对**空集**宣称 "every probe reads the fixed-side value"
  #   ⇒ REC=0(通过) ⇒ 驱动据此 `repair landed` ⇒ GT 翻成"无故障"。
  #   实测受害(2026-09-19 战役):<case> k=1 与 <case> k=1,
  #   判官 stdout 里是 `probes.tsv: No such file or directory` 紧跟一行 RECOVERED。
  #   生成与"用哪份读数"是**两件事**,不该被同一个 if 绑在一起。
  "$PY" - "$CFG" > "$WORK/probes.tsv" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1]))["probes"]:
    print("\t".join([p.get("name", "?"), p["want"]] + [str(x) for x in p["cmd"]]))
PY
  pre_src="${SWEOPS_PRE_CAPTURE:-}"
  if [ -n "$pre_src" ] && [ -f "$pre_src/probes.tsv" ]; then
    echo "[recovery] pre-deploy readings taken from the driver's record \
(fault-observable moment, before any agent tree entered the cluster)" >&2
    pre_clean=1
    while IFS=$'\t' read -r -a F; do
      [ "${#F[@]}" -ge 3 ] || continue
      name=${F[0]}; want=${F[1]}; got=${F[2]}
      # `(empty)` is the driver's sentinel for "the command printed nothing":
      # the tsv is tab-separated and bash drops trailing empty fields, so a
      # bare empty reading would lose the field and the probe would be skipped.
      # Substring-matching it is correct for both want shapes: `!X` passes (the
      # poison is indeed absent), a positive want fails.
      [ "$got" = "(empty)" ] && got=""
      echo "[recovery] pre-deploy $name = '$got' (want '$want')" >&2
      probe_ok "$got" "$want" || pre_clean=0
    done < "$pre_src/probes.tsv"
  else
  pre_clean=1
  while IFS=$'\t' read -r -a F; do
    [ "${#F[@]}" -ge 3 ] || continue
    name=${F[0]}; want=${F[1]}; argv=("${F[@]:2}")
    got=$(probe_read "${argv[@]}")
    echo "[recovery] pre-deploy $name = '$got' (want '$want')" >&2
    probe_ok "$got" "$want" || pre_clean=0
  done < "$WORK/probes.tsv"
  fi
  if [ "$pre_clean" = 1 ]; then
    echo "[recovery] VACUOUS: every probe already reads the fixed-side value \
before the agent's operator was deployed -- nothing to recover" >&2
    exit 1
  fi
fi

# 2. repack the operator image around the freshly built binary --------------
# shellcheck disable=SC2086
"$PY" "$HID/recovery_repack.py" "$BASE_IMG" "$WORK/operator.tar" "$NEW_TAG" $COPIES \
  || { echo "[recovery] repack failed" >&2; exit 2; }

# 3. import -----------------------------------------------------------------
ctr_import_all "$WORK/operator.tar" "the repacked operator" \
  || { echo "[recovery] ctr import failed" >&2; exit 2; }

# 3b. end the buggy epoch's event log ---------------------------------------
# Events have a ~1h TTL and are NOT withdrawn when the condition they describe
# clears, so the seeded fault's Warnings are still in the store when the FIXED
# operator comes up. An `event_msg` probe whose fixed side is "(无)" then reads
# buggy forever, no matter how well the fix works -- a case in the megapone
# family hit exactly this while its non-event probes had already moved to the
# fixed side.
#
# The recorded fixed snapshot was taken on a cluster that never ran the buggy
# operator, so the post-deploy window is only comparable if the previous
# epoch's events are dropped. This runs BEFORE the roll: everything the new
# operator emits -- including any Warning that would rightly keep the probe on
# the buggy side -- survives. Namespaces the corpus reader's event_msgs()
# already ignores are left alone.
clear_epoch_events() {
  local n ns_list
  ns_list=$("${KCTL[@]}" get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  for n in $ns_list; do
    case "$n" in kube-system|local-path-storage|sweops-observability) continue;; esac
    "${KCTL[@]}" -n "$n" delete events --all >/dev/null 2>&1
  done
}
if [ "${CLEAR_EVENTS:-1}" = 1 ]; then
  clear_epoch_events
  echo "[recovery] cleared the pre-deploy events (buggy epoch closed)" >&2
fi

# 4. roll the operator onto the new tag ------------------------------------
# What the Deployment actually asks for: a roll can only ever work if the
# container we repoint is the one that runs the binary we rebuilt, with a pull
# policy that lets a locally-imported tag win.
"${KCTL[@]}" -n "$NS" get deploy "$DEP" -o jsonpath=\
'{range .spec.template.spec.containers[*]}{.name}{" cmd="}{.command}{" args="}{.args}{" pull="}{.imagePullPolicy}{"\n"}{end}' \
  >&2 2>/dev/null || true
for ctrsock in "${CTR_SOCKS[@]}"; do
  ctr --address "$ctrsock" images ls -q 2>/dev/null | grep -F "$NEW_TAG" >&2 \
    || echo "[recovery] WARNING $NEW_TAG absent from $ctrsock after import" >&2
done

# 4a. the operator image the OLD TAG points at, for manifests we cannot rewrite -
# Rolling the Deployment only reaches pods the Deployment owns. A manifest the
# operator rendered BEFORE the roll is frozen where it matters: a Job's
# `spec.template` is immutable (k8s ValidateJobSpecUpdate rejects any change to
# it), so a bootstrap Job keeps naming the operator image *tag* it was created
# with, and every retry pod it spawns re-runs the BUGGY binary no matter how
# well the roll went. One case in the postgres family is the live example: the
# bootstrap Job renders its init container with image = the deployment's
# OPERATOR_IMAGE_NAME, and that init container is the ONLY way the manager
# reaches the binary in the pod that runs it (the containers share an emptyDir
# over the manager's root, so a manager baked into the operand image is masked --
# 4b cannot help here).
#
# The operator cannot re-create that Job either: it only creates the bootstrap
# Job while its status reports zero instances, and that count is derived from
# the live managed PVCs, so while the damaged PVC exists the operator refuses
# ("...already initialized") and the Job is never replaced.
#
# So point the old tag AT the candidate build: same digest, one extra ref, and
# the frozen template resolves to code the agent actually wrote. This is a
# HARNESS statement, not a semantic one -- "the image the operator is
# configured to propagate is the operator we just deployed" -- and it keeps the
# discrimination: a candidate WITHOUT the fix still fails the retry
# (`directory ... exists but is not empty`) and reads buggy.
# Opt-in (RETAG_OP): no case without `retag_operator` reaches any of this.
if [ "${RETAG_OP:-0}" = 1 ]; then
  for ctrsock in "${CTR_SOCKS[@]}"; do
    # `ctr images tag` overwrites in the recent containerd builds this runs on,
    # but older ones reject a target that already has a different digest, so
    # fall back to dropping the old reference first. The window is two commands
    # wide and the only holder is the operator pod the roll is about to replace
    # anyway; its container keeps a snapshot, so dropping the reference cannot
    # pull a volume out from under it.
    ctr --address "$ctrsock" images tag "$NEW_TAG" "$CUR_IMG" >/dev/null 2>&1 \
      || { ctr --address "$ctrsock" images rm "$CUR_IMG" >/dev/null 2>&1 || true
           ctr --address "$ctrsock" images tag "$NEW_TAG" "$CUR_IMG" >/dev/null 2>&1; } \
      && echo "[recovery] $CUR_IMG now resolves to the candidate build in $ctrsock" >&2 \
      || echo "[recovery] WARNING could not re-tag $CUR_IMG -> $NEW_TAG in $ctrsock" >&2
  done
fi

"${KCTL[@]}" -n "$NS" set image "deploy/$DEP" "$CTR_NAME=$NEW_TAG" >/dev/null 2>&1 \
  || { echo "[recovery] could not roll $DEPLOY" >&2; exit 2; }
if ! "${KCTL[@]}" -n "$NS" rollout status "deploy/$DEP" --timeout=300s >/dev/null 2>&1; then
  # Say WHY. An unattributed "never became available" costs a full 10-minute
  # smoke slot to even guess at (<case>, 2026-09-12 23:47).
  echo "[recovery] new operator never became available -- diagnosing:" >&2
  "${KCTL[@]}" -n "$NS" get pods -o wide >&2 2>/dev/null || true
  for po in $("${KCTL[@]}" -n "$NS" get pods -o \
        jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null); do
    case "$po" in "$DEP"-*) ;; *) continue;; esac
    echo "[recovery]   $po:" >&2
    "${KCTL[@]}" -n "$NS" get pod "$po" -o jsonpath=\
'{range .status.containerStatuses[*]}{"    container "}{.name}{" ready="}{.ready}{" image="}{.image}{" state="}{.state}{"\n"}{end}' \
      >&2 2>/dev/null || true
  done
  "${KCTL[@]}" -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null | tail -12 >&2 || true
  exit 2
fi

# 4b. when the fix lives in an image the operator Deployment does NOT run -----
# Rolling the Deployment puts the fixed CONTROLLER in charge, but some fixes sit
# in code executed by the workload's own pods. The postgres family is the live
# example: the bootstrap path runs the same manager binary as a subcommand
# inside pods built from the CR's own image field (the operand image), so after
# the roll the fixed controller still watches a BUGGY manager re-enter the
# unfixed path on every retry -- one live run spent its full 900 s budget
# reading the buggy side while six bootstrap pods cycled through
# `directory ... exists but is not empty`.
# When a case declares `workload_image`, pack the SAME fresh binary into that
# image (read from the CR, not from a recipe) and repoint the CR at it, then
# drop the pods carrying the failed attempts so the retry starts clean.
# Config-driven: no case without `workload_image` reaches any of this.
if [ -n "${WLOAD_COPY:-}" ]; then
  read -r -a WPROBE <<< "$WLOAD_PROBE"
  wbase=$("${KCTL[@]}" "${WPROBE[@]}" 2>/dev/null)
  echo "[recovery] workload image (read from the CR): '$wbase'" >&2
  if [ -z "$wbase" ]; then
    echo "[recovery] WARNING the CR names no workload image -- the fix cannot \
reach the pods that run it" >&2
  else
    # The repacked image goes into the store under a tag that KEEPS the original
    # one as a version prefix. That is not cosmetic: an operator in this family
    # validates its own CR, parsing the image tag as a semantic version, and
    # rejects any tag it cannot read as one -- and the repoint below is a patch
    # to that very CR. Its version parser accepts a leading numeric release
    # followed by a free-form suffix (`<major>.<minor>-<anything>`), so keeping
    # the prefix makes the candidate tag parse, while a bare `recfixed-<slug>`
    # is refused outright ("invalid version tag") and the judge dies at the
    # patch step without ever showing why. Keeping the prefix is also what lets
    # the store answer the CRI lookup: the name is still a superset of the
    # original, only the tag differs, so `wbase%:*` stays the same registry
    # path the export above just read.
    wtag="${wbase##*:}"
    [ "$wtag" = "$wbase" ] && wtag=""
    WNEW_TAG="${wbase%:*}:${wtag}${wtag:+-}recfixed-${SLUG:-x}"
    case "$WNEW_TAG" in
      */*) case "${WNEW_TAG%%/*}" in
             *.*|*:*|localhost) ;;
             *) WNEW_TAG="docker.io/$WNEW_TAG";;
           esac;;
      *)   WNEW_TAG="docker.io/library/$WNEW_TAG";;
    esac
    # Same resolution as step 0: the store holds the name the CRI qualified.
    wtar=""
    for ctrsock in "${CTR_SOCKS[@]}"; do
    for nsi in "" k8s.io; do
      for stored in "$wbase" $(ctr --address "$ctrsock" ${nsi:+--namespace "$nsi"} \
                            images ls -q 2>/dev/null \
                            | grep -E "(^|/)${wbase}\$" || true); do
        [ -n "$stored" ] || continue
        if ctr --address "$ctrsock" ${nsi:+--namespace "$nsi"} images export \
             "$WORK/wload.tar" "$stored" >/dev/null 2>&1 && [ -s "$WORK/wload.tar" ]; then
          wtar="$WORK/wload.tar"
          echo "[recovery] exported $stored for repacking ($ctrsock)" >&2
          break 3
        fi
      done
    done
    done
    if [ -z "$wtar" ]; then
      echo "[recovery] WARNING workload image '$wbase' is not in the containerd \
store -- leaving it on the buggy binary" >&2
    else
      "$PY" "$HID/recovery_repack.py" "$wtar" "$WORK/wload-new.tar" "$WNEW_TAG" \
        "${COPIES%%=*}=${WLOAD_COPY}" \
        || { echo "[recovery] workload image repack failed" >&2; exit 2; }
      ctr_import_all "$WORK/wload-new.tar" "the repacked workload image" \
        || { echo "[recovery] workload image import failed" >&2; exit 2; }
      read -r -a WPATCH <<< "${WLOAD_PATCH//<TAG>/$WNEW_TAG}"
      # Keep the apiserver's own words. Discarding them cost a full 819 s smoke
      # on 2026-09-13: the CR was refused by the operator's validating webhook
      # and all the judge could say was "could not repoint the CR".
      WPERR=$("${KCTL[@]}" "${WPATCH[@]}" 2>&1 >/dev/null) \
        || { echo "[recovery] could not repoint the CR at $WNEW_TAG: \
${WPERR:-<the patch produced no error output>}" >&2; exit 2; }
      echo "[recovery] workload repointed at $WNEW_TAG" >&2
      if [ -n "${WLOAD_RESTART:-}" ]; then
        read -r -a WRESTART <<< "$WLOAD_RESTART"
        # Best-effort: a selector that matches nothing (the operator already
        # cleaned up) is not a reason to fail the case.
        "${KCTL[@]}" "${WRESTART[@]}" >/dev/null 2>&1 \
          || echo "[recovery] WARNING the stale-attempt cleanup matched nothing" >&2
      fi
      [ "${WLOAD_SETTLE:-0}" -gt 0 ] && sleep "$WLOAD_SETTLE"
    fi
  fi
fi

# 4c. when the fix lives in a manifest the cluster was built from --------------
# Some operators do not carry their own RBAC: `config/rbac/role.yaml` is applied
# to the cluster at DEPLOY time, and the operator's reconciler then creates
# downstream (Cluster)RoleBindings under THAT ClusterRole's authority. A live
# case in the knative family is the example -- its whole fix adds rules to that
# file, with no Go change at all -- so rebuilding the binary moves nothing the
# cluster can see: the fixed operator keeps logging
#   failed to apply (cluster)rolebindings: ... is attempting to grant RBAC
#   permissions not currently held: {APIGroups:[...], ...}
# and the downstream (cluster)rolebindings are never created (full 900 s budget
# read on the buggy side).
# When a case declares `manifests`, re-apply the AGENT's own copies after the
# roll. One-directional by construction: the buggy tree ships exactly the rules
# the cluster already has (verified live -- rules deep-equal), so its apply is a
# no-op and it still reads buggy; only the fixed tree adds what it needs.
if [ "${MANIFEST_N:-0}" -gt 0 ]; then
  while IFS= read -r mft; do
    [ -n "$mft" ] || continue
    if [ ! -f "$SRC/$mft" ]; then
      echo "[recovery] WARNING manifest '$mft' is not in the agent tree" >&2
      continue
    fi
    if "${KCTL[@]}" apply -f "$SRC/$mft" >"$WORK/manifest.out" 2>"$WORK/manifest.err"; then
      echo "[recovery] applied the agent's $mft" >&2
    else
      echo "[recovery] WARNING could not apply $mft: $(head -1 "$WORK/manifest.err")" >&2
    fi
  done < "$WORK/manifests.list"
fi

# 5. activity pre-condition -------------------------------------------------
echo "[recovery] operator up; settling ${SETTLE}s" >&2
sleep "$SETTLE"
# [judge-v2] Scope the restart count to the CURRENT ReplicaSet. Pods are named
# <deploy>-<rset-hash>-<id>, and *every* ReplicaSet the Deployment has ever had
# produces that shape -- so the old "$DEP-" prefix filter also caught the pod
# from before the roll. A pod that was already crash-looping kept contributing
# its cumulative restartCount to the freshly deployed operator's score, and
# `worst=max` reported it as the new operator thrashing. Observed: <case>
# read activity_restarts=3 at k=1 and 9 at k=2 while MAX_RESTARTS is 2 -- a
# monotone rise is the tell of a cumulative counter, not of a live crash loop.
# Resolve the live RS via ownerReferences (exact); the [cap] experience is that
# name heuristics pick sibling controllers. Fall back loudly, never silently.
ROLL_RS=$("${KCTL[@]}" -n "$NS" get rs -o json 2>/dev/null | "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
dep, best = sys.argv[1], None
for r in d.get("items") or []:
    md = r.get("metadata") or {}
    owners = md.get("ownerReferences") or []
    if not any(o.get("kind") == "Deployment" and o.get("name") == dep
               for o in owners):
        continue
    ann = md.get("annotations") or {}
    try:
        rev = int(ann.get("deployment.kubernetes.io/revision") or 0)
    except ValueError:
        rev = 0
    if best is None or rev > best[0]:
        best = (rev, md.get("name") or "")
print(best[1] if best else "")
' "$DEP" 2>/dev/null)
if [ -n "$ROLL_RS" ]; then
  ROLL_PREFIX="$ROLL_RS-"
  echo "[recovery] restart accounting scoped to rs=$ROLL_RS" >&2
else
  ROLL_PREFIX="$DEP-"
  echo "[recovery] WARNING could not resolve the current ReplicaSet of $DEP -- \
falling back to the '$DEP-' name prefix, which also counts pods of OLDER \
ReplicaSets; restart counts may be inflated" >&2
fi
# Pods owned by the Deployment are named <deploy>-<rset-hash>-<id>; read their
# restart counts and fail if the new operator is crash-looping (the deployment
# being "Available" does not mean it is not thrashing).
restarts=$("${KCTL[@]}" -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null \
  | awk -v p="$ROLL_PREFIX" 'index($1, p) == 1 {print $2}')
worst=0
for r in $restarts; do
  case "$r" in ''|*[!0-9]*) continue;; esac
  [ "$r" -gt "$worst" ] && worst=$r
done
if [ "$worst" -gt "$MAX_RESTARTS" ]; then
  echo "[recovery] ACTIVITY FAILED: operator restarts=$worst > $MAX_RESTARTS \
(a crash-looping operator is not a repair)" >&2
  exit 1
fi
echo "[recovery] operator restarts=$worst (<= $MAX_RESTARTS) [scope=${ROLL_PREFIX}]" >&2
"$PY" - "$CFG" > "$WORK/activity.args" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1])).get("activity") or []:
    print("\t".join([a[1]] + [str(x) for x in a[0]]))
PY
if [ ! -s "$WORK/activity.args" ]; then
  echo "[recovery] no activity pre-condition configured -- refusing to grade \
(a dead operator also makes symptoms vanish)" >&2
  exit 2
fi
while IFS=$'\t' read -r -a F; do
  [ "${#F[@]}" -ge 2 ] || continue
  want=${F[0]}; argv=("${F[@]:1}")
  got=$(probe_read "${argv[@]}")
  case "$got" in
    *"$want"*) : ;;
    *) echo "[recovery] ACTIVITY FAILED: '${argv[*]}' read '$got', expected \
'$want' -- an operator that is not up is not a repair" >&2; dump_diag; exit 1;;
  esac
done < "$WORK/activity.args"

# 5b. end the TAKEOVER window's event log -----------------------------------
# 3b clears before the roll, which is too early for a fault whose Warning is
# emitted by a controller OUTSIDE the operator pod. With a single-replica
# Deployment the old pod keeps answering webhooks (and any Service-routed
# traffic) until the new one is Ready, so the damaged cluster generates fresh
# Warnings during the roll -- and the client-go aggregator writes them as a new
# `(combined from similar events): ...` object, i.e. AFTER 3b ran. <case>
# (2026-09-13) is the live case: its ReplicaSet retried pod creation inside that
# window, so the event_msg probe read buggy for the whole 900s budget while the
# other probe had already moved to 1/1/Running -- a case that had recovered
# graded as not recovered.
#
# By this point the roll is complete, `rollout status` returned, and the settle
# has elapsed, so the buggy operator is provably gone: what is left in the store
# is either the buggy epoch (drop it) or something the fixed operator itself
# emitted since (keep it -- this runs before any post capture). Every event_msg
# probe in the corpus wants its message ABSENT, so this can only make the
# reading more faithful.
if [ "${CLEAR_EVENTS:-1}" = 1 ]; then
  clear_epoch_events
  echo "[recovery] cleared the takeover-window events (roll finished)" >&2
fi

# 5c. RE-ARM the fault (only for cases that declare one) --------------------
# Some upstream fixes are PREVENTION-ONLY: they stop the operator from writing
# a bad value, and no code path in the fixed binary can ever un-write the copy
# the buggy binary already left behind. A case in the cassandra family is the
# textbook one -- the fix validates a field of the CR spec against the live
# topology before copying it into status, while the buggy epoch has (a) already
# copied the ghost entry and (b) blanked the spec field, so after the roll the
# changed code is never entered again: fixed and buggy binaries behave
# identically in place and the case reads buggy forever. Its recorded GT
# (a status condition flipping True->False) was never reachable that way.
#
# So for such a case the config replays the fault after the roll: here that is
# "clear the ghost entry from status, re-submit the same invalid payload". The
# discrimination is exactly what the fix changed -- the fixed operator consumes
# the payload without recording it (spec blanked, status stays empty), the
# buggy one records the ghost again -- and it sits EARLY in the reconcile, so
# it holds even on a cluster whose data nodes are still bootstrapping (this
# sandbox runs that case under-provisioned: not all pods fit, so the operator
# never reaches the later reconcile stages and the GT's other signals are
# unreachable here for that second reason as well).
#
# The re-arm must not be confused with the roll: it is a NEW injection, so the
# probes that follow need a reading that is not just "nothing happened yet".
# REARM_SETTLE gives the operator's ~2 s reconcile loop room to act, and the
# cases are expected to grade on a probe that only the fixed operator can
# satisfy (<case>: the payload must be consumed AND not recorded).
#
# ★★ O-29 (2026-09-24, a mongo-family case is the receipt) -- A SECOND,
# INDEPENDENT reason to re-arm, and the reason `rearm_script` exists: WITHOUT a
# re-arm the roll itself erases the evidence that the fault was there.
#   That case's only criterion is a `*_previous` log classifier: a regex over
#   the operator container's `--previous` log (the crash stack exists nowhere
#   else). Pre-deploy it read non-zero (the seeded buggy operator was shot down
#   by the trigger's disable->enable window). The roll replaces that container,
#   and the NEW container of a byte-identical tree does NOT crash on a settled
#   cluster (the poison status state the window needed is gone), so
#   `--previous` is empty and the classifier reads 0 -- the "fixed" side.
#   `pre=N -> post=0 (MOVED)` => RECOVERED, with an EMPTY fix.diff and
#   /operator-src byte-for-byte identical to the clean tree: the agent got
#   recovery credit for a repair it never made, and the judge credited the
#   destruction of its own evidence. Every previous/restart-type criterion
#   (a `*_previous` classifier, a restart counter) is read through the same
#   hole: the roll resets the epoch it measures.
#   So for such a case the fault CONDITION has to be re-established after the
#   roll and the increment read from there -- the reading is then a live-fault
#   reading on the AGENT'S build (buggy => it crashes again => the probe reads
#   buggy; fixed => it does not). That is a recipe with waits in it, hence a
#   script rather than an argv list.
#   Marker convention: a re-arm script prints `REARM-FIRED` when it got the
#   fault to fire again on the deployed build, `REARM-MISSED` when it gave up.
#   A fixed build legitimately never fires, so a MISS is NOT a failure -- but
#   it is logged loudly, because in that case the post reading rests on the
#   recipe having fired against the BUGGY build at seed time (proved by the
#   pre-deploy capture), not on anything this judge observed.
if [ "${REARM_N:-0}" -gt 0 ] || [ -n "${REARM_SCRIPT:-}" ]; then
  if [ -n "${REARM_SCRIPT:-}" ]; then
    sp="$HID/$REARM_SCRIPT"
    if [ ! -f "$sp" ]; then
      # Refuse rather than grade: this case declares that its fault condition
      # must be re-established, and the recipe is not here, so a
      # previous/restart-type probe would be read in an epoch the fault never
      # entered -- "the evidence is gone" would be scored as "the fault is
      # fixed". That is the exact defect this branch exists to close.
      echo "[recovery] FAIL: rearm_script '$REARM_SCRIPT' is not in $HID \
(case declares a re-arm, judge cannot run it) -- refusing to grade the \
post-deploy reading as a repair" >&2
      dump_diag; exit 1
    fi
    RA=()
    [ -n "${REARM_ARGS:-}" ] && read -r -a RA <<< "$REARM_ARGS"
    echo "[recovery] re-arm script: $REARM_SCRIPT ${RA[*]:-}" >&2
    set +o pipefail
    bash "$sp" "$KUBECONFIG" ${RA[@]+"${RA[@]}"} > "$WORK/rearm-script.log" 2>&1
    rsc=$?
    set -o pipefail
    sed 's/^/[recovery]   rearm: /' "$WORK/rearm-script.log" >&2
    [ "$rsc" -eq 0 ] || echo "[recovery]   WARNING re-arm script exited $rsc \
-- it may not have re-established the fault" >&2
    if grep -q 'REARM-FIRED' "$WORK/rearm-script.log"; then
      echo "[recovery] re-arm RE-FIRED the fault on the deployed build -- the \
post reading below is a live-fault reading" >&2
    else
      echo "[recovery] re-arm did NOT re-fire the fault on the deployed build \
-- consistent with a repair; note the fault's absence on THIS build is not \
observed here, only its presence on the seeded buggy build (pre-deploy \
capture)" >&2
    fi
  fi
  if [ "${REARM_N:-0}" -gt 0 ]; then
    n=0
    while IFS=$'\t' read -r -a F; do
      [ "${#F[@]}" -ge 1 ] || continue
      n=$((n + 1))
      echo "[recovery] re-arm #$n: ${F[*]}" >&2
      "${KCTL[@]}" "${F[@]}" >/dev/null 2>"$WORK/rearm.err" \
        || echo "[recovery]   WARNING re-arm #$n failed: $(head -1 "$WORK/rearm.err")" >&2
    done < "$WORK/rearm.args"
  fi
  echo "[recovery] re-armed the fault; settling ${REARM_SETTLE}s" >&2
  sleep "$REARM_SETTLE"
  # The operator has just been handed the payload that (in the buggy binary)
  # makes it spin forever -- it still has to be alive afterwards, or "the fault
  # is gone" would just mean "the process is gone".
  while IFS=$'\t' read -r -a F; do
    [ "${#F[@]}" -ge 2 ] || continue
    want=${F[0]}; argv=("${F[@]:1}")
    got=$(probe_read "${argv[@]}")
    probe_ok "$got" "$want" || {
      echo "[recovery] ACTIVITY FAILED after re-arm: '${argv[*]}' read '$got', \
expected '$want' -- an operator that is not up is not a repair" >&2
      dump_diag; exit 1; }
  done < "$WORK/activity.args"
  echo "[recovery] operator still up after the re-arm" >&2
fi

# 6. is the fault gone? -----------------------------------------------------
deadline=$(( $(date +%s) + BUDGET ))
last=""
while :; do
  if [ "$MODE" = signals ]; then
    # 6b. for cases whose fault is re-emitted by a controller OUTSIDE the
    # operator pod, empty the event store before EVERY post capture -----------
    # 3b and 5b clear twice, at epochs that assume the emitting controller dies
    # with the operator. The ReplicaSet controller does not: it lives in
    # kube-controller-manager and keeps retrying pod creation from the BAD
    # template the buggy operator left behind, all through the takeover -- the
    # Deployment controller only scales that RS down once the new (fixed) RS is
    # AVAILABLE, which can take minutes of image pull. So 5b's clear ran while
    # the emissions were still coming, the aggregator rewrote the
    # `(combined from similar events)` object after it, and the event_msg probe
    # read buggy for the rest of the 900 s budget although the case had visibly
    # recovered (its paired pod_status probe had already moved to the fixed
    # side).
    # Cleared per iteration, the probe answers the right question -- "is the
    # Warning being emitted NOW" -- and the case goes green at the first
    # iteration taken after the old RS stops retrying.
    # Opt-in on purpose: for a fault whose event is emitted ONCE (at seed time)
    # a per-iteration clear would erase the only evidence, and a buggy lane
    # would read clean. Cases that need it declare `clear_events_each_probe`,
    # and they must keep a second, non-event probe whose conjunction pins the
    # reading (an unrelated violation of the same workload keeps the pod off
    # the fixed side, so a buggy operator can never satisfy it in the same
    # capture).
    if [ "${CLEAR_EACH_PROBE:-0}" = 1 ]; then
      clear_epoch_events
    fi
    if cap_and_eval post "$WORK/post.json"; then
      rc=0
      "$PY" "$HID/recovery_signal.py" compare "$WORK/pre.json" "$WORK/post.json" \
        >&2 || rc=$?
      case $rc in
        0) echo "[recovery] RECOVERED" >&2; exit 0;;
        2) last="post-deploy snapshot is not evaluable";;
        *) last="fault still visible in the post-deploy snapshot";;
      esac
    else
      last="post-deploy capture failed"
    fi
  else
    # ★ 空真守卫(2026-09-20):这份清单是 RECOVERED 的**唯一**依据。
    #   文件缺失/为空 ⇒ 下面那个 while 循环体零次执行 ⇒ `ok` 恒 1 ⇒
    #   对**空集**宣称"每个探针都读到修复侧"。宁可硬挂,也不许把"没测"
    #   记成"测过了"(本仓已经把这条栽过五次)。
    #   `n_read` 是第二道:文件在、但每行都 <3 字段时,循环同样一次有效迭代都没有。
    if [ ! -s "$WORK/probes.tsv" ]; then
      echo "[recovery] FAIL: probe list missing or empty ($WORK/probes.tsv) \
-- cannot judge recovery; refusing to declare recovery on no evidence" >&2
      dump_diag
      exit 1
    fi
    ok=1
    n_read=0
    while IFS=$'\t' read -r -a F; do
      [ "${#F[@]}" -ge 3 ] || continue
      n_read=$((n_read + 1))
      name=${F[0]}; want=${F[1]}; argv=("${F[@]:2}")
      got=$(probe_read "${argv[@]}")
      probe_ok "$got" "$want" || { ok=0; last="$name: got '$got', want '$want'"; }
    done < "$WORK/probes.tsv"
    if [ "$ok" = 1 ] && [ "$n_read" -ge 1 ]; then
      echo "[recovery] RECOVERED: every probe reads the fixed-side value \
($n_read probe(s) read)" >&2
      exit 0
    fi
    [ "$n_read" -eq 0 ] && last="probe list had no usable rows"
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  echo "[recovery] not recovered yet ($last); retrying in ${RETRY}s" >&2
  sleep "$RETRY"
done
echo "[recovery] NOT RECOVERED within ${BUDGET}s -- $last" >&2
dump_diag
exit 1
