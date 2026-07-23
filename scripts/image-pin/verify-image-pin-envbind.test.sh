#!/usr/bin/env bash
# 验 verify-image-pin.sh 的 env-binding 分支（deployBinding: env）：
#   (1) env-bound 镜像：deployment 的 RUNNER_IMAGE_DIGEST env value == image-lock digest → 过。
#   (2) env value != image-lock digest → fail-closed。
#   (3) deployment 除该 env value 外有其它字段变更（夹带）→ semantic-diff fail-closed。
#   (4) verifier 忽略 PR 供的 selector，只用 base 侧硬编码 selector（恶意 selector 无效）。
#   (5) ★Task A4 Blocker 1 回归：env-bound entry 但完全未提供 HEAD_DEPLOYMENT（载体缺失）
#       → fail-closed（不得因参数缺失而跳过）。
#   (6) ★Task A4 Blocker 1 回归（核心反例）：kustomization-bound entry 但完全未提供
#       HEAD_KUSTOMIZATION（载体缺失）→ fail-closed。这正是 Codex 复现的生产级绕过：
#       runner launcher lock-only PR 不带 kustomization 时，此前会静默跳过一致性检查而
#       exit 0；本用例证明修复后必须非零退出并报确定性错误。
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
# ★非 vacuous 正向断言（Codex 抓）：不能只断言「无 env-binding 错」——那样脚本若提前退出
#   （缺工具/解析错，根本没进 env 分支）也会误判 PASS。必须断言 env 分支的**两个成功标记都出现**，
#   证明 env-binding 一致性检查 + deployment semantic-diff 都**真的执行且通过**：
#     line 189 "env-binding 一致性 OK（RUNNER_IMAGE_DIGEST env == verified digest）"
#     line 208 "deployment semantic-diff OK（仅 RUNNER_IMAGE_DIGEST env value 变更）"
#   同时确认无 env-binding 失败行（双向：既到达又通过）。
if ! grep -q "env-binding 一致性 OK" <<<"$out"; then
  fail "env 分支未到达/未通过——缺成功标记「env-binding 一致性 OK」（疑脚本提前退出，vacuous）；输出：$(echo "$out" | tail -3)"
elif ! grep -q "deployment semantic-diff OK" <<<"$out"; then
  fail "deployment semantic-diff 未执行/未通过——缺「deployment semantic-diff OK」；输出：$(echo "$out" | tail -3)"
elif grep -q "::error::.*RUNNER_IMAGE_DIGEST env value" <<<"$out" || grep -q "::error::.*deployment semantic-diff" <<<"$out"; then
  fail "env 一致却仍报 env-binding 错：$(grep '::error::.*\(RUNNER_IMAGE_DIGEST env value\|deployment semantic-diff\)' <<<"$out" | head -1)"
else
  pass "env 分支真到达且两标记通过（env-binding 一致性 OK + deployment semantic-diff OK）"
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

# ── Test 4：恶意攻击者把正确 digest 藏进**别的 env 名**，RUNNER_IMAGE_DIGEST 留错值 ──
# 证明 verifier 只用 base 侧硬编码 selector 读 RUNNER_IMAGE_DIGEST（不被 PR 内容误导去读别处）：
# head deployment 里加一条 name==DECOY_DIGEST value==正确 digest，但 RUNNER_IMAGE_DIGEST value==错值
# → 硬编码 selector 只取 RUNNER_IMAGE_DIGEST（错值）→ env value != image-lock digest → fail-closed。
echo "=== Test 4: 正确 digest 藏进别的 env 名 + RUNNER_IMAGE_DIGEST 留错值 → 硬编码 selector 只读 RUNNER_IMAGE_DIGEST → fail-closed ==="
make_deployment_decoy() {  # $1=RUNNER_IMAGE_DIGEST(错值)  $2=DECOY_DIGEST(正确值,藏别处)
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: runner-launcher
  namespace: aster-runner
spec:
  replicas: 0
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
            - name: DECOY_DIGEST
              value: $2
            - name: RUNNER_IMAGE_DIGEST
              value: $1
EOF
}
T="$(mktemp -d)"
make_allowed env             > "$T/allowed.yaml"
make_base_lock               > "$T/base-lock.yaml"
make_head_lock "$DIGEST" "$SHA40" > "$T/head-lock.yaml"
# RUNNER_IMAGE_DIGEST=错值（全零），正确 DIGEST 藏进 DECOY_DIGEST。
make_deployment_decoy "sha256:0000000000000000000000000000000000000000000000000000000000000000" "$DIGEST" > "$T/head-deploy.yaml"
make_deployment "sha256:0000000000000000000000000000000000000000000000000000000000000000" "" > "$T/base-deploy.yaml"
out="$(IMAGE_PIN_FRESHNESS=off bash "$VERIFY" \
  "$T/allowed.yaml" "$T/base-lock.yaml" "$T/head-lock.yaml" "" "" "$T/head-deploy.yaml" "$T/base-deploy.yaml" 2>&1)"
