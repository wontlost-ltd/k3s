#!/usr/bin/env bash
# 验 verify-image-pin.yml 的 lane 分派逻辑（none|cloud-pin|runner-pin|invalid）。
# ★workflow 内联 shell 无法直接单测，故本测试**复刻**分派算法（与 workflow「Compute changed files」步
#   的判定逻辑逐条对应），对多种 PR 形状断言正确 lane。分派算法若在 workflow 改动，须同步本复刻。
#
# ★runner-topology lane 已退休（一次性 go-live 迁移通道，迁移完成后其校验器因硬编码
#   expected_res = base + [deployment.yaml, external-secrets.yaml] 而永不可能再通过，
#   实际只剩「拦住一切合法 runner 配置变更」这一个作用）。退休后的规则：
#     - deployment.yaml 不再是触发路径（不含 pin 数据）→ 改它走 lane=none（日常运维：replicas/PDB/探针）
#     - kustomization.yaml（含 images 段 = pin 数据本体）与 deploy-policy.yaml（render 豁免来源）
#       仍是触发路径；碰了它们却没改 image-lock → invalid（fail-closed）
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
# $3 = kust_images_changed（true/false）——复刻 workflow 对 kustomization 的**内容级**判定：
#   只有 images 段实际变化才算 pin 变更；只改 resources（注册新清单）不触发。
dispatch() {
  local cf="$1" st="$2" kust_images_changed="${3:-false}" pin_flavor lane
  pin_flavor=none
  if grep -qxF "$CLOUD_LOCK_PATH" "$cf" || grep -qxF "$CLOUD_KUST_PATH" "$cf"; then pin_flavor=cloud; fi
  # ★deployment.yaml 已从触发路径移除（见文件头）；kustomization 改按 images 段内容判定。
  if grep -qxF "$RUNNER_LOCK_PATH" "$cf" || [[ "$kust_images_changed" == "true" ]] || grep -qxF "$RUNNER_DEPLOY_POLICY_PATH" "$cf"; then
    pin_flavor=runner
  fi
  lane=none
  if [[ "$pin_flavor" == "cloud" ]]; then
    lane=cloud-pin
  elif [[ "$pin_flavor" == "runner" ]]; then
    if grep -qxF "$RUNNER_LOCK_PATH" "$cf"; then
      lane=runner-pin
    else
      # 碰了 kustomization（images 段）或 deploy-policy（render 豁免源）却没改 image-lock → fail-closed。
      lane=invalid
    fi
  fi
  echo "$lane"
}

# 用例：$1=desc $2=期望 lane $3=changed-files（换行分隔）$4=status $5=kust_images_changed（默认 false）
tc() {
  local desc="$1" want="$2" cf st got
  cf="$(mktemp)"; st="$(mktemp)"
  printf '%s\n' "$3" > "$cf"
  printf '%s\n' "$4" > "$st"
  got="$(dispatch "$cf" "$st" "${5:-false}")"
  [[ "$got" == "$want" ]] && pass "${desc} → ${got}" || fail "${desc}：期望 ${want} 得 ${got}"
  rm -f "$cf" "$st"
}

echo "=== lane 分派用例 ==="
tc "image-pin bot（image-lock+kustomization）" "runner-pin" \
  $'apps/aster-lang/runner/image-lock.yaml\napps/aster-lang/runner/kustomization.yaml' \
  $'modified\tapps/aster-lang/runner/image-lock.yaml\nmodified\tapps/aster-lang/runner/kustomization.yaml'
tc "runner env-bound bot（image-lock+deployment）" "runner-pin" \
  $'apps/aster-lang/runner/image-lock.yaml\napps/aster-lang/runner/deployment.yaml' \
  $'modified\tapps/aster-lang/runner/image-lock.yaml\nmodified\tapps/aster-lang/runner/deployment.yaml'
tc "改 kustomization.images 但不改 image-lock（pin 数据本体被动）→ invalid" "invalid" \
  $'apps/aster-lang/runner/kustomization.yaml\napps/aster-lang/runner/role.yaml' \
  $'modified\tapps/aster-lang/runner/kustomization.yaml\nmodified\tapps/aster-lang/runner/role.yaml' \
  true
tc "非 runner PR（docs）→ none" "none" \
  $'README.md' \
  $'modified\tREADME.md'
# ── topology 退休后新增覆盖：runner 日常运维变更须能走 none（正是本次退休的动因）──
tc "★运维：加 pdb.yaml + 改 deployment(replicas) → none（退休前此形状被判 invalid，PDB 根本加不进去）" "none" \
  $'apps/aster-lang/runner/pdb.yaml\napps/aster-lang/runner/deployment.yaml' \
  $'added\tapps/aster-lang/runner/pdb.yaml\nmodified\tapps/aster-lang/runner/deployment.yaml'
tc "运维：只改 deployment（replicas/探针，不含 pin 数据）→ none" "none" \
  $'apps/aster-lang/runner/deployment.yaml' \
  $'modified\tapps/aster-lang/runner/deployment.yaml'
