#!/usr/bin/env python3
"""Diff the telemetry variants (buggy / fixed / reference) per case.

对 telemetry/<case>/{buggy,fixed,reference}/ 做结构化对比,输出:
  1. restarts     : 逐容器 restartCount(buggy 有而 fixed/reference 无的 = 故障信号)
  2. cr           : CR 状态卡住(state/phase != Ready/正常)
  3. events       : Warning/Error 事件计数差异
  4. operator.log : error/panic/warning 行数与关键词
  5. objects      : pod/sts/pvc 存在性差异(buggy 多/少什么)
  6. previous     : buggy 有崩溃日志而 fixed/reference 没有

输出:文本报告(终端)+ telemetry/<case>/diff_report.txt

用法:
  python3 diff_telemetry.py --case cassop-315
  python3 diff_telemetry.py --all
"""
import argparse
import json
import os
import re
import sys

SWEOPS = os.path.dirname(os.path.abspath(__file__))
TELEM_ROOT = os.path.join(SWEOPS, "telemetry")
VARIANTS = ("buggy", "fixed", "reference")


# ---------------------------------------------------------------- parsers
def parse_restarts(path):
    """restarts.txt -> {'ns/pod': {container: count}}

    restarts.txt 的实际格式是 "{ns} {pod} {container}={count}"(空格分隔,
    capture 的宽 jsonpath 生成),没有 "ns/pod" 斜杠形式。v1 曾误用
    parts[0].split("/")[-1] 取名 -> 把 ns 当 pod,且同 ns 的 pod 互相覆盖
    (2026-09-01 rdoptwo-297 教训:9 次重启显示成 ns 'redis-operator')。
    key 用归一化 pod 名(去 deployment hash 后缀,与 pod-status 段一致)。"""
    out = {}
    if not os.path.isfile(path):
        return out
    for line in open(path):
        parts = line.split()
        if len(parts) < 3:
            continue
        ns, pod, rest = parts[0], parts[1], parts[2:]
        counts = {}
        for tok in rest:
            tok = tok.strip("|")  # jsonpath initContainers 段的 '|' 前缀
            if "=" in tok:
                c, n = tok.split("=")
                try:
                    counts[c] = int(n)
                except ValueError:
                    pass
        if any(n > 0 for n in counts.values()):
            out[f"{ns}/{_norm_name(pod, 'pods')}"] = counts
    return out


def restart_lookup(rest, key, cont):
    """One container's restart count, tolerating a namespace rename.

    `key` is the GT target's "ns/pod" as RECORDED -- the namespace the corpus
    captured in. A sandbox env seeds into its own namespace (k8spsmdb-1154
    records "acto-namespace/test-cluster-rs0-0" but the env uses "psmdb"), and
    parse_restarts keys by "{ns}/{pod}", so an exact lookup misses and the
    caller's `.get(cont, 0)` fallback returns 0 -- the FIXED side -- for a pod
    that is visibly CrashLooping. k8spsmdb-1154 was judged VACUOUS in-sandbox
    on 2026-09-13 for exactly this, while the env probe taken two seconds
    earlier read `test-cluster-rs0-0 ... CrashLoopBackOff 4`.

    Every other namespace-bearing kind (pod_status / sts_ready / object_*)
    already strips the namespace with `t.split("/")[-1]`; restart_count was the
    only one keying the full "ns/pod". Match that: exact key wins, otherwise
    fall back to the pod name -- but only when it resolves to exactly ONE
    namespace, since two candidates means the name is genuinely ambiguous and
    the probe must not guess. Absent stays 0 (the legacy reading) so recorded
    fixed snapshots, where a no-restart pod is dropped from parse_restarts
    entirely, keep evaluating exactly as before.
    """
    hit = rest.get(key)
    if hit is not None:
        return hit.get(cont, 0)
    pod = key.split("/", 1)[1] if "/" in key else key
    cands = [v for kk, v in rest.items() if kk.split("/", 1)[-1] == pod]
    if len(cands) == 1:
        return cands[0].get(cont, 0)
    return 0


def parse_cr(path):
    """cr.txt -> {crd: [状态行]}(cr.txt 由 capture 的宽 jsonpath 生成)"""
    out = {}
    if not os.path.isfile(path):
        return out
    for line in open(path):
        if ":" in line:
            crd, rest = line.split(":", 1)
            out.setdefault(crd.strip(), []).append(rest.strip())
    return out


def parse_cr_full(dirpath):
    """cr_full/*.yaml -> 每个业务 CR 的关键状态摘要(state/phase/progress/
    conditions/rollingRestartRequested/nodeReplacements 等)。
    v2:不同 operator 的状态字段名不同(cass-operator 用
    cassandraOperatorProgress,redis 用 status.state),不能只看 state。"""
    import yaml
    d = os.path.join(dirpath, "cr_full")
    if not os.path.isdir(d):
        return {}
    SYS_CRDS = ("certificaterequests", "certificates", "issuers")
    out = {}
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".yaml"):
            continue
        crd = fn[:-5]
        if any(s in crd for s in SYS_CRDS):
            continue
        try:
            data = yaml.safe_load(open(os.path.join(d, fn)))
        except Exception:
            continue
        rows = []
        for item in data.get("items", []) if isinstance(data, dict) else []:
            spec, status = item.get("spec", {}), item.get("status", {})
            row = {
                "name": item.get("metadata", {}).get("name"),
                "state": status.get("state"),
                "phase": status.get("phase"),
                # cnpg status.phaseReason(kafkaop 同类审计 2026-09-10:摘要曾无此键,
                # <case> buggy 'Creating primary instance' vs fixed 'Instance
                # creation failed for the following jobs: ...-initdb' 是语义正中腿)
                "phase_reason": status.get("phaseReason"),
                "progress": status.get("cassandraOperatorProgress"),
                "ready": status.get("ready"),
                "conditions": [c.get("type") or c.get("reason")
                               for c in status.get("conditions", [])][:6],
                "rollingRestartRequested": spec.get("rollingRestartRequested"),
                "nodeReplacements": status.get("nodeReplacements"),
                # rook CephCluster.status.ceph(<case> #<issue>:fixed 归 0
                # wanted→details 无 MDS_INSUFFICIENT_STANDBY;buggy 恒在。
                # details 只在告警键 message 非空时列(2026-09-08)
                "ceph_health": status.get("ceph", {}).get("health"),
                "ceph_details": [k for k, v in (status.get("ceph", {})
                                                .get("details", {}) or {}).items()
                                 if v],
                # strimzi KafkaConnector.status.connectorStatus.connector.state
                # (<case>:buggy FAILED[status 内嵌 PatternSyntaxException 栈]/
                # fixed STOPPED;2026-09-10 盲点审计:9 键摘要看不见 operator 特有
                # 状态结构,connectorStatus 一直在 raw 里但从未入摘要)
                "connector_state": ((status.get("connectorStatus") or {})
                                    .get("connector") or {}).get("state"),
            }
            rows.append({k: v for k, v in row.items() if v not in (None, [], "")})
        if rows:
            out[crd] = rows
    return out


def log_stats(path):
    """operator.log -> {error/panic/warning 行数, 关键词计数}"""
    if not os.path.isfile(path):
        return {}
    stats = {"error_lines": 0, "panic_lines": 0, "warning_lines": 0}
    kw = {}
    for line in open(path, errors="ignore"):
        low = line.lower()
        if "panic" in low:
            stats["panic_lines"] += 1
        elif "error" in low:
            stats["error_lines"] += 1
        elif "warn" in low:
            stats["warning_lines"] += 1
        m = re.search(r'level=(\w+)', line)
        if m:
            kw[m.group(1)] = kw.get(m.group(1), 0) + 1
    stats["levels"] = kw
    return stats


# ---- 消息签名挖掘(v5,2026-09-02) ----
# 计数维(行数/行比例)把"特定错误串出现"这类判别淹掉:<case> 的 RV bug
# 串(does not match current version)buggy=28/fixed=0,混在共有噪音(no matching
# instances 28 vs 26)里,error_lines 只显示 62 vs 32 -> 被判"弱"。而错误消息本身
# (error 字段值)是干净的判别载体。归一化只替换可变 token,保留语义串。
def norm_msg(s):
    """错误消息归一化:可变 token -> 占位符,只留语义(跨变体比较的键)。"""
    s = s.replace('\\"', "'")
    s = re.sub(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "<uuid>", s)
    s = re.sub(r"\b[0-9a-f]{8,}\b", "<hex>", s)
    s = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b", "<ip>", s)
    s = re.sub(r"\b[a-z0-9][a-z0-9-]*\.(?:svc|cluster\.local)\b", "<dns>", s)
    # 2026-09-07:deployment RS-hash+pod-hash 序列(<case> 教训:同一
    # BackOff 事件两边各 3 条,消息含 pod hash -> 集合差误报"buggy 独有")
    s = re.sub(r"(-[0-9a-z]{4,10})-[0-9a-z]{5}\b", r"\1-<podhash>", s)
    s = re.sub(r"[\s\t]+", " ", s).strip()
    return s


def log_error_values_text(text):
    """zap 文本 -> 归一化后的 "error": 字段值序列(带重复)。

    2026-09-10(静默案重分类):从 log_error_values 拆出,使调用方能传入
    operator.log + previous_logs 的拼接文本 —— 崩溃类 case(knop-1137 的
    panic)主日志翻页后为空,error 字段只在 --previous 里,旧实现扫不到。"""
    vals = []
    for line in text.splitlines():
        m = re.search(r'"error":\s*"((?:[^"\\]|\\.)*)"', line)
        if m:
            vals.append(norm_msg(m.group(1)))
    return vals


def log_error_values(path):
    """operator.log(zap 文本行)-> 归一化后的 "error": 字段值序列(带重复)。
    kube-controller-manager 误抓日志(controllermanager.go 前缀)整份跳过。"""
    if not os.path.isfile(path):
        return []
    with open(path, errors="ignore") as f:
        head = f.read(4000)
    if "controllermanager.go" in head:
        return []  # 抓错 pod(kube-controller-manager)的整份日志跳过
    return log_error_values_text(open(path, errors="ignore").read())


# 故障特征模式(容器日志自动挖掘用;计数差异 = 候选信号)
FAULT_PATTERNS = (
    "panic", "fatal", "misconf", "no space left", "oom",
    "crashloop", "back-off", "connection refused", "failed",
    "error",
)


def container_log_stats(dirpath):
    """container_logs/ -> {归一化pod: {pattern: 行数}}(v4 采集;
    280 的 redis "Write error saving DB" 类信号在这里)。
    2026-09-02 修:文件名 <pod>-<container>.log 用 rsplit 只剥一段,容器名
    自带横杠时(knative-operator)残留尾巴 -> _norm_name 的 hash 正则失配,
    deploy pod 跨变体不聚合(20v0+0v20 镜像假候选,knop-1158 教训)。
    改为从 pods.txt 取真实 pod 名做最长前缀匹配。"""
    d = os.path.join(dirpath, "container_logs")
    out = {}
    if not os.path.isdir(d):
        return out
    pods = set()
    pt = os.path.join(dirpath, "pods.txt")
    if os.path.isfile(pt):
        for line in open(pt, errors="ignore").read().splitlines()[1:]:
            c = line.split()
            if len(c) > 1:
                pods.add(c[1])
    for fn in os.listdir(d):
        if not fn.endswith(".log"):
            continue
        stem = fn[:-4]
        pod = None
        if pods:
            # 最长前缀匹配:<pod>-<container>(pod 名本身可含横杠)
            cand = sorted((p for p in pods if stem.startswith(p + "-")),
                          key=len, reverse=True)
            if cand:
                pod = cand[0]
        if pod is None:
            # 兜底2(2026-09-06 <case> 教训):pods.txt 里没有该 pod
            # (deployment 滚动后旧 pod 的日志文件仍在)时,用 RS-hash 模式切
            # <pod>-<container>;容器名自带横杠(cassandra-operator)时 rsplit
            # 只剥一段会让 pod 键残留尾巴 -> 归一失配 -> 跨变体镜像伪判据
            # (buggy=fail N/fixed=0 + buggy=0/fixed=M 成对出现)。
            m = re.match(r"^(.*-[0-9a-z]{4,10}-[0-9a-z]{5})-.+", stem)
            pod = m.group(1) if m else fn.rsplit("-", 1)[0]  # 无 pods.txt 的旧采集
        key = _norm_name(pod, "pods")
        stats = out.setdefault(key, {p: 0 for p in FAULT_PATTERNS})
        for line in open(os.path.join(d, fn), errors="ignore"):
            low = line.lower()
            for pat in FAULT_PATTERNS:
                if pat in low:
                    stats[pat] += 1
    return out


# 容器日志消息级挖掘(2026-09-10,静默案重分类):14 案的最强判别串活在
# 业务容器日志里(<case> 的 pg_basebackup "directory ... not empty"、
# <case> 的 mongo-agent "(BadValue) Invalid command argument"、
# <case> 的 mongod "Heartbeat failed"),而 §8 的 FAULT_PATTERNS 只给
# 子串计数、§13a 只读 operator.log 的 error 字段 -> 消息本体在 diff 层隐身。
CLOG_JSON_KEYS = ("msg", "error", "message", "MESSAGE")
# 纯结构/心跳样板行:两侧共有会互相抵消,显式滤掉避免候选爆炸
CLOG_NOISE = (
    "healthz", "readyz", "started", "starting", "shutdown", "received signal",
    "graceful", "leader election", "leader-elected mode",
    "created successfully", "kube-api-access",
)
# 判定"值得挖"的词干(纯 INFO 的常规进度行不挖;severity 不作门 ——
# <case> 的 mongod 严重级是 "s":"I",按级别筛会漏)
CLOG_HINTS = ("error", "fail", "panic", "fatal", "refused", "forbidden",
              "invalid", "unable", "not found", "timed out", "timeout",
              "denied", "conflict", "unreachable", "crash", "not empty",
              "not ready", "mismatch", "duplicate", "missing")
# 良性 JSON 消息(不带 CLOG_HINTS 但纯健康语义):JSON 分支不看词干,
# 这些只因 buggy 侧 pod 活得久/重启多而"独有"(<case> 的
# "ReplicaSetMonitor ping success")。false-success 类签名不在此列 ——
# 那是 operator.log 的 CASE_SIG 职责(<case>)。
CLOG_BENIGN = ("ping success", "is ready", "is healthy", "healthy",
               "completed successfully", "no error", "up and running")
# 集群基建 addon(文件名不含 ns,只能按名字滤;见 _scan_clog_dir)
CLOG_INFRA = ("kindnet", "kube-proxy", "kube-apiserver", "kube-controller",
              "kube-scheduler", "coredns", "calico", "cilium", "flannel",
              "local-path", "metrics-server")


def norm_clog(s):
    """容器日志消息归一化:剥 klog/时间戳/文件行号/pod 名等前缀。

    2026-09-10 实证:不做这一步,同一签名每行因前缀不同而成为唯一 key,
    计数恒 1 -> 过不了 buggy>=2 门。两类实测格式:
      klog  `E0902 05:25:37.009509  1 reflector.go:227] "Failed to watch" ...`
      agent `[2026-09-03T01:40:32.212+0000] [.error] [file:fn:41] <pod>
             [01:40:32.212] Error running ...`
    """
    s = s.replace('\\"', "'")
    for _ in range(4):
        s2 = re.sub(r"^\s*(\[[^\]]*\]|[EIWF]\d{4}\s+[\d:.]+\s+\d+\s+\S+\])\s*", "", s)
        if s2 == s:
            break
        s = s2
    s = re.sub(r"\[[0-9]{4}-[0-9-]+T[^\]]*\]\s*", "", s)
    s = re.sub(r"<[A-Za-z0-9._-]+>\s*", "", s)
    s = re.sub(r"\[\d\d:\d\d:\d\d\.\d+\]\s*", "", s)
    s = re.sub(r"\b\d{4}-\d\d-\d\dT[\d:.]+Z?\b", "", s)
    # 2026-09-10(候选口径审计):此前只剥 ISO(`2026-09-07T...`),漏了两种实测格式
    # —— 同一条消息仅因时间戳不同就被切成"buggy 独有"候选:
    #   ① go log 默认 `2026/09/07 08:46:22`(k8ssandra-client-80-0 的 gocql 串)
    #   ② redis/sentinel `09 Sep 2026 16:49:35.504`(<case> 的 FAIL 串)
    # 这两条候选追到原文后两侧其实是同一条消息(fixed 只是时间戳不同)。
    # 一并补 syslog 式 `Sep  7 08:46:22` 与逗号毫秒/时区后缀。
    s = re.sub(r"\b\d{4}[-/]\d\d[-/]\d\d[ T]\d\d:\d\d:\d\d(?:[.,]\d+)?"
               r"(?:Z|[+-]\d\d:?\d\d)?\b", "", s)
    s = re.sub(r"\b\d{1,2} [A-Z][a-z]{2} \d{4} \d\d:\d\d:\d\d(?:[.,]\d+)?\b", "", s)
    s = re.sub(r"\b[A-Z][a-z]{2} +\d{1,2} \d\d:\d\d:\d\d(?:[.,]\d+)?\b", "", s)
    # redis 行首角色/级别标记(`1:M 09 Sep ... * FAIL ...` -> `FAIL ...`)
    s = re.sub(r"^\s*\d+:[MSXC]\s+", "", s)
    s = re.sub(r"^\s*[-*#.]\s+", "", s)
    s = re.sub(r"\s{2,}", " ", s).strip()
    out = norm_msg(s)
    # 2026-09-10:norm_msg 的 hex 正则只吃小写 `[0-9a-f]{8,}`,而 mongo agent
    # 的 $clusterTime 里是**大写** signature hash(BinData(0, DE4112A7...))
    # 与随机 Timestamp -> 每条消息 key 唯一、计数恒 1(<case> 的
    # (BadValue) 串 32 行因此挖不出)。补大写 hex 与 Timestamp 变参。
    out = re.sub(r"\b[0-9A-Fa-f]{8,}\b", "<hex>", out)
    out = re.sub(r"Timestamp\(<hex>,\s*\d+\)", "Timestamp(<hex>)", out)
    return out


def _clog_msgs(line):
    """容器日志行 -> 归一化消息列表(JSON 行的 msg/error/message 字段,否则整行)。

    2026-09-10:JSON 行取**全部**命中字段而非第一个 —— zap 里 msg 常是泛化
    结论("Unable to create job"),判别细节在 error 字段(cnpgop-9972 的
    `Duplicate value: "pgdata"` 因此在旧实现下被吞掉)。"""
    line = line.strip()
    if not line:
        return ()
    if line.startswith("{"):
        try:
            d = json.loads(line)
        except Exception:
            d = None
        if isinstance(d, dict):
            return tuple(norm_clog(v) for k in CLOG_JSON_KEYS
                         for v in [d.get(k)]
                         if isinstance(v, str) and len(v) >= 15
                         and not any(b in v.lower() for b in CLOG_BENIGN))
        return ()
    low = line.lower()
    if any(t in low for t in CLOG_HINTS):
        return (norm_clog(line),)
    return ()


def _pod_key(stem, pods, prefix=""):
    """日志文件名 -> 归一化 pod key(pods.txt 最长前缀,兜底切 hash 后缀)。"""
    pod = None
    if pods:
        cand = sorted((p for p in pods if stem.startswith(p + "-")),
                      key=len, reverse=True)
        if cand:
            pod = cand[0]
    if pod is None:
        m = re.match(r"^(.*-[0-9a-z]{4,10}-[0-9a-z]{5})-.+", stem)
        pod = m.group(1) if m else stem
    # job pod 的单段随机后缀(pgbasebackup 三兄弟 drg2w/j6qj9/vs4gq)归一
    return prefix + _norm_name(re.sub(r"-[a-z0-9]{5}$", "", pod), "pods")


def _pod_in_snapshot(stem, pods):
    """文件名 stem 是否归属 pods.txt 快照里的某个 pod(前缀匹配,最长优先)。"""
    if not pods:
        return None                      # 无快照 -> 无法判定,不丢
    return any(stem == p or stem.startswith(p + "-") for p in pods)


# 幽灵文件过滤开关(2026-09-10)。采集侧(collect_telemetry.py)抓 container_logs
# 前不清理目录,重采时上一次的文件留下;pod 名带 rollout hash,新一次名字不同 ->
# 旧文件不被覆盖。实测 213 文件 / 33 案。它**双向**伤人:fixed 侧多出的日志会造
# fixed-only 假信号,也会把 buggy-only 真信号淹掉(§13c 要求 fixed=0)。
# diff 侧按"归属 pod 不在本变体 pods.txt"过滤是采集修好之前唯一防线。
# 设 SWEOPS_KEEP_GHOST_CLOG=1 可关掉(排查用)。
FILTER_GHOST_CLOG = os.environ.get("SWEOPS_KEEP_GHOST_CLOG") != "1"
_GHOST_DROPPED = {}

# 第二条幽灵规则:按 mtime 陈旧度(2026-09-10 补)。第一条(名字不在 pods.txt)
# 只抓得到"同 RS 内换了 rollout hash"的残留;pod 名稳定的(bare `sts-0`/`cfg-0`
# mongod、StatefulSet 成员)重采后名字不变,**旧文件被新文件覆盖不掉也认不出**。
# 实测名字规则 217 个文件 mtime 全离群,是 mtime 规则 242 个的**真子集**;
# mtime 规则多抓的 25 个全是 previous_logs/(同 pod 但来自很多轮之前的一次采集)。
# 实例:<case> buggy 的三条 mongod/mongos "Cannot read certificate file /
# Error during global initialization" 崩溃日志,实际是 08-31 的,而该变体采集于
# 09-09 —— 差点被当成 buggy 侧真信号。参考时点取变体目录顶层文件(采集那刻写的)
# 的 max mtime。阈值可用 SWEOPS_CLOG_STALE_HOURS 调(默认 6h;一次采集窗是分钟级)。
CLOG_STALE_HOURS = float(os.environ.get("SWEOPS_CLOG_STALE_HOURS", "6"))


