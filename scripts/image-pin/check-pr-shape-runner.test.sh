#!/usr/bin/env bash
# 验 check-pr-shape.sh 的 runner env-shape（DEPLOYMENT_PATH 设定时）：
#   (1) 改 runner/image-lock + runner/deployment → 放行。
#   (2) 改 runner/image-lock + runner/kustomization（runner 形状不含 kust）→ 拒。
#   (3) 改 runner/deployment 但不改 image-lock → 拒（image-lock 必被改）。
#   (4) 夹带 .github/** → 拒。
# ★cloud 形状（不设 DEPLOYMENT_PATH）不受影响——由 check-pr-shape.sh 既有测试守（本 harness 不重测）。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHAPE="${SCRIPT_DIR}/check-pr-shape.sh"
FAILED=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILED=1; }

# 合法 image-pin bot PR 事件 payload（非 fork、Bot author、head 分支 image-pin/*）。
EVENT="$(mktemp)"
cat > "$EVENT" <<'EOF'
{
  "pull_request": {
    "head": { "repo": { "full_name": "wontlost-ltd/k3s" }, "ref": "image-pin/aster-replay-runner" },
    "base": { "repo": { "full_name": "wontlost-ltd/k3s" } },
    "user": { "login": "aster-image-pin[bot]", "id": 301590099, "type": "Bot" }
  }
}
EOF

run_shape() {  # $1=changed-files 内容（多行）→ echo exit code
  local changed; changed="$(mktemp)"; printf '%s\n' "$1" > "$changed"
  IMAGE_LOCK_PATH=apps/aster-lang/runner/image-lock.yaml \
  DEPLOYMENT_PATH=apps/aster-lang/runner/deployment.yaml \
    bash "$SHAPE" "$EVENT" "$changed" >/dev/null 2>&1
  echo $?
  rm -f "$changed"
}

echo "=== Test 1: runner/image-lock + runner/deployment → 放行（exit 0）==="
rc="$(run_shape $'apps/aster-lang/runner/image-lock.yaml\napps/aster-lang/runner/deployment.yaml')"
[[ "$rc" == "0" ]] && pass "runner env-shape 放行" || fail "runner env-shape 未放行（rc=$rc）"

echo "=== Test 2: runner/image-lock + runner/kustomization → 拒（runner 形状不含 kust）==="
rc="$(run_shape $'apps/aster-lang/runner/image-lock.yaml\napps/aster-lang/runner/kustomization.yaml')"
[[ "$rc" != "0" ]] && pass "runner 形状拒 kustomization" || fail "runner 形状误放行 kustomization（rc=$rc）"

echo "=== Test 3: 只改 runner/deployment 不改 image-lock → 拒 ==="
rc="$(run_shape 'apps/aster-lang/runner/deployment.yaml')"
[[ "$rc" != "0" ]] && pass "缺 image-lock → 拒" || fail "缺 image-lock 误放行（rc=$rc）"

echo "=== Test 4: 夹带 .github/** → 拒 ==="
rc="$(run_shape $'apps/aster-lang/runner/image-lock.yaml\napps/aster-lang/runner/deployment.yaml\n.github/workflows/evil.yml')"
[[ "$rc" != "0" ]] && pass "夹带 .github/** → 拒" || fail "夹带 .github/** 误放行（rc=$rc）"

rm -f "$EVENT"
echo ""
if [[ "$FAILED" == "0" ]]; then echo "全部通过（runner env-shape whitelist）。"; exit 0
else echo "存在失败用例，见上方 ✗。"; exit 1; fi
