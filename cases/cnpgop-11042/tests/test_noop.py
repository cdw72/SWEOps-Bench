"""Real scoring test for the SWEOps cnpgop-11042 task.

Grades the agent's /sweops_out/diagnosis.json against the hidden ground
truth (docstring details maintained in solution.sh).
"""
import json
import os
import re
import pytest

DIAGNOSIS = os.environ.get("SWEOPS_DIAG_PATH", "/sweops_out/diagnosis.json")
DETECTION = os.environ.get("SWEOPS_DETECTION_PATH", "/sweops_out/detection.json")

# --- hidden ground truth (machine-readable; docstring above = human version)
GT = {'case_id': 'cnpgop-11042', 'fault_detected_expected': True, 'file': 'internal/controller/cluster_status.go', 'file_required': True, 'files_extra': [], 'function': 'runningJobNames', 'function_required': True, 'functions_extra': []}


def _norm_file(s):
    s = (s or "").strip().strip("`\"'")
    s = s.split(" ")[0]
    s = re.sub(r":\d+\s*$", "", s)
    s = re.sub(r"^.*?/operator-src/", "", s)
    return s.strip("/")


def _norm_function(s):
    s = (s or "").strip().strip("`\"'() ")
    if ":" in s and "/" in s:
        s = s.rsplit(":", 1)[-1]
    return s.rstrip("()").strip()


def _fuzzy(a, b):
    from difflib import SequenceMatcher
    return SequenceMatcher(None, a, b).ratio()


def _file_match(agent, gt):
    """2026-09-19 用户拍板:ground_truth 是人工审核过的真值 ⇒ 精确匹配。
    只保留格式归一(_norm_file 剥工作区前缀/行号/引号),之后必须同一文件:
    相等,或 agent 侧只多仓库前缀(endswith '/'+gt)。basename 同名、0.75
    相似度这类模糊通道删除 —— 它们把误定位放行过(rdoptwo-292 k1)。"""
    a, g = _norm_file(agent), _norm_file(gt)
    if not a or not g:
        return False
    return a == g or a.endswith("/" + g)


def _gt_function_candidates(raw):
    parts = [p.strip().strip("()").strip() for p in (raw or "").split("/")]
    return [p for p in parts if p]


def _bare_fn(s):
    """2026-09-20 用户拍板:file 就是 file,function 就是 function。
    在 _norm_function(剥引号/`path:` 前缀/括号)之后再剥 `<Type>.` 限定,
    落到裸函数名 —— agent 侧与 GT 候选两侧对称使用。"""
    s = _norm_function(s)
    return s.rsplit(".", 1)[-1] if "." in s else s


def _function_match(agent, gt_raw):
    """精确(09-19)+ 裸名兜底(09-20,用户看 rbop-2218 实跑后拍板):
    归一后与真值逐字相等;或两侧剥掉 `path:` 前缀/`Type.` 限定后的裸名相等
    —— file:Type.Build 对 GT=Build 算对(文件本就精确钉死,裸名撞车风险
    被同文件约束兜住)。子串包含、大小写不敏感、相似度通道维持删除。"""
    a = _norm_function(agent)
    cands = _gt_function_candidates(gt_raw)
    if not a or not cands:
        return False
    if a in cands:
        return True
    ab = _bare_fn(agent)
    bare = {_bare_fn(c) for c in cands}
    return bool(ab) and ab in bare


def _loose_json_load(raw):
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        cleaned = re.sub(r",\s*([\]}])", r"\1", raw)
        return json.loads(cleaned)


def _fault_flag(diag):
    """检测结论:优先 detection.json(§1 Detection 的产物),退回 diagnosis.json。

    2026-09-15 起检测与 RCA 分家:§1 写 detection.json 只表"有没有故障";§2 的
    diagnosis.json 只在**发现故障时**才写 RCA 对象。参考解与改动前的产物仍把
    fault_detected 放在 diagnosis.json —— 退回读它,判定结果与旧判官逐字一致
    (兼容读,不翻旧证据的案)。返回 (值, 实际读到的文件)。
    """
    for path in (DETECTION, DIAGNOSIS):
        try:
            obj = _loose_json_load(open(path).read())
        except Exception:
            continue
        if isinstance(obj, dict) and isinstance(obj.get("fault_detected"), bool):
            return obj["fault_detected"], path
    return diag.get("fault_detected"), DIAGNOSIS