def _variant_capture_mtime(dirpath):
    """变体采集时点 ≈ 顶层文件的 max mtime(operator.log/pods.txt/events.txt/
    meta.json 都在采集那一刻写);日志子目录不参与,避免自我参照。"""
    try:
        mt = [os.path.getmtime(os.path.join(dirpath, fn))
              for fn in os.listdir(dirpath)
              if os.path.isfile(os.path.join(dirpath, fn))]
    except OSError:
        return None
    return max(mt) if mt else None


def _scan_clog_dir(d, pods, out, prefix="", ref=None):
    for fn in os.listdir(d):
        if not fn.endswith(".log"):
            continue
        if FILTER_GHOST_CLOG:
            m = _pod_in_snapshot(fn[:-4], pods)
            if m is False:
                _GHOST_DROPPED.setdefault(d, []).append(fn)
                continue
            if ref and (ref - os.path.getmtime(os.path.join(d, fn))) \
                    > CLOG_STALE_HOURS * 3600:
                _GHOST_DROPPED.setdefault(d, []).append(fn + " [stale]")
                continue
        key = _pod_key(fn[:-4], pods, prefix)
        # 集群基建 pod 的日志文件不含 ns 信息(文件名只有 pod),collector 会
        # 把它们的崩溃日志一并抓进 previous_logs —— 2026-09-10 实证
        # <case>:kindnet 的 "Failed to reconcile routes: invalid CIDR"
        # 造出一条假 buggy-only 信号(真静默案被误判)。按名字滤掉。
        if any(t in key.lower() for t in CLOG_INFRA):
            continue
        msgs = out.setdefault(key, {})
        for line in open(os.path.join(d, fn), errors="ignore"):
            for msg in _clog_msgs(line):
                if len(msg) < 15:
                    continue
                if any(t in msg.lower() for t in CLOG_NOISE):
                    continue
                msgs[msg] = msgs.get(msg, 0) + 1


_CLOG_CACHE = {}


def container_log_msgs(dirpath):
    """container_logs/ + previous_logs/ -> {pod key: {归一化消息: 计数}}(v6)。

    2026-09-10(静默案重分类):previous_logs/ 一并纳入 —— 崩溃重启前的
    operator 容器日志(panic 栈)只在这里(knop-1137 的 nil-deref panic,
    主日志翻页后为空),旧实现只挖 container_logs/ 挖不到。job pod 的单段
    随机后缀归一到同一 key,否则同一签名被拆成 3 条候选。

    结果进程内缓存:报告层与 collect_signals 各调一次,容器日志解析是
    全量跑的主要开销(单次 --all 解析两遍)。"""
    if dirpath in _CLOG_CACHE:
        return _CLOG_CACHE[dirpath]
    out = {}
    pods = set()
    pt = os.path.join(dirpath, "pods.txt")
    if os.path.isfile(pt):
        for line in open(pt, errors="ignore").read().splitlines()[1:]:
            c = line.split()
            if len(c) > 1:
                pods.add(c[1])
    ref = _variant_capture_mtime(dirpath) if FILTER_GHOST_CLOG else None
    for sub, pfx in (("container_logs", ""), ("previous_logs", "prev:")):
        d = os.path.join(dirpath, sub)
        if os.path.isdir(d):
            _scan_clog_dir(d, pods, out, pfx, ref)
    _CLOG_CACHE[dirpath] = out
    return out


def clog_sig_candidates(cm, have, cap=8, min_count=2, min_len=25):
    """{variant: {pod: {msg: n}}} -> ([(count, msg)], 跨变体聚合计数)。

    buggy-only 归一化消息(n>=min_count,fixed 为 0),按计数降序取 cap 条;
    被外层长串包含的重复候选跳过(留原子短签名)。

    2026-09-11 盲点审计(132 腿逐条对候选,8 条挖不出)修三处:
      ① **reference 硬门删除**:旧版要求 reference 也为 0 —— reference 是 pin
        基线(同故障代码),真故障族必然也在 reference(mgoptwo-895 实证:
        'Unable to reach primary' buggy 33/fixed 0/reference 118,候选=0)。
        oracle 语义(recheck)只看 buggy vs fixed,候选门与之对齐;reference
        计数进返回值供人工参考。
      ② **错误类单次族补扫**:min_count=2 会吞单次关键行 —— knop-1137 的
        panic(prev log 单 pod 1 条)、sparkop-2807 的 panic 块因残余 goroutine
        id 散成 8 个 count=1 族。对含 panic/error/failed/forbidden 等关键词
        的族降为 min_count=1(单独 5 条额度)。人工子串锚本来就能匹配散族,
        候选层也必须给单次错误族留位。
      ③ 截断在调用侧修(m[:70] -> m[:200]),锚在消息尾部的候选不再失明。"""
    agg = {}
    for v in have:
        c = {}
        for pod, msgs in cm.get(v, {}).items():
            for m, n in msgs.items():
                c[m] = c.get(m, 0) + n
        agg[v] = c
    ERRISH = re.compile(r"panic|error|failed|forbidden|refused|denied|"
                        r"fatal|timeout|not found|no such", re.I)
    cands, single_errs = [], []
    for m, n in agg.get("buggy", {}).items():
        if agg.get("fixed", {}).get(m) or len(m) < min_len:
            continue
        if n >= min_count:
            cands.append((n, m))
        elif n == 1 and ERRISH.search(m):
            single_errs.append((n, m))
    cands.sort(key=lambda x: (-x[0], len(x[1])))
    single_errs.sort(key=lambda x: len(x[1]))
    kept = []
    for n, m in cands + single_errs[:8]:
        if any(m2 in m for _, m2 in kept):
            continue
        kept.append((n, m))
        if len(kept) >= cap + 8:
            break
    return kept, agg


# events 消息文本挖掘(2026-09-02):Warning/InternalError 的消息体差异
# 是一大类真信号的载体(<case> 的 RBAC InternalError、292 的 Liveness
# probe failed),计数维度挖不到。只看业务 ns,基建噪音全滤。
EVENT_NOISE_NS = {"kube-system", "local-path-storage",
                  "sweops-observability"}
EVENT_NOISE_MSG = ("30090", "horizontalpodautoscaler", "no metrics",
                   "desired replica", "FailedScheduling")


def event_msgs(path):
    """events.txt -> {(reason, 归一化消息)} 集合(业务 ns 的 Warning 类)。"""
    if not os.path.isfile(path):
        return set()
    msgs = set()
    for line in open(path, errors="ignore"):
        parts = line.split(None, 5)
        if len(parts) < 6 or parts[2] not in ("Warning", "InternalError"):
            continue
        ns, reason, msg = parts[0], parts[3], parts[5]
        if ns in EVENT_NOISE_NS or reason == "FailedScheduling":
            continue
        if any(t in msg for t in EVENT_NOISE_MSG):
            continue
        msg = re.sub(r"-[0-9a-z]{9,10}(-[0-9a-z]{5})?\b", "-HASH", msg)
        msg = re.sub(r"acto-\d+-cluster-0", "CLUSTER", msg)
        msg = re.sub(r"10\.244\.\d+\.\d+", "IP", msg)
        msg = re.sub(r"\d+(\.\d+)?(s|m|h|ms)\b", "AGE", msg)
        msg = re.sub(r"\b\d+\b", "N", msg)
        msgs.add((reason, msg[:200]))
    return msgs


def last_state_stats(path):
    """pods.json -> {归一化pod: {oom: n, exit137: n, last_reason: str}}
    (v4;#290 的 OOMKilled 证据在 containerStatuses[].lastState)。"""
    import json as _j
    out = {}
    if not os.path.isfile(path):
        return out
    try:
        data = _j.loads(open(path).read())
    except Exception:
        return out
    for it in data.get("items", []):
        pod = _norm_name(it["metadata"]["name"], "pods")
        st = {"oom": 0, "exit137": 0, "last_reason": ""}
        for cs in it.get("status", {}).get("containerStatuses", []) or []:
            term = (cs.get("lastState") or {}).get("terminated") or {}
            if term.get("reason"):
                st["last_reason"] = term.get("reason")
            if term.get("reason") == "OOMKilled":
                st["oom"] += 1
            if str(term.get("exitCode")) == "137":
                st["exit137"] += 1
        if st["oom"] or st["exit137"] or st["last_reason"]:
            out[pod] = st
    return out


def sts_template_stats(dirpath):
    """obj_full/sts.yaml -> {sts名: {vct: 容量, ann: 注解}}(v4;
    280 的 template VCT 漂移 + 696 的注解卡死)。"""
    import yaml as _y
    f = os.path.join(dirpath, "obj_full", "sts.yaml")
    out = {}
    if not os.path.isfile(f):
        return out
    try:
        data = _y.safe_load(open(f))
    except Exception:
        return out
    for it in (data or {}).get("items", []) or []:
        name = _norm_name(it["metadata"]["name"], "sts")
        vcts = []
        for v in (it.get("spec", {}).get("volumeClaimTemplates") or []):
            req = ((v.get("spec") or {}).get("resources") or {}).get("requests") or {}
            vcts.append(f"{v['metadata']['name']}={req.get('storage','?')}")
        ann = (it.get("spec", {}).get("template", {}).get("metadata") or {}).get("annotations") or {}
        limits = []
        for c in (it.get("spec", {}).get("template", {}).get("spec", {}).get("containers") or []):
            lm = ((c.get("resources") or {}).get("limits") or {})
            limits.append(f"{c['name']}:{lm.get('memory','-')}")
        out[name] = {"vct": " ".join(vcts), "ann_has_actokey": "ACTOKEY" in json.dumps(ann),
                     "limits": " ".join(limits)}
    return out


def rbac_stats(dirpath):
    """rbac/*.yaml -> {对象数, rules 总数, 名字hash}(v4;1158 RBAC escalation)"""
    import yaml as _y
    d = os.path.join(dirpath, "rbac")
    out = {}
    if not os.path.isdir(d):
        return out
    for res in ("roles", "clusterroles", "rolebindings", "clusterrolebindings"):
        f = os.path.join(d, f"{res}.yaml")
        if not os.path.isfile(f):
            continue
        try:
            data = _y.safe_load(open(f))
        except Exception:
            continue
        items = (data or {}).get("items") or []
        n_rules = sum(len(it.get("rules") or []) for it in items)
        out[res] = {"n": len(items), "rules": n_rules}
    return out


def event_counts(path):
    """events.txt -> {warning: n, error: n, total: n}"""
    if not os.path.isfile(path):
        return {}
    w = e = t = 0
    for line in open(path, errors="ignore"):
        t += 1
        low = line.lower()
        if "warning" in low:
            w += 1
        elif "error" in low or "failed" in low:
            e += 1
    return {"total": t, "warning": w, "error_or_failed": e}


def _norm_name(name, res):
    """对象名归一化(去 pod hash 后缀/集群名),供跨变体对比。"""
    import re
    if res == "pods":
        # {4,10}:rs hash 长度 4-10 均有(<case> 768fd79=7、psmdb cbfd=4);
        # 只影响候选展示名/探针 key 归一,sts pod 数字序号不受影响
        name = re.sub(r"-[0-9a-z]{4,10}-[0-9a-z]{5}$", "", name)
    name = re.sub(r"acto-\d+-cluster-0", "CLUSTER", name)
    return name


def variant_log_text(vdir):
    """operator.log 全文 + previous_logs/ 全部崩溃日志拼接。

    pod 崩溃重启后 panic 翻页进 --previous,operator.log 现卷可能已无
    panic(cassop-705 / k8spsmdb-434 实证:buggy previous_logs 有 3 份
    nil-deref 崩溃日志、现卷 0 行)。log_sig 计数与 recheck 都须用本函数,
    否则判据现值被低估成"未触发"。"""
    parts = []
    p = os.path.join(vdir, "operator.log")
    if os.path.isfile(p):
        parts.append(open(p, errors="ignore").read())
    d = os.path.join(vdir, "previous_logs")
    if os.path.isdir(d):
        for fn in sorted(os.listdir(d)):
            fp = os.path.join(d, fn)
            if os.path.isfile(fp):
                parts.append(open(fp, errors="ignore").read())
    return "\n".join(parts)


def parse_pvc_capacity(path):
    """pvc.txt -> {归一化名: 容量}(VOLUME 列后的 CAPACITY;#280 类
    'CR 512Mi vs PVC 128Mi' 漂移信号,v4 补)。"""
    out = {}
    if not os.path.isfile(path):
        return out
    for line in open(path, errors="ignore"):
        parts = line.split()
        if len(parts) < 5 or parts[0] == "NAMESPACE" or parts[0].startswith("No resources"):
            continue
        if parts[0] in ("kube-system", "local-path-storage", "sweops-observability"):
            continue
        # NAME STATUS VOLUME CAPACITY ...:容量是第 4 列(0-idx),值形如 128Mi/1Gi
        if len(parts) > 4 and re.match(r"^\d+[MiGi]+$", parts[4]):
            out[_norm_name(parts[1], "pvc")] = parts[4]
    return out


def parse_sts_ready(path):
    """sts.txt -> {归一化名: 'x/y'}(READY 列;rdoptwo-480 leader 2/3 这类信号)。"""
    if not os.path.isfile(path):
        return {}
    out = {}
    for line in open(path, errors="ignore"):
        parts = line.split()
        if len(parts) < 4 or parts[0] == "NAMESPACE" or parts[0].startswith("No resources"):
            continue
        if parts[0] in ("kube-system", "local-path-storage", "sweops-observability"):
            continue
        out[_norm_name(parts[1], "sts")] = parts[2]
    return out


def parse_pod_status(path):
    """pods.txt -> {归一化名: (READY, STATUS)}(CrashLoopBackOff/Pending 等)。"""
    if not os.path.isfile(path):
        return {}
    out = {}
    for line in open(path, errors="ignore"):
        parts = line.split()
        if len(parts) < 5 or parts[0] == "NAMESPACE" or parts[0].startswith("No resources"):
            continue
        if parts[0] in ("kube-system", "local-path-storage", "sweops-observability"):
            continue
        out[_norm_name(parts[1], "pods")] = (parts[2], parts[3])
    return out


def object_names(path, res):
    """pods.txt/sts.txt/pvc.txt -> 归一化对象名集合。

    归一化:去掉 Deployment 生成的 pod 随机后缀(controller-manager-75c76dbb44-24k5b
    -> controller-manager)、去掉 kind 集群名前缀(etcd-acto-91-cluster-0-control-plane
    -> etcd-cp)、排除系统组件(kube-system/证书 infra)。三变体在不同 ns/集群,
    不归一化则全是噪音(2026-08-30 v2 教训)。"""
    import re
    if not os.path.isfile(path):
        return set()
    SYS_NS = ("kube-system", "local-path-storage", "sweops-observability")
    names = set()
    for line in open(path, errors="ignore"):
        parts = line.split()
        if len(parts) < 2:
            continue
        if parts[0] == "NAMESPACE" or parts[0].startswith("No resources"):
            continue
        ns, name = parts[0], parts[1]
        if ns in SYS_NS:
            continue
        # 去掉 pod 名的 replicaset-hash + pod-hash 后缀(仅 pods)
        if res == "pods":
            name = re.sub(r"-[0-9a-z]{9,10}-[0-9a-z]{5}$", "", name)
            name = re.sub(r"-[0-9a-z]{10}$", "", name)  # sts ordinal 前的 hash 段
        if res == "secrets":
            # 2026-09-08(diff objects 加 secrets 维度,配 <case> v3 判据):
            # SA token 自动 secret 名带随机后缀,跨变体必不同 -> 纯噪音,归一掉
            if len(parts) >= 3 and parts[2] == "kubernetes.io/service-account-token":
                continue
            name = re.sub(r"-token-[0-9a-z]+$", "", name)
        # 去掉集群名(不同变体的 kind 集群名不同)
        name = re.sub(r"acto-\d+-cluster-0", "CLUSTER", name)
        names.add(f"{ns}/{name}")
    return names


def previous_logs(dirpath):
    """previous_logs/ -> 崩溃日志文件名集合"""
    d = os.path.join(dirpath, "previous_logs")
    if not os.path.isdir(d):
        return set()
    return set(os.listdir(d)) - {"README"}


def fixed_health(base):
    """fixed 变体健康度:operator Running 且业务负载非空。

    srcfix 镜像运行时不起作用的 case(283/286/292/918/897/1155:
    operator Error/僵尸/不 reconcile/起集群失败),其 fixed 快照不是
    修复态,signals 会被污染 -> quarantined,不能当 oracle。"""
    p = os.path.join(base, "fixed", "pods.txt")
    if not os.path.isfile(p):
        return "missing"
    SYS = ("kube-system", "kube-public", "local-path-storage", "sweops-observability")
    opname = lambda x: any(k in x[1].lower() for k in ("operator", "controller", "manager"))
    ops, biz = [], []
    for line in open(p, errors="ignore"):
        x = line.split()
        if len(x) < 5 or x[0] == "NAMESPACE" or x[0].startswith("No resources"):
            continue
        if x[0] in SYS:
            continue
        (ops if opname(x) else biz).append(x)
    wl = biz
    pb = os.path.join(base, "buggy", "pods.txt")
    n_buggy_wl = 0
    if os.path.isfile(pb):
        for line in open(pb, errors="ignore"):
            x = line.split()
            if len(x) >= 5 and x[0] not in SYS and x[0] != "NAMESPACE":
                if not opname(x):
                    n_buggy_wl += 1
    # operator 健康 = 任一 operator pod Running(2026-09-07 修:弃"首个 operator
    # 行",<case> 换镜像残留的 Terminating 老 pod 曾误报 fh=operator Terminating,
    # 实际有健康 Running pod 在后)。
    if ops and not any(x[3] == "Running" for x in ops):
        return "operator " + "/".join(sorted({x[3] for x in ops}))
    # fix-语义=拒绝类豁免(2026-09-06 <case> 实证):#<issue> fix 就是
    # "校验拒绝" -- remoteWrite azureAd.workloadIdentity + Prometheus < v3.7.0
    # 时 reconciliation 报清晰错误、不建 sts,fixed 侧"无工作负载"是修复
    # 设计而非伪快照(fixed operator.log 实测有 'requires Prometheus >=
    # v3.7.0' + CR Reconciled=False)。签名命中才放行,防真·部署失败混入。
    case = os.path.basename(base)
    FH_FIX_REJECT = {
        "promop-8326": ["azureAD.workloadIdentity requires Prometheus"],
        # <case>(2026-09-08):#<issue> fix 的语义 = initdb job 失败后
        # 置 PhaseUnrecoverable(需人工介入)而非死等。fixed 侧唯一业务
        # pod 是 Error 态的 initdb job pod(fh 会误判 workload Error),
        # 出现 PhaseUnrecoverable 即为正确修复态。
        "cnpgop-11042": ["Cluster is unrecoverable and needs manual intervention"],
        # <case>(2026-09-08):#<issue> fix 的语义 = 错误路径里清 finalizer,
        # 让配置非法的 CR 能被删除。fixed 侧 trigger 删集群后 CR 全无是修复态
        # (工作负载被 k8s 回收),operator.log 的 mmapv1 拒收串证明 gen1 非法
        # 选项 + 删除流程真实发生过,非部署失败。
        "mgoptwo-897": ["mmapv1 storage engine is not supported"],
    }
    if case in FH_FIX_REJECT:
        blob = ""
        for f in ("fixed/operator.log", "fixed/cr.txt"):
            fp = os.path.join(base, f)
            if os.path.isfile(fp):
                blob += open(fp, errors="ignore").read()
        if any(s in blob for s in FH_FIX_REJECT[case]):
            return "ok"
    # workload 健康 = 有业务 pod 且任一 Running(2026-09-07 修:此前只看"有
    # workload 行"不看状态 → <case>/430 式 fixed zk-0 Pending/起不来被 fh=ok
    # 空真放行,伪"采集完整待注册"。Pending/ContainerCreating/ImagePullBackOff
    # 无 Running = 非修复态,拒。
    # CrashLoopBackOff 豁免(2026-09-07):fixed 侧业务 pod 全 CrashLoopBackOff
    # 且 operator 判据已被 CASE_CONFIRM 人工证实时,CrashLoop 是环境/删除残留
    # (<case> 驱动缺 SparkConnectServer jars、<case> pgbouncer 随
    # Cluster 删除、<case> 采集质量存疑项),not 非修复态。
    if wl:
        st = {x[3] for x in wl}
        if "Running" not in st and "CrashLoopBackOff" not in st:
            return "workload " + "/".join(sorted(st))
    elif n_buggy_wl > 0:
        return "workload empty"
    # 业务 CR 终态也要健康:operator Running 但 CR Failed/Error 同样是
    # 非修复态(<case> / <case> 教训:fixed CR phase=Failed
    # 却因 operator Running 漏过健康表)。
    # 例外(<case>,2026-09-01):#<issue> fix 的语义就是"校验 TLS CA 引用
    # 拒绝不合法 CR" -- seed CR 缺 CA ref,修复后 CR Failed 是预期行为
    # (operator 不再崩),不是 srcfix 问题。
    crf = os.path.join(base, "fixed", "cr.txt")
    # <case>(2026-09-08 加入):#<issue> fix 后 modes:[] 被 scram 校验
    # 干净拒绝(CR Failed 是预期拒绝态,operator 不再 panic),同 1054 语义
    if os.path.isfile(crf) and os.path.basename(base) not in ("mgopone-1054",
                                                              "mgopone-1055"):
        for line in open(crf, errors="ignore"):
            # IGNORECASE(2026-09-06):psmdb CR state 用小写 error,
            # <case> fixed state=error 曾被漏判 fh=ok
            if re.search(r"state=(Failed|Error)|phase=(Failed|Error)", line,
                         re.IGNORECASE):
                m = re.search(r"state=(\w+)|phase=(\w+)", line)
                return f"cr {m.group(1) or m.group(2)}"
    return "ok"


