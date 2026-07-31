#!/usr/bin/env sh
#
# 季度自动轮换 aster_api_user 的 PG 密码。
#
# 为什么需要编排：轮换涉及三个**互不相通**的系统，漏掉任何一个都会断线上：
#   1) Vault      —— 真相源；ExternalSecret 从这里下发
#   2) CNPG       —— 读 K8s Secret 后自动 ALTER ROLE 改库内密码
#   3) Hyperdrive —— ★凭据存在 **Cloudflare 侧、不读 Vault**，只能主动 PATCH，
#                     且不更新时**没有任何"配置过期"告警**
#
# ★fail-fast：任一步失败立即退出，**不继续往下写**。
#   因为半途失败的代价不对称——只要还没写 Vault，旧密码就仍然有效、线上不受影响；
#   而写了 Vault 却没同步 Hyperdrive，就是一次静默的生产故障。
#   所以顺序是「先验证能力 → 再写 Vault → 立刻同步 Hyperdrive」。
set -eu

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2; exit 1; }

VAULT_ADDR="${VAULT_ADDR:?}"
PG_SECRET_PATH="secret/data/data-services/aster-api-db"
CF_SECRET_PATH="secret/data/infrastructure/cloudflare"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:?}"
HYPERDRIVE_ID="${HYPERDRIVE_ID:?}"

# ── 0. 用 Kubernetes ServiceAccount 换 Vault token（不落盘任何长期凭据）──
log "向 Vault 认证（kubernetes auth, role=secret-rotation）"
JWT="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
VAULT_TOKEN="$(curl -sS -k --fail-with-body \
    --request POST "${VAULT_ADDR}/v1/auth/kubernetes/login" \
    --data "{\"role\":\"secret-rotation\",\"jwt\":\"${JWT}\"}" \
    | jq -r '.auth.client_token')" \
    || die "Vault 认证失败"
[ -n "$VAULT_TOKEN" ] && [ "$VAULT_TOKEN" != "null" ] || die "Vault 未返回 token"

vault_get() {  # $1=path  $2=field
    curl -sS -k --fail-with-body --header "X-Vault-Token: ${VAULT_TOKEN}" \
        "${VAULT_ADDR}/v1/$1" | jq -r ".data.data.$2"
}

# ── 1. 先取 Cloudflare token 并**验证 Hyperdrive 可写**，再决定要不要动 Vault ──
# ★这一步是整个脚本的安全阀：若 CF 侧不可用而我们已经改了 Vault，
#   线上就会在下一次 ESO 刷新后断连。故先证明"能同步"，再改真相源。
log "读取 Cloudflare API token"
CF_TOKEN="$(vault_get "${CF_SECRET_PATH}" api_token)" || die "读取 CF token 失败"
[ -n "$CF_TOKEN" ] && [ "$CF_TOKEN" != "null" ] || die "CF token 为空"

CF_API="https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/hyperdrive/configs/${HYPERDRIVE_ID}"

log "预检：确认 Hyperdrive 配置可读且 token 有 Hyperdrive 权限"
PRE="$(curl -sS --fail-with-body --header "Authorization: Bearer ${CF_TOKEN}" "${CF_API}")" \
    || die "Hyperdrive 预检失败（token 缺 Hyperdrive:Edit 权限？）—— 未改动任何凭据"
PRE_ACCESS="$(echo "$PRE" | jq -r '.result.origin.access_client_id // empty')"
log "预检通过；origin.host=$(echo "$PRE" | jq -r '.result.origin.host')"

# ── 2. 生成新密码 ──
# 只用字母数字：避免连接串/JSON/shell 转义问题（曾因特殊字符踩过坑）。
# ★用 base64 而非 `tr -dc < /dev/urandom`：后者在非 C locale 下会因
#   "Illegal byte sequence" 提前中断，实测可产出**1 个字符**的密码。
#   base64 输出本身就是可打印 ASCII，再删掉 +/= 即得纯字母数字。
NEW_PW="$(head -c 48 /dev/urandom | base64 | tr -d '+/=' | head -c 32)"
[ "${#NEW_PW}" -eq 32 ] || die "密码生成异常（长度 ${#NEW_PW}，期望 32）"
echo "$NEW_PW" | grep -qE '^[A-Za-z0-9]{32}$' || die "密码含非预期字符"

# ── 3. 写 Vault（真相源）──
log "写入 Vault: ${PG_SECRET_PATH}"
curl -sS -k --fail-with-body --request POST \
    --header "X-Vault-Token: ${VAULT_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "$(jq -nc --arg pw "$NEW_PW" '{data:{password:$pw}}')" \
    "${VAULT_ADDR}/v1/${PG_SECRET_PATH}" > /dev/null \
    || die "写入 Vault 失败 —— 旧密码仍有效，线上未受影响"

# ── 4. 立刻同步 Hyperdrive（把不可避免的窗口压到几秒）──
# ★只传 password：实测 Cloudflare 对 origin 是**合并更新**，
#   host/database/scheme/user/access_client_id 全部原样保留。
log "同步 Hyperdrive（仅更新 password）"
RESP="$(curl -sS --fail-with-body --request PATCH \
    --header "Authorization: Bearer ${CF_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "$(jq -nc --arg pw "$NEW_PW" '{origin:{password:$pw}}')" \
    "${CF_API}")" || die "★Hyperdrive 同步失败，但 Vault 已更新！需立即人工修复：见 runbook"

echo "$RESP" | jq -e '.success == true' > /dev/null \
    || die "★Hyperdrive 返回 success=false，Vault 已更新！需立即人工修复"

# 校验 Access 凭据没被抹掉（合并语义的回归护栏）
POST_ACCESS="$(echo "$RESP" | jq -r '.result.origin.access_client_id // empty')"
if [ -n "$PRE_ACCESS" ] && [ "$PRE_ACCESS" != "$POST_ACCESS" ]; then
    die "★access_client_id 变化（${PRE_ACCESS} → ${POST_ACCESS}）—— Cloudflare 语义可能已变，需人工核查"
fi
log "Hyperdrive 已同步；access_client_id 保持不变"

# ── 5. 催 ExternalSecret 立即刷新（否则要等 refreshInterval 1h）──
# CNPG 拿到新 Secret 后会自动 ALTER ROLE；Reloader 会滚动重启 aster-api。
log "触发 ExternalSecret 刷新"
kubectl annotate externalsecret -n data-services aster-api-postgres-credentials \
    "force-sync=$(date +%s)" --overwrite > /dev/null || die "触发 data-services ESO 刷新失败"
kubectl annotate externalsecret -n aster-cloud aster-api-db-credentials \
    "force-sync=$(date +%s)" --overwrite > /dev/null || log "警告：aster-cloud ESO 刷新触发失败（将在 1h 内自动刷新）"

log "轮换完成。Reloader 将在 Secret 更新后自动滚动重启 aster-api。"
log "如需人工核验：kubectl -n aster-cloud rollout status deploy/aster-api"
