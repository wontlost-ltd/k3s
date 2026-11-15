#!/usr/bin/env bash
# 探针凭证有效期检查（aster-api ADR 0054 §12 D9；计划 Task 8 token-expiry 步骤与 §3「TTL」）。
# 用法：token-expiry.sh <now-epoch> < token
# 退出码：0 可用（剩余 < 14 天时打 ::warning::）；3 不可用（已过期、exp - iat 超过 90 天 + 1 小时、无法解析）。
# 只输出天数与结论，不回显 token。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/guard-bypass/lib.sh
source "$HERE/lib.sh"

now="${1:?用法：token-expiry.sh <now-epoch> < token}"
claims="$(jwt_claims)" || true
read -r exp iat < <(jq -r '"\(.exp // "") \(.iat // "")"' <<<"$claims" 2>/dev/null || echo "") || true
if ! [[ "${exp:-}" =~ ^[0-9]+$ && "${iat:-}" =~ ^[0-9]+$ ]]; then
  echo "::error::探针凭证无法解析出 exp / iat（不是 TokenRequest 签发的绑定 token？）"
  exit 3
fi
lifetime=$((exp - iat)) remaining=$((exp - now))
if (( lifetime <= 0 )); then
  echo "::error::探针凭证的 exp 不晚于 iat——凭证不合规，拒绝使用"
  exit 3
fi
if (( lifetime > PROBE_TOKEN_MAX_LIFETIME )); then
  echo "::error::探针凭证有效期 $((lifetime / 86400)) 天，超过 90 天上限——凭证不合规，拒绝使用（重新运行 kubeconfig-for-probe.sh 轮换）"
  exit 3
fi
if (( remaining <= 0 )); then
  echo "::error::探针凭证已过期 $(( -remaining / 86400 )) 天——按 docs/runbooks/guard-bypass-probe.md 轮换"
  exit 3
fi
if (( remaining < 14 * 86400 )); then
  echo "::warning::探针凭证将在 $((remaining / 86400)) 天后过期——按 docs/runbooks/guard-bypass-probe.md 轮换"
fi
echo "探针凭证剩余 $((remaining / 86400)) 天（总有效期 $((lifetime / 86400)) 天）"
