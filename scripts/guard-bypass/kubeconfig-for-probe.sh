#!/usr/bin/env bash
# 生成部署层探针的 kubeconfig（aster-api ADR 0054 §12 D9；计划 Task 8、§3、§5 U-K6）。
#
# 由用户以**管理员** kubeconfig 运行；输出（stdout）为只含探针 SA 绑定 token 与集群 CA 的 kubeconfig 的 base64，
# 直接管道给 `gh secret set GUARD_PROBE_KUBECONFIG --env guard-probe -R wontlost-ltd/k3s`。不落盘：临时文件在 trap 中删除。
#
# 用法：kubeconfig-for-probe.sh --server <https://host:6443> [--duration 720h] [--kubeconfig <管理员 kubeconfig>]
# 约束：
#   - 请求时长 > 2160h（90 天）直接拒绝；
#   - 再解析**签发出的** token 的 exp - iat，超过 90 天 + 1 小时同样拒绝——API server 可能按
#     --service-account-max-token-expiration 等设置签发与请求不同的时长，只限制请求不等于限制结果；
#   - 用新 kubeconfig 自检 `kubectl auth whoami` 必须是 system:serviceaccount:aster-guard:guard-bypass-probe。
# 前置（U-K6）：Task 7c 已合并且 vap-check.sh 全部符合期望；`kubectl get secrets -n aster-agents -o name` 恰为
# secret/guard-demo-agent；U-K8 已核实 apiserver 审计日志状态。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/guard-bypass/lib.sh
source "$HERE/lib.sh"

KUBECTL="${KUBECTL:-kubectl}"
SA=guard-bypass-probe SA_NS=aster-guard
WANT_USER="system:serviceaccount:${SA_NS}:${SA}"
server="" duration=720h admin=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) server="${2:-}"; shift 2 ;;
    --duration) duration="${2:-}"; shift 2 ;;
    --kubeconfig) admin=(--kubeconfig "${2:?}"); shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
[[ "$server" =~ ^https://[^/[:space:]]+$ ]] || { echo "--server 须为 https://<host>:<port>" >&2; exit 2; }
[[ "$duration" =~ ^([0-9]+)h$ ]] || { echo "--duration 须为 <小时>h，如 720h" >&2; exit 2; }
(( BASH_REMATCH[1] <= 2160 )) || { echo "--duration ${duration} 超过 90 天上限（2160h）" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
umask 077

token="$("$KUBECTL" "${admin[@]+"${admin[@]}"}" create token "$SA" -n "$SA_NS" --duration "$duration")"
lifetime="$(jwt_claims <<<"$token" | jq -r '(.exp // 0) - (.iat // 0)' 2>/dev/null || echo 0)"
if ! [[ "$lifetime" =~ ^[0-9]+$ ]] || (( lifetime <= 0 || lifetime > PROBE_TOKEN_MAX_LIFETIME )); then
  echo "签发出的 token 有效期 ${lifetime}s 不在 (0, 90 天 + 1 小时] 内——拒绝生成（检查 apiserver 的 token 时长设置）" >&2
  exit 1
fi
"$KUBECTL" "${admin[@]+"${admin[@]}"}" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' |
  base64 -d >"$tmp/ca.crt"
[[ -s "$tmp/ca.crt" ]] || { echo "管理员 kubeconfig 中没有 certificate-authority-data" >&2; exit 1; }

kc=(--kubeconfig "$tmp/kubeconfig")
"$KUBECTL" "${kc[@]}" config set-cluster k3s --server="$server" --certificate-authority="$tmp/ca.crt" --embed-certs=true >/dev/null
"$KUBECTL" "${kc[@]}" config set-credentials "$SA" --token="$token" >/dev/null
"$KUBECTL" "${kc[@]}" config set-context probe --cluster=k3s --user="$SA" >/dev/null
"$KUBECTL" "${kc[@]}" config use-context probe >/dev/null
who="$("$KUBECTL" "${kc[@]}" auth whoami -o jsonpath='{.status.userInfo.username}')"
[[ "$who" == "$WANT_USER" ]] || { echo "自检失败：新 kubeconfig 的身份是 ${who:-未知}，不是 ${WANT_USER}" >&2; exit 1; }
echo "自检通过：${who}，有效期 $((lifetime / 86400)) 天" >&2
base64 <"$tmp/kubeconfig" | tr -d '\n'
