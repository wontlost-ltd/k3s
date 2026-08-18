# 审计表 owner 分离 —— 上线手册

**背景**：2026-08-17 安全审计。此前 aster-api 的 Flyway 与运行时共用同一个
`aster_api_user`（`migrate-at-start=true`），因此该角色是各表的 **owner**。

实测（PG 16，全程**非超级用户**）表 owner 只需两条 DDL 即可解除审计表的防篡改保护：

```sql
GRANT UPDATE ON audit_logs TO aster_api_user;              -- owner 可给自己重新授权
ALTER TABLE audit_logs DISABLE TRIGGER trg_audit_logs_append_only;
UPDATE audit_logs SET performed_by = 'MALLORY';            -- 成功
```

甚至可一步完成：`CREATE OR REPLACE FUNCTION reject_audit_log_mutation() ... RETURN NEW;`

**即：运行时凭据泄露 == 可静默改写审计记录。** 生产已核实命中该形态
（`SELECT tableowner FROM pg_tables WHERE tablename='audit_logs'` → `aster_api_user`）。

分离后实测三条攻击路径全部被拒：

| 攻击 | 分离前 | 分离后 |
|---|---|---|
| 自授 UPDATE 权限 | `GRANT`（成功） | `WARNING: no privileges were granted`（no-op） |
| `DISABLE TRIGGER` | `ALTER TABLE`（成功） | `ERROR: must be owner of table` |
| 替换守卫函数 | `CREATE FUNCTION`（成功） | `ERROR: permission denied for schema public` |
| **INSERT / SELECT** | 正常 | **正常**（审计写入不受影响） |

---

## 上线顺序（必须按序）

### 步骤 0：在 Vault 写入迁移角色密码 ⚠️ 人工

ExternalSecret 依赖该路径；不先写会导致 Secret 不存在 → CNPG 不创建角色 →
应用启动时 Flyway 连不上库。

**Vault KV-v2 是整体替换**：必须同时写 `username` 与 `password`，
只 POST 其一会抹掉另一个（见 `../secret-rotation/README.md` 的同类教训）。

请你自己在终端执行（凭据不要贴进任何 AI 会话）：

```sh
# 生成强密码并写入，两个字段一次写全
vault kv put secret/data-services/aster-migrator-db \
    username=aster_migrator \
    password="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"

# 核对两个字段都在
vault kv get -format=json secret/data-services/aster-migrator-db | jq '.data.data | keys'
# 期望：["password","username"]
```

### 步骤 1：合并本 PR，等 ArgoCD 同步

CNPG 会按 `managed.roles` 创建 `aster_migrator`。核对：

```sh
kubectl get cluster -n data-services shared-postgres \
  -o jsonpath='{.status.managedRolesStatus}' | jq
# 期望 byStatus.reconciled 包含 aster_migrator
```

> ★若 `managedRolesStatus` 为空：Secret 不满足 CNPG 的四项硬性要求
> （`type: kubernetes.io/basic-auth` / `cnpg.io/reload` label / `username` 与角色同名 /
> ESO `mergePolicy: Merge`）。这四条 **不满足时 operator 完全不 reconcile 且不报错**
> ——2026-07-31 已踩过一次，详见 `../secret-rotation/README.md`。

### 步骤 2：超级用户执行一次 owner 移交 ⚠️ 人工

`ALTER TABLE ... OWNER TO` 要求执行者是**当前 owner 或超级用户**。
新的 `aster_migrator` 首次部署时还不拥有旧表，故这一步必须由 `postgres` 做一次。
（之后新建的表由 Flyway 以 migrator 身份创建，自然归属正确，无需再人工介入。）

> ### ⚠️ 必须移交 **整个 schema**，不能只移交审计表
>
> 实操踩过一次（2026-08-18）：只 `ALTER TABLE audit_logs OWNER TO aster_migrator`
> 后，新 Pod 全部 **CrashLoopBackOff**：
>
> ```
> FlywaySqlException: Error while retrieving the list of applied migrations
> ERROR: permission denied for table flyway_schema_history
> ```
>
> 原因：Flyway 以 `aster_migrator` 连接后要读写 `flyway_schema_history`、
> 并对全部对象做 validate/apply —— 它必须拥有**所有** 34 张表，而不只是审计表。
> （当时旧 Pod 仍在服务，未造成对外中断，但新副本起不来。）

```sh
kubectl exec -n data-services shared-postgres-1 -i -- psql -U postgres -d aster_api -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
-- 1) 整个 schema 的对象移交给迁移角色（Flyway 需要全量 DDL 权限）
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO aster_migrator', r.tablename);
  END LOOP;
  FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname='public' LOOP
    EXECUTE format('ALTER SEQUENCE public.%I OWNER TO aster_migrator', r.sequencename);
  END LOOP;
  FOR r IN SELECT viewname FROM pg_views WHERE schemaname='public' LOOP
    EXECUTE format('ALTER VIEW public.%I OWNER TO aster_migrator', r.viewname);
  END LOOP;
END $$;
ALTER SCHEMA public OWNER TO aster_migrator;

-- 2) 重授运行时角色的 DML（owner 隐式全权会随 owner 一起带走）
GRANT USAGE ON SCHEMA public TO aster_api_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO aster_api_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO aster_api_user;

-- 3) ★审计表是唯一例外：只 append + read。这次 REVOKE 才真正生效
--   （V6.22.1 执行时 app_role 还是 owner，owner 隐式全权让当时的 REVOKE 没有约束力）
REVOKE UPDATE, DELETE, TRUNCATE ON audit_logs FROM aster_api_user;

-- 4) 未来由 aster_migrator 新建的表自动授予运行时 DML，避免每次加表都要人工补授权
ALTER DEFAULT PRIVILEGES FOR ROLE aster_migrator IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO aster_api_user;
ALTER DEFAULT PRIVILEGES FOR ROLE aster_migrator IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO aster_api_user;
COMMIT;
SQL
```

