# S2-0 设计：运行时 admission 强制只跑 cosign-verified digest

**状态**: 设计定案（待用户复核 → 落实现）
**日期**: 2026-07-19
**关联**: aster-cloud `docs/p0a-s2-runtime-provenance-verifier-spike.md`（S2 层3 spike，S2-0 是其地基）、digest-pin epic（wontlost-ltd/k3s#4，CI/PR 时验签）
**信任根（单源，不复制）**: `.github/image-pin/allowed-images.yaml`

---

## 0. 目标与非目标（先划清边界）

**目标**：在**运行时 pod admission** 阶段强制「只有 cosign 可验签的 `wontlost/*` 镜像 digest 才能被调度运行」。补上 digest-pin epic 明确留下的运行时缺口——现有验签只发生在 **PR 合并时的 GitHub Action**，集群运行时**零重验签**（ArgoCD selfHeal 直接 apply digest-pinned 清单，admission 不再检查签名）。

**★非目标（诚实边界，承 S2 spike）**：
- S2-0 **不解锁签字**（`isSignablePass` 仍恒 false）。它是 **artifact-deployment policy**，**不是 runtime binding 证明**——它保证「集群只跑受信来源构建的镜像」，**不**证明「某次 evaluate 响应确实由该镜像执行且内容诚实」（那是层3 = S2-1 β 的事）。
- 不改 digest-pin epic 的 CI/PR 机制（S2-0 是它的运行时补充，非替代）。
- 不做第三方 infra 镜像（traefik/vault/prometheus/cnpg）的签名强制（它们不在信任根，见 §4 灰度）。

**为什么仍要做**：任何层3 都要绑「实际跑的 image」；若运营方/漂移能让集群跑任意未签 digest，层3 的 image binding 地基不牢。S2-0 独立价值 + 是 S2-1 的硬前置。

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
| **Enforcer** | **Sigstore policy-controller** | `ClusterImagePolicy` CRD 原生 keyless（issuer + identity regexp），与现有 `verify-image-pin.sh` 的 cosign keyless 验签**同一语义模型**→信任根可直接镜像 `allowed-images.yaml`，概念最小。 |
| **灰度** | **仅 `wontlost/*` enforce**（namespace opt-in + `no-match-policy: allow`） | 第三方 infra 镜像不在信任根；靠 **namespace 标签**只拦 `aster-cloud` ns（不误伤 infra）+ **`no-match-policy: allow`** 放行 ns 内未匹配镜像。★注意：policy-controller 默认 `no-match-policy: deny`，必须显式改（见 §4）。 |
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
│  apps/infrastructure/policy-controller/application.yaml      │
│    (Helm Application, chart=sigstore/policy-controller, 仿 monitoring) │
│        │                                                     │
│        ▼ 部署                                                 │
│  policy-controller webhook (ns=cosign-system, arm64)         │
│    = ValidatingWebhookConfiguration                          │
└─────────────────────────────────────────────────────────────┘
        │ 拦截 pod admission（仅贴标签的 namespace）
        ▼
┌─────────────────────────────────────────────────────────────┐
│ ClusterImagePolicy: wontlost-keyless                         │
│   images: glob docker.io/wontlost/aster-api**                │
│           glob docker.io/wontlost/aster-cloud-migrate**      │
│   authorities.keyless.identities:                            │
│     issuer: https://token.actions.githubusercontent.com      │
│     subjectRegExp: .../aster-api/.../deploy.yml@refs/heads/main │
│     (+ migrate 的 ci.yml 身份)                                │
│   mode: enforce                                              │
└─────────────────────────────────────────────────────────────┘
        │  灰度双闸(见 §4):
        │  ① namespace opt-in: 只拦贴 policy.sigstore.dev/include=true 的 ns
        │     → 首版只贴 aster-cloud，第三方 infra ns 不过 webhook
        ▼  ② no-match-policy: allow → ns 内不匹配 CIP 的镜像放行
     config-policy-controller ConfigMap: no-match-policy: allow
```

**组件清单（改动全增量）**：

1. **`apps/infrastructure/policy-controller/application.yaml`**（新）：ArgoCD Helm `Application`，chart `policy-controller` from `https://sigstore.github.io/helm-charts`（pin `targetRevision: 0.10.6`），`releaseName: policy-controller`，`sync-wave: "3"`（早于业务 app 的 sync-wave，晚于 CRD/核心 infra），`securityContext` 硬化仿 monitoring，namespace `cosign-system`。**Helm values 设 `configData.no-match-policy: allow`**（或等价 `config-policy-controller` ConfigMap 覆盖，见 §4）。
2. **`apps/infrastructure/policy-controller/cluster-image-policy.yaml`**（新）：`ClusterImagePolicy` `wontlost-keyless`（§3 图内容）。**CRD 排序**：chart（组件 1）装 `ClusterImagePolicy` CRD + controller；CIP 是该 CRD 的 CR 实例，**必须在 CRD 建好后 apply** → 给此文件加 **`argocd.argoproj.io/sync-wave: "4"`**（> 组件 1 的 `"3"`），ArgoCD 保证 CRD 先于 CR。作为同一 Application 的 kustomize 附加资源（`kustomization.yaml` 列 Application chart 之外的额外清单，或用 ArgoCD multi-source）。实现时确认 chart 是否已含 CRD（`helm template` 检查）——若 chart 不装 CRD 需单独 apply CRD manifest 于 sync-wave `"2"`。
3. **`argocd/applicationsets/platform.yaml`**：`list.elements` 加 `{ name: policy-controller, namespace: cosign-system }`。
4. **`argocd/projects/infrastructure.yaml`**：
   - `sourceRepos` 加 `https://sigstore.github.io/helm-charts`；
   - `destinations` 加 `namespace: cosign-system`；
   - `clusterResourceWhitelist` 加 `group: policy.sigstore.dev`（`ClusterImagePolicy`、`TrustRoot` 等；webhook/CRD/ClusterRole 已白名单）；
   - `namespaceResourceWhitelist` 若有则加 policy-controller 需要的命名空间资源（多数已被 `'*'` 或既有条目覆盖，实现时核对）。
