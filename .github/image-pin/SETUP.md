# image-pin Phase 1 —— 人工配置步骤（org-admin 动作）

统一镜像 digest pin 设计 v2（A′）Phase 1。代码产物（workflow / 脚本 / 白名单 / image-lock /
ruleset JSON）已随本 PR 提交，但以下动作需 **GitHub org/repo 管理员**在 GitHub 侧执行，
无法由 CI 自动完成。**在全部完成前，请把两个 branch ruleset 的 `enforcement` 设为
`evaluate`（dry-run）**，避免用种子 image-lock fail-closed 卡死正常合并。

关联：wontlost-ltd/k3s#4、`aster-api/.claude/analysis/blocker2-automerge-gate-spike.md`。

---

## 1. 注册 image-pin GitHub App

> ★ 跨 org 事实（重要）：源仓在 org **`aster-cloud`**，k3s 在 org **`wontlost-ltd`**（两个不同
> org）。GitHub App 归属单一 org，默认只能**安装**到同 org 的仓。故：
> - **App 归属 `wontlost-ltd`**（与 k3s 同 org），**只安装到 `wontlost-ltd/k3s`**。
> - **不**安装到 `aster-cloud/*`。Phase 2 源仓 CI 是把本 App 的 **App ID + private key 存为
>   源仓自己的 secret**，用 `actions/create-github-app-token` 面向 **k3s 安装** 换取 token 再
>   开 PR —— 靠 **token 跨 org**，不是靠跨 org 安装。Phase 1 只碰 `wontlost-ltd`。

在 `https://github.com/organizations/wontlost-ltd/settings/apps` → **New GitHub App**
（需 `wontlost-ltd` **org owner** 权限）：
- **名称**：`aster-image-pin`（→ bot login `aster-image-pin[bot]`）；Homepage 填 k3s URL。
- **Webhook**：取消勾选 Active（不需要 webhook）。
- **Repository 权限（最小）**，其余全 No access：
  - `Contents: Read and write`（开 image-pin/* 分支、commit image-lock）
  - `Pull requests: Read and write`（开 PR + enable auto-merge）
  - `Checks: Read and write`（发 verify-image-pin check run，使 required-check source=App）
  - `Metadata: Read-only`（基线，自动选）
- **绝不授予**：`Administration`、`Repository rules`、`Workflows`、`Actions`、任何 Organization 权限、任何 bypass。
- **Where can this App be installed**：Only on this account。
- 创建后：记 **App ID**；Generate a private key（下载 .pem，仅此一次可见）。
- **Install App** → `wontlost-ltd` → Only select repositories → **k3s** → Install。
- 安装后取 IDs：`gh api repos/wontlost-ltd/k3s/installation --jq '{app_id,app_slug,id}'`；
  bot user id：`gh api 'users/aster-image-pin%5Bbot%5D' --jq '{login,id,type}'`。
  ruleset `Integration` bypass 的 actor_id = **App ID**（与 app_id 同）。
- 以上 IDs 交给 `setup.sh` 自动完成 Part D+E（见上）。

> Integration actor id 取法：`gh api repos/wontlost-ltd/k3s/installation --jq '.app_id'` 得 App ID；
> ruleset bypass 用的 actor_id 是该 App 的 **integration id**，可在 ruleset UI 加 bypass 时选中该 App 后
> `gh api repos/wontlost-ltd/k3s/rulesets/<id> --jq '.bypass_actors'` 回读确认。

## 半自动：Part D+E 用 setup.sh 一键做

Part A-C（UI 注册 App + 生成 pem + 装到 k3s）手动做完后，Part D（vars/secrets）+ Part E
（ruleset 填占位 + evaluate 导入）可用脚本：

```bash
# 先 dry-run 预览（默认不改任何东西）：
scripts/image-pin/setup.sh <APP_ID> /path/to/aster-image-pin.pem
# 确认无误后真正执行：
APPLY=1 scripts/image-pin/setup.sh <APP_ID> /path/to/aster-image-pin.pem
# 若要人工审 bot PR（默认 0=无人审 auto-merge，见 §4b）：
APPLY=1 IMAGE_PIN_REVIEW_COUNT=1 scripts/image-pin/setup.sh <APP_ID> /path/to/pem
```

脚本会：校验 App 确实装在 k3s（app_id 匹配）→ 自动取 bot login/id → 写 4 个 vars/secret →
填 ruleset 占位（integration_id/bypass actor_id=App ID）→ 以 **evaluate** 模式导入三 ruleset。
它 fail-closed：App 未装或 id 不符即中止，不改任何东西。

下面 §2-§3 是脚本背后的手动等价步骤（供理解/排障）。

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