def test_diagnosis_graded():
    """Grade the agent's diagnosis.json against the hidden ground truth."""
    if not os.path.exists(DIAGNOSIS):
        _fd, _src = _fault_flag({})
        pytest.fail(f"[sweops] {DIAGNOSIS} was not produced by the agent "
                    f"(detection verdict read from {_src}: {_fd!r}; "
                    f"GT expects fault_detected={GT['fault_detected_expected']})")
    try:
        raw = open(DIAGNOSIS).read()
        d = _loose_json_load(raw)
    except Exception as e:
        pytest.fail(f"[sweops] {DIAGNOSIS} is not valid JSON: {e}")
    if not isinstance(d, dict):
        pytest.fail(f"[sweops] diagnosis.json must be a JSON object, got {type(d).__name__}")

    fd, fd_src = _fault_flag(d)
    if not isinstance(fd, bool):
        # [2026-09-22 用户拍板] 检测卷坏/缺(got None)⇒ 这处坏卷**只由检测轴承担**
        # (driver 按 no-data 记、分母照算)。旧行为在这里再 fail 一次 ⇒ 一处坏卷扣
        # 两次分:RCA 的 file/function 一个字母都不差也判红(<case> /
        # <case> / <case> k=1 实证)。这里只留痕,继续判 root_cause。
        print(f"[sweops] warning: 'fault_detected' is not a JSON boolean in "
              f"{DETECTION} or {DIAGNOSIS} (got {fd!r}) -- that is scored on the "
              f"detection axis; the root-cause grade below is unaffected")
    elif fd != GT["fault_detected_expected"]:
        pytest.fail(f"[sweops] fault_detected mismatch (read from {fd_src}): "
                    f"expected {GT['fault_detected_expected']}, got {fd}\n"
                    f"[sweops] evidence: {str(d.get('evidence'))[:400]}")

    rc = d.get("root_cause")
    if not isinstance(rc, dict):
        pytest.fail("[sweops] 'root_cause' must be an object when fault_detected is true")
    agent_file = str(rc.get("file") or "").strip()
    agent_fn = str(rc.get("function") or "").strip()

    if GT["file_required"]:
        if not agent_file:
            pytest.fail(f"[sweops] root_cause.file is empty; ground truth file is {GT['file']!r}")
        if GT["file"]:
            # real GT file: match against it (+ docstring extras)
            ok = _file_match(agent_file, GT["file"]) or any(
                _file_match(agent_file, f) for f in GT["files_extra"])
            if not ok:
                pytest.fail(f"[sweops] root_cause.file mismatch:\n"
                            f"  expected: {GT['file']!r}\n"
                            f"  got:      {agent_file!r}")
    if GT["function_required"]:
        if not agent_fn:
            pytest.fail(f"[sweops] root_cause.function is empty; ground truth function is {GT['function']!r}")
        ok = _function_match(agent_fn, GT["function"]) or any(
            _function_match(agent_fn, f) for f in GT["functions_extra"])
        if not ok:
            pytest.fail(f"[sweops] root_cause.function mismatch:\n"
                        f"  expected: {GT['function']!r}\n"
                        f"  got:      {agent_fn!r}")

    for key in ("evidence", "component"):
        if not d.get(key):
            print(f"[sweops] warning: diagnosis.json missing '{key}'")
    if not rc.get("mechanism"):
        print("[sweops] warning: root_cause.mechanism missing (LLM rubric field)")
    print(f"[sweops] grade OK: fault={fd} file={agent_file!r} function={agent_fn!r}")
