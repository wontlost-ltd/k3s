# S2-0 设计：运行时 admission 强制只跑 cosign-verified digest

**状态**: 设计定案。验证分三层：
- **设计已定事实（源码/渲染实证）**：chart 0.10.6 自带 2 CRD、2 Validating+2 Mutating webhook 拓扑、failurePolicy(value line 44)/no-match(configData line 17)、arm64 镜像 manifest（`helm template --include-crds`/`docker manifest inspect`）；**glob=`@sha256:**`**（v0.13.1 `glob.Compile` 源码复算 + 可复现 Go test，§6）；**ephemeral/init 被覆盖**（`cmd/webhook/main.go:184` 源码，§7）；**tag→digest 无逃逸**（Mutating 先于 Validating，`validator.go:1074`，§6）。
- **实现 PR 静态门**：multi-source 最终渲染资源集合（防递归）、leases-cleanup digest pin、CIP/ConfigMap kustomize 校验（`kustomize build`+`kubeconform`）。
- **staging 动态门**：真 Fulcio OIDC 跨身份 fixture 负测、webhook 端到端 admission smoke-test（apiserver→webhook TLS/endpoint/网络）、tag/init/ephemeral 真 admission 正反测、wave 0→2 真 ArgoCD sync、回滚演练。

待用户复核 → 落实现。
**日期**: 2026-07-19
**关联**: aster-cloud `docs/p0a-s2-runtime-provenance-verifier-spike.md`（S2 层3 spike，S2-0 是其地基）、digest-pin epic（wontlost-ltd/k3s#4，CI/PR 时验签）
**信任根（单源，不复制）**: `.github/image-pin/allowed-images.yaml`

---

## 0. 目标与非目标（先划清边界）

**目标**：在**运行时 pod admission** 阶段，对 opt-in 的 `aster-cloud` namespace 内**信任根列出的两个 repository（`docker.io/wontlost/aster-api`、`docker.io/wontlost/aster-cloud-migrate`）**强制「只有 cosign 可验签的 digest 才能被调度运行」；namespace 内其它镜像暂放行（灰度）。补上 digest-pin epic 明确留下的运行时缺口——现有验签只发生在 **PR 合并时的 GitHub Action**，集群运行时**零重验签**（ArgoCD selfHeal 直接 apply digest-pinned 清单，admission 不再检查签名）。★**不是**全集群、全镜像、全 `wontlost/*` 保证（`no-match-policy: allow` 下未匹配镜像放行）。

**★非目标（诚实边界，承 S2 spike）**：
- S2-0 **不解锁签字**（`isSignablePass` 仍恒 false）。它是 **artifact-deployment policy**，**不是 runtime binding 证明**——它保证「opt-in namespace 内受控两仓的 pod，**webhook 健康时**只跑受信来源构建的镜像」（**非**全集群全镜像；首版 `failurePolicy: Ignore` 故障态 fail-open，见 §4），**不**证明「某次 evaluate 响应确实由该镜像执行且内容诚实」（那是层3 = S2-1 β 的事）。
- 不改 digest-pin epic 的 CI/PR 机制（S2-0 是它的运行时补充，非替代）。
- 不做第三方 infra 镜像（traefik/vault/prometheus/cnpg）的签名强制（它们不在信任根，见 §4 灰度）。

**为什么仍要做**：任何层3 都要绑「实际跑的 image」；若运营方/漂移能让集群跑任意未签 digest，层3 的 image binding 前提不成立。★**准确定位（Codex P1）**：S2-0 是 **S2-1 的必要控制之一**，**不是**「地基已牢」——它保证「集群只准入受信来源镜像」，但**不绑 pod UID / node / container ID / 实际响应 / 特定执行实例**（那些是 S2-1 β 的 execution binding）。S2-0 有独立价值（缩小可运行镜像集合）+ 为 S2-1 收窄攻击面，但单独不构成 runtime provenance。

---

## 1. 已实证现状（Explore agent + 直接核对，2026-07-19）

