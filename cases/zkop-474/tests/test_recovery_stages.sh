#!/usr/bin/env bash
# [recovery-stages] 把"卡在哪一关"从**一句日志**变成**一份结构化产物**。
#
# 背景（2026-09-18 用户口径）：REC 只是**一个**退出码，它把四件事加在一起
#   编译成功 ∧ 部署成功 ∧ 算子存活 ∧ 故障信号消失
# 于是 REC=1 时看不出是哪一件挂的，只能翻 [recovery] 日志行。用户原话：
# 「那这些指标都分别什么名字 分别怎么记录下来 我要对一下 还有编译成功
#   apply成功什么的」。
#
# 本层**不碰判官逻辑**（test_recovery.sh 一字不动），只做四件事：
#   1. 跑它，stderr 收进临时文件（判官没有实时 consumer，收完原样转发）
#   2. 从它**本来就打**的那些 [recovery] … 行里认出各环节的成败
#   3. 写 /tmp/recovery-stages.json
#   4. 退出码**原样透传** —— _RC 不变 ⇒ REC 合成不变 ⇒ reward 不变 ⇒ 账本不变
#
# 口径（宁可缺席，不可编造）：
#   * 判官**遇到失败就立刻 exit**，所以"失败行不在日志里"⇒ 那一关过了（True）
#   * 失败之后没走到的关卡一律 **null**（"没走到"不是"失败"，两件事）
#   * 认不出来（判官措辞变了）⇒ 变 null，**不会**变成错的值
#   * 撞名提醒：`recovery.json` 是判官的**输入**（/tests/hidden/recovery.json），
#     所以这份输出叫 recovery-stages.json，两个名字不许混。
#
# 门：poll_judge_semantics_selftest.case_recovery_stages —— 造几条假的判官
# 日志（build 挂 / 算子没起来 / 修好 / 没治好），逐条对字段，且反向对照
# "不接本层时确实一个字段都没有"。
set -uo pipefail

# 路径可用环境变量覆盖：门（poll_judge_semantics_selftest）要并发跑好几份，
# 不许它们互相踩同一个 /tmp。沙箱里没人设这两个键 ⇒ 就是上面写的默认值。
_STAGES_JSON="${SWEOPS_STAGES_JSON:-/tmp/recovery-stages.json}"
_IMPL="${SWEOPS_STAGES_IMPL:-${TEST_DIR:-/tests}/test_recovery.sh}"
# 可选**内部**上限（秒）：未设/0 ⇒ 不设，行为与从前逐字节相同。
#
# 为什么需要（2026-09-20 用户在「一案一改」里拍的口径）：判官自己最坏的耗时 =
# 构建+打包+导入+滚动+settle **加** 最多 BUDGET(900s) 等信号消失（那根钟在
# recovery_judge.sh:882 才起算）。而外层探针的墙钟**默认也是 900s** ⇒ 两把钟
# 根本不等：外层先到点时，本脚本被 kill 在 `bash "$_IMPL"` 这一行上，**解析器
# 根本没跑**，那一轮 stages 一个字段都没有，poll_feedback 只能回一句
# "no per-stage readings"。mgopone 族实测三轮全撞在 902.7~903.7s
# （<case>/1072/1252，2026-09-20）。
# 设了内部上限 ⇒ 判官先被切，**解析器一定跑得到**：已经跑完的关（build/pack/
# import/roll/operator_up）照常落档，没走到的关留 null，并记一个 `cut`。
#
# ★ 判分路径**不设**这个变量（test.sh 里没人设）⇒ reward 与账本零变化。
_INNER="${SWEOPS_STAGES_INNER_TIMEOUT:-0}"
_ERR=$(mktemp)
PY=/opt/sweops-venv/bin/python
[ -x "$PY" ] || PY=python3

_CUT=0
if [ "${_INNER:-0}" -gt 0 ] 2>/dev/null; then
  # `-k 15`:TERM 之后再等 15s,判官不咽气就 KILL。没有这一条,一个忽略 TERM 的
  # 子进程会让 timeout 自己挂住 ⇒ 外层照样先到点 ⇒ 又回到"解析器没跑"的老毛病。
  timeout --signal=TERM --kill-after=15 "$_INNER" bash "$_IMPL" 2>"$_ERR"
  _RC=$?
  [ "$_RC" -eq 124 ] && _CUT=1