# 人工确认的最终判据(case -> [核心信号])。
# 自动挖掘只出"候选"(差异清单,含反向噪音/重复衍生物/seed 噪音);
# 每条 case 的核心判据由人工逐条确认后写在这里,确认过的才是
# repair 行为分的 oracle(confirmed=true)。判定规则:
#   match_fixed : agent 集群上该探针的值 == fixed 侧 = 修好
#   count_zero  : agent 集群上计数为 0 = 修好
#   absent      : 该对象不存在 = 修好
# 挖掘候选里的反向/噪音项(operator_log 等)一律不进此表。
# srcfix 未修复/数据不可用,手动隔离(自动 fixed_health 抓不到的形态):
#   1154: 原 fixed rs0-2 CrashLoop 系错位 cherry-pick;2026-09-07 重采批#4
#         已翻译重建后 fixed 全健康(rs0-0/1/2 1/1 Running 0 restart,CR ready),
#         buggy 故障在场(rs0-0 mongod restart 8/0,CR initializing)→ C 组解除,移出本表
#   17372: 09-07 二次裁决翻案——srcfix 镜像已含修复(8-30 构建 cherry-pick
#         -m1 1320861c3 对 pin v1.19.4 零漂移);"日志无 standby_count_wanted"
#         判据无效(exec.go 该命令 Debug 级静默)、"树内零引用"查错树(-fix 树
#         filesystem.go:129 有完整修复)。真根因=seed fallback 两侧同打
#         standby_count_wanted=1(ceph 19.2.4 默认 0)→ 同构构造性,待配方修
CASE_QUARANTINE = {
    # <case>/<case> 移出(2026-09-09 Lane A 活体救援双测):救援 seed
    # 落地后 buggy fault present / fixed fault-absent,判别干净,已注册
    # CASE_CONFIRM(见其条目)。旧 09-07 裁决注记保留在 git/记忆,勿回填。
    "k8spsmdb-1156": "srcfix 缺 #1651/#1691 功能 no-op,两边逐字节同态(待 re-cherry-pick)",
    # <case> 移出(2026-09-08 批#6 双 v4 重采):旧注记"fixed 死循环
    # 部署 buggy bundle"已过时 —— 本轮 fixed fh=ok 且判别在场
    # (nil panic 2/0 + manager restart 2/0),已注册 CASE_CONFIRM。
}

