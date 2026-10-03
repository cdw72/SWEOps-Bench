#!/usr/bin/env python3
"""Suite PASS_TO_PASS judge: every test that was green on the unpatched pin
(tests/hidden/green.json) must still be green on the agent's patched tree."""
import json
import sys

events_path, green_path = sys.argv[1], sys.argv[2]
_green_doc = json.load(open(green_path))
green = set(_green_doc["green"])
passed = set()
recent = {}          # test -> last few output lines (bounded; failure detail feed)
_OUT_KEEP = 12
with open(events_path) as f:
    for line in f:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            e = json.loads(line)
        except Exception:
            continue
        if e.get("Test") and e.get("Action") == "pass":
            passed.add(e["Package"] + "::" + e["Test"])
        elif e.get("Test") and e.get("Action") == "output":
            tid = e["Package"] + "::" + e["Test"]
            buf = recent.setdefault(tid, [])
            buf.append(e.get("Output", ""))
            if len(buf) > _OUT_KEEP:
                del buf[:len(buf) - _OUT_KEEP]
missing = sorted(green - passed)
# 结构化出口(2026-09-18,常驻会话循环的反馈回合读它):会话中途要知道的是
# "哪些原本通过、这次不通过了",不该去解析 stderr 的散文。**只加一个文件** ——
# 退出码与 stderr 文本一字不动,六门和既有回归判官的行为完全不变。
# outputs = 新红测试的 go test 输出行(有界,前 10 个)——用户 2026-09-18
# 「给测试名字没有用吧 还是要能看到」:名字说*哪个*红,输出原文说*为什么*红。
# 旧读侧(suite_regressed)没这个键也能解析;旧包没这个键 ⇒ 反馈里只有名单。
try:
    _outputs = {}
    for _t in missing[:10]:
        _lines = [l for l in recent.get(_t, []) if l.strip()]
        if _lines:
            _outputs[_t] = _lines
    with open("/tmp/suite-regressed.json", "w") as _f:
        json.dump({"case": _green_doc.get("case"),
                   "n_green": len(green), "n_missing": len(missing),
                   "rc": 1 if missing else 0,
                   "missing": missing[:200],
                   "outputs": _outputs}, _f)
except Exception:
    pass
if missing:
    print(f"[suite] {len(missing)} baseline-green test(s) no longer pass:",
          file=sys.stderr)
    for m in missing[:40]:
        print("  FAIL " + m, file=sys.stderr)
    sys.exit(1)
print(f"[suite] all {len(green)} baseline-green tests still pass")