rc=$?
# 硬编码 selector 只读 RUNNER_IMAGE_DIGEST（错值全零 != image-lock 真 digest）→ 必 fail-closed；
# 绝不能因「正确 digest 藏在 DECOY_DIGEST」而放行（那才是 selector 被绕）。
if [[ "$rc" != "0" ]] && grep -q "::error::.*RUNNER_IMAGE_DIGEST env value" <<<"$out"; then
  pass "藏在别 env 的正确 digest 不被采信 → RUNNER_IMAGE_DIGEST 错值触发 fail-closed（selector 不可绕）"
else
  fail "★恶意绕过未拦：正确 digest 藏 DECOY_DIGEST 却放行（rc=$rc）——selector 可能被绕！输出：$(echo "$out" | tail -3)"
fi
rm -rf "$T"

echo "=== Test 5: env-bound entry 但完全未提供 HEAD_DEPLOYMENT（载体缺失）→ fail-closed（不得跳过）==="
T="$(mktemp -d)"
make_allowed env             > "$T/allowed.yaml"
make_base_lock               > "$T/base-lock.yaml"
make_head_lock "$DIGEST" "$SHA40" > "$T/head-lock.yaml"
# 第 6/7 参数（HEAD_DEPLOYMENT/BASE_DEPLOYMENT）全部留空——模拟 workflow 因 PR 未改
# runner/deployment.yaml 而没抓到部署真相文件的场景（Blocker 1 的 env-bound 对称面）。
out="$(IMAGE_PIN_FRESHNESS=off bash "$VERIFY" \
  "$T/allowed.yaml" "$T/base-lock.yaml" "$T/head-lock.yaml" "" "" "" "" 2>&1)"
rc=$?
if [[ "$rc" != "0" ]] && grep -q "::error::.*未提供 head-deployment" <<<"$out"; then
  pass "env-bound 载体缺失（未传 HEAD_DEPLOYMENT）→ 非零退出 + 报载体缺失错误（fail-closed，不跳过）"
else
  fail "env-bound 载体缺失未 fail-closed（rc=$rc）：$(echo "$out" | tail -3)"
fi
rm -rf "$T"

echo "=== Test 6（★核心反例，Codex Blocker 1）: kustomization-bound entry 但完全未提供 HEAD_KUSTOMIZATION（载体缺失）→ fail-closed ==="
# 这正是 Codex 本地复现的生产级绕过：runner launcher（kustomization-bound）lock-only PR，
# workflow 因未改 runner/kustomization.yaml 而不抓 head-kustomization → 旧版 verifier 在
# HEAD_KUSTOMIZATION 为空时静默跳过一致性检查、直接 exit 0（签名+fresh 的新 digest 放行，
# 而实际 kustomization 仍指向旧 digest）。本用例断言修复后必须非零退出并报确定性错误。
T="$(mktemp -d)"
make_allowed kustomization        > "$T/allowed.yaml"
make_base_lock                    > "$T/base-lock.yaml"
make_head_lock "$DIGEST" "$SHA40" > "$T/head-lock.yaml"
# 第 4/5 参数（HEAD_KUSTOMIZATION/BASE_KUSTOMIZATION）全部留空，第 6/7（deployment）也留空
# ——因为本 entry 是 kustomization-bound，不该被要求提供 deployment 参数。
out="$(IMAGE_PIN_FRESHNESS=off bash "$VERIFY" \
  "$T/allowed.yaml" "$T/base-lock.yaml" "$T/head-lock.yaml" "" "" "" "" 2>&1)"
rc=$?
if [[ "$rc" != "0" ]] && grep -q "::error::.*未提供 head-kustomization" <<<"$out"; then
  pass "kustomization-bound 载体缺失（未传 HEAD_KUSTOMIZATION）→ 非零退出 + 报载体缺失错误（Codex 反例已修复）"
else
  fail "★Blocker 1 未修复：kustomization-bound 载体缺失仍未 fail-closed（rc=$rc）：$(echo "$out" | tail -5)"
fi
rm -rf "$T"

echo ""
if [[ "$FAILED" == "0" ]]; then
  echo "全部通过（env 一致性 + semantic-diff allowlist + fail-closed + selector 不可绕 + 载体缺失 fail-closed）。"; exit 0
else
  echo "存在失败用例，见上方 ✗。"; exit 1
fi