| 事实 | 证据 |
|---|---|
| 集群**零 admission 控制器**（无 policy-controller/Kyverno/Gatekeeper/ClusterImagePolicy） | 全树 grep 零命中 |
| digest-pin 验签**仅 CI/PR 时**（keyless cosign in GitHub Action），运行时不重验 | `scripts/image-pin/verify-image-pin.sh:163`、`.github/workflows/verify-image-pin.yml`（`on: pull_request`） |
| 信任根 = `.github/image-pin/allowed-images.yaml`（keyless：GitHub OIDC issuer + per-image sourceRepo/workflowFile/sourceRef） | 该文件 + `verify-image-pin.sh:163-169` |
| 受控镜像仅 2 个：`docker.io/wontlost/aster-api`（源 `aster-cloud/aster-api`·`deploy.yml`·`refs/heads/main`）、`docker.io/wontlost/aster-cloud-migrate`（源 `aster-cloud/aster-cloud`·`ci.yml`·`refs/heads/main`） | `allowed-images.yaml` |
| 集群全 **arm64**（4× OCI Ampere A1.Flex），无 nodeSelector/affinity | `apps/aster-lang/cloud/deployment.yaml:24` |
| 第三方 infra 镜像（traefik/vault/prometheus/cnpg）**不在信任根**，naive cluster-wide enforce 会拦死 | infra Helm charts + `allowed-images.yaml`（只 2 镜像） |
| ArgoCD platform ApplicationSet 用 `list` 生成器，infra 组件模式 = Helm `Application`（仿 monitoring） | `argocd/applicationsets/platform.yaml`、`apps/infrastructure/monitoring/application.yaml` |
| infra project RBAC **已白名单** `ValidatingWebhookConfiguration`/`MutatingWebhookConfiguration`/`CustomResourceDefinition`/`ClusterRole(Binding)` | `argocd/projects/infrastructure.yaml:99-120` |

---

## 2. 选型决策（用户拍板）

| 决策点 | 选择 | 理由 |
|---|---|---|
| **Enforcer** | **Sigstore policy-controller** | `ClusterImagePolicy` CRD 原生 keyless（issuer + 精确 identity），与现有 `verify-image-pin.sh` 的 cosign keyless **共享 signer 身份信任根**（非同一完整语义——CI 另有 SHA/freshness，见 §5）→信任根直接镜像 `allowed-images.yaml` 的 signer 身份，概念最小。★每镜像独立 CIP（§3 P0-1）。 |
| **灰度** | **仅受控两仓 enforce**（namespace opt-in + `no-match-policy: allow`） | 第三方 infra 镜像不在信任根；靠 **namespace 标签**只拦 `aster-cloud` ns（不误伤 infra）+ **`no-match-policy: allow`** 放行 ns 内未匹配镜像。★注意：policy-controller 默认 `no-match-policy: deny`，必须显式改（见 §4）。 |
| **信任模型** | **keyless（GitHub OIDC + Fulcio/Rekor）** | 与 CI/PR 端同源，无私钥管理。 |
| **arm64** | chart 镜像已验证含 `linux/arm64`（见 §6） | Ampere A1 集群铁律。 |

---

## 3. 架构与组件

```
┌─────────────────────────────────────────────────────────────┐
│ ArgoCD (infrastructure project)                              │
│                                                              │
│  argocd/applicationsets/platform.yaml  (list 生成器)          │
│    + element: { name: policy-controller, namespace: cosign-system } │
│        │                                                     │
│        ▼ path: apps/infrastructure/policy-controller/        │
│  单个 Application (multi-source: Helm chart + 两个 CIP 清单)  │
│    chart=sigstore/policy-controller@0.10.6, ns=cosign-system │
│    App 内 wave: chart[CRD+controller+webhook+ConfigMap](0) → CIP(2) │
│        │                                                     │
│        ▼ 部署 (arm64 已实测)                                  │
│  policy-controller (chart 自带 2 CRD + controller)           │
│    webhook = 2×Validating + 2×Mutating (含 tag→digest 解析)  │
│    failurePolicy=Ignore(首版) · no-match-policy=allow         │
└─────────────────────────────────────────────────────────────┘
        │ 拦截贴标签 namespace 的 pod/高层资源 admission
        ▼
┌─────────────────────────────────────────────────────────────┐
│ ★每镜像一个 CIP（P0-1：不合并，防身份交叉授权）              │
│                                                              │
│ ClusterImagePolicy: wontlost-aster-api                       │
│   images: glob index.docker.io/wontlost/aster-api@sha256:**  │  ← 实证定案(§6)
│   authorities.keyless.identities:                            │
│     issuer:  https://token.actions.githubusercontent.com     │
│     subject: https://github.com/aster-cloud/aster-api/       │
│              .github/workflows/deploy.yml@refs/heads/main     │
│   mode: enforce                                              │
│                                                              │
│ ClusterImagePolicy: wontlost-aster-cloud-migrate             │
│   images: glob index.docker.io/wontlost/aster-cloud-migrate@sha256:** │
│   authorities.keyless.identities:                            │
│     issuer:  https://token.actions.githubusercontent.com     │
│     subject: https://github.com/aster-cloud/aster-cloud/     │
│              .github/workflows/ci.yml@refs/heads/main         │
│   mode: enforce                                              │
└─────────────────────────────────────────────────────────────┘
        │  灰度双闸(见 §4):
        │  ① namespace opt-in: 只拦贴 policy.sigstore.dev/include=true 的 ns
        │     → 首版只贴 aster-cloud，第三方 infra ns 不过 webhook
        ▼  ② no-match-policy: allow → ns 内不匹配任何 CIP 的镜像放行
     config-policy-controller ConfigMap: no-match-policy: allow
```

