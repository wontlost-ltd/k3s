#!/usr/bin/env bash
# 部署收敛等待（计划 Task 8 converge 步骤）：线上状态与本提交的渲染结果一致后，打印收敛时刻（RFC3339，末行）。
# 条件：demo-tool / aster-guard-mcp 的运行中 Pod 的 imageID digest 等于渲染镜像的 digest；两个 Deployment
# availableReplicas == 1；线上 demo-tool-ingress 的 spec 等于渲染结果（jq 规范化后比较）。
# 用法：converge.sh <repo-root>；CONVERGE_TIMEOUT（缺省 900 s）、CONVERGE_POLL（缺省 15 s）。退出码：0 收敛；3 超时。
# 只用权限表内的调用：pods get/list、deployments get、networkpolicies get。
set -euo pipefail
root="${1:?用法：converge.sh <repo-root>}"
KUBECTL="${KUBECTL:-kubectl}"
timeout="${CONVERGE_TIMEOUT:-900}" poll="${CONVERGE_POLL:-15}"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

kustomize build "$root/apps/aster-lang/guard" | yq -o=json -I=0 '.' | jq -s 'map(select(. != null))' >"$tmp/guard.json"
kustomize build "$root/apps/aster-lang/tools" | yq -o=json -I=0 '.' | jq -s 'map(select(. != null))' >"$tmp/tools.json"
digest_of() { jq -r --arg d "$2" '.[] | select(.kind == "Deployment" and .metadata.name == $d) | .spec.template.spec.containers[0].image | capture("@(?<d>sha256:[0-9a-f]{64})$").d' "$1"; }
want_proxy="$(digest_of "$tmp/guard.json" aster-guard-mcp)"
want_tool="$(digest_of "$tmp/tools.json" demo-tool)"
jq -S '.[] | select(.kind == "NetworkPolicy" and .metadata.name == "demo-tool-ingress") | .spec' "$tmp/tools.json" >"$tmp/np-want.json"
[[ -n "$want_proxy" && -n "$want_tool" && -s "$tmp/np-want.json" ]] || { echo "::error::渲染结果缺镜像 digest 或工具策略"; exit 3; }

# state <ns> <app> <deployment> <期望 digest>：输出 ok 或原因。
state() {
  local ns="$1" app="$2" dep="$3" want="$4" ids avail
  ids="$("$KUBECTL" get pods -n "$ns" -l "app=$app" -o json 2>/dev/null |
    jq -r '[.items[] | select(.status.phase == "Running" and .metadata.deletionTimestamp == null) | .status.containerStatuses[0].imageID // ""] | join(" ")')" || ids=""
  avail="$("$KUBECTL" get deployment -n "$ns" "$dep" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
  if [[ "$avail" != 1 ]]; then echo "${dep} availableReplicas=${avail:-0}"; return; fi
  if [[ "$ids" != *"@${want}" || "$ids" == *" "* ]]; then echo "${dep} imageID=${ids:-无} ≠ ${want}"; return; fi
  echo ok
}

deadline=$(( $(date +%s) + timeout ))
while :; do
  s1="$(state aster-guard aster-guard-mcp aster-guard-mcp "$want_proxy")"
  s2="$(state aster-tools demo-tool demo-tool "$want_tool")"
  np="$("$KUBECTL" get networkpolicy -n aster-tools demo-tool-ingress -o json 2>/dev/null | jq -S '.spec' 2>/dev/null || true)"
  s3=ok; [[ "$np" == "$(cat "$tmp/np-want.json")" ]] || s3="demo-tool-ingress 与渲染结果不一致"
  if [[ "$s1" == ok && "$s2" == ok && "$s3" == ok ]]; then
    date -u +%Y-%m-%dT%H:%M:%SZ
    exit 0
  fi
  echo "等待收敛：${s1}；${s2}；${s3}" >&2
  if (( $(date +%s) >= deadline )); then echo "::error::${timeout}s 内未收敛：${s1}；${s2}；${s3}"; exit 3; fi
  sleep "$poll"
done
