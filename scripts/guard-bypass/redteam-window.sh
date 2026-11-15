#!/usr/bin/env bash
# 两条反向记录（aster-api ADR 0054 §12 D8；计划 Task 10）：在临时副本命名空间里分别关掉一层，证明每一层都独立挡住直连。
# 生产的 aster-agents / aster-guard / aster-tools 不读不写；生产两层永不关闭。
#
# 用法（用户以集群管理员凭证运行，不经 Argo；先 --dry-run 审阅）：
#   bash scripts/guard-bypass/redteam-window.sh --kubeconfig ~/.kube/k3s-config [--ttl-minutes 20] [--dry-run]
#
# 副本：aster-rt-<RUN>-{agents,guard,tools}，取舍见计划 Task 10 的表——
#   agents：Namespace、ResourceQuota、LimitRange；
#   guard ：Namespace、票据探针脚本 ConfigMap，CronJob 的 jobTemplate 按需实例化为 Job（每次票据探针一份）；
#   tools ：Namespace、demo-tool（replicas 1，镜像 digest 与生产相同）、Service、demo-tool-ingress；
#           Guard 凭据改为字面量 dummy Secret（副本里没有任何真实凭证）。
# 场景与期望（任一实际 ≠ 期望则退出 1）：
#   基线（两层开）          网络 0  票据 0
#   R-N（删工具入站策略）   网络 1  票据 0
#   R-A（TICKET_CHECK=off） 网络 0  票据 1，且摘要 steps.missing == 200、markerExecuted == true
# 清理：trap 删除三个命名空间；另起一个与调用 shell 脱离的看门狗，TTL 到期删除带本 RUN 标签的命名空间（尽力而为）；
# 每次真实运行开始时删除所有已过期的红队命名空间；guard-bypass-probe 工作流也会对过期者告警。
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
APPS="${GUARD_APPS_ROOT:-$ROOT/apps/aster-lang}"
NET_PROBE="${REDTEAM_NET_PROBE:-$HERE/direct-connect-probe.sh}"
JOB_WAIT="${REDTEAM_JOB_WAIT:-180}" POLL="${REDTEAM_POLL:-3}"

KC="" TTL=20 DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kubeconfig) KC="${2:-}"; shift 2 ;;
    --ttl-minutes) TTL="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
[[ -n "$KC" && "$TTL" =~ ^[0-9]+$ && "$TTL" -ge 5 && "$TTL" -le 60 ]] || { echo "用法：redteam-window.sh --kubeconfig <管理员 kubeconfig> [--ttl-minutes 5–60] [--dry-run]" >&2; exit 2; }

RUN="${REDTEAM_RUN:-$(date +%s)}"
EXPIRES=$(( $(date +%s) + TTL * 60 ))
P="aster-rt-${RUN}"
NS_AGENTS="${P}-agents" NS_GUARD="${P}-guard" NS_TOOLS="${P}-tools"
K() { kubectl --kubeconfig "$KC" "$@"; }
WORK="$(mktemp -d)"

# ── 渲染并映射（结构化改写，不做全文替换：镜像名 aster-guard-* 不是命名空间）──
render() {
  local app="$1" keep="$2"
  kustomize build "$APPS/$app" | yq -o=json -I=0 '.' | jq -c --arg keep "$keep" 'select(. != null and (.kind | IN($keep | split(",")[])))'
}
{
  render agents Namespace,ResourceQuota,LimitRange
  render guard Namespace,ConfigMap
  render tools Namespace,Deployment,Service,NetworkPolicy
} | jq -c --arg a "$NS_AGENTS" --arg g "$NS_GUARD" --arg t "$NS_TOOLS" --arg run "$RUN" --arg exp "$EXPIRES" '
  def ns: {"aster-agents": $a, "aster-guard": $g, "aster-tools": $t}[.] // .;
  (if .kind == "Namespace" then .metadata.name |= ns
     | .metadata.labels += {"guard-bypass/redteam-expires": $exp, "guard-bypass/redteam-run": $run}
   else .metadata.namespace |= ns end)
  | (if .kind == "NetworkPolicy" then .spec.ingress[].from[].namespaceSelector.matchLabels["kubernetes.io/metadata.name"] |= ns else . end)
  | (if .kind == "Deployment" then .spec.replicas = 1 else . end)' >"$WORK/replica.jsonl"

