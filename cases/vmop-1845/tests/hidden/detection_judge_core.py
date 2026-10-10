#!/usr/bin/env python3
"""detection_judge_core.py -- detection 轮次判定的**零依赖核心**(纯机械表)。

这份文件是"一处真理":
  宿主侧: judge_prompt_emit.py import 它做离线机械重放;
  包内:   gen 发射期变换(poll_emit_patch)把它原样盖进
          <pkg>/tests/hidden/detection_judge_core.py,
          评测端 import 它做同样的判定 —— 两边逐字同源,分数才可比。

零依赖是硬要求:包内环境不含本仓其它模块,不许 import 宿主模块。

2026-09-18 用户定稿:检测判定**纯机械表,一个 LLM 都不叫**(当晚二次拍板
「不要 llm judge detect 结果了 这部分都可以删掉了」⇒ LLM 件整体移除):
  - 原 "JUDGE" 三格(mid/stable/post_repair 的 abnormal)全部有机械答案;
  - TEMPLATE / build_prompt / parse_verdict / LLMJudge / judge_live_round /
    summarize 已删(selftest 有"名字都不许回来"的哨兵)。

判定矩阵(2026-09-15 定稿框架,2026-09-18 改机械+GRACE 计对):
  run_invalid(探针从未翻转但跑到 stable) ⇒ 全轮 INVALID,不计分
  pre     + abnormal → FALSE_ALARM(wrong)
  pre     + normal   → TN
  mid     + abnormal → FALSE_ALARM(wrong)
  mid     + normal   → GRACE(**计 correct**,2026-09-18 用户拍板)
  stable  + abnormal → TP
  stable  + normal   → MISSED(wrong)
  post_rep+ normal   → TN
  post_rep+ abnormal → 按 gt_fault 拆:修好了还说异常=FALSE_ALARM(wrong);
                              没修好(判官 REC 没过)还说异常=TP
  无产物              → NO-DATA
"""


# ---------------------------------------------------------------- 判定矩阵
def verdict_for(phase: str, decision, run_invalid: bool, gt_fault: bool | None = None):
    """→ (layer_verdict, scoring|None)。**纯机械表**。decision=None 表示本轮无产物。

    表(阶段已经把"该轮真值该是什么"编码好了,不需要额外查 GT):
      pre          abnormal=错(-) / normal=对      —— 进场是种子集群,GT=正常
      mid          abnormal=错   / normal=对       —— 已注入、探针还没翻(宽限窗)
      stable       abnormal=对   / normal=错       —— 故障在场,GT=故障
      post_repair  **按 gt_fault 拆两行**:
                     修好了还说异常=错;没修好(判官 REC 没过)还说异常=对
    """
    if run_invalid:
        return "INVALID(env: fault never observable)", None
    if decision is None:
        return "NO-DATA", None
    if phase == "pre":
        if decision:
            return "FALSE_ALARM(strict: pre-injection abnormal)", "wrong"
        return "TN", None
    if phase == "mid":
        if decision:
            return "FALSE_ALARM(mid: injected, probe not yet flipped)", "wrong"
        # 2026-09-18 用户拍板:宽限窗说 normal **算对**(进分母记 correct)。
        # 之前只记录不计分;而表头注释一直写的是 normal=对 —— 这次把代码对齐注释。
        return "GRACE(recorded, normal)", "correct"
    if phase == "post_repair":
        if gt_fault:                    # 修复**没成**(判官 REC 没过),GT 仍故障
            if decision:
                return "TP(post-repair, GT still faulty)", None
            return "MISSED(post-repair, GT still faulty)", "wrong"
        if decision:
            return "FALSE_ALARM(post-repair resurfacing)", "wrong"
        return "TN", None
    # stable
    if decision:
        return "TP(fault observable)", None
    return "MISSED(fault observable, agent said normal)", "wrong"


def selftest():
    """零依赖核心的自测:判定矩阵全格 + LLM 件删净哨兵。宿主/包内都能跑。"""
    from pathlib import Path
    fails = []
    def check(name, got, want):
        if got != want:
            fails.append(f"{name}: got={got!r} want={want!r}")

    check("invalid优先", verdict_for("stable", True, True)[0].startswith("INVALID"), True)
    # 2026-09-18 用户拍板:GRACE(mid 说 normal)**算对** —— 计分必须是 correct,
    # 不是 None(不计分)。这格最容易"改回只记录",钉死。
    check("GRACE 算对(计 correct)", verdict_for("mid", False, False)[1], "correct")
    grid = {
        ("pre", True, None): "FALSE_ALARM", ("pre", False, None): "TN",
        ("mid", True, None): "FALSE_ALARM", ("mid", False, None): "GRACE",
        ("stable", True, None): "TP", ("stable", False, None): "MISSED",
        ("post_repair", True, False): "FALSE_ALARM",   # 修好了还说异常 = 错
        ("post_repair", False, False): "TN",
        ("post_repair", True, True): "TP",             # 没修好,说异常 = 对
        ("post_repair", False, True): "MISSED",
        (None, None, None): "NO-DATA",
    }
    for (ph, dec, gtf), want in grid.items():
        got = verdict_for(ph, dec, False, gt_fault=gtf)[0].split("(")[0]
        check(f"{ph}+{dec}+{gtf}", got, want)
    # 机械表必须给 abnormal 格子机械答案 —— "JUDGE" 这个词就是 LLM 时代的残留,
    # 出现即回退。
    check("无 JUDGE 残留",
          any(verdict_for(p, d, False, gt_fault=g)[0].startswith("JUDGE")
              for (p, d, g) in grid), False)
    # LLM 件删净哨兵(2026-09-18 用户拍板):名字都不许回来。只扫**模块 docstring
    # 之后、selftest 之前**的代码区 —— 墓碑清单(docstring)与本哨兵手里的名单
    # 字面量(selftest 内)都不算残留。
    src = Path(__file__).read_text().split('"""', 2)[2].split("def selftest")[0]
    for gone in ("build_prompt", "parse_verdict", "LLMJudge", "judge_live_round",
                 "TEMPLATE", "urllib", "chat/completions"):
        check(f"LLM 件已删({gone})", gone in src, False)

    if fails:
        print(f"CORE SELFTEST FAILED: {fails}"); raise SystemExit(1)
    print("CORE SELFTEST PASSED (机械表全格 + GRACE 计对 + LLM 件删净)")


if __name__ == "__main__":
    selftest()
