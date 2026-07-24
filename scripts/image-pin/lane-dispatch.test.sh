#!/usr/bin/env bash
# 验 verify-image-pin.yml 的 lane 分派逻辑（none|cloud-pin|runner-pin|runner-topology|invalid）。
# ★workflow 内联 shell 无法直接单测，故本测试**复刻**分派算法（与 workflow「Compute changed files」步
#   的判定逻辑逐条对应），对多种 PR 形状断言正确 lane。分派算法若在 workflow 改动，须同步本复刻。
set -euo pipefail

CLOUD_LOCK_PATH=apps/aster-lang/cloud/image-lock.yaml
CLOUD_KUST_PATH=apps/aster-lang/cloud/kustomization.yaml
RUNNER_LOCK_PATH=apps/aster-lang/runner/image-lock.yaml
RUNNER_DEPLOY_PATH=apps/aster-lang/runner/deployment.yaml
RUNNER_KUST_PATH=apps/aster-lang/runner/kustomization.yaml
RUNNER_DEPLOY_POLICY_PATH=apps/aster-lang/runner/deploy-policy.yaml

FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILED=1; }

# 分派算法复刻（与 workflow 逐条对应）。$1=changed-files 文件 $2=changed-status 文件。
dispatch() {
  local cf="$1" st="$2" pin_flavor lane topo_ok bn
  pin_flavor=none
  if grep -qxF "$CLOUD_LOCK_PATH" "$cf" || grep -qxF "$CLOUD_KUST_PATH" "$cf"; then pin_flavor=cloud; fi
  if grep -qxF "$RUNNER_LOCK_PATH" "$cf" || grep -qxF "$RUNNER_DEPLOY_PATH" "$cf" || grep -qxF "$RUNNER_KUST_PATH" "$cf" || grep -qxF "$RUNNER_DEPLOY_POLICY_PATH" "$cf"; then
    pin_flavor=runner
  fi
  lane=none
  if [[ "$pin_flavor" == "cloud" ]]; then
    lane=cloud-pin
  elif [[ "$pin_flavor" == "runner" ]]; then
    if grep -qxF "$RUNNER_LOCK_PATH" "$cf"; then
      lane=runner-pin
    else
      topo_ok=true
      if awk -F'\t' '$1 == "renamed" || $1 == "removed"' "$st" | grep -q .; then
        topo_ok=false
      fi
      while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        case "$line" in
          apps/aster-lang/runner/kustomization.yaml|apps/aster-lang/runner/deployment.yaml|apps/aster-lang/runner/deploy-policy.yaml) : ;;
          *) topo_ok=false ;;
        esac
      done < <(sort -u "$cf")
      if ! grep -qxF "$RUNNER_KUST_PATH" "$cf" || ! grep -qxF "$RUNNER_DEPLOY_PATH" "$cf"; then topo_ok=false; fi
      if [[ "$topo_ok" == "true" ]]; then lane=runner-topology; else lane=invalid; fi
    fi
  fi
  echo "$lane"
}

# 用例：$1=desc $2=期望 lane $3=changed-files（换行分隔）$4=status（"status\tfile" 换行分隔）
tc() {
  local desc="$1" want="$2" cf st got
  cf="$(mktemp)"; st="$(mktemp)"
  printf '%s\n' "$3" > "$cf"
  printf '%s\n' "$4" > "$st"
  got="$(dispatch "$cf" "$st")"
  [[ "$got" == "$want" ]] && pass "${desc} → ${got}" || fail "${desc}：期望 ${want} 得 ${got}"
  rm -f "$cf" "$st"
}

echo "=== lane 分派用例 ==="
tc "合法 go-live（3 授权文件，无 image-lock）" "runner-topology" \
  $'apps/aster-lang/runner/kustomization.yaml\napps/aster-lang/runner/deployment.yaml\napps/aster-lang/runner/deploy-policy.yaml' \
  $'modified\tapps/aster-lang/runner/kustomization.yaml\nmodified\tapps/aster-lang/runner/deployment.yaml\nmodified\tapps/aster-lang/runner/deploy-policy.yaml'