CASE_CONFIRM = {
    # ===== 2026-09-06 补采批 signal 审计登记(11 案;判据均已对照
    # 上游 fix 语义 + raw 日志双核,见 repair_invalid_cases.md 审计节) =====
    # <case>: fix="avoid panic while reconciling the Pooler when its
    # Cluster is deleted" —— 判据=operator panic 计数(buggy 现卷就有,循环崩)
    "cnpgop-10665": [
        {"kind": "operator_log", "target": "panic_lines", "judge": "count_zero",
         "values": {"buggy": 30, "fixed": 0},
         "note": "Pooler reconcile panic 循环(buggy=30/fixed=0;fixed 侧 pgbouncer "
                 "CrashLoop 是 Cluster 已删的预期行为,不影响本判据)"},
        {"kind": "clog_sig",
         "target": "panic: runtime error: invalid memory address",
         "judge": "count_zero", "values": {"buggy": 11, "fixed": 0},
         "note": "同因跨渠道冗余(2026-09-11 全库重扫,k8spxc-896 先例):容器日志 "
                 "JSON error 字段里的 panic 串 11/0,operator.log 侧 30/0 已有; "
                 "operator.log 失效/截断时本腿兜底"},
    ],
    # <case>(2026-09-06 重采批#2 审计登记):fix=#<issue> 校验拒绝语义。
    # buggy=静默丢 workload_identity stanza → prometheus-promop-0 容器日志
    # 'must provide an Azure Managed Identity, Azure OAuth or Azure SDK in
    # the Azure AD config' 启动崩 CrashLoop;fixed=reconciliation 拒绝不建
    # sts(operator.log 'azureAD.workloadIdentity requires Prometheus >=
    # v3.7.0' + CR Reconciled=False)。判据=pod 不存在=修好(fh 豁免已同步)。
    "promop-8326": [
        {"kind": "object_pods", "target": "default/prometheus-promop-0",
         "judge": "absent", "values": {"buggy": True, "fixed": False},
         "note": "fixed 侧 pod 不存在是 #8327 拒绝语义的预期终态,非伪快照;"
                 "辅证=fixed operator.log 版本门错误串 + buggy 容器日志 Azure AD 串"},
        {"kind": "clog_sig", "target": "must provide an Azure Managed Identity",
         "judge": "count_zero", "values": {"buggy": 2, "fixed": 0},
         "note": "2026-09-10 补:prometheus 容器逐字 \"must provide an Azure "
                 "Managed Identity\" ×2(伴 CrashLoopBackOff);与劝告级 warn "
                 "ignoring \"workload_identity\" 同源,是本案的 smoking gun"},
    ],
    # ===== 2026-09-06/07 重采批#2 signals 审计登记(3 案,判据已对
    # raw 日志逐行核实;见 repair_invalid_cases.md「Signals 可靠性审计」) =====
    # <case>: SparkConnect reconcile nil-deref panic 循环(buggy 45 行
    # panic/fixed 0;fixed 侧 sc-server CrashLoop 是 apache/spark:3.5.0
    # 缺 SparkConnectServer jars 的环境噪音,不影响本判据)。
    "sparkop-2807": [
        {"kind": "operator_log", "target": "panic_lines", "judge": "count_zero",
         "values": {"buggy": 45, "fixed": 0}},
        {"kind": "clog_sig",
         "target": "invalid memory address or nil pointer dereference",
         "judge": "count_zero", "values": {"buggy": 24, "fixed": 0},
         "note": "同因跨渠道冗余(2026-09-11 全库重扫):容器日志 panic 串 24/0,"
                 "operator.log 45/0 已有"},
    ],
    # <case>: VMAlert notifiers 空 -> Reconciler error 循环(精确串
    # 见 CASE_SIG;fixed 干净 0 行 + vmalert 工作负载 1/1 Running)。
    "vmop-2388": [
        {"kind": "log_sig", "target": "no_notifiers", "judge": "count_zero",
         "values": {"buggy": 7, "fixed": 0}},
    ],
    # <case>: proxy-webhook Service selector 碰撞(决定性结构证据,
    # f8b53f8a fix 全链改写 selector)。buggy 侧 webhook connection-refused
    # 事件是 ~50% 概率信号,不作为判据锚。
    "tektonop-3227": [
        {"kind": "svc_selector", "target": "tekton-operator-proxy-webhook",
         "judge": "match_fixed",
         "values": {"buggy": {"name": "tekton-operator"},
                    "fixed": {"name": "tekton-operator-proxy-webhook"}},
         "note": "selector 碰撞 = admission 流量被 LB 进 operator pod;fix 改写"
                 "三处 selector(svc/deploy/pod label),svc 侧即可判"},
    ],
    # ===== 2026-09-07 离线注册(5 案,判据均已对 raw 日志/对象核实) =====
    # <case>: operator CrashLoop(buggy restart 4/fixed 0;0/1 vs 1/1)。
    "otelop-5275": [
        {"kind": "restart_count", "target": "opentelemetry-operator-system/"
         "opentelemetry-operator-controller-manager/manager",
         "judge": "count_zero", "values": {"buggy": 4, "fixed": 0}},
    ],
    # <case>: 见 CASE_SIG undefined_receiver;sts 终态双重判据。
    "vmop-2185": [
        {"kind": "log_sig", "target": "undefined_receiver", "judge": "count_zero",
         "values": {"buggy": 21, "fixed": 0}},
        {"kind": "sts_ready", "target": "vmalertmanager-vmalertmanager-2185",
         "judge": "match_fixed", "values": {"buggy": "(无)", "fixed": "1/1"}},
    ],
    # <case>: 见 CASE_SIG nil_panic_283(现卷+previous 2/0)。
    "rdoptwo-283": [
        {"kind": "log_sig", "target": "nil_panic_283", "judge": "count_zero",
         "values": {"buggy": 2, "fixed": 0}},
    ],
    # <case>(2026-09-07 离线注册):#<issue> executeCommand 吞错——exec 失败
    # 后不 return 仍 log "Successfully executed the command";fix 提前返回。
    # 现采 buggy=6/fixed=0(两侧 "Could not execute" 6/6,真错误两边同有)。
    "rdoptwo-292": [
        {"kind": "log_sig", "target": "false_success_exec_292", "judge": "count_zero",
         "values": {"buggy": 6, "fixed": 0}},
    ],
    # <case>(2026-09-07):#<issue> enableMetrics 无 else——exporter disable 后
    # buggy svc 仍残留 9121 端口,fixed 移除。seed 修 clusterVersion 后重采才判别。
    "rdoptwo-474": [
        {"kind": "svc_ports", "target": "test-cluster-leader", "judge": "match_fixed",
         "values": {"buggy": "6379,9121", "fixed": "6379"},
         "note": "#484 else-branch;operator 进程级 enableMetrics buggy 锁死 true"},
    ],
    # <case>: ACTOKEY 注解卡 sts template -> 扩容副本 rs0-4 永卡
    # Init:Blocked(buggy 独有);fix 后注解可除、无卡死副本。
    "mgoptwo-696": [
        {"kind": "pod_status", "target": "test-cluster-rs0-4", "judge": "absent",
         "values": {"buggy": "0/2/Init:Blocked", "fixed": "/(无)"},
         "note": "sts_ready rs0 4/5 vs 4/4 与 arbiter sts fixed-only 佐证"},
    ],
    # <case>: adminServerService 注解漂移(#<issue> fix=SyncService SetAnnotations)
    # -> buggy svc 注解空 / fixed 同步(探针在 collect_signals 现算)。
    # 2026-09-10 补正向伴随腿:唯一判据原本是"buggy 侧注解缺席",属 T2 结构空真
    # (任何采集失败都得到同一个空值)。buggy 侧另有 ZK 节点连不上集群的真症状:
    # 原始文本双侧复数 connect/read timed out 共 7 条 / fixed 0;源 pod
    # test-cluster-0/1 都在 pods.txt 内、文件 mtime 与采集同秒,**非幽灵**。
    # 对上本案"注解不同步 -> 间歇超时"的故障语义。
    "zkop-474": [
        {"kind": "drift_svc_annotation", "target": "test-cluster-admin-server",
         "judge": "match_fixed", "values": {"buggy": False, "fixed": True}},
        {"kind": "clog_sig", "target": "java.net.SocketTimeoutException",
         "judge": "count_zero", "values": {"buggy": 7, "fixed": 0},
         "note": "正向伴随腿(buggy ZK connect/read timed out 5+2);"
                 "raw 双侧复数核过,非归一化伪影"},
    ],
    # <case>: fix="pg_basebackup 应检查已存在 PGDATA" —— 判据=repl
    # 副本 CR 终态(buggy 卡 Setting up primary/Ready=False)
    "cnpgop-11005": [
        {"kind": "cr_conditions",
         "target": "clusters.postgresql.cnpg.io/repl-11005", "judge": "match_fixed",
         "values": {"buggy": "ConsistentSystemID=False;Initialized=True;Ready=False",
                    "fixed": "ConsistentSystemID=True;ContinuousArchiving=True;Initialized=True;Ready=True"},
         "note": "repl 卡 bootstrap(buggy Ready=False + 3 个 pgbasebackup job Error)"},
        {"kind": "clog_sig", "target": "exists but is not empty",
         "judge": "count_zero", "values": {"buggy": 3, "fixed": 0},
         "note": "2026-09-10 补:manager 容器逐字 pg_basebackup: error: directory "
                 "\"/var/lib/postgresql/data/pgdata\" exists but is not empty ×3"
                 "(业务侧,events/operator.log 都没有;旧口径漏)"},
    ],
    # <case>: fix="HTTPRoute discovery for partial Gateway API CRD set"
    "grafanaop-2389": [
        {"kind": "restart_count",
         "target": "grafana/grafana-operator-controller-manager/manager",
         "judge": "count_zero", "values": {"buggy": 4, "fixed": 0},
         "note": "部分 CRD 集启动崩(buggy restart=4/CrashLoop,fixed=0/Running)"},
    ],
    # <case>: fix="checking nil pointer before dereference"(NPE 串
    # 在 previous_logs,计数依赖 variant_log_text)
    "k8spsmdb-434": [
        {"kind": "log_sig", "target": "nil_panic_previous", "judge": "count_zero",
         "values": {"buggy": 3, "fixed": 0},
         "note": "NPE 崩溃只在 --previous;辅证 restart operator b=1/f=0"},
    ],
    # <case>: fix=#<issue>(与 897 同)—— 判据=下游 monitor 用户失败串
    "k8spxc-896": [
        {"kind": "log_sig", "target": "reconcile_users_fail", "judge": "count_zero",
         "values": {"buggy": 11, "fixed": 0},
         "note": "ssl-internal 断的下游代理信号(直接判据 secret 未 capture)"},
        # 2026-09-10 补:同一信号的**容器日志渠道**版本(operator 容器日志 error 字段,
        # log_sig 读的是顶层 operator.log)。两条同因 —— 是冗余不是独立证据,
        # 价值在于任一渠道采集缺失时另一条仍能判。
        {"kind": "clog_sig",
         "target": "reconcileUsers: manage monitor user: update monitor grant: begin transaction: dial tcp",
         "judge": "count_zero", "values": {"buggy": 6, "fixed": 0},
         "note": "同因跨渠道冗余(log_sig reconcile_users_fail 的容器日志版);"
                 "raw 双侧复数过幽灵滤,6/0"},
    ],
    # <case>: fix="added missing list permission for secrets" ——
    # 判据=vmsingle 容器 forbidden 串(逐字匹配上游 RBAC 语义)
    "vmop-2384": [
        {"kind": "container_log", "target": "vmsingle-vmsingle-2384[failed]",
         "judge": "count_zero", "values": {"buggy": 6, "fixed": 0},
         "note": "cannot list secrets ... forbidden 只在 buggy(failed 行 6/0)"},
        {"kind": "clog_sig", "target": "failed to list *v1.Secret",
         "judge": "count_zero", "values": {"buggy": 6, "fixed": 0},
         "note": "2026-09-10 补:消息级同款(config-reloader \"Failed to watch\" "
                 "err=failed to list *v1.Secret … forbidden ×6);与上游 issue 逐字同构"},
    ],
    # <case>: fix="respect persistenceEnabled for initContainer"
    "rdoptwo-1540": [
        {"kind": "sts_ready", "target": "rc1540-leader", "judge": "match_fixed",
         "values": {"buggy": "0/3", "fixed": "3/3"},
         "note": "initContainer 挂载非法 -> pod 创建被拒,buggy 全套 sts/pod 缺失"},
        {"kind": "event_msg", "target": "FailedCreate: volumeMounts",
         "judge": "absent",
         "values": {"buggy": "create Pod rc1540-leader-N … invalid: "
                            "spec.initContainers[N].volumeMounts[N].name: Not found",
                    "fixed": "(无)"},
         "note": "2026-09-10 补:#1540 的逐字证据(volumeMounts 引用不存在的 "
                 "initConfig 卷);sts_ready 只说结果,这条说机制"},
    ],
    # <case>: fix="Ensure StatefulSetSelector matches deployed labels"
    "rbop-2218": [
        {"kind": "log_sig", "target": "sts_selector_invalid", "judge": "count_zero",
         "values": {"buggy": 30, "fixed": 0},
         "note": "sts invalid 循环串(辅证 operator failed 行 b=11/f=0)"},
    ],
    # <case>: fix="use uid to identify PVCs"
    "cassandraop-402": [
        {"kind": "log_sig", "target": "pvc_not_found_loop", "judge": "count_zero",
         "values": {"buggy": 21, "fixed": 0},
         "note": "PVC not found 循环 + buggy 无 sts/pod(fixed 侧 rack1-0 "
                 "CrashLoop 是采集质量存疑项,不影响本判据方向)"},
    ],
    # <case>: fix="delete the statefulset with precondition"(stale 误删)
    "rbop-648": [
        {"kind": "sts_ready", "target": "rabbitmq-cluster-server", "judge": "match_fixed",
         "values": {"buggy": "(无)", "fixed": "1/1"},
         "note": "stale 误删后不重建(buggy sts/pod 全缺),fixed 重建 1/1"},
    ],
    # <case>: replaceNodes 卡住 -> buggy progress=Updating + rack2/3
    # sts 1/2(fixed: Ready + 1/1)。sts-1 的 pod/pvc 存在性是同一信号的
    # 衍生物,只留 sts_ready 一条。operator_log 反向噪音已剔除。
    "cassop-696": [
        # 2026-09-04 re-ground:#<issue> = startOneNodePerRack 卡在起不来的 pod ->
        # buggy 全卡(现快照无任何 condition/started 节点),fixed 跳过它启动别的
        # rack 达 Healthy。旧 progress(Updating 两边都 Updating)/rack2(0/1 两边同)
        # 现值不判别,recheck 已拉 stale。判别载体 = cr_conditions Healthy 只在
        # fixed(buggy 现值无条件串)。
        {"kind": "cr_conditions",
         "target": "cassandradatacenters.cassandra.datastax.com/test-cluster",
         "judge": "match_fixed",
         "values": {"buggy": "(无条件)", "fixed": "Healthy=True"},
         "note": "re-ground:buggy DC 卡死无 condition,fixed 达 Healthy=True(#696 修复态)"},
        {"kind": "sts_ready", "target": "development-test-cluster-rack3-sts",
         "judge": "match_fixed", "values": {"buggy": "0/1", "fixed": "1/1"},
         "note": "re-ground:buggy 任何 rack 都起不来,fixed 至少 rack3 起动"},
    ],
    # <case>: secret 无 annotations -> operator nil-map panic(crash 型)
    "cassop-705": [
        {"kind": "restart_count", "target": "cass-operator/cass-operator-controller-manager/manager",
         "judge": "count_zero", "values": {"buggy": 2, "fixed": 0},
         "note": "panic 崩溃重启:buggy 2 次,fixed 0"},
        {"kind": "log_sig", "target": "panic_previous", "judge": "count_zero",
         "values": {"buggy": 5, "fixed": 0},
         "note": "panic 行数:buggy 5,fixed 0;2026-09-06 改 log_sig——"
                 "operator_log 探针只数现卷,pod 重启翻页后 panic 在 "
                 "previous_logs(实测现卷 0/previous 3 份),须合并计数"},
    ],
    # <case>: replaceNodes 无校验入 status -> reconcile 卡 replacement 段,
    # trigger patch 的 rollingRestartRequested 永不被消费(v6 实测 2026-09-03:
    # buggy cr_full spec 里仍在 + 3 pod 零滚更;fixed 消费后滚更)
    "cassop-315": [
        # 2026-09-04 re-ground:#<issue> = replaceNodes 幽灵名入 status.NodeReplacements
        # -> reconcile 卡 ReplacingNodes(ACTOKEY 永清不掉),rolling restart 永不被
        # 消费。现值 buggy:spec.replaceNodes 已清空、status.nodeReplacements=['ACTOKEY']
        # + cond ReplacingNodes=True;fixed 全清。旧 spec.replaceNodes 探针死(spec
        # (absent)两边同),recheck 拉 stale。判别载体 = cr_conditions ReplacingNodes
        # (buggy True / fixed False) + rollingRestartRequested 永不被消费。
        {"kind": "cr_conditions",
         "target": "cassandradatacenters.cassandra.datastax.com/test-cluster",
         "judge": "match_fixed",
         "values": {"buggy": "ReplacingNodes=True", "fixed": "ReplacingNodes=False"},
         "note": "re-ground:幽灵替换名卡住(buggy ReplacingNodes=True),fixed 清掉"},
        {"kind": "cr_spec", "target": "cassandradatacenters.cassandra.datastax.com/test-cluster",
         "field": "spec.rollingRestartRequested", "judge": "match_fixed",
         "values": {"buggy": "True", "fixed": "(absent)"},
         "note": "re-ground:替换卡死连带滚更请求永不消费(buggy 在场),fixed 消费"},
        {"kind": "cr_state",
         "target": "cassandradatacenters.cassandra.datastax.com",
         "field": "nodeReplacements", "judge": "match_fixed",
         "values": {"buggy": "ACTOKEY", "fixed": "(无)"},
         "note": "物证腿(2026-09-10):#315 故障本体 = 幽灵替换名残留 "
                 "status.nodeReplacements(buggy ['ACTOKEY']/fixed null);"
                 "cr_state 的 _deep_scalar 跳过 list 值,此前表达不了,加特判后登记"},
    ],
    # <case>: mirror connector 制造 FAILED(buggy NotReady / fixed Ready,
    # v6 实测 2026-09-03,cr_full conditions)
    "kafkaop-12542": [
        {"kind": "cr_conditions", "target": "kafkaconnectors.kafka.strimzi.io/bad-connector",
         "judge": "match_fixed",
         "values": {"buggy": "NotReady=True", "fixed": "Ready=True"},
         "note": "bad-connector 条件:buggy NotReady,fixed Ready"},
        {"kind": "cr_state", "target": "kafkaconnectors.kafka.strimzi.io",
         "field": "connector_state", "judge": "match_fixed",
         "values": {"buggy": "FAILED", "fixed": "STOPPED"},
         "note": "mirror connector 状态(2026-09-10):buggy FAILED —— status 内嵌 "
                 "PatternSyntaxException: Unclosed character class 'invalid[regex' "
                 "完整 Java 栈;fixed STOPPED。parse_cr_full 摘要加 connector_state "
                 "后可见(9 键摘要盲点)"},
    ],
    # k8ssandra-client-80-0: goalesce boolean-false 丢弃 -> seed 的 sts
    # Init:ImagePullBackOff(trigger 型 3 变体)
    "k8ssandra-client-80-0": [
        {"kind": "sts_ready", "target": "development-test-cluster-rack1-sts",
         "judge": "match_fixed", "values": {"buggy": "0/1", "fixed": "1/1"},
         "note": "buggy 起不来(Init 卡),fixed/reference 1/1"},
        {"kind": "sts_ready", "target": "development-test-cluster-rack2-sts",
         "judge": "match_fixed", "values": {"buggy": "0/1", "fixed": "1/1"}},
        {"kind": "sts_ready", "target": "development-test-cluster-rack3-sts",
         "judge": "match_fixed", "values": {"buggy": "0/1", "fixed": "1/1"}},
        {"kind": "cr_state", "target": "cassandradatacenters.cassandra.datastax.com",
         "field": "progress", "judge": "match_fixed",
         "values": {"buggy": "Updating", "fixed": "Ready"}},
    ],
    # <case>: high-availability:{} -> knative-operator 重启
    "knop-1137": [
        {"kind": "restart_count", "target": "knative-serving/knative-operator/knative-operator",
         "judge": "count_zero", "values": {"buggy": 1, "fixed": 0},
         "note": "operator 崩溃重启 1 次,fixed 0"},
        {"kind": "clog_sig", "target": "panic: runtime error: invalid memory address",
         "judge": "count_zero", "values": {"buggy": 1, "fixed": 0},
         "note": "2026-09-10 补:panic 栈只在 previous_logs/(双 operator pod),"
                 "主日志崩前无输出 → 旧口径(只看 operator.log)天然漏。"
                 "计数 2→1:幽灵过滤后双 operator pod 之一是残留文件,剔除后仍 >0"},
    ],
    # <case>: knative-serving 组件(crash 型)controller/webhook/autoscaler-hpa
    "knop-2233": [
        {"kind": "restart_count", "target": "knative-serving/controller/controller",
         "judge": "count_zero", "values": {"buggy": 3, "fixed": 0}},
        {"kind": "restart_count", "target": "knative-serving/webhook/webhook",
         "judge": "count_zero", "values": {"buggy": 2, "fixed": 0}},
        {"kind": "restart_count", "target": "knative-serving/autoscaler-hpa/autoscaler-hpa",
         "judge": "count_zero", "values": {"buggy": 3, "fixed": 0}},
    ],
    # <case>: fault-as-seed(shouldRunInOrder 无 HasZeroReplicas)种子即卡
    "mgopone-1024": [
        # 2026-09-04 re-ground:sts target 去 ns 前缀(parser key=归一化名 test-cluster,
        # 带 "mongodb/" 定义层脏,现值其实一致 0/3 vs 3/3)
        {"kind": "sts_ready", "target": "test-cluster", "judge": "match_fixed",
         "values": {"buggy": "0/3", "fixed": "3/3"}, "note": "种子 3 副本全卡 Init"},
        {"kind": "cr_state", "target": "mongodbcommunity.mongodbcommunity.mongodb.com",
         "field": "phase", "judge": "match_fixed",
         "values": {"buggy": "Pending", "fixed": "Running"}},
        {"kind": "event_msg", "target": 'FailedMount: "automation-config"',
         # 2026-09-12:同 <case> —— 卷名必须在前 30 字符内(见该条注释)。
         "judge": "absent",
         "values": {"buggy": "MountVolume.SetUp failed for volume \"automation-config\"",
                    "fixed": "(无)"},
         "note": "2026-09-10 补:init 容器挂不出的直接证据(secret "
                 "\"test-cluster-config\" not found);init 容器日志 collector 未采"},
    ],
    # <case>: 起集群卡住(cr phase Pending)
    "mgopone-1072": [
        {"kind": "cr_state", "target": "mongodbcommunity.mongodbcommunity.mongodb.com",
         "field": "phase", "judge": "match_fixed",
         "values": {"buggy": "Pending", "fixed": "Running"}},
        {"kind": "clog_sig", "target": "Invalid command argument",
         "judge": "count_zero", "values": {"buggy": 32, "fixed": 0},
         "note": "2026-09-10 补:agent 日志 (BadValue) Invalid command argument"
                 " ×32(setFeatureCompatibilityVersion 传 \"4.2.4\");severity 是 I,"
                 "按 error/warn 级别口径漏"},
    ],
    # <case>: 扩容卡住(buggy 2/2, fixed 3/3)
    "mgopone-1252": [
        # 2026-09-04 re-ground:sts target 去 ns 前缀;补 cr_spec statefulSet.spec.replicas
        # (#<issue> 载体:非法 2-replica sts 规格 buggy 仍在 / fixed(校验拒绝)不设)
        {"kind": "sts_ready", "target": "test-cluster", "judge": "match_fixed",
         "values": {"buggy": "2/2", "fixed": "3/3"}},
        {"kind": "cr_spec",
         "target": "mongodbcommunity.mongodbcommunity.mongodb.com/test-cluster",
         "field": "spec.statefulSet.spec.replicas", "judge": "match_fixed",
         "values": {"buggy": 2, "fixed": "(absent)"},
         "note": "re-ground:#1252 非法 replicas≠members 规格 buggy 仍在,fixed 拒绝不设"},
        {"kind": "cr_state", "target": "mongodbcommunity.mongodbcommunity.mongodb.com",
         "field": "phase", "judge": "match_fixed",
         "values": {"buggy": "Pending", "fixed": "Running"}},
        {"kind": "clog_sig", "target": "Heartbeat failed after max retries",
         "judge": "count_zero", "values": {"buggy": 48, "fixed": 0},
         "note": "2026-09-10 补:mongod 心跳失败 ×48(伴 HostUnreachable ×90);"
                 "severity 是 I,非 error/warn 级别 → 旧口径漏"},
    ],
    # <case>: unexpose 后 per-pod svc 残留(drift)
    "mgoptwo-895": [
        {"kind": "drift_svc_residue", "target": "test-cluster-rs0-*",
         "judge": "match_fixed", "values": {"buggy": "residue=True", "fixed": "residue=False"},
         "note": "rs0 unexpose 后 4 个 per-pod svc 残留=bug 在;修复后无残留"},
        {"kind": "clog_sig", "target": "Unable to reach primary for set cfg",
         "judge": "count_zero", "values": {"buggy": 33, "fixed": 0},
         "note": "issue 语义审计(2026-09-10)补:cfg-1/2 backup-agent 周期性拨不上 "
                 "cfg primary(buggy 33/fixed 0,双侧同型 20min 窗口复数核过;"
                 "unexpose 残留 svc 的运行期症状)"},
    ],
    # <case>: 复合 OOM 扩容 -> 4 业务 pod 各重启 1 次(trigger 型)
    "rdoptwo-1668": [
        {"kind": "restart_count", "target": "redis-operator/test-cluster-leader-0/test-cluster-leader",
         "judge": "count_zero", "values": {"buggy": 1, "fixed": 0, "reference": 0}},
        {"kind": "restart_count", "target": "redis-operator/test-cluster-follower-0/test-cluster-follower",
         "judge": "count_zero", "values": {"buggy": 1, "fixed": 0, "reference": 0}},
        {"kind": "restart_count", "target": "redis-operator/test-cluster-follower-2/test-cluster-follower",
         "judge": "count_zero", "values": {"buggy": 1, "fixed": 0, "reference": 0}},
    ],
    # <case>: 起集群卡 Bootstrap(flaky 系,本次复现成功)
    "rdoptwo-1863": [
        {"kind": "cr_state", "target": "redisclusters.redis.redis.opstreelabs.in",
         "field": "state", "judge": "match_fixed",
         "values": {"buggy": "Bootstrap", "fixed": "Ready"}},
        {"kind": "clog_sig", "target": "peer did not return a certificate",
         "judge": "count_zero", "values": {"buggy": 39, "fixed": 0},
         "note": "issue 语义正中(#1863:exec redis-cli 无客户端证书被 tls-auth-clients="
                 "yes 拒绝):leader-0 mongod/redis 日志 SSL 拒绝串 buggy 39/fixed 0,"
                 "同型文件无封顶,raw+窗口双核过"},
    ],
    # <case>: operator 崩溃重启
    "xtop-1060": [
        {"kind": "restart_count", "target": "acto-namespace/percona-xtradb-cluster-operator/percona-xtradb-cluster-operator",
         "judge": "count_zero", "values": {"buggy": 2, "fixed": 0}},
        {"kind": "clog_sig", "target": "panic: Malformed version",
         "judge": "count_zero", "values": {"buggy": 6, "fixed": 0},
         "note": "语义正中(2026-09-11 全库重扫):panic 消息里带着注入的坏版本串"
                 "('panic: Malformed version: ACTOKEY')6/0 —— #1060 版本解析 bug "
                 "的直接物证,restart_count 只是它的投影"},
    ],
    # <case>: TLS getCaCrt nil deref -> operator CrashLoop(#<issue> 修复 =
    # 校验拒绝不合法 CR,CR Failed 是预期,fixed_health 已特判)
    "mgopone-1054": [
        {"kind": "restart_count", "target": "mongodb/mongodb-kubernetes-operator/mongodb-kubernetes-operator",
         "judge": "count_zero", "values": {"buggy": 3, "fixed": 0},
         "note": "buggy operator CrashLoop(restart 3),fixed 0"},
        {"kind": "pod_status", "target": "mongodb-kubernetes-operator",
         "judge": "match_fixed", "values": {"buggy": "0/1/CrashLoopBackOff", "fixed": "1/1/Running"},
         "note": "buggy CrashLoopBackOff,fixed Running"},
    ],
    # <case>: reconcile.StatefulSet 对每个 STS 认领的 PVC 都调 updatePVC
    # -> buggy 扩容报 ReconciliationError(failed to expand size),fixed 干净
    "vmop-1845": [
        {"kind": "event_msg",
         "target": "ReconciliationError: failed create or update vmcluster: failed to expand size for",
         "judge": "absent",
         "values": {"buggy": "failed create or update vmcluster: failed to expand size for",
                    "fixed": "(无)"},
         "note": "buggy 对 STS PVC 盲目扩容报错,fixed 无"},
        {"kind": "container_log", "target": "operator[failed]", "judge": "count_zero",
         "values": {"buggy": 1, "fixed": 0},
         "note": "operator failed 计数 buggy 1,fixed 0"},
    ],
    # <case>: last-applied spec 存进 annotation -> 后续 reconcile 无法
    # 反序列化 -> operator Reconciler error(cannot update cluster with last
    # applied spec),VMAgent 起不来
    "vmop-1802": [
        {"kind": "event_msg",
         "target": "ReconciliationError: cannot update cluster with last applied spec",
         "judge": "absent",
         "values": {"buggy": "cannot update cluster with last applied spec: VMAgent.operat",
                    "fixed": "(无)"},
         "note": "buggy annotation 里 last-applied spec 反序列化失败,fixed 无"},
        {"kind": "pod_status", "target": "vmagent-vmagent-1802",
         "judge": "match_fixed", "values": {"buggy": "/(无)", "fixed": "2/2/Running"},
         "note": "buggy vmagent 未创建,fixed 2/2 Running"},
    ],
    # <case>: createOrUpdateVMAgent 里 createK8sAPIAccess 顺序错 ->
    # config-reloader CrashLoopBackOff(vmagent 1/2),fixed 2/2
    "vmop-1828": [
        {"kind": "pod_status", "target": "vmagent-vmagent-1828",
         "judge": "match_fixed", "values": {"buggy": "1/2/CrashLoopBackOff", "fixed": "2/2/Running"},
         "note": "buggy config-reloader 崩导致 1/2 CrashLoopBackOff,fixed 2/2"},
        {"kind": "restart_count", "target": "default/vmagent-vmagent-1828/config-reloader",
         "judge": "count_zero", "values": {"buggy": 2, "fixed": 0},
         "note": "config-reloader restart buggy 2,fixed 0"},
        {"kind": "container_log", "target": "vmagent-vmagent-1828[fatal]", "judge": "count_zero",
         "values": {"buggy": 1, "fixed": 0},
         "note": "vmagent fatal 日志 buggy 1,fixed 0"},
    ],
    # <case>: (*VMAgent).IsSharded() 用 ShardCount>1(应为 >=1?) ->
    # 非 shard 的 vmagent sts reconcile 失败(cannot reconcile StatefulSet),
    # buggy sts 0/1、vmagent pod 不存在;fixed sts 1/1 pod 2/2
    "vmop-2001": [
        {"kind": "event_msg",
         "target": "ReconciliationError: cannot reconcile *v1.StatefulSet for vmagent",
         "judge": "absent",
         "values": {"buggy": "cannot reconcile *v1.StatefulSet for vmagent(N): cannot hand",
                    "fixed": "(无)"},
         "note": "buggy vmagent sts reconcile 失败,fixed 无"},
        # 2026-09-04 re-ground:IsSharded 只认 >1 -> shardCount=1 时 factory 跳
        # RenderShard,buggy 建错名 sts `vmagent-<case>`(0/1 卡),fixed 建
        # 分片名 `vmagent-<case>-0`(1/1)。旧记录 fixed "1/1" 挂在该名下
        # 现值 (无)(fixed 名带 -0),recheck 拉 stale。拆两条按实际 sts 名。
        {"kind": "sts_ready", "target": "vmagent-vmagent-2001",
         "judge": "match_fixed", "values": {"buggy": "0/1", "fixed": "(无)"},
         "note": "re-ground:buggy 错名 sts 0/1 卡,fixed 该名不存在(-0 分片名)"},
        {"kind": "sts_ready", "target": "vmagent-vmagent-2001-0",
         "judge": "match_fixed", "values": {"buggy": "(无)", "fixed": "1/1"},
         "note": "re-ground:fixed 分片 sts -0 健康 1/1,buggy 未建"},
        {"kind": "event_msg", "target": "FailedCreate: podAntiAffinity",
         "judge": "absent",
         "values": {"buggy": "create Pod vmagent-vmagent-N-N … invalid: "
                            "spec.affinity.podAntiAffinity…",
                    "fixed": "(无)"},
         "note": "2026-09-10 补:apiserver 拒绝建 pod 的直接事件(旧口径只看 "
                 "ReconciliationError,漏了 FailedCreate 这一半)"},
    ],
    # <case>: Playlist/route resourceVersion bug —— 消息签名判别
    # (2026-09-02 实证):operator.log 的 RV 拒绝串 buggy=28/fixed=0,error_lines
    # 62 vs 32 看不出(共有噪音 no matching instances 淹掉)。log_sig 探针
    # 计数该串;agent 集群 operator.log 里串消失 = 修好。
    "grafanaop-2864": [
        {"kind": "log_sig", "target": "rv_version_mismatch",
         "judge": "count_zero",
         "values": {"buggy": 28, "fixed": 0},
         "note": "Playlist/route 更新带空 RV 被拒(does not match current version)\n"
                 "计数 buggy=28/fixed=0;agent 侧 operator.log 串计数归零=修好"},
    ],
    # <case>: alertmanager notifier 缺 chat_id -> reconcile 报
    # "missing chat_id" 循环,vmalertmanager CR 永不落地(2026-09-04 实证:
    # log_sig buggy=18/fixed=0;sts/svc/pod 三对象 buggy 全缺/fixed 齐;
    # 附带 CRD-missing 噪音串已由签名避开)。
    "vmop-2132": [
        {"kind": "log_sig", "target": "missing_chat_id",
         "judge": "count_zero",
         "values": {"buggy": 18, "fixed": 0},
         "note": "alertmanager notifier 校验错误循环;串计数归零=修好"},
        {"kind": "sts_ready", "target": "vmalertmanager-vmalertmanager-2132",
         "judge": "match_fixed", "values": {"buggy": "(无)", "fixed": "1/1"},
         "note": "CR 永不落地:buggy 无 sts,fixed 1/1"},
    ],
    # <case>: prometheusrules.go:33 nil-deref panic 循环(2026-09-04
    # 实证:panic 栈串 buggy=8/fixed=0;container_log panic 同源 8/0)。
    "logop-2172": [
        {"kind": "log_sig", "target": "prule_nil_panic",
         "judge": "count_zero",
         "values": {"buggy": 8, "fixed": 0},
         "note": "prometheusrules.go:33 panic 栈帧;串计数归零=修好"},
        {"kind": "operator_log", "target": "panic_lines", "judge": "count_zero",
         "values": {"buggy": 8, "fixed": 0},
         "note": "panic 行数 buggy=8/fixed=0(与栈签名同源,双保险)"},
    ],
    # <case>: auto-instrumentation 注入容器未设 allowPrivilegeEscalation
    # -> restricted PSS 拒建 pod(2026-09-04 实证:FailedCreate 事件 buggy=10/
    # fixed=0;app pod buggy 无/fixed 1/1 Running;cert-manager cr_spec 的
    # UUID/cert 差异是噪音已剔除)。
    "otelop-4848": [
        {"kind": "event_msg",
         "target": "FailedCreate: violates PodSecurity \"restricted:latest\"",
         "judge": "absent",
         "values": {"buggy": "violates PodSecurity \"restricted:latest\": "
                            "allowPrivilegeEscalation != false",
                    "fixed": "(无)"},
         "note": "PSS 拒注入容器事件;事件消失=修好"},
        {"kind": "pod_status", "target": "app-4848",
         "judge": "match_fixed", "values": {"buggy": "/(无)", "fixed": "1/1/Running"},
         "note": "buggy app pod 建不出来,fixed 1/1 Running"},
    ],
    # <case>: extensions stanza 下 initdb Job 模板拼出重名 pgdata 卷 ->
    # apiserver 拒 Job -> Cluster 卡 "Setting up primary"(2026-09-04 实证:
    # log_sig buggy=2/fixed=0;phase 卡 vs healthy;pod 不存在 vs 1/1;
    # fixed 侧 container error=10 是 initdb 正常输出噪音,反向已剔)。
    "cnpgop-9972": [
        {"kind": "log_sig", "target": "dup_pgdata_volume",
         "judge": "count_zero",
         "values": {"buggy": 2, "fixed": 0},
         "note": "Duplicate value: \"pgdata\" 拒 Job 串;计数归零=修好"},
        {"kind": "cr_state", "target": "clusters.postgresql.cnpg.io",
         "field": "phase", "judge": "match_fixed",
         "values": {"buggy": "Setting up primary",
                    "fixed": "Cluster in healthy state"},
         "note": "buggy 卡建主,fixed 健康"},
        {"kind": "pod_status", "target": "c-9972-1",
         "judge": "match_fixed", "values": {"buggy": "/(无)", "fixed": "1/1/Running"},
         "note": "primary pod buggy 建不出来,fixed 1/1 Running"},
        {"kind": "clog_sig", "target": "Duplicate value",
         "judge": "count_zero", "values": {"buggy": 2, "fixed": 0},
         "note": "2026-09-10 补:旧报告把这行当\"噪音\"剔了,实为铁证 —— "
                 "Job \"c-9972-1-initdb\" is invalid: … Duplicate value: \"pgdata\""},
    ],
    # <case>: validate_version.go:67 panic -> operator CrashLoop
    # (2026-09-04 实证:栈帧 buggy=2/fixed=0,restart 4/0,pod CrashLoop vs
    # Running;fixed error/warn 26/86 是健康集群 cockroach 日志噪音,反向已剔;
    # vcheck job pod 仅 fixed 存在是修复后版本检查正常跑,不作判据)。
    "crdbop-918": [
        {"kind": "log_sig", "target": "validate_version_panic",
         "judge": "count_zero",
         "values": {"buggy": 2, "fixed": 0},
         "note": "validate_version.go:67 panic 栈帧;计数归零=修好"},
        {"kind": "restart_count",
         "target": "cockroach-operator-system/cockroach-operator-manager/cockroach-operator",
         "judge": "count_zero", "values": {"buggy": 4, "fixed": 0},
         "note": "operator 崩溃重启 buggy=4,fixed=0"},
        {"kind": "pod_status", "target": "cockroach-operator-manager",
         "judge": "match_fixed",
         "values": {"buggy": "0/1/CrashLoopBackOff", "fixed": "1/1/Running"},
         "note": "operator pod buggy CrashLoop,fixed Running"},
    ],
    # ===== 2026-09-07 重采批#4 审计登记(真判别对;判据对 raw 现值双核,
    # 见 repair_invalid_cases.md「重采批#4 终态」) =====
    # <case>: acto 复现(buggy reproduced=true/fixed=false)。buggy
    # rs0-0 mongod CrashLoop(8×)+ rs0-1/2 起不来 + CR 卡 state=initializing;
    # fixed(错位 cherry-pick 已重建)rs0 全 1/1 Running 0 restart + CR ready。
    # C 组 quarantine 已解除(见 CASE_QUARANTINE 注记)。
    "k8spsmdb-1154": [
        {"kind": "restart_count", "target": "acto-namespace/test-cluster-rs0-0/mongod",
         "judge": "count_zero", "values": {"buggy": 8, "fixed": 0},
         "note": "rs0-0 mongod buggy CrashLoop 8×/fixed 0;CR buggy initializing "
                 "vs fixed ready + rs0-1/2 buggy 缺席佐证"},
    ],
    # <case>: async pool reconcile 卡住(buggy ec-pool phase=Progressing
    # 永不 Ready 且 operator 报 ReconcileSucceeded=#<issue> 语义;fixed=Ready)。
    "rook-17198": [
        {"kind": "cr_state", "target": "cephblockpools.ceph.rook.io", "field": "phase",
         "judge": "match_fixed", "values": {"buggy": "Progressing", "fixed": "Ready"},
         "note": "ec-pool phase:buggy 卡 Progressing(operator 却报 ReconcileSucceeded),"
                 "fixed Ready"},
    ],
    # ===== 2026-09-08 批#6 重采后注册(rdoptwo 280/286/290/297 双 v4 新采,
    # 现值已逐案 grep 核对;2356/1055 为在盘旧数据注册,见各 note) =====
    # <case>: silent bug —— #<issue> fix 给"VCT 不可变被静默恢复"加告警日志。
    # buggy 静默 0 条 / fixed 4 条"ignored change"(09-08 实测 0/4)。
    # 2026-09-10 用户裁决裁撤(见下),撤销后 confirmed=0 → usable=False(已接受下线)。
    "rdoptwo-280": [
        # 2026-09-10 裁撤:fix 本身就是"加这条错误日志",所以 buggy 侧永远不可能出串
        # —— 判据内容是 fix 的补丁本身,不是故障证据。唯一一条 confirmed,撤后下线。
        # 回滚 = 取消下面四行注释。
        # {"kind": "log_sig", "target": "ignored_vct_280", "judge": "fixed_only",
        #  "values": {"buggy": 0, "fixed": 4},
        #  "note": "两步 VCT patch trigger 后,fix 的 patchStatefulSet 告警;"
        #          "spec 漂移(CR 512Mi vs sts 128Mi)两侧同有,非判据"},
    ],
    # <case>: CRD 缩进 bug -> operator 读不到字段 nil-deref panic。
    # 09-08 双 v4 重采:buggy 现卷 1 + previous 1 = 2 / fixed 0;
    # manager restart 2/0 佐证。旧 quarantine 注记(fixed 死循环 buggy
    # bundle)已过时——本轮 fixed fh=ok 且判别在场,移出 CASE_QUARANTINE。
    "rdoptwo-286": [
        {"kind": "log_sig", "target": "nil_panic_286", "judge": "count_zero",
         "values": {"buggy": 2, "fixed": 0},
         "note": "nil-deref panic(现卷+previous 合计);restart 2/0 佐证"},
        {"kind": "restart_count",
         "target": "redis-operator/redis-operator/manager", "judge": "count_zero",
         "values": {"buggy": 2, "fixed": 0},
         "note": "manager 随 panic 重启"},
    ],
    # <case>: kubernetesConfig.resources nil panic(#<issue> 只修 nil-guard,
    # seed mutated resources:null 走 panic 分支)。09-08 双 v4 重采:
    # panic 现卷 0 + previous 1 = 1 / fixed 0;restart 3/0、CrashLoop/Running。
    "rdoptwo-290": [
        {"kind": "log_sig", "target": "nil_panic_290", "judge": "count_zero",
         "values": {"buggy": 1, "fixed": 0},
         "note": "panic 只留 previous_logs(现卷翻页后 0),recheck 合计现算"},
        {"kind": "restart_count",
         "target": "redis-operator/redis-operator/manager", "judge": "count_zero",
         "values": {"buggy": 3, "fixed": 0}, "note": "manager 崩溃重启"},
        {"kind": "pod_status", "target": "redis-operator", "judge": "match_fixed",
         "values": {"buggy": "0/1/CrashLoopBackOff", "fixed": "1/1/Running"},
         "note": "operator pod 终态"},
    ],
    # <case>: probe 配置透传 bug(#<issue>)—— leader pod liveness/readiness
    # probe 配错,2 容器 pod 只 1 ready,liveness 杀 pod 循环。
    # 09-08 双 v4 重采(<case> 重建后):leader sts 1/3 vs 3/3、
    # leader-1/2 restart 9/0、"Liveness probe failed" 事件 buggy-only。
    "rdoptwo-297": [
        {"kind": "sts_ready", "target": "test-cluster-leader", "judge": "match_fixed",
         "values": {"buggy": "1/3", "fixed": "3/3"},
         "note": "leader sts 就绪数;follower 两侧同 3/3 非判据"},
        {"kind": "restart_count",
         "target": "redis-operator/test-cluster-leader-1/test-cluster-leader",
         "judge": "count_zero", "values": {"buggy": 9, "fixed": 0},
         "note": "liveness 杀 pod 循环(leader-2 同 9/0,单条即可)"},
    ],
    # <case>: VMAnomaly configRawYaml 含新版才认的 seasonalities 字段,
    # buggy operator unmarshal 报错串。09-08 核对:buggy=6 / fixed=0
    # (fixed operator.log 里另有 10 条 09-02 旧采集累积的 prometheus/reader
    # 噪音串,字段不同,sig 用精确串避开)。
    "vmop-2356": [
        {"kind": "log_sig", "target": "unmarshal_anomaly_2356", "judge": "count_zero",
         "values": {"buggy": 6, "fixed": 0},
         "note": "field seasonalities not found in config.prophetModel(buggy "
                 "特有;cr_spec configRawYaml 两侧同塞,漂移在日志层不在 spec 层)"},
    ],
    # <case>(2026-09-08 注册,agent 调研 + 1054 同构):modes:[] 无
    # guard 直取 authModes[0] -> index-out-of-range panic(types.go:612);
    # fix=#<issue> 后 operator 干净拒绝非法 spec(CR phase=Failed 是预期,
    # fh 已豁免)。现算:buggy 现卷 1 + previous 2 = 3 / fixed 0。
    "mgopone-1055": [
        {"kind": "log_sig", "target": "index_panic_1055", "judge": "count_zero",
         "values": {"buggy": 3, "fixed": 0},
         "note": "panic: index out of range [0] with length 0(镜像 mgopone-1054 "
                 "同构判据);fixed 侧 'could not configure scram' 干净报错为对照"},
        {"kind": "restart_count",
         "target": "mongodb/mongodb-kubernetes-operator/mongodb-kubernetes-operator",
         "judge": "count_zero", "values": {"buggy": 4, "fixed": 0},
         "note": "operator 随 panic 重启;pod 0/1 CrashLoop vs 1/1 Running 佐证"},
    ],
    # <case>(2026-09-08 注册,零重采):bug = initdb job 失败后 operator
    # 卡 "Setting up primary" 死等;fix = 检测失败置 PhaseUnrecoverable。
    # fault 注入 = initdb --acto-invalid-flag(job 必败)。批#6 双侧:
    # buggy phase=Setting up primary(卡死)/ fixed=PhaseUnrecoverable;
    # "An instance creation job has failed" 0/33。fh 已豁免(FH_FIX_REJECT)。
    "cnpgop-11042": [
        {"kind": "cr_state", "target": "clusters.postgresql.cnpg.io", "field": "phase",
         "judge": "match_fixed",
         "values": {"buggy": "Setting up primary",
                    "fixed": "Cluster is unrecoverable and needs manual intervention"},
         "note": "buggy 卡 Setting up primary;fixed 进 PhaseUnrecoverable"
                 "(api/v1/cluster_types.go:749 长串,非短 'Unrecoverable')"},
        {"kind": "cr_state", "target": "clusters.postgresql.cnpg.io",
         "field": "phase_reason", "judge": "match_fixed",
         "values": {"buggy": "Creating primary instance cluster-11042-1",
                    "fixed": "Instance creation failed for the following jobs: "
                             "cluster-11042-1-initdb. Check the job logs ..."},
         "note": "issue 语义审计(2026-09-10)补:buggy 静默死等 'Creating primary "
                 "instance' vs fixed 明报 failed jobs(fail-fast 本体);两侧都"
                 "有值,非缺席形。摘要加 phase_reason 后可见"},
        # 2026-09-10 裁撤(用户裁决:"人为设置的 fix_only 信号不想要")。理由:本条
        # 判别的是"跑的是哪个二进制"而非"故障有没有发生" —— buggy 侧按构造永不出该
        # 串,采集/seed/窗口失效时判据照样 ok(属空真家族)。本案另有上方 cr_state
        # 兜底(Setting up primary → unrecoverable),撤掉不影响可用性。
        # 回滚 = 取消下面三行注释。
        # {"kind": "log_sig", "target": "job_failed_unrecoverable", "judge": "fixed_only",
        #  "values": {"buggy": 0, "fixed": 33},
        #  "note": "fix 的 job 失败处理日志;buggy 无此路径(静默死等)"},
    ],
    # <case>(2026-09-08 注册,批#7 双侧现采):#<issue> fix = config/rbac/
    # role.yaml 尾部 +31 行 rabbitmq 规则。buggy 缺 RBAC -> rabbitmq eventing
    # 源组件整体建不出来(controller-manager/webhook 的 pod+svc+secret 全缺,
    # candidates 全族一致);fixed 带规则 -> 组件 1/1 Running。判据=组件存在性
    # (object_* 类 recheck 走人工核;辅证=object_svc rabbitmq-webhook 同族)。
    "knop-1158": [
        {"kind": "object_pods", "target": "knative-eventing/rabbitmq-controller-manager",
         "judge": "match_fixed",
         "values": {"buggy": False, "fixed": True},
         "note": "buggy=组件整体缺席(RBAC Forbidden);fixed=1/1 Running"},
        {"kind": "object_pods", "target": "knative-eventing/rabbitmq-webhook",
         "judge": "match_fixed",
         "values": {"buggy": False, "fixed": True}},
        {"kind": "event_msg",
         "target": "InternalError: failed to apply (cluster)rolebindings",
         "judge": "absent",
         "values": {"buggy": "failed to apply (cluster)rolebindings: "
                            "clusterrolebindings.rbac.authorization.k8s.io "
                            "\"eventing-sources-rabbitmq\" is forbidden",
                    "fixed": "(无)"},
         "note": "2026-09-10 补:RBAC 拒绝被 apiserver 记为 InternalError 事件 —— "
                 "operator.log 抓错 pod(伪零)时这是唯一落盘的判别渠道"},
    ],
    # <case>(2026-09-08 注册,批#7 双侧现采,stale 引擎 rc 0/2 已判别):
    # #<issue> fix = 删 sts 前查 UID。buggy 按 label 删新集群 sts 并走完 finalizer
    # 级联(ssl-internal 被删且不再重建,Optional mount 不自愈);fixed 保住
    # sts -> finalizer 停在 sts 重试 -> secret 存活。sts 本体会被新 CR 重建
    # (快照时已同构),故用 secret 残差做 telemetry 侧判据;引擎侧 verify
    # (sts gone-or-deleting PASS/FAIL)是主判别。
    "k8spsmdb-430": [
        {"kind": "object_secrets", "target": "default/mongodb-cluster-ssl-internal",
         "judge": "match_fixed",
         "values": {"buggy": False, "fixed": True},
         "note": "buggy label 级联删除的持久残差;engine verify 为主判"},
        # 2026-09-10 补正向伴随腿(与上面同因:单腿"buggy 侧缺席"= T2 结构空真,
        # 任何采集失败都得到同一个 False)。secret 被删 -> mongod 起不来 ->
        # 三副本 liveness 全挂:events 里 Warning Unhealthy / "Liveness probe
        # failed:" 打在 rs0-0/1/2 上,buggy 3 条 / fixed 0 条(原始文本复数核过)。
        {"kind": "event_msg", "target": "Unhealthy: Liveness probe failed:",
         "judge": "absent", "values": {"buggy": "Liveness probe failed:", "fixed": "(无)"},
         "note": "正向伴随腿(rs0-0/1/2 三副本 liveness 全挂);"
                 "故障期确实发生过,可挡采集失败造成的空真通过"},
    ],
    # ===== 2026-09-09 批#8 双 v4 采后注册(6 案;判据对 raw 快照逐案核实;
    # <case>/<case>/k8spsmdb-579/<case> 四案 OK 门过但判别无效,
    # 见 batch8 复核记录,未注册) =====
    # <case>(批#8):stale 只冻 CR,重启后 operator 按 stale spec 把
    # zookeeper-cluster 2 缩到 1(buggy);#<issue> fix 后照 live 拒缩(fixed)。
    # 引擎 verify 为主判(buggy rc=0 / fixed rc=2);telemetry 侧 = 缩容后
    # pod 级残差(zookeeper-cluster-0 Pending + PVC 缺佐证)。
    "zkop-312": [
        {"kind": "sts_ready", "target": "zookeeper-cluster", "judge": "match_fixed",
         "values": {"buggy": "0/1", "fixed": "1/1"},
         "note": "stale 缩容:buggy sts 0/1/pod Pending/PVC 缺;fixed 1/1"},
    ],
    # <case>(批#8):stale delete-path——buggy 按 frozen 视图删 pxc
    # sts/pods/pvc 全套;fixed(<case> v1.7.0 backport)保住 3/3。
    # 引擎 verify 0/2。svc-selector 差是 operator 自身 deploy 噪音,不判。
    "k8spxc-716": [
        {"kind": "sts_ready", "target": "xtradb-cluster-pxc", "judge": "match_fixed",
         "values": {"buggy": "(无)", "fixed": "3/3"},
         "note": "buggy pxc sts/pods/pvc 三件全缺(误删),fixed 3/3 Running"},
    ],
    # <case>(批#8):manual 路径 dummy secret 中间态——buggy
    # reconsileSSL 早退不建 ssl-internal(previous mongod 崩溃日志 3 份);
    # fixed 建齐。同 430 判据形态。
    "k8spsmdb-578": [
        {"kind": "object_secrets", "target": "default/mongodb-cluster-ssl-internal",
         "judge": "match_fixed",
         "values": {"buggy": False, "fixed": True},
         "note": "ssl-internal 缺失;辅证 buggy previous mongod 崩溃日志 3 份"},
        # 2026-09-10 补正向伴随腿:原唯一判据"buggy 侧 secret 缺席"= T2 结构空真
        # (任何采集失败都得到同一个 False)。真症状在 operator 容器日志的 error 字段:
        # buggy 侧 operator 反复报 replset 成员状态未定义 —— 缺 ssl-internal 的客户端
        # 证书 → mongod 起不来 → cfg/rs0 成员进不了已定义状态 → operator 拨号失败。
        # buggy 5 条 / fixed 0 条(原始文本双侧复数,已过幽灵滤:名字规则 + mtime 规则)。
        # 反查"是不是没采到":fixed 的 operator 容器日志满(60000 B / 65 JSON 行 /
        # 22 条 error),且同窗口内 fixed 的 rs0-2 mongod 日志有 `RSM host was added to
        # the topology` / `RSM Topology Change` / `Updating the shard registry` 等稳态
        # 消息而 buggy 一条没有 → 成员确实起来了,不是采集断档。
        # 残留不确定性:fixed 那次采集 cert-manager CRD 缺(Issuer v1alpha2 ×20),
        # 且同案 579 的 fixed 侧偶尔也会出现该消息 → 此腿是"该次运行观测到的缺席",
        # 非"修复结构性杜绝"。仍强于纯缺席腿,故登记。
        {"kind": "clog_sig", "target": "undefined state of the replset member",
         "judge": "count_zero", "values": {"buggy": 5, "fixed": 0},
         "note": "正向伴随腿(operator 容器日志 error 字段;buggy 5/fixed 0 raw 复核);"
                 "同批 dial:: failed to ping mongo(buggy 3/fixed 0)为同因佐证,不再单列"},
    ],
    # <case>(批#8):v3 manual-TLS——ssl-internal 被删后 operator 重启,
    # buggy reconsileSSL(#<issue> 前)早退不重建;fixed 重建。fixed 侧 sts 2/3
    # 是重建恢复期快照,判据只锚 secret 存在性。
    "k8spxc-897": [
        {"kind": "object_secrets", "target": "default/xtradb-cluster-ssl-internal",
         "judge": "match_fixed",
         "values": {"buggy": False, "fixed": True},
         "note": "删 secret+重启:buggy 不重建(secret 缺);fixed 重建"},
    ],
    # <case>(2026-09-13 按 drift 配方重采后改锚):与 897 同型——删
    # ssl-internal 再重启 operator,buggy 的 reconsileSSL 早退不重建,
    # fixed 重建。旧语料是 **sieve 配方**采的(先杀 operator 再删 secret,
    # 下游表现为 monitor 用户事务连不上),那条 log_sig 在 drift 配方里
    # 根本不出现(先等 3/3 健康再删 secret,monitor 步骤会成功),
    # 新 buggy 语料实测该串 0 次(旧语料 11 次)→ 不判别,故移出 CASE_SIG。
    "k8spxc-896": [
        {"kind": "object_secrets", "target": "default/xtradb-cluster-ssl-internal",
         "judge": "match_fixed",
         "values": {"buggy": False, "fixed": True},
         "note": "删 secret+重启:buggy 不重建(secret 缺);fixed 重建"},
    ],
    # <case>(批#8):volcano admission bundle panic 循环(buggy 168 行/
    # fixed 0;operator restart 双侧 1 次,不判)。
    "sparkop-2832": [
        {"kind": "operator_log", "target": "panic_lines", "judge": "count_zero",
         "values": {"buggy": 168, "fixed": 0}},
    ],
    # <case>(批#8):mmapv1 非法 spec + CR 删除——buggy CheckNSetDefaults
    # 错误短路 Reconcile,finalizer 永不清(CR 卡 Terminating,全家对象
    # 残留,trigger FAULT VERIFIED);fixed(#<issue>)错误路径清 finalizer →
    # CR 干净删除、对象全空("无对象"= 修复态,同 <case> 形态)。
    "mgoptwo-897": [
        {"kind": "object_pods", "target": "acto-namespace/test-cluster-rs0-0",
         "judge": "absent", "values": {"buggy": True, "fixed": False},
         "note": "buggy=CR 卡 Terminating 对象残留(finalizer "
                 "delete-psmdb-pods-in-order);fixed=CR 已删对象全空"},
    ],
    # <case>(2026-09-09 活体双测实证注册):#<issue> 缺席时 affinity patch 后
    # leader STS 卡旧模板(selector 422,"Redis stateful update failed" 循环),
    # leader-2 永 Pending → 2/3;fixed 读 annotation recreate-statefulset 前台删
    # STS → 下轮按新 spec 重建,UID 8580003f/b96fc07 变 b15d8604,收敛 3/3。
    # 判据只锚 leader STS 就绪数(leader-2 Pending 是主信号;follower 两侧 3/3
    # 非判据;svc rotate label 是 #<issue> 重建衍生物,不单列)。
    "rdoptwo-480": [
        {"kind": "sts_ready", "target": "test-cluster-leader", "judge": "match_fixed",
         "values": {"buggy": "2/3", "fixed": "3/3"},
         "note": "buggy leader 2/3(leader-2 永 Pending,#411 缺席);fixed #411 "
                 "重建收敛 3/3"},
        {"kind": "clog_sig", "target": "FAIL message received from",
         "judge": "count_zero", "values": {"buggy": 4, "fixed": 0},
         "note": "issue 语义审计(2026-09-10)补:sentinel 判 master FAIL(pod 卡旧版"
                 "本→集群降级)buggy 4(follower-0/1+leader-0/1 各 1)/fixed 0;"
                 "同型 redis 日志无封顶。区别于 1692 的 norm_clog 时间戳伪影:"
                 "本锚 raw 字面双侧复数"},
    ],
    # ===== 2026-09-09 Lane A 活体救援双测注册(3 案;救援 seed 落地后判别
    # 干净,buggy fault present / fixed fault-absent,判据对 raw 快照核实) =====
    # <case>(Lane A 救援):fixed 侧 cephfilesystems 显式 standby_count_wanted
    # =1 + 去 seed fallback → #<issue> 让 ceph 把 wanted 归 0,fixed CephCluster
    # ceph.details 无 MDS_INSUFFICIENT_STANDBY;buggy 恒在(仅 MDS 无 standby)。
    # MON_DISK_LOW/POOL_NO_REDUNDANCY 两侧同有(环境噪音,非判据)。
    "rook-17372": [
        {"kind": "cr_state", "target": "cephclusters.ceph.rook.io",
         "field": "ceph_details", "judge": "match_fixed",
         "values": {"buggy": "MDS_INSUFFICIENT_STANDBY;MON_DISK_LOW;"
                             "POOL_NO_REDUNDANCY",
                    "fixed": "MON_DISK_LOW;POOL_NO_REDUNDANCY"},
         "note": "ceph.details:buggy 含 MDS_INSUFFICIENT_STANDBY(#17373 缺席,"
                 "standby wanted 未归 0);fixed 无"},
    ],
    # <case>(Lane A 救援):方案A owner-rv 抬升(stale CR ResourceVersion 标注
    # 1e10)→ fixed 重启后拒 Staleness 不缩容(2/2);buggy 照 stale spec 缩 2→1
    # (zookeeper-cluster-1 被删,健康 pod 丢失)。
    "zkop-314": [
        {"kind": "sts_ready", "target": "zookeeper-cluster", "judge": "match_fixed",
         "values": {"buggy": "1/1", "fixed": "2/2"},
         "note": "stale 缩容:buggy 缩 2→1 丢健康 pod;fixed 拒 Staleness 保 2/2"},
    ],
    # <case>(Lane A 救援):seed 换合法 operator 格式 CA(Opaque
    # cert=PEM/key=PKCS8)后,中断态 CA 残留致 keystore 永不补建(fixed 按 #<issue>
    # 两 secret 分别对账补建 keystore)。判别载体 = keystore secret 存在性。
    "k8ssand-1023": [
        {"kind": "object_secrets", "target": "default/cassandra-datacenter-keystore",
         "judge": "match_fixed",
         "values": {"buggy": False, "fixed": True},
         "note": "buggy keystore 缺(中断态 CA 残留致永不补建)+FailedMount "
                 "佐证;fixed #232 补建"},
        {"kind": "event_msg", "target": 'FailedMount: "encryption-cred-storage"',
         # 2026-09-12:卷名必须落在冒号后前 30 字符内 —— event_msg 判决只取
         # t.split(":",1)[1].strip()[:30] 做子串,原文案截断成
         # "MountVolume.SetUp failed for v" 会把 local-path-provisioner
         # 自身启动竞态的 FailedMount(config-volume / local-path-config)
         # 也吃进去,固定侧假 MISMATCH。
         "judge": "absent",
         "values": {"buggy": "MountVolume.SetUp failed for volume \"encryption-cred-storage\"",
                    "fixed": "(无)"},
         "note": "2026-09-10 补:旧报告 events 只给聚合计数(14v13),这条成族消息"
                 "被淹;逐字 = secret \"cassandra-…-keystore\" not found"},
    ],
    # <case>(2026-09-09 批#6 收口):kill-window 三版配方命中——buggy 冻
    # 停 Ongoing、重启 GetPod(rack1-1) NotFound 死循环,PVC 孤儿在场;fixed
    # #<issue> 内联落盘 Finalizing -> 重启清理 -> PVC 删除。判别载体 = PVC
    # data-cassandra-cluster-dc1-rack1-1 存在性(seed 终态 + diff 双侧同证)。
    "casskop-370": [
        {"kind": "object_pvc", "target": "default/data-cassandra-cluster-dc1-rack1-1",
         "judge": "absent",
         "values": {"buggy": True, "fixed": False},
         "note": "buggy PVC 孤儿在场(卡 Ongoing GetPod NotFound 死循环);"
                 "fixed #377 清理删除;seed 双侧 FAULT/fault-not-manifested"},
        {"kind": "log_sig", "target": "decommission_pod_notfound",
         "judge": "count_zero", "values": {"buggy": 40, "fixed": 0},
         "note": "issue 语义正中(#370:crash 后缺 pod 触发 NotFound):operator.log "
                 "level=error 'Failed to get last pod ... not found' buggy 40/"
                 "fixed 0。deep_sweep 归一化把带 pod 名的行拆成唯一键 top-20 没露,"
                 "raw grep 抓到;'Error with decommission' 20/2 不净,弃"},
    ],
    # <case>(2026-09-09 回滚 emptyDir ground truth):OT-CONTAINER-KIT
    # redis-operator #<issue>(v0.23.0)/fix #<issue>(1e7e76ea)。单删 follower ->
    # 新 IP;gossip 旧 IP 标 fail;buggy repairDisconnectedMasters 跳 slave
    # + CheckRedisNodeCount 计 fail 节点 -> state=Failed 永不自愈;fixed
    # RepairDisconnectedNodes MEET+REPLICATE ~3min 回 Ready(09-07 emptyDir
    # 实证 fixed heal 在 operator.log,当时伪快照仅因采早;settle 420s+Ready
    # 门后可分)。
    "rdoptwo-1692": [
        {"kind": "cr_state", "target": "redisclusters.redis.redis.opstreelabs.in",
         "field": "state", "judge": "match_fixed",
         "values": {"buggy": "Failed", "fixed": "Ready"},
         "note": "reason='RedisCluster has unhealthy nodes';operator 循环 "
                 "'healthy leader count does not match desired' 佐证"},
    ],
    # <case>(2026-09-10 场景重设计,ns=207 双采实证):gen0 CR 带坏
    # pxc.nodeSelector={disktype: do_not_exist};PRE_SEED_NODE_LABELS 只给
    # 2 个 worker 打该 label -> pxc-0/1 Running(集群有 primary)+ pxc-2 因
    # 硬 required anti-affinity 无第 3 个匹配节点 Pending(= 3 副本只有 2 节点
    # 可调度)。trigger merge-patch 删 selector 后:buggy smartUpdate 卡
    # upgrade.go:279 `ReadyReplicas(2)<Replicas(3) -> return nil`,永不滚
    # pxc-2;fixed #<issue>(eab99321)无此门 -> 滚通 pxc-2 -> 3/3 ready。
    # 注:必须留 primary —— 全 pod Pending 时 fixed 的 getPrimaryPod(proxyDB
    # 连 haproxy 查 primary)也失败 -> 两路同堵不判别(ns=205/206 实证)。
    "xtop-1155": [
        {"kind": "cr_state", "target": "perconaxtradbclusters.pxc.percona.com",
         "field": "state", "judge": "match_fixed",
         "values": {"buggy": "initializing", "fixed": "ready"},
         "note": "buggy 卡 gate 永不收敛(initializing);fixed 3/3 ready"},
        {"kind": "pod_status", "target": "test-cluster-pxc-2", "judge": "match_fixed",
         "values": {"buggy": "0/3/Pending", "fixed": "3/3/Running"},
         "note": "第 3 副本:buggy 带坏 selector 永不滚(Pending);fixed 滚通 Running"},
    ],
    # <case>(2026-09-09 重做 relabel+直删):gen0 haproxy.nodeSelector=
    # old(worker1-3 old/worker4 new),gen1 改 new;buggy v1.11.0 updatePod
    # 不传播 nodeSelector -> STS 卡 old;trigger 摘 old label+直删 haproxy
    # pod(绕 PDB)-> buggy replacement 卡 stale selector Pending;fixed
    # (#<issue> 全量重建传播)滚到 new 节点 Running。
    "xtop-1067": [
        {"kind": "pod_status", "target": "test-cluster-haproxy-0", "judge": "match_fixed",
         "values": {"buggy": "0/1/Pending", "fixed": "1/1/Running"},
         "note": "CR= new vs STS= old 的 spec<->config drift 显形"},
        {"kind": "sts_ready", "target": "test-cluster-haproxy", "judge": "match_fixed",
         "values": {"buggy": "0/3", "fixed": "3/3"},
         "note": "antiAffinityTopologyKey=none 后 fixed 3 副本可全落唯一 "
                 "haproxy-role=new 节点(旧 hostname 硬反亲和造成 fixed 伪快照)"},
    ],
    # nifikop-49(2026-09-10 RollingPin 修后注册,ns=205 buggy 单侧重采 +
    # 00:24 fixed 旧采):#88 fix=persist-first(resource.go 先 persist OutOfSync
    # 再写 config)。drift = 写 config B 后 persist 403 -> 重启 diff 空判
    # in-sync -> node 永不滚 -> config B 永不生效(静默,无正置故障串)。
    # 判别曾是 fixed 侧 operator 真把 node 滚过("Rolling Upgrade in Progress"
    # 10 条 + 2 pod delete),buggy 0 —— 2026-09-10 用户裁决裁撤(见下)。
    # 撤销后本案 confirmed=0 → usable_as_oracle=False(用户已接受下线)。
    "nifikop-49": [
        # 2026-09-10 裁撤:唯一一条 confirmed,且是人为 fixed_only 方向 —— buggy 侧
        # 按构造不出串,判的是"跑哪个二进制"而非"故障是否发生"。用户选择下线而非留假门。
        # (注:harbor 侧 tests/test_noop.py 文件名误导,其实是真评分器 —— 内嵌隐藏 GT
        #  dict 判 diagnosis.json 的 fault/file/function;73 个任务全有。但它判的是
        #  "agent 答得对不对",不是"遥测判据",两者不同轴。)
        # 回滚 = 取消下面四行注释(并接受 fixed_only 语义回归)。
        # {"kind": "log_sig", "target": "rolling_upgrade_49", "judge": "fixed_only",
        #  "values": {"buggy": 0, "fixed": 10},
        #  "note": "滚由 node ConfigurationState!=InSync 门控=#88 fix 生效;"
        #          "buggy 写 B 后 persist 403->重启 in-sync 永不滚(0 条);"
        #          "ClusterRollingUpgrading 是合法终态,靠本串判'滚过'而非终态"},
    ],
}