★**P0-1 修正（Codex 退回）**：**每个受控镜像必须独立一个 CIP，每个 CIP 只含该镜像对应的精确 signer 身份**。policy-controller 语义：多个匹配 CIP 之间是 **AND**，**同一 CIP 内多身份是 OR**。若把 2 镜像 + 2 身份塞进一个 CIP，实际授权 = `{aster-api, migrate} × {deploy.yml, ci.yml}` 笛卡尔积 → `aster-api` 被 `aster-cloud/ci.yml` 签也能过，**违反信任根「每镜像唯一合法来源」**。故拆两个 CIP。★用**精确 `subject`（非 `subjectRegExp`）**——身份是确定字符串；若必须用正则须 `^...$` 锚定 + 测试转义。★镜像用 `index.docker.io/...`（policy-controller 对 Docker Hub 规范化到 `index.docker.io`，见 §6 实测）+ glob 收紧防前缀误纳（见 §6）。

**组件清单（改动全增量）**：

1. **`apps/infrastructure/policy-controller/application.yaml`**（新）：**单个** ArgoCD `Application`（multi-source：Helm chart + 同仓附加 CIP 清单，见 §3b），chart `policy-controller` from `https://sigstore.github.io/helm-charts`（pin `targetRevision: 0.10.6`），`releaseName: policy-controller`，namespace `cosign-system`，`securityContext` 硬化仿 monitoring。**Helm values**：`configData: { no-match-policy: allow }`（实证：`configData` 是 chart value line 17）+ **`webhookConfig.failurePolicy: Ignore`**（实证：`failurePolicy` 是 chart value line 44，默认 `Fail`；首版 override 为 `Ignore`，见 §4）。App 内两阶段 wave 排序见 §3b。
2. **两个 CIP 文件**（新，P0-1，置于 `policies/` 子目录）：`cluster-image-policy-aster-api.yaml`（glob `index.docker.io/wontlost/aster-api@sha256:**`，subject=`.../aster-cloud/aster-api/.github/workflows/deploy.yml@refs/heads/main`）+ `cluster-image-policy-aster-cloud-migrate.yaml`（glob `.../aster-cloud-migrate@sha256:**`，subject=`.../aster-cloud/aster-cloud/.github/workflows/ci.yml@refs/heads/main`），**每镜像独立 CIP + 精确 `subject`**，标 `sync-wave: "2"`（§3b：chart 全资源 wave 0 → CIP wave 2 两阶段）。★`no-match-policy` ConfigMap **不在此文件**（归 chart/controller wave 0，§3b）。
3. **`argocd/applicationsets/platform.yaml`**：`list.elements` 加 `{ name: policy-controller, namespace: cosign-system }`。
4. **`argocd/projects/infrastructure.yaml`**：
   - `sourceRepos` 加 `https://sigstore.github.io/helm-charts`；
   - `destinations` 加 `namespace: cosign-system`；
   - `clusterResourceWhitelist` 加 `group: policy.sigstore.dev`（`ClusterImagePolicy`、`TrustRoot` 等；webhook/CRD/ClusterRole 已白名单）；
   - `namespaceResourceWhitelist` 若有则加 policy-controller 需要的命名空间资源（多数已被 `'*'` 或既有条目覆盖，实现时核对）。
5. **namespace 标签**（运维步骤，非 Git 清单）：`kubectl label namespace aster-cloud policy.sigstore.dev/include=true`。★这是**运行时 opt-in 开关**，写进运维手册。**声明式 vs 手工二选一（P1，Codex）**：
   - **手工贴标签**：秒级回滚（摘标签不需 Git commit），但 **namespace 重建后标签消失 → S2-0 静默失效**。必须配 **标签存在性监控 + 定期验证 + 丢失告警**（写进运维手册 + e2e 测「标签丢失时明确告警」），否则 S2-0 会无声关闭而无人知。
   - **声明式标签**（namespace 清单带 label）：GitOps 一致、不会静默失效，但**手工摘标签会被 ArgoCD selfHeal 自动恢复 → 不再是稳定的秒级回滚**（回滚需 Git commit 或 `argocd app set --sync-policy none`）。
   - **首版决策**：手工贴标签 + 标签监控告警（回滚速度优先，用监控补静默失效风险）。二选一必须写清，不能既宣称秒级回滚又声明式。

### 3b. CRD 排序方案（P0-3，唯一拓扑，已用 chart 0.10.6 实证）

**★关键实证（`helm template sigstore/policy-controller --version 0.10.6 --include-crds`）**：
- chart **自带 2 个 CRD**：`clusterimagepolicies.policy.sigstore.dev`、`trustroots.policy.sigstore.dev`。→ **CRD 与 controller 在同一 chart，无需单独 App 装 CRD**。
- chart 渲染出 **2 个 ValidatingWebhookConfiguration + 2 个 MutatingWebhookConfiguration**（`policy.sigstore.dev` 组 + `*.clusterimagepolicy.sigstore.dev` 组）——★**含 Mutating**（tag→digest 解析靠它），卸载/回滚必须覆盖两类 webhook（见 §4）。
- webhook `namespaceSelector` = `policy.sigstore.dev/include In [true]`（实证），`failurePolicy` 默认 `Fail`（Helm value 可覆盖）。

