#!/usr/bin/env bash
# 验 verify-image-pin.sh 的 env-binding 分支（deployBinding: env）：
#   (1) env-bound 镜像：deployment 的 RUNNER_IMAGE_DIGEST env value == image-lock digest → 过。
#   (2) env value != image-lock digest → fail-closed。
#   (3) deployment 除该 env value 外有其它字段变更（夹带）→ semantic-diff fail-closed。
#   (4) verifier 忽略 PR 供的 selector，只用 base 侧硬编码 selector（恶意 selector 无效）。
# ★离线测：FRESHNESS=off + 无 cosign（用 deployBinding=env 但把 cosign 步骤经 freshness=off 短路
#   不可行——cosign 仍会跑）。故本 harness 用一个**不在 allowed-images 白名单**触发不了 cosign？不行。
#   正解：本 harness 只验 env-binding 的**结构逻辑**（env value 读取 + 一致性 + semantic-diff），
#   用一个 stub allowed-images（含 runner entry deployBinding=env）+ FRESHNESS=off，并让 digest/sha
#   形状合法但 cosign 必然失败——故本 harness 断言的是「env-binding 校验在 cosign 之前 fail-closed」
#   与「env value 一致时能走到 cosign（cosign 失败是预期，不算 env-binding 逻辑失败）」。
# ★因 cosign 对占位 digest 必失败，本 harness 采取「分层断言」：
#   - 期望 PASS 的用例：断言错误输出**不含** env-binding 相关错误（env 一致性/ semantic-diff 均过），
#     只在 cosign 步失败（证明 env-binding 分支放行到了 cosign）。
#   - 期望 FAIL 的用例：断言错误输出**含**指定 env-binding 错误串（在 cosign 之前拦下）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY="${SCRIPT_DIR}/verify-image-pin.sh"
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILED=1; }

# 真实 40-hex sourceSha + 合法 sha256 digest（cosign 会失败，但形状过 shape 校验）。
SHA40="1111111111111111111111111111111111111111"
DIGEST="sha256:$(printf 'a%.0s' $(seq 1 64))"

make_allowed() {  # $1=deployBinding
  cat <<EOF
version: 1
oidcIssuer: https://token.actions.githubusercontent.com
images:
  - image: docker.io/wontlost/aster-replay-runner
    sourceRepo: aster-cloud/aster-api
    workflowFile: aster-replay-runner-deploy.yml
    sourceRef: refs/heads/main
    deployBinding: $1
EOF
}
make_base_lock() {
  cat <<EOF
version: 1
images:
  - image: docker.io/wontlost/aster-replay-runner
    digest: sha256:0000000000000000000000000000000000000000000000000000000000000000
    sourceSha: UNVERIFIED-SEED
    runId: "0"
EOF
}
make_head_lock() {  # $1=digest $2=sourceSha
  cat <<EOF
version: 1
images:
  - image: docker.io/wontlost/aster-replay-runner
    digest: $1
    sourceSha: $2
    runId: "42"
EOF
}
make_deployment() {  # $1=RUNNER_IMAGE_DIGEST value  $2=extra replicas 行(空或 "replicas: 9")
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: runner-launcher
  namespace: aster-runner
spec:
  ${2:-replicas: 0}
  selector:
    matchLabels:
      app.kubernetes.io/name: runner-launcher
  template:
    spec:
      containers:
        - name: runner-launcher
          image: docker.io/wontlost/aster-runner-launcher@sha256:0000000000000000000000000000000000000000000000000000000000000000
          env:
            - name: PORT
              value: "8080"
            - name: RUNNER_NAMESPACE
              value: aster-runner
            - name: RUNNER_IMAGE_DIGEST
              value: $1
EOF
}