5. **namespace 标签**（运维步骤，非 Git 清单）：`kubectl label namespace aster-cloud policy.sigstore.dev/include=true`。★这是**运行时 opt-in 开关**，写进运维手册；也可由 aster-cloud namespace 清单（`apps/aster-lang/cloud/`）声明式带上（实现时定：声明式更 GitOps，但摘标签回滚就需 Git commit——首版建议**手工贴标签**以便秒级回滚，运维手册记录）。

---

## 4. 灰度与失败模式（★安全关键）

**★灰度的真正来源 = namespace 标签 opt-in，不是「未匹配镜像默认放行」**（Codex 复审前自查纠正——原设计写反了）：

policy-controller 的默认行为是 **`no-match-policy: deny`**——在**已纳入的 namespace 里**，**任何不匹配任何 CIP 的镜像会被拒绝**（官方文档：*"any image that does not match a policy is rejected"*，除非 `config-policy-controller` ConfigMap 设 `no-match-policy: warn|allow`）。所以「未匹配 = 放行」是**错的**，不能靠它做灰度。

**真正的灰度双闸**：
1. **namespace 标签 opt-in**（主闸）：webhook **只拦贴了 `policy.sigstore.dev/include=true` 的 namespace**；未贴标签的 namespace（traefik/vault/monitoring/cnpg 所在）**webhook 完全不过** → 第三方 infra 天然不受影响。**首版只给 `aster-cloud` namespace 贴标签**。
2. **`no-match-policy: allow`（副闸，必需）**：即便在 `aster-cloud` namespace 内，也有**不在信任根**的镜像（如未来加的 sidecar、或 aster-cloud namespace 里的其它 pod）。若 `no-match-policy` 保持默认 `deny`，这些镜像会被误拒。**首版必须在 `config-policy-controller` ConfigMap 显式设 `no-match-policy: allow`**（或 `warn`）→ 只有**匹配了 CIP `images` glob 的 `wontlost/*` 镜像**才真正走 enforce 验签；namespace 内其它镜像放行。这样「仅 `wontlost/* enforce`、其余观测」才真正成立。
   - ★权衡：`no-match-policy: allow` 意味着「未知镜像在纳入 namespace 内也放行」——这是**灰度阶段的有意选择**（避免误伤），长期可收紧为把 aster-cloud namespace 所有合法镜像纳入 CIP 后切 `deny`。运维手册记录此权衡。

**失败模式（fail-closed vs fail-open）**：
- policy-controller 默认 `admission.controller` 的 `failurePolicy`。**S2-0 首版设 `mode: enforce` + 拦截失败时 fail-closed**（拒绝无法验签的 pod），但**仅对贴标签 namespace + 匹配 glob 的镜像**——爆炸半径限于 `aster-cloud` ns 的 `wontlost/*`。
- **回滚**：出问题时 (a) 摘掉 namespace 标签（立即停止拦截，秒级）；(b) CIP `mode: enforce`→`warn`（只告警不拦）；(c) ArgoCD 删 Application（彻底移除）。三级回滚，最快 (a) 无需 Git commit。
- **★webhook 自身不可用的风险**：policy-controller webhook down 时，若 `failurePolicy: Fail`，贴标签 namespace 的**新 pod 无法调度**（含 policy-controller 自身滚动更新的竞态）。缓解：policy-controller 装在**未贴标签的 `cosign-system` ns**（自己不拦自己）；webhook `namespaceSelector` 排除 `kube-system`/`cosign-system`；首版可先 `failurePolicy: Ignore` 观察一周再切 `Fail`（运维手册记录）。

---

## 5. 与 CI/PR 端信任根的一致性（单源铁律）

**信任根只有一个**：`.github/image-pin/allowed-images.yaml`。CIP 的 keyless identity **必须与之逐字一致**：

| allowed-images.yaml 字段 | CIP 对应 |
|---|---|
| `oidcIssuer: https://token.actions.githubusercontent.com` | `authorities.keyless.identities[].issuer` |
| `sourceRepo`/`workflowFile`/`sourceRef` 拼成 `https://github.com/{sourceRepo}/.github/workflows/{workflowFile}@{sourceRef}` | `authorities.keyless.identities[].subjectRegExp`（正则转义 `.`、`/`） |

