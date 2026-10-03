#!/usr/bin/env bash
# K8SPXC-1155 -- the user's CORRECTION attempt, played as a single tolerant scene
# (N3 conversion, 2026-09-12).
#
# Fault-at-seed (oat_tests/xtop-1155/mutated-0.yaml, applied by the seed):
#   gen0's PerconaXtraDBCluster carries
#     spec.pxc.affinity.antiAffinityTopologyKey: kubernetes.io/hostname
#   i.e. REQUIRED pod anti-affinity per node, while the cluster has only two
#   schedulable nodes and pxc.size is 3. That is the JIRA's "invalid
#   configuration": the third replica can never find a node, so the cluster
#   comes up with 2 of 3 replicas -- and, critically, WITH a primary.
#
#   Why the primary matters (learnt the hard way on 2026-09-10): if the bad
#   configuration matched NOTHING, every pxc pod would be Pending. Then the
#   fixed operator's smartUpdate would ALSO fail -- it calls getPrimaryPod(cr)
#   (proxyDB -> haproxy) before deleting anything -- and the fixed side would
#   look exactly like the buggy one. Two schedulable nodes is the minimum that
#   keeps the two variants apart; the third node is what pxc-2 needs AFTER the
#   correction, so the fixed side has somewhere to put it.
#
# This script is the correction half: relax the anti-affinity to `none`, then
# watch whether the operator can actually roll the corrected template out.
#
#   buggy  (v1.11.0, upgrade.go:279)  smartUpdate opens with
#       `if currentSet.Status.ReadyReplicas < currentSet.Status.Replicas {
#          return nil }`
#     2 < 3, so the corrected template never rolls and pxc-2 stays Pending
#     forever. That is the fault.
#   fixed  (#1829, PR eab99321)  the early return is gone, the corrected
#     template rolls, pxc-2 schedules on the free node and the cluster reaches
#     3/3 with status.state=ready.
#
# Why anti-affinity and NOT nodeSelector (2026-09-12, after the first N3 run of
# this case): the pin is e797d016 (v1.11.0, 2022-06). updatePod() copies a
# hand-written SUBSET of the pod spec into the StatefulSet template: Affinity is
# in it, NodeSelector is NOT (that omission is K8SPXC-1067's bug -- upstream
# #1743, a year after this pin). So a nodeSelector scene cannot be corrected on
# this base at all: after the user fixes the CR the template would not change,
# there would be no new revision, and removing the smartUpdate early return
# would have nothing to roll -- the fixed side would stay stuck at 2/3 and the
# case would have no discriminator. antiAffinityTopologyKey IS propagated
# (`currentSet.Spec.Template.Spec.Affinity = pxc.PodAffinity(podSpec.Affinity,
# sfs)`), so this scene is separated by the upstream fix ALONE, with no extra
# port and no base mismatch. (Same reasoning as xtop-1067's entry in
# resolution/bridge_cases_b.py, from the other side.)
#
# Exit code is ALWAYS 0: this same file is the N3 env's trigger_script AND the
# host bridge's scene step, and on the bridge both legs run it (candidate and
# buggy). A non-zero exit would abort the seed on whichever leg is behaving
# correctly. The verdict is carried by the marker ConfigMap below, which the
# env's fault_verify_after asserts on and the bridge's recovery predicate
# independently re-derives from the CR's own status.
#
# [poll restructure, 2026-09-24] the poll path no longer seeds the fault:
# poll-healthy.yaml seeds pxc size=2 (healthy 2/2), and THIS script injects at
# runtime by scaling size 2->3 before the correction -- see the injection block
# below. N3/bridge legs (fault at seed via mutated-0.yaml) behave exactly as
# before: their size is already 3, the patch is a no-op and pxc-2 is already
# Pending when the strand wait starts. The marker gains only `injected`
# (forensics); fault_verify_after's existing keys are byte-identical.
#
# $1 = kubeconfig.
set -uo pipefail
KC="${1:?usage: xtop-1155-scene.sh <kubeconfig>}"
NS=acto-namespace
CRD=perconaxtradbclusters.pxc.percona.com
CR=test-cluster
STS=test-cluster-pxc
MARK=xtop-1155-scene-state
# How long the correction is given to roll before "it never rolled" is
# recorded. 420s matches triggers/xtop-1155.sh's collection-side window; the
# fixed side has to rebuild three pods one at a time (smartUpdate applies to
# secondaries first, the primary last).
ROLL_WINDOW="${ROLL_WINDOW:-420}"

