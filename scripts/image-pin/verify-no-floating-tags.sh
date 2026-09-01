#!/usr/bin/env bash
# 断言：apps/ 下每个 kustomization 渲染出的镜像引用都带 @sha256 digest。
#
# ★为什么需要这条守卫（2026-09-02 的实际事故）：
#   apps/aster-lang/lsp 曾 pin 在 `newTag: "0.0.9"` —— 一个**手工推送的遗留 tag**，
#   构建于 2026-01-27。而 CI 只发布 `:${github.sha}` 不可变 tag，从不更新 0.0.9，
#   于是它冻结了七个月。期间 WS 网关的共享 token 门（2026-06-17 加入）从未上线，
#   线上二进制只有 Origin 一层检查 —— 结果是**公网未授权访问**。
#
# ★本脚本与 verify-image-pin.yml 的分工（不是替代）：
#     verify-image-pin  = 深度校验（cosign 验签 + freshness + PR 形状），逐应用**接线**
#     本脚本            = 广度守卫（每个应用都必须 digest pin），**自动发现，无需接线**
#   前者防「pin 了错的东西」，后者防「压根没 pin / 接线漏了」。
#   lsp 当初正是因为没接进 verify-image-pin 的逐个 env 路径而完全脱管。
#
# ── 三条判据上的坑（都是实测踩出来的，改动前请先读）─────────────────────
#
# ★坑一：判据必须取**渲染结果**而非源文件文本。
#   kustomize 的 images 段可以同时写 digest 与 newTag（apps/wontlost/ckeditor-builder
#   就是这样），渲染成 `repo:5.2@sha256:...` —— 此时 digest 生效、tag 只是可读标签，
#   是安全的。只 grep `newTag:` 会把它误报成缺陷。
#
# ★坑二：**不能用文本匹配提取 image**。第一版用
#     awk '/^[[:space:]]+image:[[:space:]]/'
#   看似合理，实则漏掉一半以上：kustomize 渲染时容器字段按字母序排，
#   若容器只有 image+name，image 会排在列表首项，渲染成 `- image: xxx`，
#   行首是 `-` 而非空白，该正则**不匹配**。
#   实测：awk 口径全仓只看到 8 个镜像，yq 口径看到 19 个。
#   当时之所以"测试通过"，纯粹因为受检容器碰巧都有 env/args 排在 image 前面 ——
#   **量具自身有缺陷，而它给出的绿是巧合**。
#
# ★坑三：yq 递归取 `.image` 会**过度捕获**。Helm values 里的
#     image:
#       registry: docker.io
#       repository: bitnami/redis
#       tag: latest
#   这里 `.image` 是 map 不是字符串，取出来会得到 `pullPolicy: IfNotPresent`
#   这类噪音。故必须限定 `select(tag=="!!str")` 只取标量。
#   （这类 Helm values 里的浮动 tag 是真问题，但属 chart 值而非 k8s 镜像字段，
#     需另行治理，不在本守卫射程内 —— 见下方 allowlist 说明。）
set -euo pipefail

ALLOWLIST="$(dirname "$0")/floating-tag-allowlist.txt"

fail=0
checked=0
skipped_allowed=0

is_allowed() {
  [[ -f "$ALLOWLIST" ]] || return 1
  grep -vE '^\s*(#|$)' "$ALLOWLIST" | grep -qxF "$1"
}

# ★自动发现：新增应用无需修改本文件即纳入守卫，不会重演 lsp 那种「没接线所以脱管」。
while IFS= read -r kust <&3; do
  dir="$(dirname "$kust")"

  if ! rendered="$(kubectl kustomize "$dir" 2>/dev/null)"; then
    echo "::error::渲染失败，无法校验镜像 pin：$dir"
    fail=1
    continue
  fi

  # 只取 `image:` 为**字符串标量**的字段（见坑三）。
  mapfile -t imgs < <(
    printf '%s' "$rendered" \
      | yq -r '[.. | select(tag=="!!map" and has("image")) | .image | select(tag=="!!str")] | .[]' 2>/dev/null \
      | sort -u
  )

  # ★per-directory 空渲染断言：本目录若声明了 images 段（说明确实要部署镜像），
  #   却渲染不出任何镜像，多半是 resources 写错/清单被移出（本仓的 render-guard
  #   曾专门防过「Deployment 意外移出 resources」）。全局 checked>0 掩盖不了单目录归零。
  if [[ ${#imgs[@]} -eq 0 ]] && grep -q '^images:' "$kust"; then
    echo "::error::$dir 声明了 images 段却渲染不出任何镜像 —— 疑似 resources 配置错误"
    fail=1
    continue
  fi

  for img in "${imgs[@]}"; do
    [[ -z "$img" ]] && continue
    if [[ "$img" == *"@sha256:"* ]]; then
      checked=$((checked + 1))
      continue
    fi
    if is_allowed "$img"; then
      skipped_allowed=$((skipped_allowed + 1))
      echo "::warning::$dir 使用浮动 tag（已在 allowlist 豁免）：$img"
      continue
    fi
    echo "::error::$dir 渲染出**非 digest** 镜像引用：$img"
    echo "           可变 tag 会让镜像静默停留在旧版本（安全修复不上线且无任何信号）。"
    echo "           修法：kustomization.yaml 的 images 段用 digest: sha256:... 而非 newTag；"
    echo "           确需豁免（第三方基础设施镜像）则在 $ALLOWLIST 登记并写明理由。"
    fail=1
  done
# ★用 fd 3 读目录列表：循环体内的 mapfile 会消费 stdin，
#   若目录列表也走 stdin，计数器会被截断/污染（实测报 unbound variable）。
done 3< <(find apps -name kustomization.yaml)

if [[ "$checked" -eq 0 ]]; then
  # ★空集必须失败：否则 find 一旦失效（改目录结构、脚本被挪走），
  #   本守卫会「零个镜像全部通过」——那是最典型的恒绿门禁。
  echo "::error::未检查到任何 digest 镜像 —— 发现逻辑失效，按 fail-closed 处理。"
  exit 1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "IMAGE-PIN 校验失败（digest=$checked 豁免=$skipped_allowed）"
  exit 1
fi

echo "IMAGE-PIN OK: $checked 个 digest pin，$skipped_allowed 个已登记豁免"