# 人工预置的消息签名(case -> [{id, sig, note}])。签名 = 期望错误串(子串或
# regex),在 operator.log / container_logs 里逐变体数出现次数。13b 自动挖出
# 候选;匹配上 CASE_CONFIRM 里 kind=log_sig / target=<id> 的同 id 探针才算确认。
# 自动挖掘(13a)只出 buggy-only 的归一化签名(无人工先验也能挖到判别串);
# 人工把判别签名固化到这里,避免下次重挖漂移。
CASE_SIG = {
    # <case>: #<issue> secret 无 annotations -> nil-map panic(重采后
    # panic 只在 previous_logs,现卷 0;2026-09-06 从 operator_log 探针迁移)
    "cassop-705": [
        {"id": "panic_previous",
         "sig": "assignment to entry in nil map",
         "note": "#705 configsecret nil-map panic(精确串;泛串 'panic: ' 会命中"
                 "cassandra-writer 两边共有的 1 次崩溃噪音)"},
    ],
    # <case>(2026-09-10 issue 语义审计):#<issue> crash 后缺 pod -> decommission
    # 死循环 NotFound。'Error with decommission' 20/2 不净,须用带 pod 名的精确串。
    "casskop-370": [
        {"id": "decommission_pod_notfound",
         "sig": "Failed to get last pod",
         "note": "level=error 'Failed to get last pod <pod>: not found' 循环"
                 "(buggy 40/fixed 0;deep_sweep 归一化拆唯一键没露出,raw 抓到)"},
    ],
    # <case>(2026-09-06 重采批#2 审计登记):VMAlert notifiers 空 ->
    # reconcile 每轮 Reconciler error;#<issue> fix 后正确生成 deploy。
    "vmop-2388": [
        {"id": "no_notifiers",
         "sig": "no notifiers found, properly configure selectors or static notifiers",
         "note": "buggy operator.log 7 行精确串(vs fixed 0);families 里"
                 "fault_absent 匹配串第五例"},
    ],
    # <case>(2026-09-07 离线注册):#<issue> fix=去掉 resources 缺省时的
    # nil-deref(controller-runtime recover 后以 Reconciler error 出现,
    # panic 栈进 previous_logs;buggy 2/fixed 0)。
    "rdoptwo-283": [
        {"id": "nil_panic_283",
         "sig": "panic: runtime error: invalid memory address or nil pointer dereference",
         "note": "nil-deref panic 现卷+previous 合计 2/0;manager restart 2/0 佐证"},
    ],
    # <case>(2026-09-07 离线注册):#<issue> executeCommand exec.Stream 失败
    # 后不 return 仍打假 INFO "Successfully executed the command";leader 因
    # seed probe 自伤 cluster-create 必败,fixed 恒 0(fixed 提前返回只留 ERROR)。
    "rdoptwo-292": [
        {"id": "false_success_exec_292",
         "sig": "Successfully executed the command",
         "note": "buggy=6/fixed=0('Could not execute' 两侧 6/6 为真错误对照)"},
    ],
    # <case>(2026-09-07 离线注册):VMAlertManagerConfig route 引用未定义
    # receiver -> reconcile 循环报错、VMAlertManager sts 不建;fix 后正常。
    "vmop-2185": [
        {"id": "undefined_receiver",
         "sig": "incorrect result configuration, config source=",
         "note": "buggy operator.log 21 行(vs fixed 0);sts vmalertmanager "
                 "buggy 无/fixed 1/1 佐证"},
    ],
    # ===== 2026-09-06 补采批 15 新案 signal 审计后登记(逐条核对过
    # raw 串与 fixed 侧 0 计数;计数含 operator.log+previous_logs) =====
    # <case>: #<issue> nil-pointer fix 前,operator reconcile NPE 崩溃
    # 只留 --previous(3 份崩溃日志,现卷 0 行)—— 必须扫 previous_logs
    "k8spsmdb-434": [
        {"id": "nil_panic_previous",
         "sig": "invalid memory address or nil pointer dereference",
         "note": "#434 NPE 崩溃栈(在 previous_logs,现卷翻页后为 0)"},
    ],
    # <case>: 已移出本表(2026-09-13)。原 log_sig "reconcileUsers: manage
    # monitor user" 是 **sieve 配方**的产物(先杀 operator 再删 ssl-internal);
    # drift 配方先等集群健康再删,monitor 用户那步成功,buggy 侧实测读 0 →
    # 探针不判别。改在 CASE_CONFIRM 里锚 secret 存在性(与 897 同型)。
    # <case>: selector 碰撞 -> sts 更新被 apiserver 拒(#<issue> fix)
    "rbop-2218": [
        {"id": "sts_selector_invalid",
         "sig": r'StatefulSet.apps \"rabbitmq-cluster-server\" is invalid',
         "note": "selector 不匹配导致 sts invalid(buggy=30/fixed=0,原始串含转义引号)"},
    ],
    # <case>: 按 name(非 uid)认 PVC + stale 读 -> 扩容期
    # PVC not found 循环(#<issue> fix)
    "cassandraop-402": [
        {"id": "pvc_not_found_loop",
         "sig": r'persistentvolumeclaims \"data-volume',
         "note": "PVC 识别失败循环(buggy=21/fixed=0)"},
    ],
    # <case>: Playlist/route resourceVersion bug —— 更新请求带空
    # currentVersion -> apiserver 拒 "Provided version '' does not match
    # current version"(2026-09-02 实证 buggy=28/fixed=0,error_lines 只显示
    # 62 vs 32 被共有噪音 "no matching instances" 淹掉)。字符串在 operator.log。
    "grafanaop-2864": [
        {"id": "rv_version_mismatch",
         "sig": r"does not match current version",
         "note": "Playlist/route 更新带空 RV 被拒(RV bug 本体)"},
    ],
    # <case>: alertmanager notifier 缺 chat_id(2026-09-04 实证
    # buggy=18/fixed=0,"incorrect result configuration, config source=" 包裹)。
    "vmop-2132": [
        {"id": "missing_chat_id",
         "sig": "missing chat_id",
         "note": "notifier 校验失败的本体串(避开 CRD-missing 噪音)"},
    ],
    # <case>: prometheusrules.go:33 nil-deref panic(2026-09-04 实证
    # buggy=8/fixed=0,与 issue 栈一致)。
    "logop-2172": [
        {"id": "prule_nil_panic",
         "sig": "prometheusrules.go:33",
         "note": "panic 栈帧行(比泛 panic 串更特异)"},
    ],
    # <case>: initdb Job 模板重名 pgdata 卷被 apiserver 拒
    # (2026-09-04 实证 buggy=2/fixed=0)。
    # 2026-09-04 审计:原 sig 'Duplicate value: "pgdata"' 是解码形态,但
    # operator.log 是 JSON 转义(`Duplicate value: \"pgdata\"`),txt.count
    # 数到 0 -> log_sig 探针失效(13a auto 走解码反而数到 2)。改用不含
    # 引号的稳定片段(apiserver 卷名校验错误特有),转义与否都匹配。
    "cnpgop-9972": [
        {"id": "dup_pgdata_volume",
         "sig": "spec.template.spec.volumes[3].name: Duplicate value",
         "note": "initdb Job 卷名重复被 apiserver 拒;quote-free 片段避开 JSON 转义"},
    ],
    # <case>: version 校验 panic(2026-09-04 实证 buggy=2/fixed=0)。
    "crdbop-918": [
        {"id": "validate_version_panic",
         "sig": "validate_version.go:67",
         "note": "panic 栈帧行(比泛 panic 串更特异)"},
    ],
    # ===== 2026-09-08 批#6 注册(现值逐案 grep 核对) =====
    "rdoptwo-280": [
        {"id": "ignored_vct_280",
         "sig": "ignored change in cr.spec.storage.volumeClaimTemplate",
         "note": "#280 fix 加的 patchStatefulSet 告警:buggy 静默恢复 desired=stored "
                 "不打日志。【2026-09-10 已弃用】原 judge=fixed_only,因人为主导方向"
                 "被裁撤(CASE_CONFIRM 侧注释存档)。此条仅留证据,不再作 oracle。"},
    ],
    "rdoptwo-286": [
        {"id": "nil_panic_286",
         "sig": "panic: runtime error: invalid memory address or nil pointer dereference",
         "note": "CRD 缩进丢字段 -> reconcile nil-deref(现卷 1 + previous 1)"},
    ],
    "rdoptwo-290": [
        {"id": "nil_panic_290",
         "sig": "panic: runtime error: invalid memory address or nil pointer dereference",
         "note": "resources:null 走 GetReplicaCounts nil 分支(panic 只在 "
                 "previous_logs,现卷翻页后 0)"},
    ],
    "vmop-2356": [
        {"id": "unmarshal_anomaly_2356",
         "sig": "field seasonalities not found in type config.prophetModel",
         "note": "精确串(含 type,少写即 0 命中)避开 fixed operator.log 累积的 "
                 "09-02 prometheus/reader 旧噪音(字段不同);buggy=6/fixed=0(09-08 核)"},
    ],
    "mgopone-1055": [
        {"id": "index_panic_1055",
         "sig": "panic: runtime error: index out of range [0] with length 0",
         "note": "authModes[0] 空 modes 无 guard(现卷 1 + previous 2 = 3/0)"},
    ],
    "cnpgop-11042": [
        {"id": "job_failed_unrecoverable",
         "sig": "An instance creation job has failed",
         "note": "fix 后的 job 失败处理路径日志(buggy=0/fixed=33,09-08 批#6 核)。"
                 "【2026-09-10 已弃用】原 judge=fixed_only 方向被裁撤(CASE_CONFIRM "
                 "侧注释存档);本案 oracle 现由 cr_state 承担。"},
    ],
    # nifikop-49: 滚 node = #88 persist-first fix 生效的机制签名
    # (roll 门控=node OutOfSync 已被 persist)。buggy 静默 drift 0 条。
    "nifikop-49": [
        {"id": "rolling_upgrade_49",
         "sig": "Rolling Upgrade in Progress",
         "note": "#88 fix 滚 node 签名(fixed=10/buggy=0,09-10 RollingPin 重采核)。"
                 "【2026-09-10 已弃用】原 judge=fixed_only 方向被裁撤(CASE_CONFIRM "
                 "侧注释存档);本案因此 confirmed=0、usable=False(用户接受下线)。"},
    ],
}


