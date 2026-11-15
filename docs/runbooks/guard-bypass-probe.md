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

## 3. 签发 / 轮换静态凭证（U-K6；OIDC 迁移 M4 之前）

凭证模式由 Environment 变量 `GUARD_PROBE_AUTH` 决定，见 §3a。本节只适用于 `static` 与 `dual`。

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

## 3a. 迁移到 GitHub OIDC（aster-api ADR 0057 §4 / §7）

工作流的 `probe` job 有 `id-token: write`，`Select credential mode` 读取 `vars.GUARD_PROBE_AUTH`：

| 值 | 行为 |
|---|---|
| 未设置 / `static` | 与引入开关前完全相同：Environment secret `GUARD_PROBE_KUBECONFIG` + 有效期检查 |
| `dual` | 探针仍用静态凭证；另取 OIDC token（audience `k3s-guard-probe`），断言 OIDC 身份为 `github-actions:wontlost-ltd/k3s:guard-probe`，且它能在 `aster-agents` 建 Pod、不能读 Secret |
| `oidc` | 只用 OIDC：kubeconfig 不含 exec 插件，由 `K3S_SERVER`、`scripts/guard-bypass/k3s-server-ca.crt` 与 `tokenFile` 组成；包装脚本在每次调用 kubectl 前按需刷新 token |
| 其它 | 判 3 |

迁移步骤（只在 M1 之后做：三台 master 已按 `docs/runbooks/k3s-server-host-config.md` 安装 `oidc` 组件）：

```bash
REPO=wontlost-ltd/k3s
# M0（k3s PR 合并、Argo 同步后）：准入策略对两个身份都符合期望
bash scripts/guard-bypass/vap-check.sh --kubeconfig ~/.kube/k3s-config     # 用例编号带 @sa / @oidc，全部 ✓
# M2：并行运行两种凭证
gh variable set GUARD_PROBE_AUTH --env guard-probe --body dual -R "$REPO"
gh workflow run guard-bypass-probe.yml -R "$REPO" --ref main
#     退出条件：这次 workflow_dispatch 运行与下一次 schedule 运行都绿；在任一台 master 上按
#     k3s-server-host-config.md §4 能查到 OIDC 用户与这两次运行的 run_id
# M3：只用 OIDC
gh variable set GUARD_PROBE_AUTH --env guard-probe --body oidc -R "$REPO"
gh workflow run guard-bypass-probe.yml -R "$REPO" --ref main               # 绿
# M4：删除静态凭证，并让已签发的 SA token 失效（SA 本身保留，Argo 会重建同名 SA，新 UID 不接受旧 token）
gh secret delete GUARD_PROBE_KUBECONFIG --env guard-probe -R "$REPO"
kubectl --kubeconfig ~/.kube/k3s-config delete sa guard-bypass-probe -n aster-guard
gh workflow run guard-bypass-probe.yml -R "$REPO" --ref main               # 绿
```

回滚：M2 / M3 删除变量，或改回 `dual`；M4 之后要回到静态凭证，按 §3 重新签发 secret 并设为 `dual`。M5（另起 PR）删除静态路径与 SA 身份。

## 4. 吊销（凭证疑似泄露）

```bash
kubectl --kubeconfig ~/.kube/k3s-config delete sa guard-bypass-probe -n aster-guard
# Argo 会按 apps/aster-lang/guard/serviceaccount.yaml 重建同名 SA。绑定 token 校验 SA 的 UID，
# 旧 token 在 SA 进入删除后约 60 秒内全部认证失败；新 UID 不接受旧 token。确认已重建后再按 §3 签发新凭证。
gh secret delete GUARD_PROBE_KUBECONFIG --env guard-probe -R wontlost-ltd/k3s   # 签发新凭证之前先清掉旧值
```

处置影响面时，按计划 §3「能做到的最坏事」一栏评估。审计日志开启后（`docs/runbooks/k3s-server-host-config.md` §4），可以按身份还原该凭证在三台 apiserver 上的全部调用。

**OIDC 模式下**没有可吊销的长期凭证：ID token 只在单次运行内有效。怀疑工作流被滥用时，先删除变量 `GUARD_PROBE_AUTH`，再在三台 master 上 `rollback oidc`，或从认证配置里删掉该 JWT 发行方（apiserver 每分钟自动重读，不需要重启）；然后用审计日志里的 `aster-lang.dev/gha-run-id` 定位到具体运行。

## 5. 失败时怎么看

