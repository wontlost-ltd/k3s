#!/usr/bin/env bash
# 断言 .github/image-pin/apps.yaml 注册表与磁盘现实**双向**一致（k3s#500）。
#
# ★为什么必须双向：
#   正向（注册表 → 磁盘）：登记了不存在的路径 → strict path 会 cp 失败或读空，
#     表现为难懂的中途报错，而非清晰的"登记错了"。
#   反向（磁盘 → 注册表）：★**这一向才是真正的安全洞** —— 某目录有了
#     image-lock.yaml 却没登记，意味着它的 pin 变更**不进任何 lane**、
#     不经 cosign 验签就能合入，而 CI 全绿。
#     aster-lsp 就是这样脱管七个月的（#519：手工 tag 缺 token 门 → 公网未授权访问）。
#
# ★这与 verify-no-floating-tags.sh 的分工：
#     本脚本            = 注册表 ↔ 磁盘 一致（**深度**门控的覆盖面没有缺口）
#     verify-no-floating-tags = 每个应用都 digest pin（**广度**兜底）
#   前者防"该进门控的没进"，后者防"压根没 pin"。
set -euo pipefail

REGISTRY="${APPS_REGISTRY:-.github/image-pin/apps.yaml}"
[[ -f "$REGISTRY" ]] || { echo "::error::找不到注册表：$REGISTRY"; exit 1; }

fail=0
checked=0

# ── 正向：注册表声明的每个路径都必须存在 ──
while IFS=$'\t' read -r name lock kust deploy policy; do
  [[ -z "$name" ]] && continue
  for f in "$lock" "$kust" "$deploy" "$policy"; do
    [[ -z "$f" || "$f" == "null" ]] && continue
    checked=$((checked + 1))
    if [[ ! -f "$f" ]]; then
      echo "::error::注册表登记了不存在的路径：[$name] $f"
      fail=1
    fi
  done
done < <(yq -r '.apps[] | [.name, .lock, .kust, (.deploy // ""), (.policy // "")] | @tsv' "$REGISTRY")

# ── 反向：磁盘上每个 image-lock.yaml 都必须已登记 ──
# ★这一向是安全关键：未登记 = 不进任何 lane = 不验签即可合入。
# ★先把已登记清单取出来，不要在循环体内跑 yq —— 循环体内的命令会消费
#   process substitution 的 stdin，导致 grep 读到空输入而误报"未登记"
#   （实测：cloud 明明已登记却被报出来）。同类坑见 verify-no-floating-tags.sh 的 fd 3。
registered="$(yq -r '.apps[].lock' "$REGISTRY")"
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  checked=$((checked + 1))
  if ! printf '%s\n' "$registered" | grep -qxF "$f"; then
    echo "::error::存在未登记的 image-lock：$f"
    echo "           未登记 = 其 pin 变更不进任何 lane、不经 cosign 验签即可合入。"
    echo "           修法：在 $REGISTRY 的 apps 列表里补一条（见该文件头部字段语义）。"
    fail=1
  fi
done < <(find apps -name image-lock.yaml 2>/dev/null)

# ── lane 名唯一性：重名会让 pin_flavor 查询取到多行、read 只吃第一行 ──
dupes="$(yq -r '.apps[].name' "$REGISTRY" | sort | uniq -d)"
if [[ -n "$dupes" ]]; then
  echo "::error::注册表存在重复的 lane 名：$dupes"
  fail=1
fi

if [[ "$checked" -eq 0 ]]; then
  # ★空集必须失败：注册表被清空或 find 失效时，本守卫会"零个检查全部通过"。
  echo "::error::未检查到任何路径 —— 注册表为空或发现逻辑失效，按 fail-closed 处理。"
  exit 1
fi

[[ "$fail" -ne 0 ]] && { echo "REGISTRY-SYNC 失败（共检查 $checked 项）"; exit 1; }
echo "REGISTRY-SYNC OK: 注册表与磁盘双向一致（共检查 $checked 项）"