# ---------------------------------------------------------------- signals
def collect_signals(case, base, have):
    """从已采数据提取机器可读的候选故障信号(buggy≠fixed/reference)。

    repair 行为分的 oracle 原料:每条 signal = 探针 + 三态实测值;
    agent patch 集群上重测,值落在 fixed 侧 = 修好。自动提取的是候选
    (confirmed=false),噪音(两边都有的常态差异)由人工确认剔除。
    与 diff_report 的各段同源,但独立面向机器。"""
    sig = []

    def vfile(v, name):
        return os.path.join(base, v, name)

    def _absent(x):
        return x in (None, False, "(无)", "(absent)", "(no obj_full)", "",
                     "(no cr_full)", "(parse fail)")

    def _pol(vals):
        """候选极性(2026-09-10):注册/复核时区分"真信号"与"反向噪音"。
        buggy 独有 = 故障信号;fixed 独有 = 修复动作/反向噪音(如
        knop-1158 的 rabbitmq-controller 0→130、cnpgop-11005 的
        repl-11005-1[error] 0→10);数值则按大小方向。"""
        b = vals.get("buggy")
        others = [vals.get(v) for v in have if v != "buggy"]
        if others and all(_absent(o) for o in others) and not _absent(b):
            return "buggy_only"
        if _absent(b) and any(not _absent(o) for o in others):
            return "fixed_only"
        if others and all(isinstance(x, (int, float)) and not isinstance(x, bool)
                          for x in [b] + others):
            if all(b > x for x in others):
                return "buggy_high"
            if all(b < x for x in others):
                return "fixed_high"
        return "differs"

    def add(kind, target, values, detail=""):
        vals = {v: values.get(v) for v in have}
        if len(set(json.dumps(vals[v], sort_keys=True) for v in have)) > 1:
            sig.append({"id": f"{kind}:{target}", "kind": kind, "target": target,
                        "values": vals, "detail": detail, "confirmed": False,
                        "polarity": _pol(vals)})

    # 1. restart 计数
    rest = {v: parse_restarts(vfile(v, "restarts.txt")) for v in have}
    allk = set()
    for v in have:
        for pod, cs in rest[v].items():
            allk |= {(pod, c) for c in cs}
    for pod, c in sorted(allk):
        add("restart_count", f"{pod}/{c}",
            {v: rest[v].get(pod, {}).get(c, 0) for v in have})

    # 2. pod 状态
    pstat = {v: parse_pod_status(vfile(v, "pods.txt")) for v in have}
    for pod in sorted(set().union(*[set(pstat[v]) for v in have])):
        add("pod_status", pod, {v: "/".join(pstat[v].get(pod, ("", "(无)"))) for v in have})

    # 3. sts ready
    stsr = {v: parse_sts_ready(vfile(v, "sts.txt")) for v in have}
    for s in sorted(set().union(*[set(stsr[v]) for v in have])):
        add("sts_ready", s, {v: stsr[v].get(s, "(无)") for v in have})

    # 4. pvc 容量
    pvcap = {v: parse_pvc_capacity(vfile(v, "pvc.txt")) for v in have}
    for pv in sorted(set().union(*[set(pvcap[v]) for v in have])):
        add("pvc_capacity", pv, {v: pvcap[v].get(pv, "(无)") for v in have})

    # 5. CR 状态
    crf = {v: parse_cr_full(os.path.join(base, v)) for v in have}
    for crd in sorted(set().union(*[set(crf[v]) for v in have])):
        add("cr_state", crd, {v: crf[v].get(crd) for v in have})

    # 6. 对象存在性(2026-09-08 加 secrets 维度,配 <case> v3 判据)
    for res in ("pods", "sts", "pvc", "svc", "secrets"):
        obs = {v: object_names(vfile(v, f"{res}.txt"), res) for v in have}
        for o in sorted(set().union(*[obs[v] for v in have])):
            add(f"object_{res}", o, {v: o in obs[v] for v in have})

    # 6b. svc selector 对比(2026-09-06 <case> 教训):两边 svc 都在、
    # 存在性维度无差异,但 spec.selector 才是碰撞/修复的决定性判据
    # (buggy `name: tekton-operator` vs fixed `name: tekton-operator-proxy-webhook`)
    try:
        import yaml as _y
        ssel = {}
        for v in have:
            f = vfile(v, "obj_full/svc.yaml")
            d = {}
            if os.path.isfile(f):
                doc = _y.safe_load(open(f, errors="ignore")) or {}
                for it in doc.get("items") or []:
                    try:
                        d[it["metadata"]["name"]] = it.get("spec", {}).get("selector") or {}
                    except (KeyError, TypeError):
                        continue
            ssel[v] = d
        for name in sorted(set().union(*[set(ssel[v]) for v in have])):
            if sum(1 for v in have if name in ssel[v]) >= 2:
                add("svc_selector", name, {v: ssel[v].get(name) for v in have})
    except Exception:
        pass

    # 7. drift 三探针(与 diff 段同源)
    if case == "mgoptwo-895":
        import yaml as _y
        vals = {}
        for v in have:
            f = vfile(v, "cr_full/perconaservermongodbs.psmdb.percona.com.yaml")
            nsvc = 0
            sf = vfile(v, "svc.txt")
            if os.path.isfile(sf):
                nsvc = len(re.findall(r"test-cluster-rs0-\d+", open(sf, errors="ignore").read())) // 2
            if os.path.isfile(f):
                try:
                    d = _y.safe_load(open(f))
                    expo = (d["items"][0]["spec"]["replsets"][0].get("expose") or {}).get("enabled")
                    vals[v] = f"expose={expo},svc={nsvc},residue={expo is not True and nsvc >= 1}"
                except Exception:
                    vals[v] = "(parse fail)"
            else:
                vals[v] = "(no cr_full)"
        add("drift_svc_residue", "test-cluster-rs0-*", vals)
    elif case == "mgoptwo-696":
        vals = {}
        for v in have:
            f = vfile(v, "obj_full/sts.yaml")
            vals[v] = ("ACTOKEY" in open(f, errors="ignore").read()
                       if os.path.isfile(f) else "(no obj_full)")
        add("drift_sts_annotation", "test-cluster-rs0 template", vals)
    elif case == "zkop-474":
        import yaml as _y
        vals = {}
        for v in have:
            f = vfile(v, "obj_full/svc.yaml")
            hit = None
            if os.path.isfile(f):
                try:
                    st = _y.safe_load(open(f))
                    for it in (st or {}).get("items") or []:
                        if it["metadata"]["name"] == "test-cluster-admin-server":
                            hit = "ACTOKEY" in json.dumps(it["metadata"].get("annotations") or {})
                except Exception:
                    hit = "(parse fail)"
            vals[v] = hit if hit is not None else "(no obj_full)"
        add("drift_svc_annotation", "test-cluster-admin-server", vals)
    elif case == "rdoptwo-474":
        # 2026-09-07:exporter-disable 后 svc 是否残留 9121(#<issue> enableMetrics
        # 无 else;seed 修 clusterVersion 后此维度才可达)。
        import yaml as _y
        for target in ("test-cluster-leader", "test-cluster-follower"):
            vals = {}
            for v in have:
                f = vfile(v, "obj_full/svc.yaml")
                val = None
                if os.path.isfile(f):
                    try:
                        doc = _y.safe_load(open(f)) or {}
                        for it in doc.get("items") or []:
                            if (it.get("metadata") or {}).get("name") == target:
                                ports = sorted(p.get("port")
                                               for p in (it.get("spec") or {}).get("ports") or []
                                               if isinstance(p, dict) and p.get("port"))
                                val = ",".join(str(x) for x in ports)
                                break
                    except Exception:
                        val = "(parse fail)"
                vals[v] = val if val is not None else "(svc无)"
            add("svc_ports", target, vals)

    # 8. 业务容器日志故障模式(v4)
    clog = {v: container_log_stats(os.path.join(base, v)) for v in have}
    for pod in sorted(set().union(*[set(clog[v]) for v in have])):
        for pat in FAULT_PATTERNS:
            vals = {v: clog[v].get(pod, {}).get(pat, 0) for v in have}
            if any(x for x in vals.values()):
                add("container_log", f"{_norm_name(pod, 'pods')}[{pat}]", vals)

    # 8b. events 消息文本(2026-09-02):buggy 独有的 Warning/InternalError
    # 消息(计数挖掘不到的载体,<case> InternalError 教训)
    emsg = {v: event_msgs(vfile(v, "events.txt")) for v in have}
    uniq = (set(emsg.get("buggy", ())) - set(emsg.get("fixed", ()))
            - set(emsg.get("reference", ())))
    for reason, msg in sorted(uniq)[:6]:
        add("event_msg", f"{reason}: {msg[:70]}",
            {v: (msg[:160] if (reason, msg) in emsg.get(v, ()) else "(无)")
             for v in have})

    # 9. lastState OOM(v4)
    lst = {v: last_state_stats(vfile(v, "pods.json")) for v in have}
    for pod in sorted(set().union(*[set(lst[v]) for v in have])):
        add("last_state", pod, {v: lst[v].get(pod, {"oom": 0, "exit137": 0, "last_reason": ""}) for v in have})

    # 10. sts template(VCT/注解/limits,v4)
    stst = {v: sts_template_stats(os.path.join(base, v)) for v in have}
    for s in sorted(set().union(*[set(stst[v]) for v in have])):
        for field in ("vct", "ann_has_actokey", "limits"):
            vals = {v: (stst[v].get(s) or {}).get(field) for v in have}
            if any(x is not None for x in vals.values()):
                add("sts_template", f"{s}.{field}", vals)

    # 11. rbac(v4)
    rb = {v: rbac_stats(os.path.join(base, v)) for v in have}
    for res in ("roles", "clusterroles", "rolebindings", "clusterrolebindings"):
        vals = {v: rb[v].get(res) for v in have}
        if any(x is not None for x in vals.values()):
            add("rbac", res, vals)

    # 12. operator.log(有效时)error/panic —— 方向校准(v4):
    #   * stuck 类 case(buggy operator 卡住不动)天然"buggy error 少、fixed
    #     error 多"—— 修复后处理的事件更多。反向信号(buggy < fixed)直接
    #     剔除,不污染候选(<case> 教训:buggy=3(fixed=50)实为噪音)
    #   * 正向才收:buggy error >= fixed error(且差值>0),且 buggy 超过
    #     噪声底限(2 行,seed 里的 CassandraTask "dc2 not found" 类噪音)
    lstats = {}
    valid = {}
    for v in have:
        p = vfile(v, "operator.log")
        ok = os.path.isfile(p) and "controllermanager.go" not in open(p, errors="ignore").read(4000)
        valid[v] = ok
        lstats[v] = log_stats(p) if ok else {}
    if all(valid[v] for v in have) and any(lstats.values()):
        # 2026-09-10:加入 warning_lines —— <case> 的判别串
        # (`ignoring "workload_identity" ... version=v3.6.0`)是 warn 级,
        # 旧版只收 error/panic 会把它漏掉。
        for key in ("error_lines", "panic_lines", "warning_lines"):
            b = lstats.get("buggy", {}).get(key, 0)
            f = lstats.get("fixed", {}).get(key, 0)
            r = lstats.get("reference", {}).get(key, 0) if "reference" in lstats else 0
            if b >= 2 and b > f and b > r:
                add("operator_log", key,
                    {v: lstats[v].get(key, 0) for v in have})

    # 13. 消息签名挖掘(v5,2026-09-02):特定错误串的"计数/存在"判别 —— 计数维
    #     的行数差会被共有噪音淹掉(<case>:error_lines 62 vs 32),
    #     但错误消息本体是干净的(同一 case 实证 buggy=28/fixed=0)。两路:
    #     13a auto:operator.log 里 buggy-only 的归一化 "error":值
    #             (buggy>=2,fixed==0,reference==0),cap 6 —— 无人工先验也
    #             能挖出判别串(2864 的 RV 串即由此浮现)
    #     13b 人工:CASE_SIG[case] 逐条在 operator.log 全文本按变体计数;
    #             结果给 CASE_CONFIRM kind=log_sig 的探针做原料
    # 容器日志不在此(8 段 FAULT_PATTERNS 已覆盖计数信号);这里只针对
    # operator.log 的 error 字段消息。
    if valid.get("buggy") and valid.get("fixed"):
        # 13a auto
        _ov = {}
        for v in have:
            if not valid.get(v):
                continue
            _c = {}
            # 2026-09-10:改用 variant_log_text(operator.log + previous_logs)
            # —— 崩溃类 case 的 error 字段翻页进 --previous 后现卷为空
            # (<case> panic / <case> nil-map),旧版扫不到。
            for s in log_error_values_text(variant_log_text(os.path.join(base, v))):
                _c[s] = _c.get(s, 0) + 1
            _ov[v] = _c
        cand = []
        for s, n in _ov.get("buggy", {}).items():
            if (n >= 2 and len(s) >= 20
                    and _ov.get("fixed", {}).get(s, 0) == 0
                    and _ov.get("reference", {}).get(s, 0) == 0):
                cand.append((n, s))
        cand.sort(key=lambda x: (-x[0], len(x[1])))
        kept = []
        for n, s in cand:
            if any(s2 in s for _, s2 in kept):  # 留原子短签名,跳外层包裹重复
                continue
            kept.append((n, s))
            if len(kept) >= 6:
                break
        for n, s in kept:
            add("log_sig", f"auto:{s[:60]}",
                {v: _ov.get(v, {}).get(s, 0) for v in have},
                detail=f"[auto buggy-only] {s[:220]}")
        # 13b 人工 CASE_SIG(默认子串计数;带 re 标记的按 regex 全文本找)
        for rule in CASE_SIG.get(case, []):
            pat = rule.get("sig", "")
            rx = re.compile(pat) if rule.get("re") else None
            counts = {}
            for v in have:
                if not valid.get(v):
                    counts[v] = 0
                    continue
                txt = variant_log_text(os.path.join(base, v))
                counts[v] = len(rx.findall(txt)) if rx else txt.count(pat)
            if len(set(counts.values())) > 1 or any(counts.values()):
                add("log_sig", rule["id"], counts, detail=rule.get("note", ""))

    # 13c. 容器日志消息级签名(v6,2026-09-10 静默案重分类):buggy 独有的
    #      归一化容器日志消息(buggy>=2,fixed==0,reference==0),cap 8。
    #      §8 只给 FAULT_PATTERNS 子串计数、§13a 只读 operator.log 的 error
    #      字段 —— 14 案(pg_basebackup 目录非空 / mongo-agent BadValue /
    #      mongod Heartbeat failed 等)消息本体因此在 diff 层隐身。
    cm = {v: container_log_msgs(os.path.join(base, v)) for v in have}
    kept, _cagg = clog_sig_candidates(cm, have)
    for n, m in kept:
        pods = sorted(p for p, ms in cm.get("buggy", {}).items() if m in ms)
        # 2026-09-11:m[:70] 截断曾把锚在消息尾部的候选切掉(peer did not
        # return a certificate / Duplicate value / Invalid command argument
        # 等 5 腿因此"只登记无候选支撑")—— 实测锚最深在偏移 589
        # (<case> 的 BadValue 串)/panic 串在 3972 字符块内,
        # target 放宽到 600。
        add("clog_sig", m[:600],
            {v: _cagg.get(v, {}).get(m, 0) for v in have},
            detail=f"[auto buggy-only 容器日志] {m[:300]} | "
                   f"buggy pods: {','.join(pods[:3])}")

    # 14. CR spec/conditions 挖掘(v6,2026-09-03):判别在 CR 对象层而非
    #     日志/计数的 case —— 315 = spec.rollingRestartRequested 永不被
    #     消费(buggy 在场/fixed 消费后消失),12542 = bad-connector
    #     conditions NotReady=True vs Ready=True。cr_state 只抽 status 的
    #     state/phase/ready/replicas 通用键,这里补 spec 字段(深度 2)与
    #     conditions type/status。只比两边同名同 kind 的 CR(随机名 CR 如
    #     cert-manager CertificateRequest 自动出局);只在 buggy≠fixed 时
    #     出候选,reference 不参与判别避免缺采误报。
    if valid.get("buggy") and valid.get("fixed"):
        import yaml as _y14

        def _cr_index(v):
            idx = {}
            cdir = os.path.join(base, v, "cr_full")
            if not os.path.isdir(cdir):
                return idx
            for fn in os.listdir(cdir):
                if not fn.endswith(".yaml"):
                    continue
                try:
                    d = _y14.safe_load(open(os.path.join(cdir, fn),
                                            errors="ignore"))
                except Exception:
                    continue
                items = d.get("items", [d]) if isinstance(d, dict) else d
                if not isinstance(items, list):
                    continue
                kind = fn[:-5]
                for it in items:
                    if not isinstance(it, dict):
                        continue
                    name = (it.get("metadata") or {}).get("name")
                    if name:
                        idx[(kind, name)] = it
            return idx

        def _flat(d, pfx="", depth=2):
            out = {}
            if not isinstance(d, dict) or depth < 0:
                return out
            for k, v in d.items():
                key = f"{pfx}.{k}" if pfx else str(k)
                if isinstance(v, bool):
                    out[key] = str(v)
                elif isinstance(v, (str, int, float)) or v is None:
                    out[key] = v
                elif isinstance(v, list):
                    out[key] = json.dumps(v, ensure_ascii=False)[:120]
                elif isinstance(v, dict):
                    if depth == 0:
                        out[key] = json.dumps(v, ensure_ascii=False)[:120]
                    else:
                        out.update(_flat(v, key, depth - 1))
            return out

        ci = {v: _cr_index(v) for v in have if valid.get(v)}
        shared = set(ci.get("buggy", {})) & set(ci.get("fixed", {}))
        for kind, name in sorted(shared):
            cr = {v: ci[v][(kind, name)] for v in ci}
            # a) spec 字段(存在性/值差异;缺失侧记 "(absent)")
            fs = {v: _flat(cr[v].get("spec") or {}) for v in cr}
            keys = set()
            for v in fs:
                keys.update(fs[v])
            for k in sorted(keys):
                vals = {v: fs[v].get(k, "(absent)") for v in cr}
                if vals.get("buggy") != vals.get("fixed"):
                    add("cr_spec", f"{kind}/{name}.{k}", vals)
            # b) conditions type/status 集合
            cv = {}
            for v in cr:
                cc = (cr[v].get("status") or {}).get("conditions") or []
                cv[v] = ";".join(sorted(f"{c.get('type')}={c.get('status')}"
                                        for c in cc if isinstance(c, dict)))
            if cv.get("buggy") != cv.get("fixed"):
                add("cr_conditions", f"{kind}/{name}", cv)

    return sig