| 现象 | 先查 |
|---|---|
| `Assert probe identity` 失败（静态身份） | secret 里放错了 kubeconfig（例如管理员凭证）：立即按 §4 吊销并重签 |
| `Select credential mode` 退出 3 | `GUARD_PROBE_AUTH` 不是 `static`、`dual`、`oidc` 之一 |
| `Configure OIDC credential` 退出 3 | 「没有 ACTIONS_ID_TOKEN_REQUEST_*」：job 缺 `id-token: write`。「claim 不符」：不是 main 上的本工作流 / Environment，或 GitHub 改了 claim |
| OIDC 身份不符（whoami 不是 `github-actions:…`） | apiserver 没有加 `--authentication-config`（`node.sh check` 应显示 `installed  组件 oidc`），或 claim 规则不通过（节点上 `journalctl -u k3s` 查 `oidc`）；也可能是 apiserver 访问不到 GitHub 的 JWKS |
| OIDC 身份能认证但不能建 Pod | RBAC 未同步（Argo `aster-lang-agents`） |
| `Token expiry` 退出 3 | 已过期，或有效期超过 90 天：按 §3 轮换 |
| `Wait for convergence` 超时 | Argo 未同步、pin PR 未合并、Deployment 未就绪、`demo-tool-ingress` 被手工改过 |
| network `inconclusive` | 摘要 `reasons`：正向对照失败（Pod 的 DNS / 出站）；金丝雀失败（代理、aster-api、演示租户策略）；Pod 未在 90 s 内结束（PSA / 准入 / 配额 / 调度）；cross Pod 落在工具节点（节点数不足） |
| network `bypass` | **事故**：某条直连路径可达，或静态形状违规（`static` 字段）。立即排查 `demo-tool-ingress` 与 kube-router |
| auth `bypass` | **事故**：工具执行了无票据调用或报告 `ticketCheck=off`。立即把 `demo-tool` 缩到 0 并排查 |
| watchdog 红 | 最近 36 h 内没有成功的 probe job：Environment 被误配、secret 被删、工作流被禁用 |

遗留的红队副本命名空间（带 `guard-bypass/redteam-expires` 标签且已过期）只告警。用管理员凭证执行 `kubectl delete ns <name>` 删除。

## 6. 审计（U-K8）

- **GitHub 侧**：Environment `guard-probe` 的部署记录（每次取用凭证的运行、提交与触发者）；org 审计日志（Environment / secret / variable 的变更）。
- **集群侧**：探针 Pod 带 `guard-bypass/run-id=<run_id>-<attempt>` 标签，可以回溯到具体运行。apiserver 审计日志由 aster-api ADR 0057 开启，安装与查询见 `docs/runbooks/k3s-server-host-config.md`。探针两个身份的所有请求都会记录，包括 watch 与被拒的越权尝试；写入记 RequestResponse，其余记 Metadata。OIDC 身份的每条记录带 `user.extra["aster-lang.dev/gha-run-id"]`。开启状态在节点上用 `node.sh check` 查看（`installed  组件 audit`），不要 grep `config.yaml`。

## 7. 已知问题：被放行的跨节点路径（#466 生产发现，2026-11-15）

**现象**：`aster-guard` 里的 Pod 落在**另一个节点**时连不上 `demo-tool`。代理启动时 `fetch failed` 后崩溃重启；票据探针 30 s 预热后判 3。落在**工具所在节点**时一切正常。

**只读证据（kubectl）**：
- 7 个落在 master-1 的代理 Pod（RS `59899555c8` / `7c9fb94ff7` / `b5b5bcc8c`）全部 CrashLoop，唯一落在 master-3 的 `5ff9978cb8-9mrmn` 就绪。
- 票据探针 `29912420`（master-1）BackoffLimitExceeded；`29912390/400/410/430`（master-3）全部 Complete。
- 网络探针运行 43713055499 中，master-1 上的 `aster-agents` Pod 能经 VXLAN 访问 master-3 上的代理 `/healthz`（不受策略保护的跨节点路径通），对工具的直连为 curl 7。
- 节点上 flannel 为 vxlan（VNI 1），`public-ip` 是各节点 192.168.0.x / 192.168.1.2，k3s 参数中没有 flannel / kube-router 的自定义项。

**结论**：数据面的跨节点转发正常，问题只出在**受策略保护的目标 + 被放行的跨节点来源**。工具所在节点上的 kube-router 没有按「来源命名空间 = aster-guard」放行这份流量。可能原因有二：
- **H1**：工具节点上该策略的来源 ipset 不含远端 Pod IP；
- **H2**：来源 IP 在跨节点途中被改写（SNAT / 伪装成节点或 flannel 地址），不再是 Pod IP，自然不在 ipset 里。

### 在节点上区分 H1 / H2（只读，用户执行；贴输出前确认不含 token / 凭证）

H1 与 H2 不互斥，两组观测可能同时成立。tcpdump 看到的源地址是决定性证据：源地址不是 Pod IP，即为 H2；源地址是 Pod IP 但不在 ipset 里，即为 H1。

工具节点（`kubectl get pod -n aster-tools -l app=demo-tool -o wide` 的 NODE，今天是 master-3），`ssh root@master-3`：