else
  bash "$_IMPL" 2>"$_ERR"
  _RC=$?
fi
cat "$_ERR" >&2

_STAGES_CUT="$_CUT" _STAGES_ERR="$_ERR" _STAGES_RC="$_RC" \
  _STAGES_OUT="$_STAGES_JSON" "$PY" - <<'PYEOF'
import json, os, re

log = open(os.environ["_STAGES_ERR"], errors="replace").read()
rc = int(os.environ["_STAGES_RC"])

# 关卡顺序 = 判官自己的执行顺序（脚本头注释 1-6）。只列**会 exit** 的关：
# `applied the agent's …` 失败时只打 WARNING 不 exit，所以它不作为关卡。
ORDER = ["build", "precheck", "pack", "import", "roll",
         "operator_up", "activity", "healed"]
#                    ↑ 把 DEP 拆开：DEP 只说"部署上去了没"（= _RC<=1），
#                      这三关说"上去之后活着没 / 治好了没"。
# 每一关独一无二的那句失败声明。判官遇挫即 exit ⇒ 至多命中一条。
# 「没有源码树」并进 build：「源码树都没有」和「源码树编不过」在用户口径里
# 是同一件事（编译成功 = False），单列一关只会让 reached 更难看懂。
FAIL = {
    "build":       r"agent tree does not build"
                   r"|\[recovery\] no source tree at ",
    "precheck":    r"pre-deploy capture failed -- cannot grade"
                   r"|VACUOUS: every probe already reads the fixed-side"
                   r"|no activity pre-condition configured"
                   # ★ O-32 甲(2026-09-24):判官在**构建之前**就拒绝给分
                   #   (agent 没交源码修复)⇒ 归 precheck 这一关。「没走到」的
                   #   关卡已经用 null 表达了,这里要说的是「卡在预检」。
                   r"|\[recovery\] FAIL: no source repair submitted",
    "pack":        r"\[recovery\] repack failed",
    "import":      r"\[recovery\] ctr import failed",
    "roll":        r"\[recovery\] could not roll ",
    "operator_up": r"new operator never became available",
    "activity":    r"ACTIVITY FAILED",
    "healed":      r"NOT RECOVERED within ",
}
# 各关的**正证据**：只在"这一关真的过了"时才打的行。用来在 rc 说不清时兜底
# （例：算子起来了但后面又倒，rc 未必是 0）。
POS = {
    "build":       r"\[recovery\] repacked tag ",
    # ★ 2026-09-21 修:`\S+` 只吃**一个**非空白词,而判官实际打的是多词标签
    # (`[recovery] imported the repacked operator into …`,见 test_recovery.sh
    # 的 ctr_import_all 调用)⇒ 这一格**恒不匹配**、`pack_ok` 恒为 null(而
    # `import_ok` 为 true)。实测 349 份 stages 产物里 76 份踩中、涉及 14 案。
    # 放宽成 `.+` 与下一行 `import` 同款。只动"正证据"表,不改任何判定阈值。
    "pack":        r"\[recovery\] imported .+ into ",
    "import":      r"\[recovery\] imported .*into .*",
    "roll":        r"\[recovery\] operator up; settling ",
    "operator_up": r"\[recovery\] operator up; settling |operator still up after",
    "activity":    r"\[recovery\] operator still up after the re-arm",
    "healed":      r"\[recovery\] RECOVERED",
    # ★ 2026-09-20 补:这张表**少了 precheck**,而下面的循环对每一关都查
    # `POS[st]` —— 于是只要出现 `rc != 0 且 failed_at` 是 None/unknown 的组合,
    # 解析器就在 precheck 这一格抛 `KeyError: 'precheck'`,**产物一个字节都写不
    # 出来**,而 stderr 里的 traceback 早被外层 `>/dev/null` 吞了 ⇒ 账本上只留
    # 一个 "no_stages_json"。实测签名对得上:<case> 的 n=3..7(4.3~4.5s)
    # 与 <case> 的 n=2,3(3.6s)—— `go build` 不可能 4 秒跑完,那是判官早早
    # 非零退出、措辞又认不出(`failed_at="unknown"`)那一种。
    #
    # 为什么 precheck 的**唯一**正证据是"用了交来的术前片"这两句:活读那条路
    # 成功时判官**一个字都不打**(循环 break 得静默)⇒ 没有可靠的正证据。此时
    # 宁缺勿编 —— 留 None,不猜 True。
    "precheck":    r"pre-deploy reading[s]? taken from the driver's "
                   r"(capture|record)",
}

