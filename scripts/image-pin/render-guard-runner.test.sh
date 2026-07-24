#!/usr/bin/env bash
# 验 verify-rendered-by-digest-runner.yml 的 render-guard 逻辑（runner 受控镜像持续 by-digest 守卫）。
# ★复刻 workflow「Assert runner controlled images render/pin by-digest」步的判定，对多种篡改断言行为。
#   launcher（kustomization-bound）：除非 deploy-policy deferred，否则渲染须 @sha256（transformer 覆写
#   by name，故 deployment.yaml 的浮动 tag 被覆写=无害 pass；改 image NAME/删 transformer=真回落 fail）。
#   runner（env-bound）：RUNNER_IMAGE_DIGEST env value 须 sha256:64hex。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER_SRC="${REPO_ROOT}/apps/aster-lang/runner"
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILED=1; }

for c in yq kubectl; do command -v "$c" >/dev/null || { echo "::error::依赖缺失（${c}）→ 非通过"; exit 2; }; done
[[ -d "$RUNNER_SRC" ]] || { echo "::error::找不到 runner 源 ${RUNNER_SRC} → 非通过"; exit 2; }

# render-guard 逻辑复刻（对象绑定，与 workflow 逐条对应）。返回 0=pass，非 0=fail-closed。
guard() {
  local DIR="$1" LAUNCHER=docker.io/wontlost/aster-runner-launcher DEPLOY_NAME=runner-launcher RUNNER_NS=aster-runner
  local fail=0 rendered dep_count deferred dep c_count img dep_file rc rid_count rid
  rendered="$(kubectl kustomize "$DIR" 2>/dev/null)" || return 1
  local dep_sel="select(.apiVersion == \"apps/v1\" and .kind == \"Deployment\" and .metadata.namespace == \"$RUNNER_NS\" and .metadata.name == \"$DEPLOY_NAME\")"
  dep_count="$(echo "$rendered" | yq -N "${dep_sel} | .kind" 2>/dev/null | grep -c '^Deployment$' || true)"
  deferred="$(yq "[.deferredImages[]? | select(.image == \"$LAUNCHER\")] | length" "$DIR/deploy-policy.yaml" 2>/dev/null || echo 0)"
  if [[ "$deferred" != "0" ]]; then
    local launcher_refs
    launcher_refs="$(echo "$rendered" | yq -N '.. | select(has("image")) | .image' 2>/dev/null \
      | grep -cE "^((index\.)?docker\.io/)?wontlost/aster-runner-launcher(@|:)" || true)"
    [[ "$launcher_refs" == "0" ]] || fail=1
  else
    if [[ "$dep_count" != "1" ]]; then
      fail=1
    else
      dep="$(echo "$rendered" | yq -N -o=json "${dep_sel}")"
      c_count="$(jq "[.spec.template.spec.containers[] | select(.name == \"$DEPLOY_NAME\")] | length" <<<"$dep")"
      if [[ "$c_count" != "1" ]]; then
        fail=1
      else
        img="$(jq -r ".spec.template.spec.containers[] | select(.name == \"$DEPLOY_NAME\") | .image" <<<"$dep")"
        [[ "$img" =~ ^${LAUNCHER}@sha256:[0-9a-f]{64}$ ]] || fail=1
      fi
    fi
  fi
  dep_file="$DIR/deployment.yaml"
  rc="$(yq "[.spec.template.spec.containers[] | select(.name == \"$DEPLOY_NAME\")] | length" "$dep_file")"
  if [[ "$rc" != "1" ]]; then
    fail=1
  else
    rid_count="$(yq "[.spec.template.spec.containers[] | select(.name == \"$DEPLOY_NAME\") | .env[] | select(.name == \"RUNNER_IMAGE_DIGEST\")] | length" "$dep_file")"
    rid="$(yq ".spec.template.spec.containers[] | select(.name == \"$DEPLOY_NAME\") | .env[] | select(.name == \"RUNNER_IMAGE_DIGEST\") | .value" "$dep_file" 2>/dev/null || true)"
    [[ "$rid_count" == "1" ]] || fail=1
    [[ "$rid" =~ ^sha256:[0-9a-f]{64}$ ]] || fail=1
  fi
  return $fail
}

# $1=desc $2=mutation(eval, 作用于 $A) $3=期望(pass|fail)
tc() {
  local desc="$1" mut="$2" want="$3" A r
  A="$(mktemp -d)" || { echo "FATAL mktemp"; exit 2; }
  cp "$RUNNER_SRC"/*.yaml "$A/" || { echo "FATAL cp"; exit 2; }
  eval "$mut"
  if guard "$A"; then r=pass; else r=fail; fi
  [[ "$r" == "$want" ]] && pass "${desc} → ${r}" || fail "${desc}：期望 ${want} 得 ${r}"
  rm -rf "$A"
}

echo "=== runner render-guard 行为矩阵 ==="
tc "当前 go-live 树（launcher @sha256 + RID sha256）" "true" "pass"
tc "deployment.yaml 浮动 tag（transformer 按 name 覆写→渲染仍 @digest→无害）" \
  'yq -i ".spec.template.spec.containers[0].image = \"docker.io/wontlost/aster-runner-launcher:latest\"" "$A/deployment.yaml"' "pass"
tc "image NAME→evil（transformer no-match→launcher@sha256 缺失→真回落）" \
  'yq -i ".spec.template.spec.containers[0].image = \"docker.io/evil/x:latest\"" "$A/deployment.yaml"' "fail"
tc "删 kustomization images transformer + name tag" \
  'yq -i "del(.images)" "$A/kustomization.yaml"; yq -i ".spec.template.spec.containers[0].image = \"docker.io/wontlost/aster-runner-launcher:jvm-latest\"" "$A/deployment.yaml"' "fail"
tc "RUNNER_IMAGE_DIGEST env → 浮动 tag" \
  'yq -i "(.spec.template.spec.containers[0].env[] | select(.name == \"RUNNER_IMAGE_DIGEST\")).value = \"latest\"" "$A/deployment.yaml"' "fail"
tc "RUNNER_IMAGE_DIGEST env 删除" \
  'yq -i ".spec.template.spec.containers[0].env = [.spec.template.spec.containers[0].env[] | select(.name != \"RUNNER_IMAGE_DIGEST\")]" "$A/deployment.yaml"' "fail"
tc "RUNNER_IMAGE_DIGEST env → 畸形非 64hex" \
  'yq -i "(.spec.template.spec.containers[0].env[] | select(.name == \"RUNNER_IMAGE_DIGEST\")).value = \"sha256:xyz\"" "$A/deployment.yaml"' "fail"
tc "合法 deferred launcher（rollback，移出 resources）→ launcher Deployment 不渲染，自洽豁免" \
  'yq -i ".deferredImages = [{\"image\":\"docker.io/wontlost/aster-runner-launcher\",\"reason\":\"rollback\"}]" "$A/deploy-policy.yaml"; yq -i "del(.resources[] | select(. == \"deployment.yaml\" or . == \"external-secrets.yaml\"))" "$A/kustomization.yaml"' "pass"

echo "=== Codex 复审新增反例（对象绑定 + 自洽 deferred）==="
# 反例：加 deferred 但 Deployment 仍在 resources + 容器改浮动镜像 → 旧版存在性 grep 会假绿；对象绑定须 fail。
tc "★deferred 但 Deployment 仍部署（矛盾态，容器浮动）→ fail-closed" \
  'yq -i ".deferredImages = [{\"image\":\"docker.io/wontlost/aster-runner-launcher\",\"reason\":\"evil\"}]" "$A/deploy-policy.yaml"; yq -i ".spec.template.spec.containers[0].image = \"docker.io/wontlost/aster-runner-launcher:latest\"" "$A/deployment.yaml"' "fail"
# 反例：真实 launcher 容器改 name→evil（transformer no-match），但在 deployment 加 decoy sidecar 引用
#   launcher name（transformer 覆写成 @digest）满足全局 grep → 旧版假绿；对象绑定按容器名 runner-launcher
#   精确选，真实容器 image 是 evil → fail。
tc "★decoy sidecar（真 launcher 容器→evil name + decoy 容器满足全局 grep）→ fail-closed" \
  'yq -i ".spec.template.spec.containers[0].image = \"docker.io/evil/x:latest\"" "$A/deployment.yaml"; yq -i ".spec.template.spec.containers += [{\"name\":\"decoy\",\"image\":\"docker.io/wontlost/aster-runner-launcher\"}]" "$A/deployment.yaml"' "fail"
# 反例：sidecar 重排——index 0 放合法 RID 的 decoy 容器，真实 runner-launcher 容器 RID 浮动。
#   旧版 containers[0] 读 decoy 的合法 RID 假绿；按容器名选须 fail。
tc "★sidecar 重排（index0=decoy 合法 RID，真容器 RID 浮动）→ fail-closed" \
  'yq -i "(.spec.template.spec.containers[] | select(.name == \"runner-launcher\") | .env[] | select(.name == \"RUNNER_IMAGE_DIGEST\")).value = \"latest\"" "$A/deployment.yaml"; yq -i ".spec.template.spec.containers = [{\"name\":\"decoy\",\"image\":\"x@sha256:0000000000000000000000000000000000000000000000000000000000000000\",\"env\":[{\"name\":\"RUNNER_IMAGE_DIGEST\",\"value\":\"sha256:97dbc3b017efa5e9f23a21c08f18d4770f42c4ced9e8092f803ad43643804728\"}]}] + .spec.template.spec.containers" "$A/deployment.yaml"' "fail"
# ★Codex 复审2：deferred + Deployment 改名（避开固定四元组）但仍在 resources + 浮动 launcher 镜像。
#   旧版只查固定四元组缺席→dep_count=0 假绿；新版查渲染中任何容器引用 launcher 镜像→仍引用→fail。
tc "★deferred + Deployment 改名规避四元组 + 仍带 launcher 浮动镜像 → fail-closed" \
  'yq -i ".deferredImages = [{\"image\":\"docker.io/wontlost/aster-runner-launcher\",\"reason\":\"evil\"}]" "$A/deploy-policy.yaml"; yq -i ".metadata.name = \"evil-launcher\"" "$A/deployment.yaml"; yq -i ".spec.template.spec.containers[0].image = \"docker.io/wontlost/aster-runner-launcher:latest\"" "$A/deployment.yaml"' "fail"

echo ""
if [[ "$FAILED" == "0" ]]; then
  echo "全部通过（对象绑定 launcher 容器 @sha256 / transformer 覆写无害 / 真回落+decoy+sidecar重排 fail-closed / RID env 按容器名 by-digest / deferred 自洽闭环）。"; exit 0
else
  echo "存在失败用例，见上方 ✗。"; exit 1
fi
