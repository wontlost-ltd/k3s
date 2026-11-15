# 部署层绕过探针（guard-bypass-probe）运维手册

对应 aster-api ADR 0054 §12（R67）与计划 `docs/superpowers/plans/2026-11-15-guard-bypass-phase-c.md` Task 8 / §3 / §5。工作流：`.github/workflows/guard-bypass-probe.yml`。

## 1. 它证明什么

| 层 | 探针 | 通过条件 |
|---|---|---|
| 网络层 | `scripts/guard-bypass/direct-connect-probe.sh network`（GitHub 托管 runner 在 `aster-agents` 起一次性 Pod） | 同节点 / 跨节点 × Service / Pod IP 直连 `demo-tool` 全部被挡；正向对照（代理 `/healthz`）可达；金丝雀 `demo_echo` 经代理成功、`demo_delete` 被 DENY |
| 票据层 | CronJob `aster-guard/guard-auth-probe`（`apps/aster-lang/guard/probe/auth-probe.sh`），工作流以 `auth-status` 读取收敛后的结果 | 无票据 / 伪造 / 畸形票据 401、批量 400、无票据副作用为 0、`ticketCheck` 为 on |

退出码：`0` 通过，`1` 绕过，`3` 无法判定，后两者都判红。**不得用重跑代替排查**：先看摘要里的 `reasons`（正向对照 / 金丝雀 / DNS / 调度）。连续三次 inconclusive，就回到设计复盘。

## 2. Environment `guard-probe`（U-K5，一次性）

```bash
REPO=wontlost-ltd/k3s
# 部署分支只放行 main，不允许 tag；管理员不可绕过；不设必需审批人（否则 push / schedule 运行都会停在待审批）
gh api -X PUT "repos/$REPO/environments/guard-probe" --input - <<'JSON'
{"can_admins_bypass": false,
 "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
gh api -X POST "repos/$REPO/environments/guard-probe/deployment-branch-policies" -f name=main -f type=branch
gh api "repos/$REPO/environments/guard-probe/deployment-branch-policies"   # 核对：只有 main（type=branch）
```

托管 runner 方案的信任前提是 k3s `main` 只能经 `pull_request` ruleset 合入，且该 ruleset 没有 bypass。每次轮换凭证时都要核对一遍，并把输出贴到相关 PR：

```bash
gh api "repos/$REPO/rulesets" --jq '.[] | select(.name == "image-pin-main-branch") | .id' |
  xargs -I{} gh api "repos/$REPO/rulesets/{}" --jq '{enforcement, bypass_actors, rules: [.rules[].type]}'
# 期望：enforcement "active"、bypass_actors []、rules 含 "pull_request"
```

若选择设必需审批人，Task 9 的验收改为人工批准该次运行，watchdog 的阈值改为 7 天。

## 3. 签发 / 轮换凭证（U-K6）

前置条件，缺一不可：

1. Task 7c 已合并，且 `bash scripts/guard-bypass/vap-check.sh --kubeconfig ~/.kube/k3s-config` 的全部用例符合期望；
2. `kubectl get secrets -n aster-agents -o name` 的输出恰为 `secret/guard-demo-agent`。准入策略只拦新建的 Secret，不清理已存在的，多出的要先删除；
3. U-K8 已核实 apiserver 审计日志状态（见 §6）。

```bash
bash scripts/guard-bypass/kubeconfig-for-probe.sh --server https://158.179.18.241:6443 --kubeconfig ~/.kube/k3s-config |
  gh secret set GUARD_PROBE_KUBECONFIG --env guard-probe -R wontlost-ltd/k3s
```

- 缺省有效期 30 天（`--duration 720h`），硬上限 90 天。脚本会拒绝超过上限的请求，也会拒绝签发结果的 `exp - iat` 超过 90 天 + 1 小时的 token。
- 脚本用新 kubeconfig 自检 `auth whoami`，结果必须是 `system:serviceaccount:aster-guard:guard-bypass-probe`。
- 输出不落盘。在日历上设提醒，到期前轮换；工作流在剩余不足 14 天时打 `::warning::`。
- 轮换就是重跑上面的命令覆盖 secret，旧 token 到期后自然失效。

## 4. 吊销（凭证疑似泄露）

```bash
kubectl --kubeconfig ~/.kube/k3s-config delete sa guard-bypass-probe -n aster-guard
# Argo 会按 apps/aster-lang/guard/serviceaccount.yaml 重建同名 SA。绑定 token 校验 SA 的 UID，
# 旧 token 在 SA 进入删除后约 60 秒内全部认证失败；新 UID 不接受旧 token。确认已重建后再按 §3 签发新凭证。
gh secret delete GUARD_PROBE_KUBECONFIG --env guard-probe -R wontlost-ltd/k3s   # 签发新凭证之前先清掉旧值
```

处置影响面时，按计划 §3「能做到的最坏事」一栏评估。

## 5. 失败时怎么看

| 现象 | 先查 |
|---|---|
| `Assert probe identity` 失败 | secret 里放错了 kubeconfig（例如管理员凭证）：立即按 §4 吊销并重签 |
| `Token expiry` 退出 3 | 已过期，或有效期超过 90 天：按 §3 轮换 |
| `Wait for convergence` 超时 | Argo 未同步、pin PR 未合并、Deployment 未就绪、`demo-tool-ingress` 被手工改过 |
| network `inconclusive` | 摘要 `reasons`：正向对照失败（Pod 的 DNS / 出站）；金丝雀失败（代理、aster-api、演示租户策略）；Pod 未在 90 s 内结束（PSA / 准入 / 配额 / 调度）；cross Pod 落在工具节点（节点数不足） |
| network `bypass` | **事故**：某条直连路径可达，或静态形状违规（`static` 字段）。立即排查 `demo-tool-ingress` 与 kube-router |
| auth `bypass` | **事故**：工具执行了无票据调用或报告 `ticketCheck=off`。立即把 `demo-tool` 缩到 0 并排查 |
| watchdog 红 | 最近 36 h 内没有成功的 probe job：Environment 被误配、secret 被删、工作流被禁用 |

遗留的红队副本命名空间（带 `guard-bypass/redteam-expires` 标签且已过期）只告警。用管理员凭证执行 `kubectl delete ns <name>` 删除。

## 6. 审计（U-K8）

- **GitHub 侧**：Environment `guard-probe` 的部署记录（每次取用凭证的运行、提交与触发者）；org 审计日志（Environment / secret 的变更）。
- **集群侧**：探针 Pod 带 `guard-bypass/run-id=<run_id>-<attempt>` 标签，可以回溯到具体运行。API 请求级审计取决于 k3s 是否开启了 apiserver 审计日志。核实方法：查看三台 control-plane 的 `/etc/rancher/k3s/config.yaml`，看 `kube-apiserver-arg` 里有没有 `audit-log-path` / `audit-policy-file`。
- 如果没开审计日志，缺的证据是该 SA 何时、从哪个源 IP、发了哪些 API 请求（含失败的越权尝试）。可以补一份只记录 `system:serviceaccount:aster-guard:guard-bypass-probe` 的 Metadata 级审计策略，然后逐台重启三台 control-plane 上的 k3s。