**★唯一拓扑决策（消除上一版三套拓扑矛盾）——单个 ArgoCD Application，用 sync-wave 在 App 内两阶段排序**：

CRD + controller + CIP 全在**同一个 ArgoCD Application** 里，**sync-wave 在单 App 内有真实 ordering + 每 wave 健康等待语义**（跨独立 App 才没有——上一版「跨 App Lua health check」是错的，已删；ArgoCD Lua health 只能评估当前对象、不能查另一个 App）。

★**诚实修正（Codex——不声称没渲染出来的 wave 1）**：Helm chart 模板资源**默认无 wave 注解 = wave 0**；multi-source 只合并各 source 输出，不会自动给 Helm 输出注入 wave 1。故**真实模型是两阶段 wave 0 → wave 2**，不是三 wave：
- **wave 0**（chart source，全默认 wave 0）：CRD（`clusterimagepolicies`/`trustroots`）+ controller Deployment + 4 webhook + `config-policy-controller` ConfigMap（Helm value `configData: { no-match-policy: allow }`）+ Helm value `webhookConfig.failurePolicy: Ignore`（首版）。★ArgoCD 在同 wave 内**按 kind 排序，CRD 先于其它资源 apply**（内置行为）；controller Deployment 有内置 health 评估。
- **wave 2**（Git source `policies/`，显式标 `argocd.argoproj.io/sync-wave: "2"`）：**两个 CIP**。ArgoCD 等 wave 0 全部 `Healthy`（含 CRD `Established` + controller Deployment Ready）才推进 wave 2 → CIP apply 时 CRD 必已 established。

★**健康门的诚实边界（Codex——不过度声称）**：ArgoCD wave 只等 **CRD `Established` + controller Deployment `Healthy`**；这**不严格证明 API server 能成功调用 webhook endpoint**（TLS/证书、Service selector/endpoints、apiserver→webhook 网络、controller 内部初始化都可能未就绪）。故**webhook 端到端可调用性由 admission smoke-test 验证**（提交一个真 admission 请求确认 webhook 响应）——作为**贴 namespace 标签前的强制 staging gate**，不靠 wave 健康门隐含保证。

**ConfigMap 归属**：`config-policy-controller`（no-match-policy）**由 chart/controller 部分（wave 0）管理**（它是 controller 运行配置），`policies/` 目录只含两个 `ClusterImagePolicy`。唯一所有者，无歧义。

**★目录结构（Codex——防 multi-source 自我递归认领）**：
```
apps/infrastructure/policy-controller/
├── application.yaml            # 外层 ApplicationSet 只认这个 Application CR
├── kustomization.yaml          # 只列 application.yaml
└── policies/                   # 内层 Application multi-source 的 Git source 只指向这里
    ├── kustomization.yaml
    ├── cluster-image-policy-aster-api.yaml
    └── cluster-image-policy-aster-cloud-migrate.yaml
```
内层 Application 的 Git source 指向 `policies/`（**非**父目录），避免再次渲染自己的 `application.yaml` 造成重复认领/递归。

---

## 4. 灰度与失败模式（★安全关键）

**★灰度的真正来源 = namespace 标签 opt-in，不是「未匹配镜像默认放行」**（Codex 复审前自查纠正——原设计写反了）：

policy-controller 的默认行为是 **`no-match-policy: deny`**——在**已纳入的 namespace 里**，**任何不匹配任何 CIP 的镜像会被拒绝**（官方文档：*"any image that does not match a policy is rejected"*，除非 `config-policy-controller` ConfigMap 设 `no-match-policy: warn|allow`）。所以「未匹配 = 放行」是**错的**，不能靠它做灰度。

**真正的灰度双闸**：
1. **namespace 标签 opt-in**（主闸）：webhook **只拦贴了 `policy.sigstore.dev/include=true` 的 namespace**；未贴标签的 namespace（traefik/vault/monitoring/cnpg 所在）**webhook 完全不过** → 第三方 infra 天然不受影响。**首版只给 `aster-cloud` namespace 贴标签**。
2. **`no-match-policy: allow`（副闸，必需）**：即便在 `aster-cloud` namespace 内，也有**不在信任根**的镜像（如未来加的 sidecar、或 aster-cloud namespace 里的其它 pod）。若 `no-match-policy` 保持默认 `deny`，这些镜像会被误拒。**首版必须在 `config-policy-controller` ConfigMap 显式设 `no-match-policy: allow`**（或 `warn`）→ 只有**匹配了某个 CIP `images` glob 的受控两仓镜像**才真正走 enforce 验签；namespace 内其它镜像放行。这样「仅受控两仓 enforce、其余观测」才真正成立。
   - ★权衡：`no-match-policy: allow` 意味着「未知镜像在纳入 namespace 内也放行」——这是**灰度阶段的有意选择**（避免误伤），长期可收紧为把 aster-cloud namespace 所有合法镜像纳入 CIP 后切 `deny`。运维手册记录此权衡。

