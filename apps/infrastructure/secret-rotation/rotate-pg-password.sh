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
#   顺序：预检 Hyperdrive 可用 → 写 Vault → 等**数据库**改完 → 再同步 Hyperdrive。
#   ★最后两步的先后是硬约束：Cloudflare 在 PATCH 时会真的去连一次数据库验证凭据，
#     库还没改就 PATCH 必然 400/code 2013（实测踩过）。
set -eu

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ERROR: $*" >&2; exit 1; }

VAULT_ADDR="${VAULT_ADDR:?}"
PG_SECRET_PATH="secret/data/data-services/aster-api-db"
CF_SECRET_PATH="secret/data/infrastructure/cloudflare"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:?}"
HYPERDRIVE_ID="${HYPERDRIVE_ID:?}"
# 校验数据库是否已接受新密码用（见步骤 5）：借 CNPG 主实例 pod 里的 psql 执行。
PG_NAMESPACE="${PG_NAMESPACE:-data-services}"
PG_CLUSTER="${PG_CLUSTER:-shared-postgres}"
PG_USER="${PG_USER:-aster_api_user}"
PG_DB="${PG_DB:-aster_api}"

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

# 记录旧密码，供失败时回滚（Vault 虽有版本历史，但脚本内直接持有更可靠）
OLD_PW="$(vault_get "${PG_SECRET_PATH}" password)"
[ -n "$OLD_PW" ] && [ "$OLD_PW" != "null" ] || die "读取当前密码失败"

# 失败回滚：把 Vault 写回旧密码并催刷新，使三方重新一致。
# ★只在「已写 Vault 但数据库/Hyperdrive 尚未跟上」时调用。
rollback_vault() {
    log "回滚：将 Vault 写回旧密码"
    if curl -sS -k --fail-with-body --request POST \
        --header "X-Vault-Token: ${VAULT_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "$(jq -nc --arg pw "$OLD_PW" '{data:{password:$pw}}')" \
        "${VAULT_ADDR}/v1/${PG_SECRET_PATH}" > /dev/null; then
        kubectl annotate externalsecret -n data-services aster-api-postgres-credentials \
            "force-sync=$(date +%s)" --overwrite > /dev/null 2>&1 || true
        log "回滚成功：Vault 已恢复旧密码，线上保持一致"
    else
        log "★回滚失败！Vault 仍是新密码而数据库是旧密码，需立即人工介入"
    fi
}

# ── 3. 写 Vault（真相源）──
log "写入 Vault: ${PG_SECRET_PATH}"
curl -sS -k --fail-with-body --request POST \
    --header "X-Vault-Token: ${VAULT_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "$(jq -nc --arg pw "$NEW_PW" '{data:{password:$pw}}')" \
    "${VAULT_ADDR}/v1/${PG_SECRET_PATH}" > /dev/null \
    || die "写入 Vault 失败 —— 旧密码仍有效，线上未受影响"

# ── 4. 催 ExternalSecret 刷新，让 CNPG 去改库内密码 ──
# 链路：ESO → Secret aster-api-postgres-credentials → CNPG managed role → ALTER ROLE
log "触发 ExternalSecret 刷新（data-services）"
kubectl annotate externalsecret -n data-services aster-api-postgres-credentials \
    "force-sync=$(date +%s)" --overwrite > /dev/null \
    || { rollback_vault; die "触发 data-services ESO 刷新失败"; }

# ── 5. ★等数据库真正改完密码，再动 Hyperdrive ──
#
# 这是本脚本最关键的顺序约束。原实现「写 Vault → 立刻 PATCH Hyperdrive」是**错的**：
# 实测 Cloudflare 在 PATCH 时会**真的去连一次数据库**验证凭据，此刻 CNPG 还没
# ALTER ROLE，于是必然返回
#     400 / code 2013 "Invalid database credentials"
# 结果是 Vault 已改而 Hyperdrive 没改——正是我们最想避免的半途状态。
#
# 所以必须先确认库内密码已生效（新密码能连上），再同步 Hyperdrive。
PG_POD="$(kubectl get pods -n "$PG_NAMESPACE" \
    -l "cnpg.io/cluster=${PG_CLUSTER},role=primary" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[ -n "$PG_POD" ] || { rollback_vault; die "找不到 CNPG 主实例 pod —— 已回滚"; }

