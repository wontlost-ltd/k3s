#!/usr/bin/env bash
# check-pr-shape —— image-pin PR 形状/来源门控（blocker2 纵深防御）
#
# 与 ruleset 的 push-path-restriction 冗余（纵深）：即便 ruleset 漏配，本检查也拦。
# ★ 但本检查**不是**主信任边界 —— 真正的强制在 GitHub ruleset（App 无 bypass）。
#   本 workflow 只提供那个被 pin 到 App 的 required check；ruleset 决定能否合并。
#
# 用法：check-pr-shape.sh <pr-event.json> <changed-files.txt>
#   pr-event.json    = GitHub pull_request 事件 payload（$GITHUB_EVENT_PATH）
#   changed-files.txt = 本 PR 改动文件列表（每行一个，相对 repo 根）
# 环境变量：
#   IMAGE_PIN_BOT_LOGIN   期望的 bot login（如 "aster-image-pin[bot]"）
#   IMAGE_PIN_BOT_ID      期望的 bot numeric user id（锚点，防 login 改名/伪造）
#   IMAGE_LOCK_PATH       允许改动的唯一路径（默认 apps/aster-lang/cloud/image-lock.yaml）
#
# 退出码：0 = 是合法 image-pin PR；非 0 = 不是（workflow 据此决定是否发 success check）。
set -euo pipefail

EVENT="${1:?usage: check-pr-shape.sh <pr-event.json> <changed-files.txt>}"
CHANGED="${2:?usage: check-pr-shape.sh <pr-event.json> <changed-files.txt>}"
LOCK_PATH="${IMAGE_LOCK_PATH:-apps/aster-lang/cloud/image-lock.yaml}"

die() { echo "::error::$*" >&2; exit 1; }
command -v jq >/dev/null || die "jq 未安装"
[[ -f "$EVENT" ]] || die "找不到事件 payload：$EVENT"
[[ -f "$CHANGED" ]] || die "找不到 changed-files：$CHANGED"

# ── 非 fork：head.repo 必须 == base.repo（fork PR 无 secrets，也不该验签）──
head_repo="$(jq -r '.pull_request.head.repo.full_name // ""' "$EVENT")"
base_repo="$(jq -r '.pull_request.base.repo.full_name // ""' "$EVENT")"
[[ -n "$head_repo" && "$head_repo" == "$base_repo" ]] \
  || die "拒绝 fork PR：head=$head_repo base=$base_repo"

# ── PR author = image-pin bot（锚定 user.id + type==Bot，login 仅辅助；label 非信任根）──
author_login="$(jq -r '.pull_request.user.login // ""' "$EVENT")"
author_id="$(jq -r '.pull_request.user.id // ""' "$EVENT")"
author_type="$(jq -r '.pull_request.user.type // ""' "$EVENT")"
[[ "$author_type" == "Bot" ]] || die "PR author 非 Bot (type=${author_type}), 非 image-pin PR"
if [[ -n "${IMAGE_PIN_BOT_ID:-}" ]]; then
  [[ "$author_id" == "$IMAGE_PIN_BOT_ID" ]] \
    || die "PR author id=$author_id != 期望 image-pin bot id=$IMAGE_PIN_BOT_ID"
fi
if [[ -n "${IMAGE_PIN_BOT_LOGIN:-}" ]]; then
  [[ "$author_login" == "$IMAGE_PIN_BOT_LOGIN" ]] \
    || die "PR author login=$author_login != 期望 $IMAGE_PIN_BOT_LOGIN"
fi

# ── head 分支模式 image-pin/* ──
head_ref="$(jq -r '.pull_request.head.ref // ""' "$EVENT")"
[[ "$head_ref" == image-pin/* ]] || die "head 分支非 image-pin/*：$head_ref"

# ── 改动文件必须**精确**只有 image-lock；触碰任何其它路径即拒 ──
mapfile -t files < <(grep -v '^[[:space:]]*$' "$CHANGED" || true)
[[ "${#files[@]}" -gt 0 ]] || die "PR 无改动文件"
for f in "${files[@]}"; do
  [[ "$f" == "$LOCK_PATH" ]] \
    || die "image-pin PR 只能改 ${LOCK_PATH}, 却改了 ${f} (触碰 .github/**, CODEOWNERS, allowed-images.yaml 等一律拒)"
done

echo ">> PR 形状/来源合法：author=$author_login(id=$author_id,Bot) head=$head_ref 仅改 $LOCK_PATH"
