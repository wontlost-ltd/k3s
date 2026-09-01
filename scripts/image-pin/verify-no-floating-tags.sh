#!/usr/bin/env bash
# 断言：受控命名空间下的每一个应用，渲染出的镜像引用都带 @sha256 digest。
#
# ★为什么需要这条守卫（2026-09-02 的实际事故）：
#   apps/aster-lang/lsp 曾 pin 在 `newTag: "0.0.9"` —— 一个**手工推送的遗留 tag**，
#   构建于 2026-01-27。而 CI 只发布 `:${github.sha}` 不可变 tag，从不更新 0.0.9，
#   于是它冻结了七个月。期间 WS 网关的共享 token 门（2026-06-17 加入）从未上线，
#   线上二进制只有 Origin 一层检查 —— 结果是**公网未授权访问**。
#
#   现有的 verify-image-pin.yml 管不到它：那个 workflow 的路径是**逐个硬编码的
#   env 变量**（CLOUD_LOCK_PATH / RUNNER_LOCK_PATH），不是 glob。
#   新应用不接线就完全不在门控内，而「没接线」这件事本身无人报警。
#
# ★本脚本与 verify-image-pin.yml 的分工（不是替代）：
#     verify-image-pin  = 深度校验（cosign 验签 + freshness + PR 形状），逐应用接线
#     本脚本            = 广度守卫（每个应用都必须 digest pin），**自动发现，无需接线**
#   前者防「pin 了错的东西」，后者防「压根没 pin / 接线漏了」。
#
# ★判据取**渲染结果**而非源文件文本：
#   kustomize 的 images 段可以同时写 digest 与 newTag（apps/wontlost/ckeditor-builder
#   就是这样），渲染成 `repo:5.2@sha256:...` —— 此时 digest 生效、tag 只是可读标签，
#   是安全的。只 grep `newTag:` 会把它误报成缺陷（我第一次就报错了）。
#   唯一可靠的判据是最终 image 字段里有没有 `@sha256:`。
set -euo pipefail

fail=0
checked=0

# 自动发现所有 kustomization 目录 —— ★这是本脚本的关键性质：
#   新增应用无需修改本文件即自动纳入守卫，不会重演「lsp 因未接线而脱管」。
while IFS= read -r kust; do
  dir="$(dirname "$kust")"
  # 只检查自身声明了 images 段的目录（base/overlay 中不含镜像的跳过）
  grep -q '^images:' "$kust" || continue

  if ! rendered="$(kubectl kustomize "$dir" 2>/dev/null)"; then
    echo "::error::渲染失败，无法校验镜像 pin：$dir"
    fail=1
    continue
  fi

  while IFS= read -r img; do
    checked=$((checked + 1))
    if [[ "$img" != *"@sha256:"* ]]; then
      echo "::error::$dir 渲染出**非 digest** 镜像引用：$img"
      echo "           可变 tag 会让镜像静默停留在旧版本（安全修复不上线且无任何信号）。"
      echo "           修法：kustomization.yaml 的 images 段用 digest: sha256:... 而非 newTag。"
      fail=1
    fi
  done < <(echo "$rendered" | awk '/^[[:space:]]+image:[[:space:]]/ {print $2}' | sort -u)
done < <(find apps -name kustomization.yaml)

if [[ "$checked" -eq 0 ]]; then
  # ★空集必须失败：否则 find 一旦失效（改目录结构、脚本被挪走），
  #   本守卫会「零个镜像全部通过」——那是最典型的恒绿门禁。
  echo "::error::未检查到任何镜像 —— 发现逻辑失效，按 fail-closed 处理。"
  exit 1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "IMAGE-PIN 校验失败（共检查 $checked 个镜像引用）"
  exit 1
fi

echo "IMAGE-PIN OK: $checked 个镜像引用均为 digest pin"
