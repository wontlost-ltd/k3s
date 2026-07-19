#!/usr/bin/env bash
# 守 S2-0 的 4 个 ClusterImagePolicy 与信任根 allowed-images.yaml 的契约一致性。
#
# 契约（见 docs/p0a-s2-0-cosign-admission-design.md §7）：
#   - 信任根每 repository 恰 1 digest-verify CIP + 1 tag-fail CIP（N 仓 → 2N CIP）。
#   - digest-verify：glob index.docker.io/<repo>@sha256:**；keyless issuer/subject
#     == allowed-images 派生值；images/authorities/keyless.identities 各恰 1 项。
#   - tag-fail：glob index.docker.io/<repo>:**；唯一 authority static.action==fail。
#   - 4 份全 mode: enforce。
#   - ★字段收紧（防缩域字段漂移盲区）：
#     - digest-verify CIP 的 .spec 只允许 images/authorities/mode 三键（不许加
#       match 等缩小作用域的额外字段）；authorities[0] 只允许 keyless 键。
#     - tag-fail CIP 的 authorities[0] 只允许 static 键。
#     - 全部 CIP 的 apiVersion == policy.sigstore.dev/v1beta1、
#       kind == ClusterImagePolicy、sync-wave 注解 == "2"。
#
# 退出 0 = 一致；非 0 = 漂移（打印具体项）。依赖 yq。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWED="${ALLOWED_IMAGES_FILE:-$REPO_ROOT/.github/image-pin/allowed-images.yaml}"
CIP_DIR="${CIP_DIR:-$REPO_ROOT/apps/infrastructure/policy-controller/policies}"
ISSUER="https://token.actions.githubusercontent.com"

fail() { echo "CIP-DRIFT: $*" >&2; exit 1; }

command -v yq >/dev/null || fail "yq 未安装"
[[ -f "$ALLOWED" ]] || fail "信任根不存在: $ALLOWED"
[[ -d "$CIP_DIR" ]] || fail "CIP 目录不存在: $CIP_DIR"

# 校验信任根 issuer 常量
allowed_issuer="$(yq eval '.oidcIssuer' "$ALLOWED")"
[[ "$allowed_issuer" == "$ISSUER" ]] || fail "allowed-images oidcIssuer 非预期: $allowed_issuer"