tc "运维：新增独立清单（network-policy）→ none" "none" \
  $'apps/aster-lang/runner/network-policy.yaml' \
  $'added\tapps/aster-lang/runner/network-policy.yaml'
# ★env-bound pin（aster-replay-runner）真相载体是 deployment 的 RUNNER_IMAGE_DIGEST，
#   但 bot 必定同时双写 image-lock → 仍落 runner-pin（不因 deployment 移出触发路径而漏验签）。
tc "★env-bound bot 仍进 strict：image-lock+deployment → runner-pin" "runner-pin" \
  $'apps/aster-lang/runner/image-lock.yaml\napps/aster-lang/runner/deployment.yaml' \
  $'modified\tapps/aster-lang/runner/image-lock.yaml\nmodified\tapps/aster-lang/runner/deployment.yaml'
tc "仅 deploy-policy（Codex 抓跨 PR 绕过：单独加豁免不得 no-op）→ invalid" "invalid" \
  $'apps/aster-lang/runner/deploy-policy.yaml' \
  $'modified\tapps/aster-lang/runner/deploy-policy.yaml'
tc "仅 kustomization 且 images 变（未改 image-lock）→ invalid" "invalid" \
  $'apps/aster-lang/runner/kustomization.yaml' \
  $'modified\tapps/aster-lang/runner/kustomization.yaml' \
  true
tc "kustomization+deployment 且 images 变但无 image-lock（手改 images 绕过）→ invalid" "invalid" \
  $'apps/aster-lang/runner/kustomization.yaml\napps/aster-lang/runner/deployment.yaml' \
  $'modified\tapps/aster-lang/runner/kustomization.yaml\nmodified\tapps/aster-lang/runner/deployment.yaml' \
  true
# ── 内容级判定：改 kustomization 但 images 段不变（注册新清单）→ 不是 pin 变更 ──
tc "★运维：注册 pdb.yaml（改 kustomization.resources，images 不变）→ none" "none" \
  $'apps/aster-lang/runner/pdb.yaml\napps/aster-lang/runner/kustomization.yaml\napps/aster-lang/runner/deployment.yaml' \
  $'added\tapps/aster-lang/runner/pdb.yaml\nmodified\tapps/aster-lang/runner/kustomization.yaml\nmodified\tapps/aster-lang/runner/deployment.yaml' \
  false
tc "★同一 PR 既注册清单又动 images（混合）→ invalid（images 变即严守）" "invalid" \
  $'apps/aster-lang/runner/pdb.yaml\napps/aster-lang/runner/kustomization.yaml' \
  $'added\tapps/aster-lang/runner/pdb.yaml\nmodified\tapps/aster-lang/runner/kustomization.yaml' \
  true
tc "cloud pin → cloud-pin" "cloud-pin" \
  $'apps/aster-lang/cloud/image-lock.yaml\napps/aster-lang/cloud/kustomization.yaml' \
  $'modified\tapps/aster-lang/cloud/image-lock.yaml'
# ★cloud+runner 混合：runner images 未变 → 不再升级为 runner lane，落 cloud-pin（strict 链）。
#   **不放松**：cloud-pin 的 check-pr-shape.sh 路径白名单只许 cloud image-lock + cloud kustomization，
#   夹带 runner/kustomization.yaml 命中 `*)` catch-all 直接 die（已实测：
#   "image-pin PR 只能改 .../cloud/image-lock.yaml 和 .../cloud/kustomization.yaml, 却改了 .../runner/kustomization.yaml"）。
#   即 lane 从 invalid 变 cloud-pin，但**最终仍 fail-closed**，只是由后置校验器而非分派器拒。
tc "cloud+runner 混合但 runner images 不变 → cloud-pin（后由 check-pr-shape 路径白名单拒）" "cloud-pin" \
  $'apps/aster-lang/cloud/kustomization.yaml\napps/aster-lang/runner/kustomization.yaml' \
  $'modified\tapps/aster-lang/cloud/kustomization.yaml\nmodified\tapps/aster-lang/runner/kustomization.yaml' \
  false
tc "cloud+runner 混合且 runner images 也变 → runner 分支 invalid（分派器即拒）" "invalid" \
  $'apps/aster-lang/cloud/kustomization.yaml\napps/aster-lang/runner/kustomization.yaml' \
  $'modified\tapps/aster-lang/cloud/kustomization.yaml\nmodified\tapps/aster-lang/runner/kustomization.yaml' \
  true
tc "deploy-policy 与 deployment 同现但无 image-lock（仍是豁免源被动）→ invalid" "invalid" \
  $'apps/aster-lang/runner/deploy-policy.yaml\napps/aster-lang/runner/deployment.yaml' \
  $'modified\tapps/aster-lang/runner/deploy-policy.yaml\nmodified\tapps/aster-lang/runner/deployment.yaml'

echo ""
if [[ "$FAILED" == "0" ]]; then
  echo "全部通过（lane 分派完备互斥：none/cloud-pin/runner-pin/invalid）。"; exit 0
else
  echo "存在失败用例，见上方 ✗。"; exit 1
fi
