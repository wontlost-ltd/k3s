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
unregistered=0
ALLOWED="$(dirname "$REGISTRY")/allowed-images.yaml"

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

# ── 反向：磁盘上每个「自己 pin 镜像」的应用都必须已登记 ──
# ★这一向是安全关键：未登记 = 不进任何 lane = 不验签即可合入。
#
# ★★发现信号必须是「kustomization 有非空 images 段」，**不能**是「有 image-lock」。
#   我第一版用 `find apps -name image-lock.yaml`，那**恰恰抓不到 lsp 当初脱管的形态** ——
#   lsp 脱管七个月期间根本没有 image-lock（该文件是本次才创建的），
#   它的形态是「kustomization 里有手工 digest、无 image-lock、未登记」。
#   变异实测：造一个这种形状的新应用，registry-sync 与 no-floating-tags **双双全绿**。
#   （no-floating-tags 只保证"是个 digest"，不保证"这个 digest 被签过名"。）
#
# ★先把已登记清单取出来，不要在循环体内跑 yq —— 循环体内的命令会消费
#   process substitution 的 stdin，导致 grep 读到空输入而误报"未登记"
#   （实测：cloud 明明已登记却被报出来）。同类坑见 verify-no-floating-tags.sh 的 fd 3。
registered_lock="$(yq -r '.apps[].lock' "$REGISTRY")"
registered_kust="$(yq -r '.apps[].kust' "$REGISTRY")"

# ★用 fd 3：循环体内要跑 yq，会消费 process substitution 的 stdin。
while IFS= read -r kust <&3; do
  [[ -z "$kust" ]] && continue
  # 只关心**自己 pin 镜像**的目录：images 段非空。
  n_imgs="$(yq -r '(.images // []) | length' "$kust" 2>/dev/null || echo 0)"
  [[ "$n_imgs" -eq 0 ]] && continue
  checked=$((checked + 1))
  if ! printf '%s\n' "$registered_kust" | grep -qxF "$kust"; then
    # ★分档：镜像是否已在信任根白名单里，决定「能不能登记」。
    #   在白名单 → 有签名基础设施，未登记就是**真缺口** → error。
    #   不在白名单 → 该镜像根本没接入 cosign 体系（无 CIP、无信任根），
    #     登记进来只会让 lane 跑一个必然失败的验签 → warning + 记账，
    #     不阻塞。★但绝不静默跳过：静默 = 又一个「无人知晓」的脱管。
    unregistered=$((unregistered + 1))
    imgs="$(yq -r '(.images // [])[] | (.name // .newName // "?")' "$kust" 2>/dev/null | tr '\n' ' ')"
    in_root=false
    for im in $imgs; do
      grep -q "image: .*${im}" "$ALLOWED" 2>/dev/null && in_root=true
    done
    if [[ "$in_root" == "true" ]]; then
      echo "::error::存在未登记的 pin 应用：${kust}（镜像 ${imgs}已在信任根白名单）"
      echo "           未登记 = 其镜像变更不进任何 lane、不经 cosign 验签即可合入，且 CI 全绿。"
      echo "           这正是 aster-lsp 脱管七个月的形态（#519）。"
      echo "           修法：在 $REGISTRY 的 apps 列表里补一条（见该文件头部字段语义）。"
      fail=1
    else
      echo "::warning::未登记且未接入签名体系：${kust}（镜像 ${imgs}不在信任根白名单）"
      echo "           其镜像变更不经 cosign 验签 —— 但该镜像尚无 CIP/信任根条目，"
      echo "           登记进来会跑一个必然失败的验签。需先在源仓接 cosign 签名。"
    fi
  fi
done 3< <(find apps -name kustomization.yaml 2>/dev/null)

# 磁盘上的 image-lock 也必须已登记（登记了 kust 却漏登 lock 的情形）
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  checked=$((checked + 1))
  if ! printf '%s\n' "$registered_lock" | grep -qxF "$f"; then
    echo "::error::存在未登记的 image-lock：$f"
    fail=1
  fi
done < <(find apps -name image-lock.yaml 2>/dev/null)

# ── lane 名唯一性：重名会让 pin_flavor 查询取到多行、read 只吃第一行 ──
dupes="$(yq -r '.apps[].name' "$REGISTRY" | sort | uniq -d)"
if [[ -n "$dupes" ]]; then
  echo "::error::注册表存在重复的 lane 名：$dupes"
  fail=1
fi

# ── ★lane 名字符集与保留字（洞 4：注释声称过但从未实现）──
#
# ★`name: none` 是**完整的 fail-open**：detection 会正确命中该应用的 image-lock
#   （hit=true、matched="none"、计数为 1），于是 pin_flavor="none" ——
#   **与「零命中」的哨兵值撞车** → lane=none → touches_lock=false →
#   整条 strict path（cosign/shape/render）被跳过，CI 全绿。
#   连第二道闸（`pin_flavor != none` 才检查脚本存在）也一并失效。
#
# ★`multi` 同理撞哨兵；`*-pin` 结尾会拼成 `xxx-pin-pin` 撞 lane 断言的 catch-all；
#   含空格会被 `wc -w` 数成多个而误判 multi；含 `;`/`$` 等则是注入面。
while IFS= read -r name <&4; do
  [[ -z "$name" ]] && continue
  checked=$((checked + 1))
  if [[ ! "$name" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "::error::非法 lane 名 '$name' —— 只允许小写字母、数字、连字符，且以字母开头。"
    fail=1
  fi
  case "$name" in
    none|multi|invalid)
      echo "::error::lane 名 '$name' 是**保留字**（与分派哨兵值撞车）。"
      echo "           用 none 会让该应用的 pin 变更整条跳过 strict path 且 CI 全绿（fail-open）。"
      fail=1 ;;
    *-pin)
      echo "::error::lane 名 '$name' 不得以 -pin 结尾（会拼成 ${name}-pin 撞 lane 断言的 catch-all）。"
      fail=1 ;;
  esac
done 4< <(yq -r '.apps[].name' "$REGISTRY")

if [[ "$checked" -eq 0 ]]; then
  # ★空集必须失败：注册表被清空或 find 失效时，本守卫会"零个检查全部通过"。
  echo "::error::未检查到任何路径 —— 注册表为空或发现逻辑失效，按 fail-closed 处理。"
  exit 1
fi

[[ "$fail" -ne 0 ]] && { echo "REGISTRY-SYNC 失败（共检查 $checked 项）"; exit 1; }
echo "REGISTRY-SYNC OK: 注册表与磁盘双向一致（共检查 ${checked} 项，${unregistered} 个未登记但未接签名体系）"