# 票据探针 Job 模板：CronJob 的 jobTemplate，TOOL_URL 指向副本工具，ConfigMap 名称沿用渲染结果（带哈希后缀）。
kustomize build "$APPS/guard" | yq -o=json -I=0 '.' | jq -c --arg g "$NS_GUARD" --arg t "$NS_TOOLS" '
  select(. != null and .kind == "CronJob") | {apiVersion: "batch/v1", kind: "Job", metadata: {namespace: $g, labels: {"guard-bypass/redteam": "auth-probe"}}, spec: .spec.jobTemplate.spec}
  | (.spec.template.spec.containers[0].env[] | select(.name == "TOOL_URL") | .value) |= sub("\\.aster-tools\\."; ".\($t).")
  # 其余恰为生产命名空间名的字段（如对工具 Pod 反亲和的 namespaces）一并映射到副本。
  | walk(if . == "aster-tools" then $t elif . == "aster-guard" then $g else . end)' >"$WORK/auth-job.json"
PROBE_IMAGE="$(jq -r '.spec.template.spec.containers[0].image' "$WORK/auth-job.json")"

# 副本工具的 dummy 凭据（工具在 TICKET_CHECK=on 时启动必需；伪造票据因此得到 guard_unavailable）。
jq -n --arg t "$NS_TOOLS" '{apiVersion: "v1", kind: "Secret", type: "Opaque", metadata: {name: "demo-tool-guard", namespace: $t},
  stringData: {"tool-api-key": "redteam-dummy", "tenant-id": "redteam"}}' >>"$WORK/replica.jsonl"

NET_ARGS=(network --agents-ns "$NS_AGENTS" --tool-ns "$NS_TOOLS" --tool-selector app=demo-tool --tool-svc demo-tool:8080
  --admit-ns "$NS_GUARD" --probe-image "$PROBE_IMAGE" --positive-url https://kubernetes.default.svc.cluster.local/livez)

if [[ "$DRY" == 1 ]]; then
  echo "# dry-run：零次 kubectl 调用。真实运行时将先清扫过期红队命名空间（guard-bypass/redteam-expires < now）。"
  echo "# RUN=${RUN}，副本命名空间 ${NS_AGENTS} / ${NS_GUARD} / ${NS_TOOLS}，TTL ${TTL} 分钟"
  echo "# 将执行：kubectl apply（下列清单）→ 基线 → R-N（delete networkpolicy demo-tool-ingress）→ R-A（恢复策略 + set env TICKET_CHECK=off）→ 删除三个命名空间"
  echo "# 网络探针：$(basename "$NET_PROBE") ${NET_ARGS[*]} --run-id <场景>"
  echo "# 票据探针 Job 模板："
  jq . "$WORK/auth-job.json"
  echo "# 副本清单："
  jq -s . "$WORK/replica.jsonl"
  rm -rf "$WORK"
  exit 0
fi

# ── 真实运行 ──
cleanup() {
  K delete ns "$NS_AGENTS" "$NS_GUARD" "$NS_TOOLS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 3' INT TERM

# 启动清扫：删除所有已过期的红队命名空间（看门狗随宿主机消失时的兜底）。查询失败即中止（trap 已就位）。
now="$(date +%s)"
K get ns -l guard-bypass/redteam-expires -o json >"$WORK/expired.json" || { echo "无法列出红队命名空间，中止" >&2; exit 1; }
jq -c . "$WORK/expired.json" |
  jq -r --argjson now "$now" '.items[] | select((.metadata.labels["guard-bypass/redteam-expires"] | tonumber? // 0) < $now) | .metadata.name' |
  while read -r ns; do echo "清扫过期红队命名空间 ${ns}"; K delete ns "$ns" --wait=false >/dev/null; done

# 看门狗：与调用 shell 脱离，TTL 到期删除带本 RUN 标签的命名空间。
# （REDTEAM_WATCHDOG=0 只供离线测试关闭。macOS 没有 setsid，退化为 nohup + disown。）
if [[ "${REDTEAM_WATCHDOG:-1}" == 1 ]]; then
  watchdog_cmd="sleep $((TTL * 60)); kubectl --kubeconfig '$KC' delete ns -l guard-bypass/redteam-run=$RUN --wait=false"
  if command -v setsid >/dev/null; then setsid nohup sh -c "$watchdog_cmd" >/dev/null 2>&1 &
  else nohup sh -c "$watchdog_cmd" >/dev/null 2>&1 & fi
  disown || true
fi

# 先命名空间、再 Secret、最后工作负载：避免 Pod 先于 dummy Secret 创建而进入 CreateContainerConfigError 退避。
jq -s '{apiVersion: "v1", kind: "List", items: (sort_by({"Namespace": 0, "Secret": 1}[.kind] // 2))}' "$WORK/replica.jsonl" | K apply -f - >/dev/null
K rollout status deploy/demo-tool -n "$NS_TOOLS" --timeout=180s >/dev/null

# auth_probe <场景>：实例化一次票据探针 Job，等结束，输出末行摘要。
auth_probe() {
  local name="auth-probe-$1" deadline line
  jq --arg n "$name" '.metadata.name = $n' "$WORK/auth-job.json" | K create -f - >/dev/null
  deadline=$(( $(date +%s) + JOB_WAIT ))
  until K get job -n "$NS_GUARD" "$name" -o json | jq -e '(.status.succeeded // 0) + (.status.failed // 0) > 0' >/dev/null; do
    (( $(date +%s) < deadline )) || { echo '{"verdict":"inconclusive","reasons":["票据探针 Job 超时"]}'; return; }
    sleep "$POLL"
  done
  line="$(K logs -n "$NS_GUARD" "job/$name" 2>/dev/null | tail -n1)"
  jq -ce . <<<"$line" 2>/dev/null || echo '{"verdict":"inconclusive","reasons":["票据探针输出不是 JSON"]}'
}
# net_probe <场景> [额外参数…]：输出末行摘要（网络探针以管理员凭证运行）。
net_probe() {
  local scenario="$1"; shift
  KUBECONFIG="$KC" bash "$NET_PROBE" "${NET_ARGS[@]}" --run-id "rt-${RUN}-${scenario}" "$@" 2>/dev/null | tail -n1
}
code_of() { case "$(jq -r '.verdict // ""' <<<"$1" 2>/dev/null)" in pass) echo 0 ;; bypass) echo 1 ;; *) echo 3 ;; esac; }