log "等待 CNPG 用新密码更新数据库角色…（校验借 ${PG_POD} 的 psql）"
#
# ★用 CNPG pod 里现成的 psql 校验，而不是在本容器连库：
#   运行镜像 alpine/k8s **没有 psql**（实测），而为一次探测换镜像会牺牲
#   kubectl/curl/jq。自研 SCRAM 握手同样不可取——我实现过一版，
#   对**已知正确**的密码也返回失败，纯属自找 bug。
#   借 CNPG pod 的 psql 是零新依赖且最可信的做法。
DB_OK=0
i=0
while [ "$i" -lt 60 ]; do          # 最多 ~5 分钟
    if kubectl exec -n "$PG_NAMESPACE" "$PG_POD" -c postgres -- \
        env PGPASSWORD="$NEW_PW" psql -h 127.0.0.1 -U "$PG_USER" -d "$PG_DB" \
        -tAc 'select 1' > /dev/null 2>&1; then
        DB_OK=1
        break
    fi
    i=$((i + 1))
    sleep 5
done

if [ "$DB_OK" -ne 1 ]; then
    rollback_vault
    die "等待数据库改密码超时（~5 分钟）—— 已回滚，线上未受影响"
fi
log "数据库已接受新密码（等待约 $((i * 5)) 秒）"

# ── 6. 同步 Hyperdrive ──
# ★只传 password：实测 Cloudflare 对 origin 是**合并更新**，
#   host/database/scheme/user/access_client_id 全部原样保留。
log "同步 Hyperdrive（仅更新 password）"
if ! RESP="$(curl -sS --fail-with-body --request PATCH \
    --header "Authorization: Bearer ${CF_TOKEN}" \
    --header "Content-Type: application/json" \
    --data "$(jq -nc --arg pw "$NEW_PW" '{origin:{password:$pw}}')" \
    "${CF_API}")"; then
    log "★Hyperdrive 同步失败。数据库已是新密码，回滚会造成库与 Vault 不一致，"
    log "  故**不自动回滚**——请立即人工修复（见 README「失败了怎么办」）。"
    die "Hyperdrive PATCH 失败"
fi

echo "$RESP" | jq -e '.success == true' > /dev/null \
    || die "★Hyperdrive 返回 success=false，数据库已是新密码，需立即人工修复"

# 校验 Access 凭据没被抹掉（合并语义的回归护栏）
POST_ACCESS="$(echo "$RESP" | jq -r '.result.origin.access_client_id // empty')"
if [ -n "$PRE_ACCESS" ] && [ "$PRE_ACCESS" != "$POST_ACCESS" ]; then
    die "★access_client_id 变化（${PRE_ACCESS} → ${POST_ACCESS}）—— Cloudflare 语义可能已变，需人工核查"
fi
log "Hyperdrive 已同步；access_client_id 保持不变"

# ── 7. 催应用侧 ExternalSecret 刷新，Reloader 随后滚动重启 ──
log "触发 ExternalSecret 刷新（aster-cloud）"
kubectl annotate externalsecret -n aster-cloud aster-api-db-credentials \
    "force-sync=$(date +%s)" --overwrite > /dev/null \
    || log "警告：aster-cloud ESO 刷新触发失败（将在 1h 内自动刷新）"

log "轮换完成。Reloader 将在 Secret 更新后自动滚动重启 aster-api。"
log "如需人工核验：kubectl -n aster-cloud rollout status deploy/aster-api"