cut = os.environ.get("_STAGES_CUT") == "1"

hits = [s for s in ORDER if re.search(FAIL[s], log)]
failed_at = hits[0] if hits else None
# 被内部上限切掉时 rc=124，但那**不是**判官的失败声明 ⇒ 不写 unknown
# （unknown 的意思是"有失败、只是认不出是哪句"，与"还没走到"是两件事）。
# 已经被判官打出来的失败声明照样认 —— 切之前就挂了的，照常报。
if rc != 0 and failed_at is None and not cut:
    failed_at = "unknown"          # rc 说挂了，但没认出是哪句 ⇒ 不猜

out = {"rc": rc, "failed_at": failed_at}
if cut:
    out["cut"] = True
    out["cut_msg"] = ("probe-side budget expired while the judge was still running "
                      "-- the stages kept above are the ones that had finished; "
                      "this is not a failure report")
for i, st in enumerate(ORDER):
    if failed_at == st:
        out[st + "_ok"] = False
    elif failed_at is None or failed_at == "unknown":
        # rc==0 ⇒ 全过；认不出 ⇒ 只认正证据，认不出就是 None
        # `.get` 是**防崩**不是宽容:表里少一格就会让整份产物写不出来(见 POS 里
        # precheck 那条注释),而"少一格"正是这张表最容易犯的错。查不到 ⇒ 不匹配
        # ⇒ None(缺席),与"编造"是两件事。
        out[st + "_ok"] = True if (rc == 0 or re.search(POS.get(st, r"(?!)"), log)) else None
    elif ORDER.index(failed_at) > i:
        out[st + "_ok"] = True     # 失败发生在它后面 ⇒ 它过了
    else:
        out[st + "_ok"] = None     # 没走到，别记成失败
# 用户点名的四个名字，直接给出来（其余是它们的细分件）：
#   编译成功 = build_ok        部署成功 = DEP（已有名字，= _RC<=1）
#   算子存活 = operator_up_ok  信号消失 = healed_ok
out["reached"] = next((s for s in reversed(ORDER) if out[s + "_ok"] is True), None)

# 工作负载那一路（4b：修复在别的镜像里）是**旁支**，不进上面的线性序。
# 只是 WARNING 不 exit 的两句（manifest 不在树里 / apply 不上去）同样不记。
def wl(pos, neg):
    if re.search(neg, log):
        return False
    return True if re.search(pos, log) else None
out["workload_pack_ok"] = wl(r"\[recovery\] exported .* for repacking ",
                             r"workload image repack failed")
out["workload_import_ok"] = wl(r"\[recovery\] workload repointed at ",
                              r"workload image import failed")
out["workload_repoint_ok"] = wl(r"\[recovery\] workload repointed at ",
                                r"could not repoint the CR at ")

# failed_msg：给列一个能读的原因（判官自己的最后一句），不另造措辞。
if failed_at and failed_at != "unknown":
    m = re.search(FAIL[failed_at], log)
    line = log[:m.start()].rsplit("\n", 1)[-1] + log[m.start():].split("\n", 1)[0]
    out["failed_msg"] = line.strip()[-160:]
else:
    out["failed_msg"] = None

tmp = os.environ["_STAGES_OUT"] + ".tmp"
json.dump(out, open(tmp, "w"), ensure_ascii=False, indent=1)
os.replace(tmp, os.environ["_STAGES_OUT"])
PYEOF

rm -f "$_ERR"
exit "$_RC"