ROWS=() FAIL=0
record() { # record <场景> <探针> <期望> <摘要> [额外断言 jq]
  local actual; actual="$(code_of "$4")"
  local ok=1
  [[ "$actual" == "$3" ]] || ok=0
  if [[ -n "${5:-}" ]] && ! jq -e "$5" >/dev/null 2>&1 <<<"$4"; then ok=0; fi
  [[ "$ok" == 1 ]] || FAIL=1
  ROWS+=("$(printf '| %s | %s | %s | %s | %s |' "$1" "$2" "$3" "$actual" "$([[ "$ok" == 1 ]] && echo ✓ || echo ✗)")")
  echo "== $1 / $2：期望 $3，实际 ${actual}；摘要：$4"
}

record 基线 网络 0 "$(net_probe base)"
record 基线 票据 0 "$(auth_probe base)"

K delete networkpolicy -n "$NS_TOOLS" demo-tool-ingress >/dev/null
record R-N 网络 1 "$(net_probe rn)"
record R-N 票据 0 "$(auth_probe rn)"

jq -c 'select(.kind == "NetworkPolicy")' "$WORK/replica.jsonl" | K apply -f - >/dev/null
K set env deploy/demo-tool -n "$NS_TOOLS" TICKET_CHECK=off >/dev/null
K rollout status deploy/demo-tool -n "$NS_TOOLS" --timeout=180s >/dev/null
record R-A 网络 0 "$(net_probe ra --no-tool-shape-check)"
# 只看退出码不够（ticketCheck=off 本身就给 1）：必须证明无票据调用真的执行了。
record R-A 票据 1 "$(auth_probe ra)" '.steps.missing == 200 and .markerExecuted == true'

echo
echo "| 场景 | 探针 | 期望 | 实际 | 符合 |"
echo "|---|---|---|---|---|"
printf '%s\n' "${ROWS[@]}"
[[ "$FAIL" == 0 ]] || { echo "反向记录不符合期望" >&2; exit 1; }
echo "两条反向记录均符合期望"