**失败模式（fail-closed vs fail-open）**：

★**P0-2 修正（Codex 退回——原文把正常态语义误当故障态）**：`mode`（enforce/warn）与 webhook `failurePolicy`（Fail/Ignore）是**两个不同的旋钮**，作用时机不同：
- **正常态（webhook 可达）**：API server 调 webhook → webhook 跑 CIP glob + `no-match-policy` → 只有**匹配某 CIP glob 的受控两仓未签镜像**被拒；不匹配镜像按 `no-match-policy: allow` 放行。此时「仅受控两仓 enforce」成立。
- **故障态（webhook 不可达）**：API server **根本没机会跑 CIP glob 或 no-match-policy**——`failurePolicy` 直接作用于 `namespaceSelector 命中 AND webhook rules 命中`。若 `failurePolicy: Fail`，**贴标签 `aster-cloud` namespace 内所有命中 webhook rules 的 admission 请求全 fail-closed**（含不匹配 CIP 的 sidecar、其它 workload、ArgoCD 对这些资源的更新）。**故障爆炸半径 = 整个 `aster-cloud` namespace 的 workload admission，不是两个镜像**。`no-match-policy: allow` 只在 webhook 正常执行后有意义，**不能缩小 outage 爆炸半径**。

**据此的设计选择**：
- policy-controller 装在**未贴标签的 `cosign-system` ns**（自己不拦自己，防自锁）；webhook `namespaceSelector` 天然只命中贴 `policy.sigstore.dev/include=true` 的 ns（`kube-system`/`cosign-system`/infra ns 均不贴 → 不受 outage 影响）。
- **首版 `failurePolicy: Ignore`**（实证：chart Helm value `webhookConfig.failurePolicy`，默认 `Fail` → override `Ignore`；webhook down 时放行而非全拦）观察运行稳定性 → 达门槛后再切 `Fail`。★注意：`failurePolicy: Ignore` 期间 webhook down 会**静默放行未签镜像**（安全性降级）——故必须配 webhook 可用性告警。
- **★阶段化保证（Codex P0-2——「强制」是有条件的，量化切换判据）**：**首版 = webhook 健康时 enforce（`wontlost` 两仓未签镜像被拒）；webhook 故障时为可用性 fail-open，并由告警暴露安全降级。达到量化稳定门槛后切 `Fail`，才形成「故障态也 fail-closed」的终态。** 切换门槛（写进运维手册，非「观察稳定后」这种不可执行措辞）：连续观察 ≥7 天 + webhook 可用率 ≥99.9% + admission p99 延迟/错误率在阈内 + 告警演练成功 + break-glass 演练成功。

**回滚（★P1：卸载顺序——只有摘标签是 outage-无关的可靠 break-glass；★必须覆盖两类 webhook）**：
1. **摘 opt-in 标签**（`kubectl label ns aster-cloud policy.sigstore.dev/include-`）：**唯一可靠、不依赖 webhook 正常工作**的 break-glass，秒级。★先实证：摘标签是对 Namespace 对象的 update，须确认 chart 渲染的 webhook `rules` **不拦 Namespace 更新**（否则 break-glass 自身被拦）。实证 render 的 `policy.sigstore.dev` webhook 只按 `namespaceSelector` 命中 pod-producing 资源，Namespace update 不在其内 → 摘标签可行（实现时再确认渲染 rules）。
2. **临时把两类 webhook 的 `failurePolicy` 改 `Ignore`，或直接删 `ValidatingWebhookConfiguration` + `MutatingWebhookConfiguration`**（★chart 出 **2 Validating + 2 Mutating**，四个都要处理——tag→digest 靠 Mutating）：删除 backend 前先解除 fail-closed，防级联删除时 webhook 仍在但 backend 已删造成新 outage。
3. 从 ApplicationSet/Git 移除（否则 selfHeal 会重建）或暂停自动同步。
4. 删 controller、两个 CIP、2 个 CRD（`clusterimagepolicies`/`trustroots`）。
5. 验证**无残留 Validating/Mutating WebhookConfiguration**。
★**危险点**：直接删 Application 时若 Deployment/Service 先于 webhook config 被删、而 webhook 仍 `Fail` → 制造新 admission outage。故顺序 2（含 Mutating）必须在 3/4 之前。★`mode: enforce→warn` **不是** webhook outage 的可靠 break-glass（它需 API 更新 + controller 正常处理），只在 controller 健康时有用。