tc "image-pin bot（image-lock+kustomization）" "runner-pin" \
  $'apps/aster-lang/runner/image-lock.yaml\napps/aster-lang/runner/kustomization.yaml' \
  $'modified\tapps/aster-lang/runner/image-lock.yaml\nmodified\tapps/aster-lang/runner/kustomization.yaml'
tc "runner env-bound bot（image-lock+deployment）" "runner-pin" \
  $'apps/aster-lang/runner/image-lock.yaml\napps/aster-lang/runner/deployment.yaml' \
  $'modified\tapps/aster-lang/runner/image-lock.yaml\nmodified\tapps/aster-lang/runner/deployment.yaml'
tc "topology 触及非授权 runner 文件（role.yaml）→ invalid" "invalid" \
  $'apps/aster-lang/runner/kustomization.yaml\napps/aster-lang/runner/role.yaml' \
  $'modified\tapps/aster-lang/runner/kustomization.yaml\nmodified\tapps/aster-lang/runner/role.yaml'
tc "topology 含 rename → invalid" "invalid" \
  $'apps/aster-lang/runner/kustomization.yaml\napps/aster-lang/runner/deployment.yaml' \
  $'modified\tapps/aster-lang/runner/kustomization.yaml\nrenamed\tapps/aster-lang/runner/deployment.yaml'
tc "topology 含 delete → invalid" "invalid" \
  $'apps/aster-lang/runner/kustomization.yaml\napps/aster-lang/runner/deployment.yaml' \
  $'modified\tapps/aster-lang/runner/kustomization.yaml\nremoved\tapps/aster-lang/runner/service.yaml'
tc "非 runner PR（docs）→ none" "none" \
  $'README.md' \
  $'modified\tREADME.md'
tc "仅 deploy-policy（Codex 抓跨 PR 绕过：单独加豁免不得 no-op）→ invalid" "invalid" \
  $'apps/aster-lang/runner/deploy-policy.yaml' \
  $'modified\tapps/aster-lang/runner/deploy-policy.yaml'
tc "仅 kustomization（缺 deployment，非完整 go-live）→ invalid" "invalid" \
  $'apps/aster-lang/runner/kustomization.yaml' \
  $'modified\tapps/aster-lang/runner/kustomization.yaml'
tc "kustomization+deployment（无 deploy-policy，合法：不删 deferred 由校验器兜底）→ runner-topology" "runner-topology" \
  $'apps/aster-lang/runner/kustomization.yaml\napps/aster-lang/runner/deployment.yaml' \
  $'modified\tapps/aster-lang/runner/kustomization.yaml\nmodified\tapps/aster-lang/runner/deployment.yaml'
tc "cloud pin → cloud-pin" "cloud-pin" \
  $'apps/aster-lang/cloud/image-lock.yaml\napps/aster-lang/cloud/kustomization.yaml' \
  $'modified\tapps/aster-lang/cloud/image-lock.yaml'
tc "cloud+runner 同命中（非法混合）→ runner 分支，未改 image-lock+触 cloud 非授权 → invalid" "invalid" \
  $'apps/aster-lang/cloud/kustomization.yaml\napps/aster-lang/runner/kustomization.yaml' \
  $'modified\tapps/aster-lang/cloud/kustomization.yaml\nmodified\tapps/aster-lang/runner/kustomization.yaml'
tc "topology 只改 kustomization+deployment（不删 deferred，校验器兜底拒但 lane 仍 topology）" "runner-topology" \
  $'apps/aster-lang/runner/kustomization.yaml\napps/aster-lang/runner/deployment.yaml' \
  $'modified\tapps/aster-lang/runner/kustomization.yaml\nmodified\tapps/aster-lang/runner/deployment.yaml'

echo ""
if [[ "$FAILED" == "0" ]]; then
  echo "全部通过（lane 分派完备互斥：none/cloud-pin/runner-pin/runner-topology/invalid）。"; exit 0
else
  echo "存在失败用例，见上方 ✗。"; exit 1
fi