# 收集所有 CIP（跨全部文件）到临时汇总
mapfile -t CIP_FILES < <(find "$CIP_DIR" -name 'cluster-image-policy-*.yaml' | sort)
[[ ${#CIP_FILES[@]} -gt 0 ]] || fail "未找到任何 CIP 文件"

# 每个 repository 走一遍
repo_count="$(yq eval '.images | length' "$ALLOWED")"
expected_cip=$(( repo_count * 2 ))
actual_cip=${#CIP_FILES[@]}
[[ "$actual_cip" -eq "$expected_cip" ]] || fail "CIP 数量=${actual_cip}，期望 2×${repo_count}=${expected_cip}（N 仓→2N CIP）"

# 提取某 name 的 CIP 文件（在所有文件里找）
cip_field() { # $1=name $2=yq-path
  local name="$1" path="$2" f
  for f in "${CIP_FILES[@]}"; do
    if [[ "$(yq eval '.metadata.name' "$f")" == "$name" ]]; then
      yq eval "$path" "$f"; return 0
    fi
  done
  echo "__MISSING__"
}

# 提取某 name 的 CIP 文件在给定路径下的排序后键集合（逗号拼接，便于整串比较）
cip_keys() { # $1=name $2=yq-path
  local name="$1" path="$2" f
  for f in "${CIP_FILES[@]}"; do
    if [[ "$(yq eval '.metadata.name' "$f")" == "$name" ]]; then
      yq eval "${path} | keys | sort | join(\",\")" "$f"; return 0
    fi
  done
  echo "__MISSING__"
}

# ── 全局字段收紧：apiVersion/kind/sync-wave 对全部 CIP 文件生效（防缩域字段漂移盲区）──
for f in "${CIP_FILES[@]}"; do
  cname="$(yq eval '.metadata.name' "$f")"
  [[ "$(yq eval '.apiVersion' "$f")" == "policy.sigstore.dev/v1beta1" ]] || fail "${cname} apiVersion 漂移"
  [[ "$(yq eval '.kind' "$f")" == "ClusterImagePolicy" ]]                || fail "${cname} kind 漂移"
  [[ "$(yq eval '.metadata.annotations["argocd.argoproj.io/sync-wave"]' "$f")" == "2" ]] || fail "${cname} sync-wave 注解漂移(非 \"2\")"
done

i=0
while [[ $i -lt $repo_count ]]; do
  image="$(yq eval ".images[$i].image" "$ALLOWED")"          # docker.io/wontlost/aster-api
  src_repo="$(yq eval ".images[$i].sourceRepo" "$ALLOWED")"  # aster-cloud/aster-api
  wf="$(yq eval ".images[$i].workflowFile" "$ALLOWED")"      # deploy.yml
  ref="$(yq eval ".images[$i].sourceRef" "$ALLOWED")"        # refs/heads/main
  repo="${image#docker.io/}"                                  # wontlost/aster-api
  slug="${repo#wontlost/}"                                    # aster-api
  norm="index.docker.io/${repo}"
  expected_subject="https://github.com/${src_repo}/.github/workflows/${wf}@${ref}"

  dv="wontlost-${slug}"
  tf="wontlost-${slug}-reject-tag"

  # ── digest-verify CIP ──
  [[ "$(cip_field "$dv" '.spec.images | length')" == "1" ]]        || fail "$dv images 非恰 1 项"
  [[ "$(cip_field "$dv" '.spec.images[0].glob')" == "${norm}@sha256:**" ]] || fail "$dv glob 漂移"
  [[ "$(cip_field "$dv" '.spec.authorities | length')" == "1" ]]   || fail "$dv authorities 非恰 1 项"
  [[ "$(cip_field "$dv" '.spec.authorities[0].keyless.identities | length')" == "1" ]] || fail "$dv keyless.identities 非恰 1 项(防 OR 扩权)"
  [[ "$(cip_field "$dv" '.spec.authorities[0].keyless.identities[0].issuer')" == "$ISSUER" ]] || fail "$dv issuer 漂移"
  [[ "$(cip_field "$dv" '.spec.authorities[0].keyless.identities[0].subject')" == "$expected_subject" ]] || fail "${dv} subject 漂移（期望 ${expected_subject}）"
  [[ "$(cip_field "$dv" '.spec.mode')" == "enforce" ]]            || fail "$dv 非 enforce"
  # ★缩域字段漂移防护：.spec 只许 images/authorities/mode 三键；authorities[0] 只许 keyless 键
  [[ "$(cip_keys "$dv" '.spec')" == "authorities,images,mode" ]]  || fail "${dv} .spec 出现多余/缺失键(期望恰 authorities,images,mode)"
  [[ "$(cip_keys "$dv" '.spec.authorities[0]')" == "keyless" ]]   || fail "${dv} authorities[0] 出现多余/缺失键(期望恰 keyless)"

  # ── tag-fail CIP ──
  [[ "$(cip_field "$tf" '.spec.images | length')" == "1" ]]        || fail "$tf images 非恰 1 项"
  [[ "$(cip_field "$tf" '.spec.images[0].glob')" == "${norm}:**" ]] || fail "$tf glob 漂移"
  [[ "$(cip_field "$tf" '.spec.authorities | length')" == "1" ]]   || fail "$tf authorities 非恰 1 项"
  [[ "$(cip_field "$tf" '.spec.authorities[0].static.action')" == "fail" ]] || fail "$tf static.action 非 fail"
  [[ "$(cip_field "$tf" '.spec.mode')" == "enforce" ]]            || fail "$tf 非 enforce"
  # ★缩域字段漂移防护：.spec 只许 images/authorities/mode 三键；authorities[0] 只许 static 键
  [[ "$(cip_keys "$tf" '.spec')" == "authorities,images,mode" ]]  || fail "${tf} .spec 出现多余/缺失键(期望恰 authorities,images,mode)"
  [[ "$(cip_keys "$tf" '.spec.authorities[0]')" == "static" ]]    || fail "${tf} authorities[0] 出现多余/缺失键(期望恰 static)"

  i=$(( i + 1 ))
done

echo "CIP-SYNC OK: ${actual_cip} 个 CIP 与信任根 ${repo_count} 仓契约一致"
