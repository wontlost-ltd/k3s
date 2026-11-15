#!/usr/bin/env bash
# 探针凭证的身份断言（aster-api ADR 0054 §12 D9、ADR 0057 §4.2）：防止误放管理员 kubeconfig，或 OIDC 映射出意外身份。
#
#   assert-identity.sh static                  当前 KUBECONFIG 的 auth whoami 恰为探针 SA
#   assert-identity.sh oidc --oidc-dir <d>     <d>/bin/kubectl（OIDC 包装脚本）的 whoami 恰为 OIDC 用户，且
#                                              能在 aster-agents 建 Pod、不能读 Secret（RBAC 绑定与预期一致）
#   assert-identity.sh dual --oidc-dir <d>     以上两者
# 退出码：0；2 用法错误；3 身份或权限不符（工作流判红）。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/guard-bypass/lib.sh
source "$HERE/lib.sh"

KUBECTL="${KUBECTL:-kubectl}"
mode="${1:-}"; [[ $# -gt 0 ]] && shift
oidc_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --oidc-dir) oidc_dir="${2:-}"; shift 2 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done
case "$mode" in static|dual|oidc) ;; *) echo "模式须为 static|dual|oidc，实为「${mode}」" >&2; exit 2 ;; esac

fail3() { echo "::error::$*"; exit 3; }

if [[ "$mode" != oidc ]]; then
  who="$("$KUBECTL" auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || true)"
  echo "静态 kubeconfig 身份：${who:-未知}"
  [[ "$who" == "$PROBE_SA_USER" ]] || fail3 "静态 kubeconfig 不是探针 SA（${who:-未知}）"
fi
if [[ "$mode" != static ]]; then
  k="$oidc_dir/bin/kubectl"
  [[ -n "$oidc_dir" && -x "$k" ]] || fail3 "没有 OIDC 包装脚本 ${k}（Configure OIDC credential 步骤未运行？）"
  who="$("$k" auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || true)"
  echo "OIDC 身份：${who:-未知}"
  [[ "$who" == "$PROBE_OIDC_USER" ]] || fail3 "OIDC 身份不是 ${PROBE_OIDC_USER}（${who:-未知}）：apiserver 未开启 --authentication-config，或 claim 规则不符"
  can_create="$("$k" auth can-i create pods -n aster-agents 2>/dev/null || true)"
  can_secret="$("$k" auth can-i get secrets -n aster-agents 2>/dev/null || true)"
  [[ "$can_create" == yes ]] || fail3 "OIDC 身份不能在 aster-agents 建 Pod：RBAC 未绑定该用户（apps/aster-lang/agents/rolebinding-probe.yaml）"
  [[ "$can_secret" == no ]] || fail3 "OIDC 身份能读 aster-agents 的 Secret：权限超出探针权限表，立即排查"
  echo "OIDC 身份权限：create pods = yes，get secrets = no"
fi