# ---------------------------------------------------------------- confirmed 现值重算 (D2, 2026-09-04)
def _yaml_items(path):
    """cr_full/<kind>.yaml -> items 列表(与 collect_signals §14 同源)。"""
    import yaml as _y
    if not os.path.isfile(path):
        return []
    try:
        d = _y.safe_load(open(path, errors="ignore"))
    except Exception:
        return []
    items = d.get("items", [d]) if isinstance(d, dict) else d
    return items if isinstance(items, list) else []


def _deep_scalar(node, key):
    """嵌套 dict/list 里第一个标量的 key 值;None 表示没找到。"""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key and not isinstance(v, (dict, list)):
                return v
            r = _deep_scalar(v, key)
            if r is not None:
                return r
    elif isinstance(node, list):
        for x in node:
            r = _deep_scalar(x, key)
            if r is not None:
                return r
    return None


def _count(v):
    """Read a probe value as a COUNT, or None if it is not a count.

    The count_zero / fixed_only judges compare readings against 0, but the
    readers return sentinel STRINGS when the artifact a probe needs is absent
    from a variant dir ("(log无效)", "(无)", "(svc无)", "?"). `x > 0` on one of
    those raised TypeError and took the WHOLE evaluation down with it -- one
    unreadable probe lost every other probe in the case (cnpgop-10665,
    2026-09-13 00:10: rows came back empty and the in-sandbox recovery judge
    reported VACUOUS). `"0" or 0` was the quieter half of the same bug: a
    string "0" is == 0 False, so a real zero read as non-zero.

    None means "not a count" -- neither >0 nor ==0.
    """
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return None


def recheck_confirmed(case, base, have, confirmed):
    """对每条 confirmed 探针,用当前 raw 重算现值,判断"现在是否还判别 buggy≠fixed"。

    2026-09-04 审计发现(D2):diff 原先盲信静态 CASE_CONFIRM,不校验现值 ——
    buggy 已干净的旧快照(如 cassop-705 #705 未触发、panic 0/0)仍标 usable,
    静默伪装成 OK oracle。此函数把 /tmp/audit_ok.py 的现值重算搬进主流程。

    判据语义:
      * count_zero   -> ok = 现值 buggy>0 且 fixed==0(故障计数在场)
      * match_fixed/absent -> ok = 现值 buggy != 现值 fixed(仍判别)
      * drift_* / auto:xx / 载体缺失 -> ok=True + note(无法现算,人工核 diff_report)
    返回 (逐条 recheck 列表, case 是否全 ok)。
    注意:本函数只读现值,不改 usable(调用方按"全失配才拉 False"策略处理)。"""
    import yaml as _y  # noqa: F401  (drift 段用)

    def vfile(v, name):
        return os.path.join(base, v, name)

    def valid_log(v):
        p = vfile(v, "operator.log")
        return os.path.isfile(p) and "controllermanager.go" not in open(p, errors="ignore").read(4000)

    out = []
    for probe in confirmed:
        k = probe.get("kind")
        t = probe.get("target", "")
        judge = probe.get("judge", "match_fixed")
        field = probe.get("field")
        pres = {}
        note = ""
        # ---- 逐 kind 现算 buggy/fixed 现值 ----
        if k == "restart_count":
            parts = t.split("/")
            key, cont = "/".join(parts[:-1]), parts[-1]
            for v in have:
                rest = parse_restarts(vfile(v, "restarts.txt"))
                pres[v] = restart_lookup(rest, key, cont)
        elif k == "operator_log":
            for v in have:
                if not valid_log(v):
                    pres[v] = "(log无效)"
                else:
                    pres[v] = log_stats(vfile(v, "operator.log")).get(t, 0)
        elif k == "container_log":
            m = re.match(r"(.*)\[(.*)\]$", t)
            for v in have:
                vdir = os.path.join(base, v)
                st = container_log_stats(vdir) if os.path.isdir(vdir) else {}
                pres[v] = (st.get(m.group(1)) or {}).get(m.group(2), 0) if m else "(bad-target)"
        elif k.startswith("object_"):
            # 2026-09-10(逃逸口审计):此前 object_* 落到末尾 else 分支
            # ("kind=… 现算未实现")且 ok=True —— 10 条 confirmed 判据
            # (ssl-internal secret / keystore / rabbitmq·prometheus pod /
            # cassandra PVC)从未做过现值重算,等于"免检"。这里复用
            # collect_signals §6 的同一函数(object_names),口径一致。
            res = k[len("object_"):]
            tlast = t.split("/")[-1]
            for v in have:
                names = object_names(vfile(v, f"{res}.txt"), res)
                # object_names 产出 "ns/name";target 可能写成 "ns/name" 也可能
                # 只写裸名 —— 两种都认,但要求整段相等(勿用子串,否则
                # xxx-ssl-internal 会误命中 xxx-ssl-internal-old)。
                pres[v] = (t in names) or any(n.split("/")[-1] == tlast for n in names)
        elif k in ("drift_svc_annotation", "drift_sts_annotation"):
            # 同 collect_signals 的 drift 探针(svc/sts 模板里是否残留 ACTOKEY 注解);
            # <case> / <case> 各一条,此前也走 else 免检。
            import yaml as _y
            for v in have:
                f = vfile(v, "obj_full/sts.yaml" if k == "drift_sts_annotation"
                          else "obj_full/svc.yaml")
                hit = None
                if os.path.isfile(f):
                    try:
                        st = _y.safe_load(open(f))
                        for it in (st or {}).get("items") or []:
                            if it["metadata"]["name"] == t:
                                hit = "ACTOKEY" in json.dumps(
                                    it["metadata"].get("annotations") or {})
                    except Exception:
                        hit = "(parse fail)"
                pres[v] = hit if hit is not None else "(no obj_full)"
        elif k == "clog_sig":
            # 2026-09-10(静默案重分类):容器日志归一化消息计数。target = 归一化
            # 消息(norm_clog 已剥 klog 前缀/时间戳/<pod>/hex)的稳定子串;
            # container_logs/ 与 previous_logs/ 一起数,msg/error 等字段都算。
            # 与 container_log(按 pod[severity] 计行)互补:本 kind 是跨 pod 的
            # 消息级判别(pg_basebackup 业务错、mongod heartbeat、panic 栈)。
            for v in have:
                cm = container_log_msgs(os.path.join(base, v))
                pres[v] = sum(n for ms in cm.values() for msg, n in ms.items()
                              if t in msg)
        elif k == "log_sig":
            sigtxt = None
            for rule in CASE_SIG.get(case, []):
                if rule.get("id") == t:
                    sigtxt = rule.get("sig")
                    if rule.get("re"):
                        sigtxt = None
            if sigtxt is None:
                # auto 挖出或非 CASE_SIG 的 sig:现算不可靠(解码路径不同),人工核
                note = "非 CASE_SIG id/auto 探针,现算需人工核 diff_report log_sig 段"
                for v in have:
                    pres[v] = "(manual)"
            else:
                for v in have:
                    if not valid_log(v):
                        pres[v] = "(log无效)"
                    else:
                        txt = variant_log_text(os.path.join(base, v))
                        pres[v] = txt.count(sigtxt)
        elif k == "pod_status":
            tlast = t.split("/")[-1]
            for v in have:
                ps = parse_pod_status(vfile(v, "pods.txt"))
                pres[v] = "/".join(ps.get(tlast, ("", "(无)")))
        elif k == "sts_ready":
            tlast = t.split("/")[-1]
            for v in have:
                ss = parse_sts_ready(vfile(v, "sts.txt"))
                pres[v] = ss.get(tlast, "(无)")
        elif k == "event_msg":
            reason = t.split(":", 1)[0].strip() if ":" in t else ""
            sub = t.split(":", 1)[1].strip()[:30] if ":" in t else ""
            for v in have:
                hit = None
                for (rs, msg) in event_msgs(vfile(v, "events.txt")):
                    if reason and rs == reason and (not sub or sub in msg):
                        hit = msg[:160]
                        break
                pres[v] = hit if hit else "(无)"
        elif k == "cr_state":
            for v in have:
                crf = parse_cr_full(os.path.join(base, v))
                rows = crf.get(t, [])
                val = None
                for r in rows:
                    if field == "nodeReplacements":
                        # cass-operator status.nodeReplacements:list[str](<case>
                        # #<issue> 幽灵名残留 ['ACTOKEY'],buggy 在/fixed null)。
                        # _deep_scalar 只回标量,list 须 join(同 ceph_details 先例,
                        # 2026-09-10 盲点审计补)。
                        nr = r.get("nodeReplacements") or []
                        val = ";".join(sorted(nr)) or None
                    elif field == "ceph_details":
                        # rook CephCluster.status.ceph.details:list[str] 键(仅在
                        # 该告警 message 非空时列入)。join 成串后走"现值不等=判别"
                        # 语义;配 <case>(MDS_INSUFFICIENT_STANDBY 只在 buggy)。
                        cd = r.get("ceph_details") or []
                        val = ";".join(sorted(cd)) or None
                    else:
                        val = _deep_scalar(r, field) if field else r.get("name")
                    if val is not None:
                        break
                pres[v] = val if val is not None else "(无)"
        elif k in ("cr_spec", "cr_conditions"):
            prefix, _, name = t.rpartition("/")
            if not prefix:
                prefix = t
            for v in have:
                items = _yaml_items(vfile(v, f"cr_full/{prefix}.yaml"))
                it = next((x for x in items
                           if (x.get("metadata") or {}).get("name") == name), None)
                if it is None:
                    pres[v] = "(cr无)"
                elif k == "cr_spec":
                    spec = it.get("spec") or {}
                    fk = field.split(".")[-1] if field else ""
                    val = _deep_scalar(spec, fk)
                    pres[v] = val if val is not None else "(absent)"
                else:
                    cc = (it.get("status") or {}).get("conditions") or []
                    pres[v] = ";".join(sorted(f"{c.get('type')}={c.get('status')}"
                                              for c in cc if isinstance(c, dict))) or "(无条件)"
        elif k == "svc_selector":
            # 2026-09-07:<case> 判据(结构②);两边 svc.yaml 现取 selector
            for v in have:
                sel = None
                try:
                    doc = _y.safe_load(open(vfile(v, "obj_full/svc.yaml"),
                                            errors="ignore")) or {}
                    for it in doc.get("items") or []:
                        if (it.get("metadata") or {}).get("name") == t:
                            sel = (it.get("spec") or {}).get("selector") or {}
                            break
                except Exception:
                    sel = "(parse fail)"
                pres[v] = sel if sel is not None else "(svc无)"
        elif k == "drift_svc_residue":
            note = "drift 探针在 collect_signals 现算,以候选为准"
            for v in have:
                pres[v] = "(drift)"
        elif k == "svc_ports":
            # 2026-09-07 <case>:读 obj_full/svc.yaml 主 svc 的端口列表
            for v in have:
                val = None
                try:
                    doc = _y.safe_load(open(vfile(v, "obj_full/svc.yaml"),
                                            errors="ignore")) or {}
                    for it in doc.get("items") or []:
                        if (it.get("metadata") or {}).get("name") == t:
                            ports = sorted(p.get("port")
                                           for p in (it.get("spec") or {}).get("ports") or []
                                           if isinstance(p, dict) and p.get("port"))
                            val = ",".join(str(x) for x in ports)
                            break
                except Exception:
                    val = "(parse fail)"
                pres[v] = val if val is not None else "(svc无)"
        else:
            note = f"kind={k} 现算未实现"
            for v in have:
                pres[v] = "?"
        # ---- ok 判定 ----
        if note.startswith("drift"):
            ok, why = True, note
        elif note.startswith("kind="):
            # 2026-09-10(逃逸口审计):未实现的 kind **不再默认放行**。
            # 旧行为是 ok=True + 附注 —— 等于新增一个 kind 只要忘了实现 recheck,
            # 该判据就永久"免检通过"(本次审计在 121 条里查出 10 条这种)。
            # 免检=假门,故改为失败并显式报出,逼出遗漏。
            ok, why = False, f"{note} —— 未实现即视为不可信(免检=假门)"
        elif k == "log_sig" and "(manual)" in pres.values():
            ok, why = True, note or "manual"
        else:
            if judge == "count_zero":
                nb, nf = _count(pres.get("buggy")), _count(pres.get("fixed"))
                ok = nb is not None and nb > 0 and nf == 0
                why = "" if ok else (f"现值 buggy={pres.get('buggy')} 须>0 且 fixed=0")
            elif judge == "fixed_only":
                # 2026-09-08:<case> 类"fix 加了告警日志"的 silent bug,
                # 判别方向与 count_zero 相反 —— 修复后 agent 集群该串 >=1。
                nb, nf = _count(pres.get("buggy")), _count(pres.get("fixed"))
                ok = nb == 0 and nf is not None and nf > 0
                why = "" if ok else (f"现值 须 buggy=0 且 fixed>0"
                                     f"(got b={pres.get('buggy')} f={pres.get('fixed')})")
            else:
                ok = str(pres.get("buggy")) != str(pres.get("fixed"))
                why = "" if ok else f"现值 buggy==fixed=={pres.get('buggy')},不再判别"
        out.append({"kind": k, "target": t, "field": field, "judge": judge,
                    "present": {v: pres[v] for v in have}, "ok": ok, "why": why})
    case_ok = all(r["ok"] for r in out)
    return out, case_ok