> 新增审计表（如 `audit_chain_anchors`）时，第 3 步要相应补一条 REVOKE——
> 默认权限会给它 `arwd`，而审计表应当只有 `ar`。

同时 Flyway 迁移 `V6.24.0` 会做同样的事作为幂等兜底——两者顺序无关，先跑哪个都行。

### 步骤 3：核对（务必实跑，不要只看 Synced/Healthy）

```sh
kubectl exec -n data-services shared-postgres-1 -- psql -U postgres -d aster_api -c "
SELECT tablename, tableowner FROM pg_tables
WHERE tablename IN ('audit_logs','audit_chain_anchors');"
# 期望 owner 全是 aster_migrator

kubectl exec -n data-services shared-postgres-1 -- psql -U postgres -d aster_api -c "
SELECT relacl FROM pg_class WHERE relname='audit_logs';"
# 期望能看到 aster_api_user=ar/...（a=INSERT r=SELECT），**没有** w(UPDATE)/d(DELETE)

# ★同时核对业务表**没有**被误收：应用要正常 UPDATE 策略/工作流
kubectl exec -n data-services shared-postgres-1 -- psql -U postgres -d aster_api -c "
SELECT relname, array_to_string(relacl,' | ') FROM pg_class
WHERE relname IN ('audit_logs','policy_versions');"
# 期望的**不对称**：
#   audit_logs      → aster_api_user=ar    （仅 append+read）
#   policy_versions → aster_api_user=arwd  （完整 DML）
```

> 实测参考（2026-08-18 生产）：
> ```
> audit_logs      | aster_migrator=arwdDxt/aster_migrator | aster_api_user=ar/aster_migrator
> policy_versions | aster_migrator=arwdDxt/aster_migrator | aster_api_user=arwd/aster_migrator
> ```

**行为探针**（这才是真验证——权限表看着对不代表运行时对）：

```sh
# 应用角色应当写得进、改不动
kubectl exec -n data-services shared-postgres-1 -- psql -U aster_api_user -d aster_api -c "
UPDATE audit_logs SET performed_by='probe' WHERE id=(SELECT MIN(id) FROM audit_logs);"
# 期望：ERROR: permission denied for table audit_logs

kubectl exec -n data-services shared-postgres-1 -- psql -U aster_api_user -d aster_api -c "
ALTER TABLE audit_logs DISABLE TRIGGER trg_audit_logs_append_only;"
# 期望：ERROR: must be owner of table audit_logs
```

### 步骤 4：确认应用正常

```sh
kubectl logs -n aster-cloud -l app=aster-api --tail=100 | grep -iE "flyway|migrat"
# 期望：迁移成功；无 permission denied
kubectl get pods -n aster-cloud -l app=aster-api
# 期望：Running 且 Ready（审计写入依赖 INSERT，若被误收会在这里暴露）
```

---

## 回滚

若应用因权限问题起不来，**先恢复可用性再排查**：

```sh
kubectl exec -n data-services shared-postgres-1 -- psql -U postgres -d aster_api <<'SQL'
ALTER TABLE audit_logs OWNER TO aster_api_user;
ALTER SEQUENCE audit_logs_id_seq OWNER TO aster_api_user;
ALTER TABLE IF EXISTS audit_chain_anchors OWNER TO aster_api_user;
SQL
```

并把 Deployment 里的 `QUARKUS_FLYWAY_USERNAME` / `QUARKUS_FLYWAY_PASSWORD` 两个 env 移除
（Flyway 会回落到数据源凭据）。回滚后审计表仍可写、仍有哈希链与触发器，
只是 owner 可自解那条路径重新打开——属于**回到分离前的状态**，不比现状更差。

---

## 边界（不要高估）

分离**只**解决「运行时凭据泄露 → 可改写审计」。仍然不防：

- **超级用户**（`postgres`）：绕过一切权限检查，可 DISABLE TRIGGER 后改写。
  层 3（链尾锚定）能事后检出，但阻止不了。
- **拿到 `aster_migrator` 凭据者**：它是 owner，等价于分离前的攻击面。
  故该凭据只应存在于 Vault + K8s Secret，不进任何人的本地环境。
- **删除尚未锚定的最新记录**：锚定每小时一次，最近一小时内的新增记录可被无声删除。
  这是周期性锚定的固有性质，缓解手段是提高频率或改为写入时同步锚定。
