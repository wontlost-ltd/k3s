#!/usr/bin/env bash
# gitleaks 自定义规则的双向自测（issue #486）。
#
# ★为什么需要：规则本身也会坏，而坏掉的表现是**静默放行**——
#   与「没装扫描器」不可区分。故必须有一个会失败的夹具钉住它。
#
# 用法：bash scripts/secret-scan/rules.test.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
IMG=zricethezav/gitleaks:v8.30.1
TD=scripts/secret-scan/testdata

# ★前置：docker 必须真的可用，且必须**先于**任何断言检查。
#
#   实测踩过：非交互式 bash 的 PATH 里没有 docker，`docker run` 直接 127。
#   而 127 ≠ 0，于是「正向：抓到了吗」这条按 exit 非 0 判定为**通过**——
#   一个因为工具缺失而"通过"的测试，比没有测试更危险：它会让人以为门禁在守着。
#   反向那条则被误判为失败，把人引去改规则（规则本来是对的）。
#   本机还有一个坑：`docker` 可能只是 shell **alias**（本仓开发机上
#   `docker` aliased to podman），交互式可用、脚本里 command not found。
#   故按顺序找**真实可执行文件**：docker → podman。
RUNTIME=""
for c in docker podman; do
  if command -v "$c" >/dev/null 2>&1; then RUNTIME="$c"; break; fi
done
if [ -z "$RUNTIME" ]; then
  echo "✗ 前置失败：找不到 docker 或 podman，无法执行本测试。"
  echo "  （不要把它当成'跳过'——静默跳过会让门禁形同虚设。）"
  exit 2
fi
echo "  使用容器运行时：$RUNTIME"

fail=0

# ① 正向：含明文凭据的夹具必须被抓到
#    注意 testdata 在全局 allowlist 里，故这里**临时复制到仓外**再扫，
#    否则测的是豁免规则而不是检测规则。
TMP=$(mktemp -d)
cp "$TD/should-be-caught.sh" "$TMP/"
cp .gitleaks.toml "$TMP/"
set +e
out=$("$RUNTIME" run --rm -v "$TMP":/repo:ro -w /repo "$IMG" \
       detect --source=/repo --config=/repo/.gitleaks.toml --no-git --no-banner --redact 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "✗ 正向失败：含明文凭据的夹具**未被抓到**，规则已失效"
  echo "$out" | tail -3
  fail=1
else
  echo "✓ 正向：明文凭据被抓到"
fi

# ①b 正向（规则 2 独立）：连接串内联凭据
#     ★与 ①a 分开成两个夹具：混在一个文件里时，废掉规则 1 仍会被规则 2 抓到，
#       于是"正向通过"变成一条恒真断言（实测踩过）。
rm -f "$TMP/should-be-caught.sh"
cp "$TD/should-be-caught-dsn.sh" "$TMP/"
set +e
out=$("$RUNTIME" run --rm -v "$TMP":/repo:ro -w /repo "$IMG" \
       detect --source=/repo --config=/repo/.gitleaks.toml --no-git --no-banner --redact 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "✗ 正向(DSN)失败：连接串内联凭据未被抓到"
  fail=1
else
  echo "✓ 正向(DSN)：连接串内联凭据被抓到"
fi
rm -f "$TMP/should-be-caught-dsn.sh"

# ② 反向：合法写法不得误报
rm -f "$TMP/should-be-caught.sh"
cp "$TD/should-not-fire.sh" "$TMP/"
# gitleaks 约定：**无泄露 → exit 0**，有泄露 → exit 非 0。
# （上面正向用例正是靠这条：抓到了才 exit 非 0，所以走 else 分支。）
set +e
out=$("$RUNTIME" run --rm -v "$TMP":/repo:ro -w /repo "$IMG" \
       detect --source=/repo --config=/repo/.gitleaks.toml --no-git --no-banner --redact 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "✓ 反向：合法写法未误报"
else
  echo "✗ 反向失败：合法写法被误报，规则过宽会逼人关掉门禁"
  echo "$out" | grep -E "Finding|File|Line" | head -6
  fail=1
fi

rm -rf "$TMP"
exit $fail