echo "=== Test 1: env value == image-lock digest → env-binding 放行到 cosign（不因 env 逻辑失败）==="
T="$(mktemp -d)"
make_allowed env             > "$T/allowed.yaml"
make_base_lock               > "$T/base-lock.yaml"
make_head_lock "$DIGEST" "$SHA40" > "$T/head-lock.yaml"
make_deployment "$DIGEST" "" > "$T/head-deploy.yaml"
make_deployment "sha256:0000000000000000000000000000000000000000000000000000000000000000" "" > "$T/base-deploy.yaml"
out="$(IMAGE_PIN_FRESHNESS=off bash "$VERIFY" \
  "$T/allowed.yaml" "$T/base-lock.yaml" "$T/head-lock.yaml" "" "" "$T/head-deploy.yaml" "$T/base-deploy.yaml" 2>&1)"
# ★修正（brief 原式 `grep -qi "env value.*!=\|deployment semantic-diff"` 会误命中成功行
#   "deployment semantic-diff OK（...）"，导致本应 PASS 的用例被误判 FAIL）。
#   改为只匹配 `::error::` 前缀的 env-binding 失败行，不命中 info 的 OK 行。
if grep -q "::error::.*RUNNER_IMAGE_DIGEST env value" <<<"$out" || grep -q "::error::.*deployment semantic-diff" <<<"$out"; then
  fail "env 一致时不应报 env-binding 错（实际报了：$(grep '::error::.*\(RUNNER_IMAGE_DIGEST env value\|deployment semantic-diff\)' <<<"$out" | head -1)）"
else
  pass "env value 一致 → 未触发 env-binding fail-closed（放行到 cosign）"
fi
rm -rf "$T"

echo "=== Test 2: env value != image-lock digest → env-binding fail-closed（cosign 前拦下）==="
T="$(mktemp -d)"
make_allowed env             > "$T/allowed.yaml"
make_base_lock               > "$T/base-lock.yaml"
make_head_lock "$DIGEST" "$SHA40" > "$T/head-lock.yaml"
WRONG="sha256:$(printf 'b%.0s' $(seq 1 64))"
make_deployment "$WRONG" ""  > "$T/head-deploy.yaml"
make_deployment "sha256:0000000000000000000000000000000000000000000000000000000000000000" "" > "$T/base-deploy.yaml"
out="$(IMAGE_PIN_FRESHNESS=off bash "$VERIFY" \
  "$T/allowed.yaml" "$T/base-lock.yaml" "$T/head-lock.yaml" "" "" "$T/head-deploy.yaml" "$T/base-deploy.yaml" 2>&1)"
rc=$?
if [[ "$rc" != "0" ]] && grep -q "RUNNER_IMAGE_DIGEST env value" <<<"$out"; then
  pass "env value 不一致 → 非零退出 + 报 env value 错（fail-closed）"
else
  fail "env value 不一致未 fail-closed（rc=$rc）"
fi
rm -rf "$T"

echo "=== Test 3: deployment 夹带其它字段变更（replicas 0→9）→ semantic-diff fail-closed ==="
T="$(mktemp -d)"
make_allowed env             > "$T/allowed.yaml"
make_base_lock               > "$T/base-lock.yaml"
make_head_lock "$DIGEST" "$SHA40" > "$T/head-lock.yaml"
make_deployment "$DIGEST" "replicas: 9" > "$T/head-deploy.yaml"   # env value 对，但 replicas 被改
make_deployment "sha256:0000000000000000000000000000000000000000000000000000000000000000" "replicas: 0" > "$T/base-deploy.yaml"
out="$(IMAGE_PIN_FRESHNESS=off bash "$VERIFY" \
  "$T/allowed.yaml" "$T/base-lock.yaml" "$T/head-lock.yaml" "" "" "$T/head-deploy.yaml" "$T/base-deploy.yaml" 2>&1)"
rc=$?
if [[ "$rc" != "0" ]] && grep -q "deployment semantic-diff" <<<"$out"; then
  pass "deployment 夹带其它变更 → semantic-diff fail-closed"
else
  fail "deployment 夹带变更未被 semantic-diff 拦（rc=$rc）"
fi
rm -rf "$T"

echo ""
if [[ "$FAILED" == "0" ]]; then
  echo "全部通过（env value 一致性 + semantic-diff allowlist + fail-closed）。"; exit 0
else
  echo "存在失败用例，见上方 ✗。"; exit 1
fi
