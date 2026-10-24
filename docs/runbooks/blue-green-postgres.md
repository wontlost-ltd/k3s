# 蓝绿数据库切换（结构性重造专用，ADR 0050 §2.4）

**何时使用**：只在确需重造数据库时——PostgreSQL 大版本升级、编码/排序规则变更、无法用 expand/contract 表达的结构变更。
日常清数据、加列、权限修复一律走迁移（ADR 0050 §2.1），**不要**用本手册。

**目标**：对外不可用窗口只剩"写入冻结 + 连接重置"的几分钟；任何时刻都有可回退的一侧。

## 0. 前置

- 最近一次 CNPG 备份 `completed`，`firstRecoverabilityPoint` 覆盖到今天（`kubectl -n data-services get cluster shared-postgres -o jsonpath='{.status.lastSuccessfulBackup}'`）。
- `docs/runbooks/pg-restore-drill.md` 的三个坑已知：`externalClusters[].barmanObjectStore.serverName` 必须是生产集群名 `shared-postgres`；字段放在 `barmanObjectStore` 层；CRD 结构以 `kubectl get crd clusters.postgresql.cnpg.io -o json` 为准。
- 在 `release-evidence.md` 第 4 节开一行，填日期与集群名。

## 1. 起第二个集群（绿）

以 `docs/runbooks/pg-restore-drill.yaml` 为模板复制为 `shared-postgres-green`：从对象存储恢复到最新可恢复点；资源与存储类与生产一致；**不要**接入现有 Service。
恢复完成后核对：三个库存在、行数抽样与蓝侧一致、`aster_api` 的 owner 自检查询通过（OWNER-SEPARATION.md 步骤 3）。

## 2. 在绿侧执行重造与迁移

- 在绿侧完成结构性重造（如版本升级）与 ADR 0050 §2.1 的迁移/回填。
- 跑 aster-api 的 Flyway（指向绿侧的临时 Job 或本地 `migrate`），确认 `afterMigrate` 自检 ok。
- 跑 aster-cloud drizzle migrate（临时 Job，`DATABASE_URL` 指向绿侧）。

## 3. 逻辑复制追平增量

蓝侧 `CREATE PUBLICATION` 覆盖三个库各自的所有表，绿侧 `CREATE SUBSCRIPTION`（每库一条）。等待 `pg_stat_subscription` 的 `received_lsn` 追近蓝侧 `pg_current_wal_lsn()`。

**逻辑复制不覆盖的项，切流前必须手工处理**：
- DDL：绿侧结构已在第 2 步定稿，冻结后不得再在蓝侧做 DDL。
- 序列当前值：冻结后对每个序列 `SELECT setval('<seq>', (SELECT last_value FROM <seq>))` 从蓝侧抄到绿侧（脚本遍历 `pg_sequences`）。
- large objects、`TRUNCATE`（不复制）；若蓝侧在复制期间有 TRUNCATE，需重做该表的初始同步。
- `drizzle.__drizzle_migrations` 与 `flyway_schema_history`：以绿侧为准，不从蓝侧复制。

## 4. 写入冻结与一致性校验

- 冻结：aster-api 置维护模式（扩容为 0 或开只读开关，以当时实现为准，在登记表写明方式）；aster-cloud 置只读（PlatformSetting 只读开关或维护页）；ai-workspace 缩容为 0。
- 等 `received_lsn == pg_current_wal_lsn()`，再执行序列对齐。
- 校验脚本：每库每表 `count(*)` 与 `max(主键/updated_at)` 蓝绿一致；`aster_api.audit_chain_anchors` 最新锚点一致。

## 5. 切流（两个独立动作，分别记录生效时间）

1. k3s：把 `shared-postgres-rw`/`-ro` 的 Service 指向绿集群（或改各 Deployment 的 host 环境变量，视现状），随后 `rollout restart` aster-api 与 aster-ai-workspace 以淘汰旧连接池。
2. Cloudflare：更新 Hyperdrive 配置指向绿侧（新建配置 id 更稳妥），改 `wrangler.toml` binding 后经 `deploy-worker` 发布；观察 Worker 健康。
3. 解除冻结前做一次写入探针（创建并删除一条测试策略版本）。

## 6. 回切条件与窗口

- **冻结未解除**：切流后任一数据面报错 → 反向切回蓝侧（Service / Hyperdrive 各自回改），无数据丢失。
- **冻结已解除**：绿侧已产生新写入，不可回切；只能前向修复。登记表写明"回切窗口关闭时间"。
- 蓝集群保留 7 天后删除；期间保持备份调度指向绿集群（更新 `ScheduledBackup` 的 cluster 名）。

## 7. 事后

- 更新 `apps/infrastructure/postgres-cluster/manifests/cluster.yaml` 为绿侧定义（名称可在下次重造时再对调回来）。
- 在 `release-evidence.md` 第 4 节补齐全部列；若切换总时长超过 15 分钟，记录原因。