---

## 5. 与 CI/PR 端信任根的一致性（单源铁律）

**信任根只有一个**：`.github/image-pin/allowed-images.yaml`。CIP 的 keyless identity **与之共享 signer 身份**：

| allowed-images.yaml 字段 | CIP 对应 |
|---|---|
| `oidcIssuer: https://token.actions.githubusercontent.com` | `authorities.keyless.identities[].issuer` |
| `sourceRepo`/`workflowFile`/`sourceRef` 拼成 `https://github.com/{sourceRepo}/.github/workflows/{workflowFile}@{sourceRef}` | `authorities.keyless.identities[].subject`（精确串，非正则） |

★**P1 修正（Codex——「同一完整验签语义」是过度表述）**：CIP 与 CI **共享 signer identity 信任根**（issuer + workflow subject），但 **CI 另有 runtime CIP 不复制的强约束**：
- CI 还绑 `--certificate-github-workflow-{repository,ref,sha}`（`verify-image-pin.sh:163`）；
- CI 另查 `sourceSha == main HEAD` 的 **freshness**（`verify-image-pin.sh:176`）。
- 故 CIP **可接受该合法 workflow 历史上签过的旧 digest**，**不执行** source-SHA/freshness 约束。诚实定位：「**CIP 与 CI 共享 signer identity 信任根；CI 另有 source SHA + freshness 强约束，S2-0 不等价复制**」。若要运行时完整复制 CI 决策，需维护「已批准 digest allowlist」或验证含 source-commit 的 provenance attestation——**S2-0 不做**（超出「只跑受信来源镜像」目标）。

**★漂移风险 + 缓解**：CIP（两份 YAML）与 `allowed-images.yaml` 手写 → 可能漂移。缓解：
- **首版**：CIP 注释显式指向 `allowed-images.yaml` 为权威源 + CI 校验脚本 `scripts/image-pin/verify-cip-sync.sh` 断言 CIP 的 issuer/subject == `allowed-images.yaml` 派生值（mirror 现有 `verify-rendered-by-digest.yml` 守门）。★注意：此脚本**只防 signer identity YAML 漂移**，**不弥合上面的 source-SHA/freshness 语义差异**（那是设计上的有意不复制，非漂移）。
- 长期：CIP 由 `allowed-images.yaml` 模板生成（免手写漂移），首版不引入生成器（YAGNI）。

---

## 6. arm64 验证（已实证）+ glob/registry 规范化（已源码定案 + 可复现测试）

**arm64（已实测）**：
- Chart `policy-controller` 版本 `0.10.6`，webhook 镜像**按 digest pin**：`ghcr.io/sigstore/policy-controller/policy-controller@sha256:0bcd60beb93f4427c29cf3a669743caf58490e98ded4380c33c09f092734a6ab`。
- `docker manifest inspect` 实测该 digest **含 `linux/amd64` + `linux/arm64`** → Ampere A1 可跑。
- chart values **无 amd64 nodeAffinity/nodeSelector 默认**（`affinity: {}`、`commonNodeSelector: {}`）→ 无需剥离 arch pin。
- leases-cleanup job 镜像 `cgr.dev/chainguard/kubectl:latest-dev`（Chainguard 多架构，含 arm64）。★**供应链盲点（Codex P1）**：这是**可变 tag `latest-dev`**，且在**未 opt-in 的 `cosign-system` ns**（S2-0 不验它）→ controller 部署本身不是完整 digest-pinned。**实现时须**：把此镜像 pin 到固定 digest（Helm value override）+ 实证 arm64；若不 pin，**必须在运维手册诚实记录为接受的残余供应链风险**。
- ★**实现时铁律**：装完 `kubectl get pods -n cosign-system` 确认 webhook pod `Running`（非 Pending，Pending=arch 不匹配）。

★**glob 匹配契约（P1，Codex——已用 policy-controller v0.13.1 的 `pkg/apis/glob/glob.go` 源码逐字复算定案，非纸面猜）**：

**实证方法**：policy-controller 的 `glob.Compile` 是确定性正则翻译（`.`→`\.`、`**`→`.*`、`*`→`[^/]*`、`^...$` 全串锚定），匹配对象是 `name.ParseReference(image).Name()`（规范化后完整引用：`docker.io`/短名→`index.docker.io`，digest 保留 `@sha256:...`）。**可复现测试**：`scripts/image-pin/testdata/globcheck/`（固定 v0.13.1 `Compile` 逻辑 + Docker Hub 规范化的表驱动 Go test，`go test -v ./...` 已绿，覆盖两仓）。复算四个候选 glob × 各镜像引用：