**★漂移风险 + 缓解**：CIP 是 YAML 手写，`allowed-images.yaml` 是另一份 YAML → 两份可能漂移（改了信任根忘了改 CIP）。缓解方案（实现时选一，写进运维手册）：
- **首版（推荐）**：CIP 里注释显式指向 `allowed-images.yaml` 为权威源 + 加一个 CI 校验脚本 `scripts/image-pin/verify-cip-sync.sh`，断言 CIP 的 issuer/identity 与 `allowed-images.yaml` 派生值一致（mirror 现有 `verify-rendered-by-digest.yml` 的守门思路）。
- 长期：CIP 由 `allowed-images.yaml` 模板生成（避免手写漂移），但首版不引入生成器（YAGNI）。

---

## 6. arm64 验证（已实证，非假设）

- Chart `policy-controller` 版本 `0.10.6`，webhook 镜像**按 digest pin**：`ghcr.io/sigstore/policy-controller/policy-controller@sha256:0bcd60beb93f4427c29cf3a669743caf58490e98ded4380c33c09f092734a6ab`。
- `docker manifest inspect` 实测该 digest **含 `linux/amd64` + `linux/arm64`** → Ampere A1 可跑。
- chart values **无 amd64 nodeAffinity/nodeSelector 默认**（`affinity: {}`、`commonNodeSelector: {}`）→ 无需剥离 arch pin。
- leases-cleanup job 镜像 `cgr.dev/chainguard/kubectl:latest-dev`（Chainguard 多架构，含 arm64）。
- ★**实现时铁律**：装完 `kubectl get pods -n cosign-system` 确认 webhook pod `Running`（非 Pending，Pending=arch 不匹配）。

---

## 7. 验证计划（本地实测，禁止 CI 外包）

**无生产集群写权限的前提下，最大化本地实证**：

1. **CIP schema + keyless 语义 + 灰度三态**：本地 `kind`/`k3d` 起临时集群（arm64 mac 原生）→ `helm install policy-controller sigstore/policy-controller -n cosign-system` + 设 `no-match-policy: allow` → apply CIP → 给测试 namespace 贴 `policy.sigstore.dev/include=true` → 验证三态：(a) 匹配 glob 的**已签**镜像=通过；(b) 匹配 glob 的**未签/错身份**镜像=被拒（enforce 生效）；(c) **不匹配 glob** 的镜像（模拟 sidecar）=放行（`no-match-policy: allow` 生效）；(d) **未贴标签** namespace 的任意镜像=放行（namespace opt-in 生效）。四态齐证灰度正确。
2. **信任根一致性**：写 `scripts/image-pin/verify-cip-sync.sh` + 本地跑，断言 CIP identity == `allowed-images.yaml` 派生值；故意改一字 → 脚本报错（守门有效）。
3. **arm64**：§6 已实测镜像 manifest 含 arm64（本地 `docker manifest inspect`）。
4. **ArgoCD 清单合法性**：`kubectl kustomize apps/infrastructure/policy-controller/` 渲染无错 + `argocd app diff`（若有集群访问）或本地 `kubeconform`/`kustomize build | kubeval` 校验。
5. **回滚演练**：本地集群摘 namespace 标签 → 验证拦截立即停止。

**验证工具缺失记录**：若本地无 kind/k3d，退化为 `kustomize build` 静态校验 + CIP 语义人工核对 + arm64 manifest 实测，并在运维手册标注「需在 staging 集群做一次真 admission 拦截 e2e」。

---

## 8. 交叉审查与交付

- **禁止自审**：Claude 生成 → Codex 审（审查重点：信任根一致性/灰度爆炸半径/fail-closed 回滚/CIP keyless 语义正确/arm64/是否误称「解锁签字」）。
- **交付节奏**：设计定案 → 用户复核本 spec → writing-plans 出实现计划 → 落实现 → 本地验证 → Codex 审 → 交用户合入。
- S2-0 独立 PR（k3s 仓），与 S2-1（β，aster-cloud，大工程）解耦。

---

## 附：为什么不选 Kyverno / 不直接全集群 enforce（决策留痕）

- **Kyverno**：通用 policy engine，`verifyImages` 也能 keyless，但更重、概念面更大，对「只验镜像签名」是杀鸡用牛刀；与现有 cosign keyless 模型需多一层映射。policy-controller 与 `verify-image-pin.sh` 同语义 → 信任根直接镜像。
- **全集群 enforce**：第三方 infra 镜像不在信任根 → 立即被拦 → 集群 infra 崩。除非同时把所有第三方镜像加进信任策略（大工程 + 持续维护第三方 digest）。灰度 = 仅 `wontlost/*` 是唯一务实起点。
- **只 warn 不 enforce**：不真正解锁层2 runtime 强制（spike 要的是强制）。可作 enforce 前过渡，但非终态；首版直接对 `aster-cloud` ns 的 `wontlost/*` enforce（爆炸半径已锁死，无需先 warn）。