```bash
# 1) 找到 demo-tool-ingress 对应的链与来源 ipset
iptables-save | grep -E 'demo-tool-ingress' | head
#    记下规则里的 `--match-set KUBE-SRC-xxxx src`（与 KUBE-DST-yyyy）
ipset list KUBE-SRC-xxxx
#    H1 成立：Members 里只有本节点（10.42.2.x）的 aster-guard Pod，没有 master-1 上代理的 IP（例如 10.42.0.248）
#    H1 不成立：远端代理 IP 在里面
# 2) 看被拒流量的真实来源（等代理下一次重启，或在票据探针落在别的节点时）
timeout 300 tcpdump -ni any 'tcp dst port 8080 and dst host <demo-tool Pod IP> and tcp[tcpflags] & tcp-syn != 0' -c 10
#    H2 成立：源地址是 10.42.0.0（master-1 的 flannel.1 地址）或 192.168.0.2（节点 IP），而不是代理 Pod IP
#    H2 不成立：源地址就是代理 Pod IP（此时结合 1)，若 IP 不在 ipset 即 H1）
# 3) 策略拒绝计数是否随之增长
iptables-save -c | grep -E 'KUBE-NWPLCY|KUBE-POD-FW' | grep -E 'REJECT|DROP'
# 4) kube-router 同步错误
journalctl -u k3s --since '3 hours ago' | grep -iE 'netpol|network.?polic|ipset|iptables-restore' | tail -50
```

来源节点（代理所在节点，今天是 master-1），`ssh root@master-1`：

```bash
iptables --version            # nf_tables 还是 legacy；与 k3s 自带的 iptables 是否一致
ls -l /var/lib/rancher/k3s/data/current/bin/aux/ 2>/dev/null | grep -i iptables
iptables -t nat -S POSTROUTING; iptables -t nat -S FLANNEL-POSTRTG; iptables -t nat -S KUBE-POSTROUTING
nft list ruleset 2>/dev/null | grep -nE 'masquerade|snat' | head -40
#    H2 的成因：存在命中「-s 10.42.0.0/16 -d 10.42.0.0/16」的 MASQUERADE（FLANNEL-POSTRTG 的 RETURN 没有先命中），
#    或 legacy 与 nft 两套规则并存（RHEL / Oracle Linux 9 上常见），导致 Pod 到 Pod 的跨节点流量被伪装
ip route get <demo-tool Pod IP> from <代理 Pod IP> iif cni0   # 应经 flannel.1
# 只看网络相关键：config.yaml 含 server token 等凭证，不要整份贴出
grep -E '^(flannel|cluster-cidr|service-cidr|kube-proxy-arg|kube-router|disable-network-policy|egress-selector|node-ip|node-external-ip)' /etc/rancher/k3s/config.yaml
cat /var/lib/rancher/k3s/agent/etc/flannel/net-conf.json   # 只含网段与后端类型
```

### 修复方向与取舍（安全目标：只有 aster-guard 命名空间能到达工具）

| 方案 | 结论 |
|---|---|
| 给策略加 `ipBlock`（节点 IP / flannel 地址） | **不可接受**。被伪装后，同一来源节点上的**所有** Pod（含 aster-agents 的模型 Pod）都表现为该地址，放行它就等于放行整个节点，网络层隔离失效。而且 `ipBlock` peer 正是本集群 kube-router 出过事故的形态（R31） |
| 修 k3s / flannel / iptables 配置 | **正解**。H2：消除跨节点 Pod 流量的伪装（统一 iptables 后端；flannel 伪装规则按 k3s 默认只对出集群流量生效）。H1：把 k3s 升级到修复 kube-router 跨节点 ipset 的版本，或换 Calico。修好后由下述回归检查证明 |
| 代理与工具同节点（required podAffinity） | **只能作临时止血**：策略不变，隔离目标不变，但掩盖了缺陷，也让回归检查无法覆盖。止血期间须把工作流的 `--require-admitted-cross-node` 一并去掉，并在 #466 记录 |
| peer 改为 `namespaceSelector + podSelector` | **不可行**。组合 peer 正是本集群 kube-router 已知会退化为 deny-all 的形态（apps/aster-lang/cloud、lsp 注释）；而且 H1 / H2 下来源同样不在 ipset 里，改 peer 无济于事 |

### 回归检查

- 代理 Deployment 与票据探针 CronJob 对 `aster-tools/demo-tool` 设 **preferred 反亲和**（`manifests.test.sh` 断言）。这样金丝雀（模型 → 代理 → 工具）与票据探针走的都是被放行的跨节点路径。
- 工作流的网络探针带 `--proxy-ns aster-guard --proxy-selector app=aster-guard-mcp --require-admitted-cross-node`：
  - 摘要多出 `admitted: {proxyNode, proxyReady, crossNode}`；
  - 代理未就绪、金丝雀失败或代理与工具同节点，都判 3；
  - 跨节点时原因文本直接指向本节。
- `auth-status` 带 `--tool-ns/--tool-selector`：票据探针在放行位置连不上工具，且与工具跨节点时，原因文本也指向本节。