| glob | digest（docker.io/index/短名 三等价） | tag `:jvm-latest` | `aster-api-malicious`（前缀） | 其它 registry |
|---|---|---|---|---|
| `index.docker.io/wontlost/aster-api`（裸） | ❌ 全不匹配 | ❌ | ❌ | ❌ |
| `index.docker.io/wontlost/aster-api**` | ✅ | ✅ | **⚠️ 误命中** | ❌ |
| **`index.docker.io/wontlost/aster-api@sha256:**`** | ✅ 三等价全命中 | ❌ | ❌ | ❌ |
| `index.docker.io/wontlost/aster-api:**` | ❌ | ✅ tag | ❌ | ❌ |

**结论（定案）**：
- **裸 repo 串匹配不了任何东西**（Codex 判断正确）→ 必须带 wildcard。
- **尾部裸 `**` 会误纳 `aster-api-malicious`**（前缀风险实证为真）→ **禁用**。
- **✅ 采用 `index.docker.io/wontlost/aster-api@sha256:**`**（migrate 同形 `.../aster-cloud-migrate@sha256:**`）：三种等价 digest 引用（`docker.io/`、`index.docker.io/`、短名）全命中、前缀不误纳、别 registry 不漏。因部署本就 by-digest（kustomize transformer→`@sha256:`），完全对齐。

★**「tag 逃逸」问题辨析（Codex 第 4 轮 P0——我上一版结论错了，已用源码更正）**：上一版说「`@sha256:**` 不匹配 tag → tag 镜像落 `no-match-policy: allow` 逃过 enforce」是**错的**。查 policy-controller v0.13.1 源码：
- admission 顺序 **mutation 先于 validation**（k8s 铁律）。policy-controller 的 **Mutating webhook `resolvePodSpec`（`pkg/webhook/validator.go:1074-1085`）把 tag 解析为 digest 后写回** container image 字段：`cs[i].Image = fmt.Sprintf("%s@%s", tagRef.Name(), digest.DigestStr())`（保留 tag 并追加 digest）。
- 随后 **Validating webhook 用 `GetMatchingPolicies(ref.Name(), …)`（`validator.go:1157,1165`）** 匹配——`ref.Name()` 对 `repo:tag@sha256:x` 规范化**丢弃 tag** = `index.docker.io/wontlost/aster-api@sha256:x` → **命中 `@sha256:**` CIP → 走 enforce 验签**。
- **结论：提交 tag 形式 → Mutating 解析为 digest → Validating 命中 CIP → 被强制验签。无 tag 逃逸，无需第二个「拒-tag」CIP。** ★唯一前提：tag 在注册表可解析（`resolveDigest` 需网络）；不可解析则 mutation 跳过、镜像保持 tag → 落 `no-match-policy: allow`——但那种镜像根本拉不起来，非绕过。**此结论待 staging 真 admission 复验（提交未签 tag → 应被拒），设计层已从源码定论无 gap。**

**CRD 装载（已实证）**：`helm template sigstore/policy-controller --version 0.10.6 --include-crds` 确认 chart **自带** `clusterimagepolicies.policy.sigstore.dev` + `trustroots.policy.sigstore.dev` 两个 CRD。

---

## 7. 验证计划（本地实测，禁止 CI 外包）

**无生产集群写权限的前提下，最大化本地实证**：

