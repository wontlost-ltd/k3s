# Phase 1 交叉审查记录 —— Claude 生成 → Codex 对抗式审查 → Claude 修复

统一镜像 digest pin 设计 v2（A′）Phase 1。wontlost-ltd/k3s#4。
Codex 首轮：**72/100 退回修正**（签名链路方向对，但有 2 死锁 + 1 注入风险）。
修复后 Claude 本地全量回归通过。

## Codex 抓出的问题与修复

### Critical 1 — 全局 required check + workflow `paths` 过滤 → 非 image PR 死锁
`verify-image-pin` 是 main 全局 required check，但 workflow 原来 `on.pull_request.paths:[image-lock]`
只在改 image-lock 时触发 → 人工 PR 永远产生不了该 check → 永久阻塞。
**修**：去掉 `paths`，workflow 对所有 PR 运行；`changed` 步骤判 `touches_lock`：未改 image-lock →
发 no-op success；改了 → 严格路径。始终发 App source check run（`always()`，成功/失败都发）。

### Critical 2 — 对所有 entry 做 freshness → 单镜像发布被其它 entry 卡死
原脚本遍历整个 lock 对**每个** entry 查 HEAD。CI 只更新 aster-api 时，migrate 仍是旧 SHA/种子 →
整个 PR fail。
**修**：脚本签名改为 `verify-image-pin.sh <allowed> <base-lock> <head-lock>`，只验证 head 相对
base **变化的** entry（同名 image 的 digest+sourceSha 一致则跳过）。未变更 entry 视为既有 bootstrap
状态。workflow 取 base(可信 checkout) + head(gh api contents 数据) 两份 lock 传入。
**验证**：单改 aster-api → 只 aster-api 验签(cosign=1)、migrate 跳过；base==head → changed=0 通过。

### Critical 3 — PR 的 image 字符串拼进 yq 表达式 → 表达式注入
原 `yq "... select(.image == \"$image\")"` 把 PR 值插进 yq 表达式。
**修**：全部转 JSON 一次后用 `jq --arg img "$image" 'select(.image==$img)'`（数据面，非表达式）。
另加 image 字符集 fail-closed 校验 + allowed-images 字段形状校验（sourceRepo/workflowFile/sourceRef）。
**验证**：`docker.io/...\" or true or \"x` 被字符集守卫在 cosign 前拒(cosign=0)。

### 额外 bug（修复后 Claude 回归测出，非 Codex）— 全数字 sourceSha 被 yq 数值化损坏
合法 git SHA 可全为十进制数字；`yq -o=json` 把它当 int/float 解析 → `1111…1 → 1.11e+39` 精度损坏。
**修**：yq 转 JSON 时 `(.. | select(tag=="!!int" or tag=="!!float")) |= tostring` 强制标量转字符串。
**验证**：全 1 的 40-hex sourceSha 原样传到 cosign。

## 次要修复
- push ruleset `bypass_mode:"always"` 与注释对齐（admin break-glass 维护 .github/**，仍受 main
  ruleset require_pull_request 约束）。
- SETUP.md §4b：记录人工 PR review 规则决策点（no-op success 不提供 review 保障，需显式设
  required_approving_review_count 或接受 0）。
- workflow：不 `cat` 未信任 image-lock 到日志（只打 sha256 摘要，防 log-injection）；check run
  失败也发 failure（可排障）。
- 建议未做（记入 backlog）：action pin 到 commit SHA + yq checksum 真值（SETUP.md 标注占位）。

## 本地回归证据（cosign 用 shim 隔离签名，逻辑全测）
- shellcheck 两脚本 clean；actionlint workflow exit 0；全 YAML/JSON 合法。
- check-pr-shape：正 + fork/非bot/多文件/id伪造 全按预期。
- verify：种子拒(cosign=0) / 未知镜像拒 / 注入拒(cosign=0) / 单镜像 diff 只验变更(cosign=1) /
  base==head 通过(changed=0) / 全数字 sha 不损坏。

## 仍属人工/运行时（无法本地证）
- 真实 cosign 签名验签（需真 CI digest + Fulcio/Rekor）→ Phase 2 首个真实 PR 冒烟。
- ruleset 导入 + App 注册 + required-check-source=App 生效 → SETUP.md，org-admin 执行。

Codex 会话 ID：019f436d-ee5f-71c1-a4e0-360ff8d42208
