# 发布证据登记（ADR 0050）

本文件登记那些**只能由人工在控制台或生产库执行**、却是 ADR 0050 发布契约前置条件的动作。每条都要有日期、执行者与可复核的输出；
没有登记的前置条件视为未完成，依赖它的 PR 不得合入。

## 1. Cloudflare Workers Builds 自动部署关闭（aster-cloud，Task 1 前置）

| 日期 | 执行者 | 项目 | 证据 |
|---|---|---|---|
| （待填） | （待填） | aster-cloud → Settings → Builds：main 自动构建/部署 = 关闭 | 控制台截图路径：`docs/runbooks/evidence/<日期>-workers-builds-off.png` |

核对命令（切换后的每次生产部署都应来自 GitHub Actions，message 含 `deploy-worker` 的 run id）：

```sh
npx wrangler deployments list --name aster-cloud | head -20
```

仓库变量：`gh variable set ENABLE_CI_WORKER_DEPLOY --body true -R wontlost-ltd/aster-cloud`（日期：待填）。

## 2. aster_api 首轮 owner 移交（Task 3 前置，OWNER-SEPARATION.md 步骤 2）

| 日期 | 执行者 | 库 | 核对输出 |
|---|---|---|---|
| 2026-10-24 | 运维（清库重建时） | aster_api | `pg_tables` owner 37/37 = aster_migrator；`audit_logs` → `aster_api_user=ar`；`policy_versions` → `aster_api_user=arwd`；schema public owner = aster_migrator |

> 新环境或再次重建后在此追加一行，并粘贴 OWNER-SEPARATION.md 步骤 3 三条查询的原始输出。

## 3. break-glass 手动 Worker 发布登记

仅在 `deploy-worker` 连续失败且迁移 Job 已成功时，由 admin 执行本地 `pnpm deploy`。执行前后各登记一行。

| 时间（UTC） | 执行者 | main SHA | 迁移 Job 状态（ArgoCD phase / revision） | 原因 | 事后 `wrangler deployments list` 首行 |
|---|---|---|---|---|---|
| | | | | | |

## 4. 蓝绿数据库切换登记

按 `docs/runbooks/blue-green-postgres.md` 执行时登记：冻结开始/结束时间、新旧集群名、追平的 LSN、切流动作（Service / Hyperdrive）与各自生效时间、回切窗口关闭时间。

| 日期 | 旧集群 | 新集群 | 冻结窗口 | 切流完成 | 回切窗口关闭 | 备注 |
|---|---|---|---|---|---|---|
| | | | | | | |