1. **CIP schema + keyless 语义 + 灰度四态**：本地 `kind`/`k3d`（arm64 mac 原生）→ `helm install policy-controller sigstore/policy-controller -n cosign-system` + `no-match-policy: allow` → apply **两个 CIP** → 测试 namespace 贴 `policy.sigstore.dev/include=true` → 验证：(a) 匹配 glob 的**已签**镜像=通过；(b) 匹配 glob 的**未签/错身份**镜像=被拒（enforce）；(c) **不匹配任何 CIP** 的镜像（模拟 sidecar）=放行（`no-match-policy: allow`）；(d) **未贴标签** namespace 任意镜像=放行（opt-in）。
2. **★P0-1 交叉授权负测（★Codex——身份不可本地伪造，须用真 fixture）**：目标 = 证明「`aster-cloud/ci.yml` 身份签的 `aster-api` 镜像被拒」。但**本地 kind/k3d 不能伪造 Fulcio OIDC 身份**。故采用：(a) **静态**断言两 CIP 的 image↔subject 一一对应（`verify-cip-sync.sh` 覆盖）；(b) **动态**用 policy-tester + **固定证书/签名 fixture**（预先由受控 GitHub Actions 测试 workflow 生成的 cross-signed fixture，或用已存在的错身份签名测试 digest）→ 证明错身份被拒。**不把「本地伪造身份」写成可执行步骤**；真跨身份动态负测在 staging 用真实 fixture 补。
3. **★绕过面矩阵（P1，Codex）——ephemeral/init 覆盖已从源码定案**：★**静态事实已定（v0.13.1 源码，非留 staging）**：`cmd/webhook/main.go:184-185` `SupportedSubResources() = ["/ephemeralcontainers", ""]` + `:203` 注册 `Pod`→`crdEphemeralContainers`；`validator.go:310/352` `checkEphemeralContainers` 验签 + `:1093/1124` `resolveEphemeralContainers` 解析 digest → **ephemeral container 被 validate + mutate 覆盖，不是绕过路径**。webhook 覆盖资源 `pods, cronjobs, jobs, statefulsets, daemonsets`（`main.go:145`）+ pod ephemeralcontainers 子资源（controller 运行时动态注册 webhook rules，故 Helm 渲染的 `WebhookConfiguration` 静态 rules 为空——这也是为何不能只看渲染 YAML）。**staging 动态复验**：Pod/Deployment/Job/CronJob/StatefulSet/DaemonSet/init container/ephemeral container（`kubectl debug --image=<未签受控仓镜像>`）各跑一次「匹配 glob 未签镜像」证被拦。
4. **★tag→digest 语义（Codex 第 4 轮 P0，已源码定论无 gap）**：S2-0 目标 =「**允许提交 tag，但最终 PodSpec 被 Mutating 固定为验证过的 digest**」。源码已证：Mutating `resolvePodSpec` 解析 tag→digest 写回 → Validating 对 digest 命中 CIP 验签（§6）。**staging 复验**：提交**未签 tag** 形式 → 应在 mutation/validation 链中**被拒**（非放行）；提交已签 tag → mutation 后 pod spec 为 digest 且通过。
5. **glob 匹配矩阵（已本地定案 + 可复现测试，§6）**：`scripts/image-pin/testdata/globcheck/`（固定 v0.13.1 `glob.Compile` 逻辑的表驱动 Go test，`go test -v ./...` 已绿）证 `@sha256:**` 命中三等价 digest 引用、不误纳前缀/别 registry/tag；覆盖两仓。staging 用 `policy-tester`（同 chart appVersion）真跑复验一遍。
6. **信任根一致性**：`scripts/image-pin/verify-cip-sync.sh` 断言两 CIP 的 issuer/subject == `allowed-images.yaml` 派生值；改一字→报错。
7. **CRD 排序（§3b 两阶段 wave）**：本地/staging 验证单 App wave 0（chart，含 CRD+controller）→ wave 2（CIP）真能保证 CRD established 后才 apply CIP（删 CRD 重装 → CIP apply 不再 `no matches`）+ webhook 端到端 **admission smoke-test**（贴标签前的强制 gate，确认 apiserver 能调 webhook）。
8. **ArgoCD 清单合法性 + multi-source 渲染集合**：`kustomize build` + `kubeconform`/`kubeval` 静态校验；★确认内层 Git source 指向 `policies/` 只渲染两 CIP（不含 `application.yaml`，防递归认领，§3b 目录结构）。
9. **回滚演练（§4 顺序）**：摘标签→改 failurePolicy→移除 App，逐步验证无级联 outage。

**验证工具缺失记录**：若本地无 kind/k3d，退化为 `kustomize build` 静态校验 + CIP 语义人工核对 + arm64/glob manifest 实测，并在运维手册标注「**必须在 staging 集群做一次真 admission 拦截 + 绕过面 + P0-1 交叉授权负测的 e2e**」——admission 语义（尤其 init/ephemeral/交叉授权）**不能只靠静态校验**。

---

## 8. 交叉审查与交付

- **禁止自审**：Claude 生成 → Codex 审（审查重点：信任根一致性/灰度爆炸半径/fail-closed 回滚/CIP keyless 语义正确/arm64/是否误称「解锁签字」）。
- **交付节奏**：设计定案 → 用户复核本 spec → writing-plans 出实现计划 → 落实现 → 本地验证 → Codex 审 → 交用户合入。
- S2-0 独立 PR（k3s 仓），与 S2-1（β，aster-cloud，大工程）解耦。

---

## 附：为什么不选 Kyverno / 不直接全集群 enforce（决策留痕）

- **Kyverno**：通用 policy engine，`verifyImages` 也能 keyless，但更重、概念面更大，对「只验镜像签名」是杀鸡用牛刀；与现有 cosign keyless 模型需多一层映射。policy-controller 与 `verify-image-pin.sh` **共享同一 keyless signer identity 模型**（★非「同一完整语义」——CI 另有 SHA/freshness，见 §5）→ 信任根 signer 身份直接镜像。
- **全集群 enforce**：第三方 infra 镜像不在信任根 → 立即被拦 → 集群 infra 崩。除非同时把所有第三方镜像加进信任策略（大工程 + 持续维护第三方 digest）。灰度 = 仅 opt-in namespace 内受控两仓 enforce 是唯一务实起点。
- **只 warn 不 enforce**：不真正解锁层2 runtime 强制（spike 要的是强制）。可作 enforce 前过渡，但非终态；首版直接对 `aster-cloud` ns 的受控两仓 enforce（爆炸半径已锁死，无需先 warn）。
