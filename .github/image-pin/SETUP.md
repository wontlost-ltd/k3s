# image-pin Phase 1 —— 人工配置步骤（org-admin 动作）

统一镜像 digest pin 设计 v2（A′）Phase 1。代码产物（workflow / 脚本 / 白名单 / image-lock /
ruleset JSON）已随本 PR 提交，但以下动作需 **GitHub org/repo 管理员**在 GitHub 侧执行，
无法由 CI 自动完成。**在全部完成前，请把两个 branch ruleset 的 `enforcement` 设为
`evaluate`（dry-run）**，避免用种子 image-lock fail-closed 卡死正常合并。

关联：wontlost-ltd/k3s#4、`aster-api/.claude/analysis/blocker2-automerge-gate-spike.md`。

---

## 1. 注册 image-pin GitHub App

创建一个 **GitHub App**（org 级），仅安装到需要的仓：
- **安装范围**：`wontlost-ltd/k3s`（开 PR / 发 check）+ 源仓 `aster-cloud/aster-api`、
  `aster-cloud/aster-cloud`（Phase 2 跨仓开 PR 时需要；Phase 1 仅 k3s 即可）。
- **Repository 权限（最小）**：
  - `Contents: Read and write`（开 image-pin/* 分支、commit image-lock）
  - `Pull requests: Read and write`（开 PR + enable auto-merge）
  - `Checks: Read and write`（发 verify-image-pin check run）
  - `Metadata: Read-only`
- **绝不授予**：`Administration`、`Repository rules`、任何 bypass。
- 生成 **private key**，记下 **App ID** 与安装后的 **Integration actor id**。

> Integration actor id 取法：`gh api repos/wontlost-ltd/k3s/installation --jq '.app_id'` 得 App ID；
> ruleset bypass 用的 actor_id 是该 App 的 **integration id**，可在 ruleset UI 加 bypass 时选中该 App 后
> `gh api repos/wontlost-ltd/k3s/rulesets/<id> --jq '.bypass_actors'` 回读确认。

## 2. 配置仓库 Variables / Secrets（`wontlost-ltd/k3s`）

| 类型 | 名称 | 值 |
|---|---|---|
| Variable | `IMAGE_PIN_APP_ID` | image-pin App 的 App ID |
| Variable | `IMAGE_PIN_BOT_LOGIN` | `aster-image-pin[bot]`（App 的 bot login，实际以安装后为准） |
| Variable | `IMAGE_PIN_BOT_ID` | 该 bot 的 numeric user id（`gh api users/aster-image-pin%5Bbot%5D --jq .id`） |
| Secret | `IMAGE_PIN_APP_PRIVATE_KEY` | App private key（PEM 全文） |

> 未配置 `IMAGE_PIN_APP_ID` 时，`verify-image-pin.yml` 的发 check 步骤会 skip
> （Phase 2 接通前的过渡态）。

## 3. 导入三个 ruleset

先把 JSON 里的**占位 `0`** 替换成真实 ID（文件本身已是合法 JSON，只需换值）：
- `main-branch.json`：`required_status_checks[0].integration_id: 0` → image-pin App 的 **App ID**。
- `reserved-branches.json`：`bypass_actors[0].actor_id: 0` → image-pin App 的 **integration id**。
- `protected-paths-push.json`：`bypass_actors[0].actor_id: 5` 是 **RepositoryRole=admin**（无需改；
  表示受保护路径的改动只有 admin 能走）。

导入（先 evaluate，验证无误再改 active）：
```bash
for f in main-branch protected-paths-push reserved-branches; do
  gh api -X POST repos/wontlost-ltd/k3s/rulesets \
    --input .github/image-pin/rulesets/$f.json
done
# 回读确认 bypass_actors / required check source 正确后：
#   在 UI 或 API 把 enforcement 从 evaluate 改 active。
```

## 4. 冒烟测试（Phase 1 验收）

1. **真实签名 smoke**：等 Phase 2 首个 CI PR（或手动构造）写入**真实** digest+sourceSha 的
   image-lock，确认 `verify-image-pin.sh` 的 cosign verify + freshness 全过、check run 由
   App 身份发出、required check source 显示为 image-pin App（非 GitHub Actions）。
2. **负路径**：
   - 改一个非 image-lock 文件的 image-pin/* PR → `check-pr-shape.sh` 拒 + push ruleset 拦。
   - 把 sourceSha 改成一个**旧的**（历史签过的）→ freshness 失败（防 signed-rollback）。
   - 非 Bot author 开的 PR → shape 检查拒。
3. 全绿后，把 `main-branch.json` / `reserved-branches.json` 的 enforcement 置 `active`。

## 4b. 人工 PR 的 review 规则（重要）

`verify-image-pin` 对**未改 image-lock** 的人工 PR 发 no-op success（Codex 审查 Critical 1
的修法，避免全局 required check 死锁）。这意味着 `verify-image-pin` **不**为人工 PR 提供
review 保障。`main-branch.json` 当前 `required_approving_review_count: 0`。

**决策点**：若 k3s 希望人工 PR 走人审，请把 `main-branch.json` 的
`required_approving_review_count` 提到 ≥1（image-pin bot PR 走 auto-merge 不受影响，因为
它满足 required check 且 review 数可由 App 满足或单独豁免——需评估）。若接受 0 review（当前
k3s 单人维护现状），保持 0 并在此记录接受。**不要**让 no-op success 成为"main 无任何门"的
默认松动。

## 5. 过渡态（Phase 2 接通前）

- image-lock 的 `sourceSha` 目前是 `UNVERIFIED-SEED`（种子）。verify 脚本对非 40-hex 的
  sourceSha **会 fail**——这是有意的（种子不得进生产验签）。故 **ruleset 保持 evaluate**，
  或在 Phase 2 CI 写入首个真实 pin 前不要求该 check。
- Phase 2（两源仓 CI 开 PR 到 k3s）落地后，image-lock 由 CI 覆盖为真实值，再切 active。