# ---------------------------------------------------------------- diff
def diff_case(case):
    base = os.path.join(TELEM_ROOT, case)
    if not os.path.isdir(base):
        print(f"[diff] {case}: 无 telemetry 目录")
        return None

    have = [v for v in VARIANTS if os.path.isdir(os.path.join(base, v))]
    if len(have) < 2:
        print(f"[diff] {case}: 只有 {have},需要至少 2 个变体")
        return None

    lines = []
    p = lines.append
    p(f"=== {case} telemetry diff({'+'.join(have)}) ===")

    def vfile(v, name):
        return os.path.join(base, v, name)

    # 1. restarts
    rest = {v: parse_restarts(vfile(v, "restarts.txt")) for v in have}
    p("\n[restarts] 有重启的容器(buggy 有而 fixed/reference 无 = 故障信号):")
    # 跨变体区分度:同 pod+容器,buggy 重启数 > 其他变体 -> 标 <<<(v3:
    # 705/1060/1668 的 operator 重启差信号曾因只罗列不标记被漏判)
    def restart_signal():
        allk = set()
        for v in have:
            for pod, cs in rest[v].items():
                allk |= {(pod, c) for c in cs}
        sig = []
        for pod, c in sorted(allk):
            vals = {v: rest[v].get(pod, {}).get(c, 0) for v in have}
            if len(set(vals.values())) > 1:
                sig.append((pod, c, vals))
        return sig
    rs = restart_signal()
    for v in have:
        for pod, counts in rest[v].items():
            bad = {c: n for c, n in counts.items() if n > 0}
            if bad:
                p(f"  {v:>10}: {pod} {bad}")
    for pod, c, vals in rs:
        p(f"  >>> {pod} {c}: "
          f"{' | '.join(f'{v}={vals[v]}' for v in have)}  <<< 重启数不一致")
    # fixed vs reference 的 restart 差异
    if "fixed" in rest and "reference" in rest:
        fix_total = sum(n for pc in rest["fixed"].values() for n in pc.values())
        ref_total = sum(n for pc in rest["reference"].values() for n in pc.values())
        if fix_total != ref_total:
            p(f"  [note] fixed 重启总数 {fix_total} vs reference {ref_total}(修复完整性差异)")

    # 2. cr(v2:用 cr_full 的完整状态,不再用窄 jsonpath)
    crf = {v: parse_cr_full(os.path.join(base, v)) for v in have}
    p("\n[cr] 业务 CR 状态(cr_full,多字段):")
    all_crds = set()
    for v in have:
        all_crds |= set(crf[v])
    for crd in sorted(all_crds):
        for v in have:
            rows = crf[v].get(crd)
            if rows:
                p(f"  {v:>10}: {crd} {json.dumps(rows, ensure_ascii=False)[:400]}")
        # 差异行
        vals = {v: json.dumps(crf[v].get(crd), sort_keys=True) for v in have}
        if len(set(vals.values())) > 1:
            p(f"  >>>{crd}: 三变体不一致(候选故障/修复信号)")

    # 2b. 卡住型信号(v2:<case> 类 "rollingRestartRequested=True 但 pods
    # 不滚" 的故障,restarts 全 0 检测不到;直接对比 CR 请求位 vs 实际动作)
    p("\n[stuck-signal] 请求-动作一致性(rollingRestartRequested 等):")
    for v in have:
        for crd, rows in crf[v].items():
            for row in rows:
                if row.get("rollingRestartRequested"):
                    # 该变体请求了滚动重启 -> 看 pods 是否真在滚
                    # (parse_restarts 的 key 是 "ns/pod",过滤只看 pod 部分,
                    #  否则 redis-operator ns 下的业务 pod 会被整 ns 误杀)
                    rst = parse_restarts(vfile(v, "restarts.txt"))
                    biz = {k: c for k, c in rst.items()
                           if not any(x in k.split("/")[-1] for x in
                                      ("operator", "cert", "prometheus", "coredns"))}
                    total = sum(n for pc in biz.values() for n in pc.values())
                    p(f"  {v:>10}: rollingRestartRequested=True, 业务容器重启总数={total}"
                      f"{'  <<< 卡住(请求了但没动作)' if total == 0 else '  (正在滚动)'}")

    # 3. events
    ev = {v: event_counts(vfile(v, "events.txt")) for v in have}
    p("\n[events] Warning/Error 计数:")
    for v in have:
        p(f"  {v:>10}: {ev[v]}")

    # 3a. events 消息级 buggy-only diff(2026-09-10):旧版只给计数,成族消息
    # (<case> 的 FailedMount×4、<case> 的 PodSecurity 拒绝)被
    # 聚合数字淹没 —— 这正是"准静默"误判的主要渠道之一。
    emsg = {v: event_msgs(vfile(v, "events.txt")) for v in have}
    uniq = (set(emsg.get("buggy", ())) - set(emsg.get("fixed", ()))
            - set(emsg.get("reference", ())))
    p("\n[events-msg] buggy 独有 Warning/InternalError 消息(计数维看不到):")
    if uniq:
        for reason, msg in sorted(uniq)[:10]:
            p(f"  >>> {reason}: {msg[:150]}")
    else:
        p("  (无 buggy-only 消息)")

    # 3b. 容器日志消息级签名(2026-09-10):§8 的 FAULT_PATTERNS 只有子串
    # 计数,消息本体(最有判别的载体)此前在报告里完全不可见。
    cm = {v: container_log_msgs(os.path.join(base, v)) for v in have}
    kept, _ca = clog_sig_candidates(cm, have)
    p("\n[container-log-sig] buggy 独有业务容器消息(buggy>=2, fixed=0):")
    if kept:
        for n, m in kept:
            pods = sorted(pp for pp, ms in cm.get("buggy", {}).items() if m in ms)
            p(f"  >>> buggy={n} fixed=0  {m[:130]}")
            p(f"      pods: {','.join(pods[:3])}")
    else:
        p("  (无 buggy-only 容器消息)")

    # 4. operator.log
    ls = {v: log_stats(vfile(v, "operator.log")) for v in have}
    p("\n[operator.log] error/panic/warning 行数:")
    for v in have:
        s = ls[v]
        # 旧 capture 曾抓错 pod(kube-system 的 kube-controller-manager 排在
        # 业务 ns 前),整份日志是系统组件的 -> 数字全是噪音,标注无效
        path = vfile(v, "operator.log")
        junk = ""
        if os.path.isfile(path) and 'controllermanager.go' in open(path, errors="ignore").read(4000):
            junk = "  [!] 抓错 pod(kube-controller-manager),数字无效"
        p(f"  {v:>10}: error={s.get('error_lines',0)} panic={s.get('panic_lines',0)} "
          f"warn={s.get('warning_lines',0)} levels={s.get('levels',{})}{junk}")

    # 5. objects(2026-09-08 加 secrets:capture v4 已采 secrets.txt,897 类
    # SILENT 漂移的判据=secret 存在性,此前 diff 不读)
    p("\n[objects] 对象存在性差异:")
    for res in ("pods", "sts", "pvc", "svc", "secrets"):
        obs = {v: object_names(vfile(v, f"{res}.txt"), res) for v in have}
        all_o = set()
        for v in have:
            all_o |= obs[v]
        for o in sorted(all_o):
            pres = {v: (o in obs[v]) for v in have}
            if not all(pres.values()):
                p(f"  {res}: {o}  {' '.join(f'{v}={pres[v]}' for v in have)}")

    # 5a. svc selector 对比(与 signals 6b 同源;存在性一致但 selector 变了
    # = <case> 类碰撞/修复的决定性证据)
    try:
        import yaml as _y
        p("\n[svc-selector] Service spec.selector 对比(不一致 = 候选信号):")
        ssel = {}
        for v in have:
            f = vfile(v, "obj_full/svc.yaml")
            ssel[v] = {}
            if os.path.isfile(f):
                doc = _y.safe_load(open(f, errors="ignore")) or {}
                for it in doc.get("items") or []:
                    try:
                        ssel[v][it["metadata"]["name"]] = it.get("spec", {}).get("selector") or {}
                    except (KeyError, TypeError):
                        continue
        n_sig = 0
        for name in sorted(set().union(*[set(ssel[v]) for v in have])):
            if sum(1 for v in have if name in ssel[v]) < 2:
                continue
            vals = {v: ssel[v].get(name) for v in have}
            if len(set(json.dumps(vals[v], sort_keys=True) for v in have)) > 1:
                p(f"  {name}: {' | '.join(f'{v}={json.dumps(vals[v], sort_keys=True)}' for v in have)}  <<<")
                n_sig += 1
        if n_sig == 0:
            p("  (全部一致)")
    except Exception:
        pass

    # 5b. sts READY x/y 对比(v3:rdoptwo 系 leader 1/3 vs 3/3 的核心信号,
    # 旧版只比存在性漏掉了)
    stsr = {v: parse_sts_ready(vfile(v, "sts.txt")) for v in have}
    p("\n[sts-ready] StatefulSet READY 副本对比(x/y,不一致 = 候选信号):")
    all_sts = set()
    for v in have:
        all_sts |= set(stsr[v])
    n_sig = 0
    for s in sorted(all_sts):
        vals = {v: stsr[v].get(s, "(无)") for v in have}
        if len(set(vals.values())) > 1:
            p(f"  {s}: {' | '.join(f'{v}={vals[v]}' for v in have)}  <<<")
            n_sig += 1
    if n_sig == 0:
        p("  (全部一致)")

    # 5b2. PVC 容量对比(v4:#<issue> "CR 512Mi vs PVC 128Mi" 漂移信号曾在
    # 只比存在性时漏掉)
    pvcap = {v: parse_pvc_capacity(vfile(v, "pvc.txt")) for v in have}
    p("\n[pvc-capacity] PVC 容量对比(不一致 = 漂移信号):")
    all_pvc = set()
    for v in have:
        all_pvc |= set(pvcap[v])
    n_sig = 0
    for pv in sorted(all_pvc):
        vals = {v: pvcap[v].get(pv, "(无)") for v in have}
        if len(set(vals.values())) > 1:
            p(f"  {pv}: {' | '.join(f'{v}={vals[v]}' for v in have)}  <<<")
            n_sig += 1
    if n_sig == 0:
        p("  (全部一致)")

    # 5c. pod STATUS 对比(v3:CrashLoopBackOff/Pending 等状态差异)
    pstat = {v: parse_pod_status(vfile(v, "pods.txt")) for v in have}
    p("\n[pod-status] Pod 状态对比(READY/STATUS 不一致 = 候选信号):")
    all_pods = set()
    for v in have:
        all_pods |= set(pstat[v])
    n_sig = 0
    for pod in sorted(all_pods):
        vals = {v: pstat[v].get(pod, ("", "(无)")) for v in have}
        statuses = {v: vals[v][1] for v in have}
        readies = {v: vals[v][0] for v in have}
        if len(set(statuses.values())) > 1 or (len(set(readies.values())) > 1
                                               and any("/" in r for r in readies.values())):
            p(f"  {pod}: {' | '.join(f'{v}={vals[v][0]}/{vals[v][1]}' for v in have)}  <<<")
            n_sig += 1
    if n_sig == 0:
        p("  (全部一致)")

    # 6. previous logs
    prev = {v: previous_logs(os.path.join(base, v)) for v in have}
    p("\n[previous] 崩溃日志(previous_logs/):")
    for v in have:
        p(f"  {v:>10}: {len(prev[v])} 个: {sorted(prev[v])[:6]}")

    # 6b. drift 探针(离线版,与 reverify_source_mode.sh 的判定同源;
    #     从已采 cr_full / obj_full / svc.txt 判定,不需要活集群)
    p("\n[drift] spec↔live 漂移探针(zkop-474 / mgoptwo-696 / mgoptwo-895):")
    n_drift = 0
    for v in have:
        verdicts = []
        # <case>: rs0 已 unexpose 但 per-pod svc 残留 = bug 在
        if "mgoptwo-895" == case:
            import yaml as _y
            f = vfile(v, "cr_full/perconaservermongodbs.psmdb.percona.com.yaml")
            if os.path.isfile(f):
                try:
                    d = _y.safe_load(open(f))
                    rs0 = d["items"][0]["spec"]["replsets"][0]
                    expo = (rs0.get("expose") or {}).get("enabled")
                    nsvc = 0
                    sf = vfile(v, "svc.txt")
                    if os.path.isfile(sf):
                        nsvc = len(re.findall(r"test-cluster-rs0-\d+", open(sf, errors="ignore").read())) // 2
                    present = (expo is not True) and nsvc >= 1
                    verdicts.append(f"rs0.expose={expo} rs0-svc={nsvc} -> "
                                    f"{'残留(bug 在)' if present else '无残留'}")
                except Exception as e:
                    verdicts.append(f"(解析失败 {e})")
        # <case>: sts template 注解卡 ACTOKEY = bug 在(v4 obj_full 才有)
        elif "mgoptwo-696" == case:
            f = vfile(v, "obj_full/sts.yaml")
            if os.path.isfile(f):
                txt = open(f, errors="ignore").read()
                hit = "ACTOKEY" in txt
                verdicts.append(f"sts template 含 ACTOKEY: {hit} -> "
                                f"{'注解卡死(bug 在)' if hit else '干净'}")
            else:
                verdicts.append("(无 obj_full,重采后可判)")
        # <case>: CR 写的注解没同步到 admin-server svc = bug 在
        elif case == "zkop-474":
            import yaml as _y
            crf = vfile(v, "cr_full/zookeeperclusters.zookeeper.pravega.io.yaml")
            if os.path.isfile(crf):
                try:
                    d = _y.safe_load(open(crf))
                    spec_ann = (d["items"][0]["spec"].get("adminServerService", {})
                                .get("annotations") or {})
                    has_key = "ACTOKEY" in json.dumps(spec_ann)
                    svf = vfile(v, "obj_full/svc.yaml")
                    live = ""
                    if os.path.isfile(svf):
                        st = _y.safe_load(open(svf))
                        for it in (st or {}).get("items", []):
                            if it["metadata"]["name"] == "test-cluster-admin-server":
                                live = json.dumps(it["metadata"].get("annotations") or {})
                    verdicts.append(f"CR.spec 注解含 ACTOKEY: {has_key}; "
                                    f"svc 注解: {live[:60] or '(无 obj_full)'} -> "
                                    f"{'未同步(bug 在)' if (has_key and 'ACTOKEY' not in live and live or has_key and not live) else '同步/待重采'}")
                except Exception as e:
                    verdicts.append(f"(解析失败 {e})")
        for ver in verdicts:
            p(f"  {v:>10}: {ver}")
            n_drift += 1
    if n_drift == 0:
        p("  (非 drift 类 case,跳过)")

    # 7. prom up 数量
    p("\n[prom] up targets:")
    for v in have:
        pth = vfile(v, "prom/up.json")
        if os.path.isfile(pth):
            try:
                data = json.load(open(pth))
                n = len(data.get("data", {}).get("result", []))
                n_up = sum(1 for r in data["data"]["result"] if r.get("value", ["", "0"])[1] == "1")
                p(f"  {v:>10}: {n} targets, {n_up} up")
            except Exception:
                p(f"  {v:>10}: (解析失败)")

    report = "\n".join(lines)
    with open(os.path.join(base, "diff_report.txt"), "w") as f:
        f.write(report + "\n")
    print(report)

    # 机器可读信号判据(repair oracle):
    #   confirmed: CASE_CONFIRM 里人工确认的核心判据(行为分唯一依据)
    #   candidates: 自动挖掘的候选(含噪音,仅供人工确认时参考)
    signals = collect_signals(case, base, have)
    confirmed = CASE_CONFIRM.get(case, [])
    fh = fixed_health(base) if "fixed" in have else "n/a"
    qr = CASE_QUARANTINE.get(case)
    # D2 (2026-09-04):confirmed 现值重算 —— 否则 buggy 干净的旧快照(705/80-0)
    # 静默伪装 usable。全失配才拉 False(705/80-0:所有探针都不再判别);
    # 部分失配(696)保留但打警示,须 re-ground/重采后现值才回判别。
    recheck, recheck_ok = recheck_confirmed(case, base, have, confirmed)
    usable = (fh == "ok" and len(confirmed) > 0 and not qr)
    stale_reason = ""
    if usable and not recheck_ok:
        nfail = sum(1 for r in recheck if not r["ok"])
        if nfail == len(recheck):
            usable = False
            stale_reason = ("confirmed 现值全失配(如 buggy 现值已干净/未触发),"
                            "需 re-ground 或重采后才可信")
        else:
            stale_reason = f"confirmed {nfail}/{len(recheck)} 条现值失配(记录值过期/探针陈旧),建议 re-ground"
    for r in recheck:
        if not r["ok"]:
            print(f"  [recheck] ! {case} {r['kind']} {r['target']} "
                  f"{'.'+r['field'] if r.get('field') else ''}: {r['why']}")
    sj = os.path.join(base, "signals.json")
    with open(sj, "w") as f:
        json.dump({"case": case, "variants": have,
                   "confirmed": confirmed,
                   "confirmed_recheck": recheck,
                   "candidates": signals,
                   "zero_signal": len(signals) == 0,
                   "fixed_health": fh,
                   "quarantine": qr,
                   "usable_as_oracle": usable,
                   "stale_reason": stale_reason or None},
                  f, indent=1, ensure_ascii=False)
    print(f"[diff] {case}: 确认判据 {len(confirmed)} 条 / 候选 {len(signals)} 条, "
          f"fixed_health={fh}"
          f"{'  <<< 隔离:' + qr if qr else ''}"
          f"{'  <<< 无确认判据,不能用' if fh == 'ok' and not confirmed else ''}"
          f"{'  <<< fixed 非修复态,隔离' if fh not in ('ok', 'n/a') else ''}"
          f"{('  <<< D2:confirmed 现值失配: ' + stale_reason + (' -> usable=False' if not usable else ' (usable 保留)')) if stale_reason else ''}")
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--case")
    ap.add_argument("--all", action="store_true")
    args = ap.parse_args()

    if args.case:
        cases = [args.case]
    elif args.all:
        cases = sorted(os.listdir(TELEM_ROOT)) if os.path.isdir(TELEM_ROOT) else []
    else:
        sys.exit("需要 --case 或 --all")

    for c in cases:
        diff_case(c)
        print()


if __name__ == "__main__":
    main()