k() { kubectl --kubeconfig "$KC" "$@"; }

affinity_key() {
  k -n "$NS" get sts "$STS" \
    -o jsonpath='{.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[0].topologyKey}' \
    2>/dev/null || true
}

# ---------------------------------------------------------------------------
# [poll] 运行期故障注入(2026-09-24 重构,用户拍板)。
# 健康前缀 = poll-healthy.yaml(pxc size=2 + required hostname 反亲和,恰好 2/2
# 带-primary;haproxy 亲和 none 不搁浅)。故障在这里进场:把 size 2->3。
# 不改 pod 模板 => 不触发 smartUpdate 滚动;STS 创建 pxc-2(序号最高、最后
# 创建),两节点已被 pxc-0/pxc-1 占 => pxc-2 必然 Pending。零竞态,搁浅者
# 恒为 pxc-2(探针读的就是它)。N3 旧路径(mutated-0.yaml,seed 即 size=3)
# 走到这里时 patch 是 no-op、pxc-2 已 Pending,行为与旧版相同。
# ---------------------------------------------------------------------------
k -n "$NS" patch "$CRD" "$CR" --type=merge \
  -p '{"spec":{"pxc":{"size":3}}}' >/dev/null 2>&1 \
  || echo "[1155] WARN: injection patch (pxc size -> 3) returned non-zero"
