#!/usr/bin/env bash
# setup.sh —— image-pin Phase 1 半自动配置（Parts D+E）
#
# 你手动做 Part A-C（GitHub UI 注册 App + 生成 private key + 安装到 k3s），
# 然后本脚本做剩下的：写 k3s 的 vars/secrets + 填 ruleset 占位 + 以 evaluate 模式导入。
# 见 .github/image-pin/SETUP.md。wontlost-ltd/k3s#4。
#
# 用法：
#   scripts/image-pin/setup.sh <APP_ID> <PEM_PATH> [REPO]
#     APP_ID    = image-pin App 的 App ID（Part B）
#     PEM_PATH  = 下载的 .pem 私钥路径（Part B）
#     REPO      = 目标仓，默认 wontlost-ltd/k3s
# 环境变量：
#   IMAGE_PIN_REVIEW_COUNT   main ruleset 的 required_approving_review_count，默认 0
#                            （0=bot PR 无人审 auto-merge；1=每次部署需人审。见 SETUP.md §4b）
#   APPLY=1                  真正执行；默认 dry-run（只打印将做什么，不改任何东西）
#
# 依赖：gh（已登录且对 REPO 有 admin）、jq。
set -euo pipefail

APP_ID="${1:?usage: setup.sh <APP_ID> <PEM_PATH> [REPO]}"
PEM_PATH="${2:?usage: setup.sh <APP_ID> <PEM_PATH> [REPO]}"
REPO="${3:-wontlost-ltd/k3s}"
REVIEW_COUNT="${IMAGE_PIN_REVIEW_COUNT:-0}"
APPLY="${APPLY:-0}"

die() { echo "错误：$*" >&2; exit 1; }
run() {
  if [[ "$APPLY" == "1" ]]; then echo "+ $*"; "$@";
  else echo "[dry-run] $*"; fi
}

command -v gh >/dev/null || die "需要 gh"
command -v jq >/dev/null || die "需要 jq"
[[ "$APP_ID" =~ ^[0-9]+$ ]] || die "APP_ID 必须是数字，得到：$APP_ID"
[[ -f "$PEM_PATH" ]] || die "找不到私钥 pem：$PEM_PATH"
[[ "$REVIEW_COUNT" =~ ^[0-9]+$ ]] || die "IMAGE_PIN_REVIEW_COUNT 必须是数字"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULESET_DIR="$SCRIPT_DIR/../../.github/image-pin/rulesets"

# ── 校验 App 确实装在 REPO 上，且 slug 与我们假设一致 ──
echo "== 校验 App 安装 =="
inst="$(gh api "repos/${REPO}/installation" 2>/dev/null)" \
  || die "取 ${REPO} 的 App 安装失败：确认 App 已安装到该仓、且你的 gh 有 admin 权限"
inst_app_id="$(jq -r '.app_id' <<<"$inst")"
app_slug="$(jq -r '.app_slug' <<<"$inst")"
[[ "$inst_app_id" == "$APP_ID" ]] \
  || die "REPO 上安装的 App id=$inst_app_id 与传入 APP_ID=$APP_ID 不符（是否装了别的 App？）"
bot_login="${app_slug}[bot]"
echo "  App slug=$app_slug  →  bot login=$bot_login"

# ── 取 bot 的 numeric user id（IMAGE_PIN_BOT_ID）──
enc_login="${bot_login/\[/%5B}"; enc_login="${enc_login/\]/%5D}"
bot_id="$(gh api "users/${enc_login}" --jq '.id' 2>/dev/null)" \
  || die "取 bot user id 失败：$bot_login"
echo "  bot user id=$bot_id"

# ── Part D：vars + secret ──
echo ""
echo "== Part D：k3s vars/secret =="
run gh variable set IMAGE_PIN_APP_ID    --repo "$REPO" --body "$APP_ID"
run gh variable set IMAGE_PIN_BOT_LOGIN --repo "$REPO" --body "$bot_login"
run gh variable set IMAGE_PIN_BOT_ID    --repo "$REPO" --body "$bot_id"
if [[ "$APPLY" == "1" ]]; then
  echo "+ gh secret set IMAGE_PIN_APP_PRIVATE_KEY --repo $REPO < $PEM_PATH"
  gh secret set IMAGE_PIN_APP_PRIVATE_KEY --repo "$REPO" < "$PEM_PATH"
else
  echo "[dry-run] gh secret set IMAGE_PIN_APP_PRIVATE_KEY --repo $REPO < $PEM_PATH"
fi

# ── Part E：填 ruleset 占位 + evaluate 导入 ──
echo ""
echo "== Part E：ruleset（enforcement=evaluate，占位0→真实ID，review_count=$REVIEW_COUNT）=="
tmp="$(mktemp -d)"

jq --argjson id "$APP_ID" --argjson rc "$REVIEW_COUNT" '
  .enforcement = "evaluate"
  | (.rules[] | select(.type=="pull_request").parameters.required_approving_review_count) = $rc
  | (.rules[] | select(.type=="required_status_checks").parameters.required_status_checks[]
       | select(.context=="verify-image-pin")).integration_id = $id
' "$RULESET_DIR/main-branch.json" > "$tmp/main.json"

jq --argjson id "$APP_ID" '.enforcement="evaluate" | .bypass_actors[0].actor_id=$id' \
  "$RULESET_DIR/reserved-branches.json" > "$tmp/reserved.json"

jq '.enforcement="evaluate"' "$RULESET_DIR/protected-paths-push.json" > "$tmp/push.json"

for f in main push reserved; do
  echo "  -- ruleset: $f (evaluate) --"
  if [[ "$APPLY" == "1" ]]; then
    gh api -X POST "repos/${REPO}/rulesets" --input "$tmp/$f.json" \
      --jq '"  created ruleset id=\(.id) name=\(.name) enforcement=\(.enforcement)"'
  else
    echo "[dry-run] gh api -X POST repos/${REPO}/rulesets --input $f.json"
    jq -r '"  would create: name=\(.name) enforcement=\(.enforcement)"' "$tmp/$f.json"
  fi
done
rm -rf "$tmp"

echo ""
echo "完成（APPLY=$APPLY）。下一步："
echo "  1. 看 k3s Settings → Rules → Rule Insights，确认 evaluate 无误伤。"
echo "  2. 用真实签名 image-lock PR 冒烟（见 SETUP.md §4）。"
echo "  3. 全绿后把三 ruleset enforcement 从 evaluate 改 active。"
echo "  review_count=$REVIEW_COUNT（0=bot 无人审 auto-merge；改前见 SETUP.md §4b）。"
