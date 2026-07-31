# secret-rotation —— 季度自动轮换 PG 密码

每季度第一个周日 03:00 UTC 自动轮换 `aster_api_user` 的密码。

## 为什么需要编排

轮换涉及三个**互不相通**的系统，漏掉任何一个都会断线上：

```
Vault (真相源)
  ├─→ ExternalSecret(1h) ─→ data-services/aster-api-postgres-credentials
  │                            └─→ CNPG managed role（自动 ALTER ROLE 改库内密码）
  ├─→ ExternalSecret(1h) ─→ aster-cloud/aster-api-db-credentials
  │                            └─→ aster-api Pod（★env 注入，需 Reloader 重启才生效）
  └─✗  Cloudflare Hyperdrive —— 凭据存在 **Cloudflare 侧、不读 Vault**
                                 必须主动 PATCH，且不更新时**无任何告警**
```

★ 最危险的是 Hyperdrive：ExternalSecret 刷新对它无效，漏掉就是一次静默的生产故障
（aster-cloud 经 Hyperdrive 的请求开始认证失败，但没有任何一处报"配置过期"）。

## 执行顺序（硬约束）

```
1. 预检 Hyperdrive 可读 + token 权限   ← 失败则完全不动任何凭据
2. 写 Vault
3. 催 ExternalSecret → CNPG ALTER ROLE
4. ★轮询等待**数据库真的接受新密码**    ← 超时则回滚 Vault
5. 同步 Hyperdrive
6. 催应用侧 ESO → Reloader 滚动重启
```

★ **第 4 步不能省，第 5 步不能提前**：实测 Cloudflare 在 PATCH 时会**真的去连一次
数据库**验证凭据。库还没改就 PATCH，必然返回 `400 / code 2013
"Invalid database credentials"`，结果是 **Vault 已改而 Hyperdrive 没改**
——正是最该避免的半途状态（这个坑我们真踩过）。

## fail-fast 设计

`backoffLimit: 0`，任一步失败立即停、**不重试**。

| 失败时机 | 处置 | 后果 |
|---|---|---|
| 写 Vault **之前** | 直接退出 | 旧密码仍有效，线上无影响 ✅ |
| 写了 Vault，数据库未跟上 | **自动回滚 Vault** | 恢复一致 ✅ |
| 数据库已改，Hyperdrive 失败 | **不回滚**，报警等人工 | 回滚反而会让库与 Vault 不一致 ⚠️ |

## ⚠️ 前置：Vault 侧需手工配置（无法从 GitOps 完成）

CronJob 用 Kubernetes auth 认证 Vault，需要先建策略与 role。
**配好之前脚本会 fail-fast**（这是预期行为，不是故障）。

用 OIDC admin 身份执行：

```bash
export VAULT_ADDR=https://vault.aster-lang.cloud
vault login -method=oidc -path=Authentik role=admin

# 1) 策略：只允许读 CF token、读写 PG 密码
vault policy write secret-rotation - <<'EOF'
path "secret/data/data-services/aster-api-db" {
  capabilities = ["read", "create", "update"]
}
path "secret/data/infrastructure/cloudflare" {
  capabilities = ["read"]
}
EOF

# 2) 绑定到 CronJob 的 ServiceAccount
vault write auth/kubernetes/role/secret-rotation \
    bound_service_account_names=secret-rotation \
    bound_service_account_namespaces=secret-rotation \
    policies=secret-rotation \
    ttl=10m
```

另需确认 `secret/infrastructure/cloudflare` 的 `api_token` 具备
**Account → Hyperdrive → Edit** 权限（它同时被 cert-manager 用于 DNS-01，
所以还需保留 Zone → DNS → Edit）。

## 手工触发（验证用）

```bash
kubectl create job -n secret-rotation --from=cronjob/rotate-pg-password rotate-manual-$(date +%s)
kubectl logs -n secret-rotation -l app=rotate-pg-password --tail=50 -f
```

## 验证轮换是否真的成功

★ 空日志**不等于**成功。四层实证（2026-07-31 手工轮换时用的就是这套）：

```bash
# 1. Pod 起来了
kubectl get pods -n aster-cloud -l app=aster-api

# 2. Pod env 与 K8s Secret 一致（指纹比对，不打印明文）
POD=$(kubectl get pods -n aster-cloud -l app=aster-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n aster-cloud "$POD" -- printenv | grep -i password | cut -d= -f2- | shasum -a 256
kubectl get secret -n aster-cloud aster-api-db-credentials -o jsonpath='{.data.password}' | base64 -d | shasum -a 256

# 3. ★实连数据库 —— 证明 CNPG 真的 ALTER ROLE 了
PW=$(kubectl get secret -n aster-cloud aster-api-db-credentials -o jsonpath='{.data.password}' | base64 -d)
kubectl run pgcheck-$$ -n data-services --rm -i --restart=Never --quiet \
  --image=postgres:16-alpine --env="PGPASSWORD=$PW" -- \
  psql -h shared-postgres-rw -U aster_api_user -d aster_api -tAc "select current_user"

# 4. 端到端（穿 Hyperdrive → Tunnel → Access → PG）
curl -s -o /dev/null -w '%{http_code}\n' https://aster-lang.cloud
```

## 失败了怎么办

看日志定位失败在哪一步：

- **"未改动任何凭据"** → 安全，修复后重跑即可（多为 CF token 缺 Hyperdrive 权限）
- **"★Hyperdrive 同步失败，但 Vault 已更新"** → **需立即人工介入**。
  Vault 里已是新密码而 Hyperdrive 仍是旧的。修复：

  ```bash
  NEW_PW=$(vault kv get -field=password secret/data-services/aster-api-db)
  CF=$(vault kv get -field=api_token secret/infrastructure/cloudflare)
  curl -s -X PATCH "https://api.cloudflare.com/client/v4/accounts/61ecb24622cdc5ba2552851054bba5ce/hyperdrive/configs/b712d2c83ffe41f0b4d0ec615314a935" \
    -H "Authorization: Bearer $CF" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg pw "$NEW_PW" '{origin:{password:$pw}}')" | jq '{success,errors}'
  ```

- **"★access_client_id 变化"** → Cloudflare 可能改了 PATCH 语义（原为**合并**更新）。
  停止自动轮换并人工核查 Access 配置。