# 等 pxc-2 落定 Pending:连续两次读数一致(防把「还没建出来」当终态)。
injected=no
ph=""
for _ in $(seq 1 40); do
  ph=$(k -n "$NS" get pod "$STS-2" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$ph" = "Pending" ] && [ "${ph_prev:-}" = "Pending" ]; then injected=yes; break; fi
  ph_prev="$ph"
  sleep 15
done
echo "[1155] injection: pxc size -> 3; $STS-2 phase=${ph:-<none>} (injected=$injected)"

echo "[1155] == invalid configuration in place?"
gen0=0
for _ in $(seq 1 60); do
  gen0=$(k -n "$NS" get sts "$STS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  # 2, not 3: pxc-2 is the replica the unsatisfiable anti-affinity strands.
  # Waiting for 3 would hang here on BOTH variants and the scene would never
  # reach the correction at all.
  [ "$gen0" = "2" ] && break
  sleep 5
done
aff0=$(affinity_key)
echo "[1155] gen0: ${STS} ready=${gen0:-?}/3, sts anti-affinity topologyKey=${aff0:-<none>}"

# ---------------------------------------------------------------------------
# The correction. A merge-patch, never `kubectl apply`: the CR was created by
# Acto's python client, so it carries no last-applied-configuration annotation,
# and a three-way apply with no "previous version" to diff against is an
# INCREMENTAL merge -- a field absent from the applied config is simply left at
# its live value. `none` is the operator's own "off" spelling
# (api.AffinityTopologyKeyOff), and PodAffinity() returns nil for it, so the
# template's whole Affinity block goes away -> new revision -> a roll is due.
# ---------------------------------------------------------------------------
# BOTH components, not just pxc. The CR carries the same topology key on
# spec.haproxy.affinity, and haproxy.size is 3 as well, so correcting pxc alone
# left haproxy-2 permanently Pending on the two schedulable nodes -- and
# status.state then cannot reach `ready` on EITHER leg. 2026-09-12: the host
# bridge's candidate leg timed out at 900s with the capture warning
# `test-cluster-haproxy-2(Pending); test-cluster-pxc-0(Pending)`, i.e. the
# recovery predicate was unreachable, not the fix broken.
# The discriminator is untouched by this: it lives entirely in smartUpdate's
# early return on the PXC StatefulSet (readyReplicas 2 < replicas 3), which
# haproxy's own affinity has no part in.
k -n "$NS" patch "$CRD" "$CR" --type=merge \
  -p '{"spec":{"pxc":{"affinity":{"antiAffinityTopologyKey":"none"}},"haproxy":{"affinity":{"antiAffinityTopologyKey":"none"}}}}' >/dev/null 2>&1 \
  || echo "[1155] WARN: correction patch returned non-zero"
left=$(k -n "$NS" get "$CRD" "$CR" -o jsonpath='{.spec.pxc.affinity.antiAffinityTopologyKey}' 2>/dev/null || true)
left_hpx=$(k -n "$NS" get "$CRD" "$CR" -o jsonpath='{.spec.haproxy.affinity.antiAffinityTopologyKey}' 2>/dev/null || true)
# Reading it back is not paranoia: it is the difference between "the correction
# was applied" and "the correction was attempted". If the operator writes the
# field back, `left` is not `none` and the marker records patched=no, so the env
# goes red on its own rather than shipping a green scene that proved nothing.
if [ "$left" = "none" ] && [ "$left_hpx" = "none" ]; then patched=yes; else patched=no; fi
echo "[1155] correction: pxc-antiAffinityTopologyKey now ${left:-<absent>}, haproxy-antiAffinityTopologyKey now ${left_hpx:-<absent>} (patched=$patched)"

# ---------------------------------------------------------------------------
# Did the operator roll the corrected template out? Two observation windows so
# a roll that is merely slow is not mistaken for a roll that is blocked.
# ---------------------------------------------------------------------------
ready=0
for _ in $(seq 1 $((ROLL_WINDOW / 5))); do
  ready=$(k -n "$NS" get pods -l app.kubernetes.io/component=pxc \
    --field-selector status.phase=Running \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
    | grep -c true || true)
  [ "${ready:-0}" = "3" ] && break
  sleep 5
done
sleep 20
state=$(k -n "$NS" get "$CRD" "$CR" -o jsonpath='{.status.state}' 2>/dev/null || true)
spec_aff=$(affinity_key)
p2=$(k -n "$NS" get pod "$STS-2" -o jsonpath='{.status.phase}' 2>/dev/null || true)
# haproxy readiness is recorded because status.state gates on it: a candidate
# leg that stalls with haproxy short is a scene defect, not a fix defect, and
# the two used to look identical in the marker.
hpx=$(k -n "$NS" get pods -l app.kubernetes.io/component=haproxy \
  --field-selector status.phase=Running \
  -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
  | grep -c true || true)
echo "[1155] after correction: pxc ready=${ready:-0}/3, haproxy ready=${hpx:-0}/3, CR state=${state:-?}, sts topologyKey=${spec_aff:-<none>}, pxc-2=${p2:-<none>}"

# fault=present means: the correction did NOT roll. On the buggy operator that
# is the whole point; on the fixed one it means the scene did not reproduce and
# the env must not go green.
fault=present
if [ "${ready:-0}" = "3" ]; then fault=absent; fi

k -n "$NS" create configmap "$MARK" \
  --from-literal=gen0="${gen0:-unknown}" \
  --from-literal=injected="$injected" \
  --from-literal=patched="$patched" \
  --from-literal=aff0="${aff0:-none}" \
  --from-literal=ready="${ready:-0}" \
  --from-literal=state="${state:-unknown}" \
  --from-literal=pxc2="${p2:-none}" \
  --from-literal=haproxy="${hpx:-0}" \
  --from-literal=fault="$fault" --dry-run=client -o yaml \
  | k apply -f - >/dev/null 2>&1

echo "=== xtop-1155 scene done (patched=$patched ready=${ready:-0}/3 state=${state:-?} fault=$fault) ==="
# Always 0 -- see the header. The marker is the verdict carrier.
exit 0
