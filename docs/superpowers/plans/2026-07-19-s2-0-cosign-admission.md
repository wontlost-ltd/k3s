# S2-0 Cosign-Verified Digest Admission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 k3s 集群 pod admission 阶段强制「opt-in 的 `aster-cloud` namespace 内、受控两仓（`wontlost/aster-api` + `wontlost/aster-cloud-migrate`）只跑 cosign-verified digest 镜像」，补 digest-pin epic 留下的运行时验签缺口。

**Architecture:** 通过 ArgoCD platform ApplicationSet 部署 Sigstore policy-controller（单个 Application：Helm chart + 4 个 ClusterImagePolicy，App 内两阶段 sync-wave 0→2）。灰度靠 namespace opt-in 标签 + `no-match-policy: allow`；首版 `failurePolicy: Ignore`。信任根单源 `.github/image-pin/allowed-images.yaml`，由 `verify-cip-sync.sh` 守四 CIP 契约漂移。

**Tech Stack:** Kubernetes admission（Sigstore policy-controller v0.13.1 / chart 0.10.6，keyless GitHub OIDC）、ArgoCD ApplicationSet + multi-source Application、Helm、kustomize、bash + yq 守门脚本、Go（glob 复算测试，已存在）。

## Global Constraints

- **信任根单源**：`.github/image-pin/allowed-images.yaml` 是唯一权威；CIP 从它派生 signer 身份，**绝不**复制/新增第二处信任声明。N 仓 → 2N CIP 严格对应。
- **注释/文档中文**：所有 YAML 注释、脚本注释、文档用简体中文。
- **arm64 铁律**：集群全 Ampere A1（arm64）。任何新镜像必须实测 manifest 含 `linux/arm64`（policy-controller webhook 镜像已验证含 arm64）。
- **诚实边界**：S2-0 **不解锁签字**、**不是 runtime binding 证明**——是 artifact-deployment policy。任何文案不得声称它证明「响应由该镜像执行」。
- **CIP 契约**：每受控仓 = 1 digest-verify CIP（glob `index.docker.io/<repo>@sha256:**` + 精确 keyless subject，`images`/`authorities`/`keyless.identities` 各恰一项，禁止 OR 扩权）+ 1 tag-fail CIP（glob `index.docker.io/<repo>:**` + 唯一 authority `static.action: fail`）。四份全 `mode: enforce`。
- **灰度双闸**：首版只给 `aster-cloud` namespace 贴 `policy.sigstore.dev/include=true`（手工，配标签监控告警）+ `no-match-policy: allow`。首版 `failurePolicy: Ignore`。
- **禁止 `git add -A`**：只按显式路径 stage（避免误扫 `.claude/` 等分析文件）。
- **提交页脚**：commit 结尾 `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`。
- **验证本地化**：所有可本地验证的步骤本地跑（`kubectl kustomize`、`go test`、`yq`、bash 脚本自测）；需真集群 apiserver/OIDC 的留 staging 动态门，明确标注。

## 权威事实（实证，实现时引用，勿重新假设）

- policy-controller chart：repo `https://sigstore.github.io/helm-charts`，`version 0.10.6`，`appVersion 0.13.1`。
- chart 自带 2 CRD：`clusterimagepolicies.policy.sigstore.dev`、`trustroots.policy.sigstore.dev`。
- chart 渲染 2 ValidatingWebhookConfiguration + 2 MutatingWebhookConfiguration；`policy.sigstore.dev` webhook 的 `namespaceSelector` = `policy.sigstore.dev/include In [true]`。
- Helm values：`webhookConfig.failurePolicy`（默认 `Fail`）；`configData`（默认 `{}`，用于注入 `no-match-policy`）。
- webhook 镜像 `ghcr.io/sigstore/policy-controller/policy-controller@sha256:0bcd60beb93f4427c29cf3a669743caf58490e98ded4380c33c09f092734a6ab` 含 `linux/arm64`（已 `docker manifest inspect` 验）。leases-cleanup 镜像 `cgr.dev/chainguard/kubectl:latest-dev`（可变 tag，见 Task 2 pin）。
- 信任根条目（`allowed-images.yaml`）：
  - `docker.io/wontlost/aster-api` ← `sourceRepo: aster-cloud/aster-api`, `workflowFile: deploy.yml`, `sourceRef: refs/heads/main`, `oidcIssuer: https://token.actions.githubusercontent.com`。
  - `docker.io/wontlost/aster-cloud-migrate` ← `sourceRepo: aster-cloud/aster-cloud`, `workflowFile: ci.yml`, `sourceRef: refs/heads/main`。
- ArgoCD 集成锚点：
  - `argocd/applicationsets/platform.yaml:13-23`（`list.elements`，每元素 `{name, namespace}` → `path: apps/infrastructure/{{.name}}`）。
  - `argocd/projects/infrastructure.yaml:10`（`sourceRepos:`）、`:22`（`destinations:`）、`:61`（`clusterResourceWhitelist:`，已含 CRD/webhook/ClusterRole）、`:122`（`namespaceResourceWhitelist:`，已含 ConfigMap/Service/ServiceAccount/Deployment/Secret，无 `'*'`）。
- glob 匹配语义定案（源码复算 + Go test）：`@sha256:**` 只命中三等价 digest 引用；`:**` 命中 tag 形式；mutation 写回 `repo:tag@sha256` 规范化后只命中 digest CIP。测试在 `scripts/image-pin/testdata/globcheck/`（已绿）。
- 分支：`p0a-s2-0-cosign-admission`（设计文档 + glob 测试已提交在此分支）。

---

## File Structure

**新建**：
- `apps/infrastructure/policy-controller/application.yaml` — ArgoCD multi-source Application（Helm chart source + Git `policies/` source）。
- `apps/infrastructure/policy-controller/kustomization.yaml` — 只列 `application.yaml`（供 ApplicationSet 的 `path` 渲染）。
- `apps/infrastructure/policy-controller/policies/kustomization.yaml` — 列 4 个 CIP。
- `apps/infrastructure/policy-controller/policies/cluster-image-policy-aster-api.yaml` — digest-verify CIP（aster-api）。
- `apps/infrastructure/policy-controller/policies/cluster-image-policy-aster-api-reject-tag.yaml` — tag-fail CIP（aster-api）。
- `apps/infrastructure/policy-controller/policies/cluster-image-policy-aster-cloud-migrate.yaml` — digest-verify CIP（migrate）。
- `apps/infrastructure/policy-controller/policies/cluster-image-policy-aster-cloud-migrate-reject-tag.yaml` — tag-fail CIP（migrate）。
- `scripts/image-pin/verify-cip-sync.sh` — 守四 CIP 契约漂移（bash + yq）。
- `docs/POLICY_CONTROLLER_RUNBOOK.md` — 运维手册（贴/摘标签、切 failurePolicy、卸载顺序、标签监控、staging e2e 清单）。

**修改**：
- `argocd/applicationsets/platform.yaml` — `list.elements` 加 `policy-controller` 元素。
- `argocd/projects/infrastructure.yaml` — `sourceRepos` 加 sigstore helm repo；`destinations` 加 `cosign-system` ns；`clusterResourceWhitelist` 加 `policy.sigstore.dev` group。

**已存在（不改，作为信任根/测试）**：
- `.github/image-pin/allowed-images.yaml`（信任根，只读引用）。
- `scripts/image-pin/testdata/globcheck/`（glob 复算测试，Task 5 复用其断言语义）。

---

## Task 1: ArgoCD 项目授权（infrastructure project 放行 policy-controller）

**为什么先做**：ApplicationSet 部署的 Application 属于 `infrastructure` project；project 不放行 sigstore helm repo + `cosign-system` ns + `policy.sigstore.dev` CRD 组，则后续 sync 被 ArgoCD RBAC 拒。这是纯配置前置，无运行副作用。

**Files:**
- Modify: `argocd/projects/infrastructure.yaml`（`sourceRepos:` @:10、`destinations:` @:22、`clusterResourceWhitelist:` @:61）

**Interfaces:**
- Produces: `infrastructure` project 允许 `sourceRepos` 含 `https://sigstore.github.io/helm-charts`、`destinations` 含 `cosign-system`、`clusterResourceWhitelist` 含 `policy.sigstore.dev/ClusterImagePolicy` + `policy.sigstore.dev/TrustRoot`。后续 Task 2 的 Application 依赖这些。

- [ ] **Step 1: 加 sigstore helm repo 到 sourceRepos**

在 `argocd/projects/infrastructure.yaml` 的 `sourceRepos:` 列表末尾（`open-telemetry` 那行之后）追加：

```yaml
    # Sigstore policy-controller（S2-0 cosign admission）
    - 'https://sigstore.github.io/helm-charts'
```

- [ ] **Step 2: 加 cosign-system namespace 到 destinations**

在 `destinations:` 列表末尾（`otel-system` 之后）追加：

```yaml
    # policy-controller namespace（S2-0）
    - namespace: cosign-system
      server: https://kubernetes.default.svc
```

- [ ] **Step 3: 加 policy.sigstore.dev CRD 组到 clusterResourceWhitelist**

在 `clusterResourceWhitelist:` 列表末尾（`ClusterRoleBinding` 之后）追加：

```yaml
    # Sigstore policy CRDs（S2-0；webhook/CRD/ClusterRole 组已在上方白名单）
    - group: policy.sigstore.dev
      kind: ClusterImagePolicy
    - group: policy.sigstore.dev
      kind: TrustRoot
```

- [ ] **Step 4: 校验 YAML 合法 + 无意破坏**

Run:
```bash
cd /Users/rpang/IdeaProjects/k3s
yq eval '.spec.sourceRepos | contains(["https://sigstore.github.io/helm-charts"])' argocd/projects/infrastructure.yaml
yq eval '.spec.destinations[] | select(.namespace == "cosign-system") | .namespace' argocd/projects/infrastructure.yaml
yq eval '.spec.clusterResourceWhitelist[] | select(.group == "policy.sigstore.dev") | .kind' argocd/projects/infrastructure.yaml
```
Expected:
```
true
cosign-system
ClusterImagePolicy
TrustRoot
```

- [ ] **Step 5: Commit**

```bash
git add argocd/projects/infrastructure.yaml
git commit -m "$(cat <<'EOF'
feat(s2-0): infrastructure project 放行 policy-controller

sourceRepos 加 sigstore helm repo; destinations 加 cosign-system ns;
clusterResourceWhitelist 加 policy.sigstore.dev CRD 组(webhook/CRD/
ClusterRole 组已白名单)。S2-0 admission 前置授权。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: policy-controller ArgoCD Application（chart + 目录骨架）

**Files:**
- Create: `apps/infrastructure/policy-controller/application.yaml`
- Create: `apps/infrastructure/policy-controller/kustomization.yaml`

**Interfaces:**
- Consumes: Task 1 的 project 授权。
- Produces: 一个 `argoproj.io/v1alpha1 Application` 名 `policy-controller`，multi-source（Helm chart source pin `0.10.6` + Git `policies/` source），`no-match-policy: allow` + `failurePolicy: Ignore` + leases 镜像 digest pin。ApplicationSet（Task 4）通过 `path: apps/infrastructure/policy-controller` 渲染此目录。

- [ ] **Step 1: 写 Application 清单**

Create `apps/infrastructure/policy-controller/application.yaml`：

```yaml
# Sigstore policy-controller Application（S2-0 cosign-verified digest admission）
#
# 单个 Application，multi-source：
#   source[0] = Helm chart（装 CRD + controller + webhook + config ConfigMap）
#   source[1] = Git policies/（4 个 ClusterImagePolicy，标 sync-wave "2"）
# App 内两阶段 wave：chart 全资源默认 wave 0 → CIP wave 2（CRD established 后才 apply）。
#
# ★S2-0 是 artifact-deployment policy，不解锁签字、非 runtime binding 证明。
# ★信任根单源 .github/image-pin/allowed-images.yaml；CIP 由 verify-cip-sync.sh 守漂移。
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: policy-controller
  namespace: argocd
  annotations:
    # 早于业务 app、晚于核心 infra
    argocd.argoproj.io/sync-wave: "3"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: infrastructure
  sources:
    # ── source[0]：policy-controller Helm chart ──
    - repoURL: https://sigstore.github.io/helm-charts
      chart: policy-controller
      targetRevision: 0.10.6
      helm:
        releaseName: policy-controller
        valuesObject:
          # webhook 故障态放行（首版；达门槛后切 Fail，见 runbook）
          webhookConfig:
            failurePolicy: Ignore
          # ns 内不匹配任何 CIP 的镜像放行（灰度副闸）
          configData:
            no-match-policy: allow
          # leases-cleanup 镜像 digest pin（供应链：默认 latest-dev 可变 tag）
          # ★实现时用 `docker manifest inspect cgr.dev/chainguard/kubectl:latest-dev`
          #   取当前 arm64 digest 填此处；确认含 linux/arm64。
          leasescleanup:
            image:
              # 占位——实现 Step 2 填真实 digest
              name: cgr.dev/chainguard/kubectl@sha256:REPLACE_WITH_PINNED_DIGEST
    # ── source[1]：4 个 ClusterImagePolicy ──
    - repoURL: https://github.com/wontlost-ltd/k3s.git
      targetRevision: main
      path: apps/infrastructure/policy-controller/policies
  destination:
    server: https://kubernetes.default.svc
    namespace: cosign-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: 取 leases-cleanup 镜像的 arm64 digest 并填入**

Run:
```bash
docker manifest inspect cgr.dev/chainguard/kubectl:latest-dev | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print([m['digest'] for m in d['manifests'] if m['platform']['architecture']=='arm64'][0])"
```
把输出的 `sha256:...` 填入 `application.yaml` 的 `leasescleanup.image.name`（替换 `REPLACE_WITH_PINNED_DIGEST`）。
★若 chart 0.10.6 的 leases 镜像 value 键名不是 `leasescleanup.image.name`，先 `helm show values sigstore/policy-controller --version 0.10.6 | grep -iA3 lease` 确认真实键路径，用真实键。若 chart 无该 value 覆盖点，改为在 runbook 记录为「接受的残余供应链风险」并删掉此 valuesObject 段（勿留占位 digest）。

- [ ] **Step 3: 写目录 kustomization**

Create `apps/infrastructure/policy-controller/kustomization.yaml`：

```yaml
# ApplicationSet path 渲染入口：只声明 Application CR 本身。
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - application.yaml
```

- [ ] **Step 4: 校验 Application YAML 合法 + kustomize 渲染**

Run:
```bash
cd /Users/rpang/IdeaProjects/k3s
yq eval '.spec.sources | length' apps/infrastructure/policy-controller/application.yaml
yq eval '.spec.sources[0].targetRevision' apps/infrastructure/policy-controller/application.yaml
yq eval '.spec.sources[0].helm.valuesObject.webhookConfig.failurePolicy' apps/infrastructure/policy-controller/application.yaml
yq eval '.spec.sources[0].helm.valuesObject.configData."no-match-policy"' apps/infrastructure/policy-controller/application.yaml
kubectl kustomize apps/infrastructure/policy-controller/ | yq eval '.kind' -
```
Expected:
```
2
0.10.6
Ignore
allow
Application
```
★确认 `application.yaml` 里 leases 镜像不含 `REPLACE_WITH_PINNED_DIGEST` 占位（Step 2 已填真 digest，或已删该段）。

- [ ] **Step 5: Commit**

```bash
git add apps/infrastructure/policy-controller/application.yaml apps/infrastructure/policy-controller/kustomization.yaml
git commit -m "$(cat <<'EOF'
feat(s2-0): policy-controller ArgoCD Application(chart+骨架)

multi-source Application: Helm chart 0.10.6(failurePolicy:Ignore +
no-match-policy:allow + leases 镜像 digest pin) + Git policies/。
两阶段 wave: chart 默认 wave 0 → CIP wave 2。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: 4 个 ClusterImagePolicy + policies kustomization

**Files:**
- Create: `apps/infrastructure/policy-controller/policies/cluster-image-policy-aster-api.yaml`
- Create: `apps/infrastructure/policy-controller/policies/cluster-image-policy-aster-api-reject-tag.yaml`
- Create: `apps/infrastructure/policy-controller/policies/cluster-image-policy-aster-cloud-migrate.yaml`
- Create: `apps/infrastructure/policy-controller/policies/cluster-image-policy-aster-cloud-migrate-reject-tag.yaml`
- Create: `apps/infrastructure/policy-controller/policies/kustomization.yaml`

**Interfaces:**
- Consumes: Task 2 的 Application `source[1]` 指向本 `policies/` 目录。
- Produces: 4 个 `policy.sigstore.dev/v1beta1 ClusterImagePolicy`，全标 `sync-wave: "2"`、`mode: enforce`。digest-verify CIP 的 `metadata.name` = `wontlost-aster-api` / `wontlost-aster-cloud-migrate`；tag-fail CIP = `wontlost-aster-api-reject-tag` / `wontlost-aster-cloud-migrate-reject-tag`。Task 5 的守门脚本断言这些精确 name/glob/subject。

- [ ] **Step 1: 写 aster-api digest-verify CIP**

Create `apps/infrastructure/policy-controller/policies/cluster-image-policy-aster-api.yaml`：

```yaml
# digest-verify CIP：aster-api
# 信任根：.github/image-pin/allowed-images.yaml（sourceRepo aster-cloud/aster-api,
#   workflowFile deploy.yml, sourceRef refs/heads/main）。由 verify-cip-sync.sh 守漂移。
# glob @sha256:** 只命中三等价 digest 引用；每仓独立 CIP + 精确 subject 防笛卡尔积交叉授权。
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: wontlost-aster-api
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  images:
    - glob: "index.docker.io/wontlost/aster-api@sha256:**"
  authorities:
    - keyless:
        identities:
          - issuer: https://token.actions.githubusercontent.com
            subject: https://github.com/aster-cloud/aster-api/.github/workflows/deploy.yml@refs/heads/main
  mode: enforce
```

- [ ] **Step 2: 写 aster-api tag-fail CIP**

Create `apps/infrastructure/policy-controller/policies/cluster-image-policy-aster-api-reject-tag.yaml`：

```yaml
# tag-fail CIP：aster-api（闭 unresolved-tag TOCTOU）
# 不可解析 tag → mutation 跳过保留 repo:tag → 命中此 :** glob → static fail 无条件拒。
# 可解析 tag → mutation 变 digest → ref.Name() 丢 tag → 只命中 digest CIP，不命中此。
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: wontlost-aster-api-reject-tag
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  images:
    - glob: "index.docker.io/wontlost/aster-api:**"
  authorities:
    - static:
        action: fail
        message: "受控仓 aster-api 只允许 cosign-verified digest；tag 形式（含不可解析 tag）一律拒绝（S2-0 TOCTOU 闭合）"
  mode: enforce
```

- [ ] **Step 3: 写 migrate digest-verify CIP**

Create `apps/infrastructure/policy-controller/policies/cluster-image-policy-aster-cloud-migrate.yaml`：

```yaml
# digest-verify CIP：aster-cloud-migrate
# 信任根：sourceRepo aster-cloud/aster-cloud, workflowFile ci.yml, sourceRef refs/heads/main。
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: wontlost-aster-cloud-migrate
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  images:
    - glob: "index.docker.io/wontlost/aster-cloud-migrate@sha256:**"
  authorities:
    - keyless:
        identities:
          - issuer: https://token.actions.githubusercontent.com
            subject: https://github.com/aster-cloud/aster-cloud/.github/workflows/ci.yml@refs/heads/main
  mode: enforce
```

- [ ] **Step 4: 写 migrate tag-fail CIP**

Create `apps/infrastructure/policy-controller/policies/cluster-image-policy-aster-cloud-migrate-reject-tag.yaml`：

```yaml
# tag-fail CIP：aster-cloud-migrate（闭 unresolved-tag TOCTOU）
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: wontlost-aster-cloud-migrate-reject-tag
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  images:
    - glob: "index.docker.io/wontlost/aster-cloud-migrate:**"
  authorities:
    - static:
        action: fail
        message: "受控仓 aster-cloud-migrate 只允许 cosign-verified digest；tag 形式一律拒绝（S2-0 TOCTOU 闭合）"
  mode: enforce
```

- [ ] **Step 5: 写 policies kustomization**

Create `apps/infrastructure/policy-controller/policies/kustomization.yaml`：

```yaml
# 4 个 ClusterImagePolicy（2 digest-verify + 2 tag-fail）。
# ★内层 Git source 只指向本目录，不含 application.yaml（防 multi-source 递归认领）。
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cluster-image-policy-aster-api.yaml
  - cluster-image-policy-aster-api-reject-tag.yaml
  - cluster-image-policy-aster-cloud-migrate.yaml
  - cluster-image-policy-aster-cloud-migrate-reject-tag.yaml
```

- [ ] **Step 6: 校验 4 CIP 渲染 + 契约字段**

Run:
```bash
cd /Users/rpang/IdeaProjects/k3s
# 恰 4 个 CIP，全 policy.sigstore.dev/v1beta1 ClusterImagePolicy
kubectl kustomize apps/infrastructure/policy-controller/policies/ | yq eval-all '[.] | length' -
kubectl kustomize apps/infrastructure/policy-controller/policies/ | yq eval '.kind' - | sort -u
# 全 mode: enforce
kubectl kustomize apps/infrastructure/policy-controller/policies/ | yq eval '.spec.mode' - | sort -u
# digest glob 精确
kubectl kustomize apps/infrastructure/policy-controller/policies/ | \
  yq eval 'select(.metadata.name == "wontlost-aster-api") | .spec.images[0].glob' -
```
Expected:
```
4
ClusterImagePolicy
enforce
index.docker.io/wontlost/aster-api@sha256:**
```

- [ ] **Step 7: Commit**

```bash
git add apps/infrastructure/policy-controller/policies/
git commit -m "$(cat <<'EOF'
feat(s2-0): 4 个 ClusterImagePolicy(2 digest-verify + 2 tag-fail)

digest-verify: @sha256:** glob + 精确 keyless subject(每仓独立防笛卡尔积);
tag-fail: :** glob + static:action:fail(闭 unresolved-tag TOCTOU)。全 enforce
+ sync-wave 2。policies/ 独立目录防 multi-source 递归认领。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: 挂入 platform ApplicationSet

**Files:**
- Modify: `argocd/applicationsets/platform.yaml`（`list.elements` @:14-23）

**Interfaces:**
- Consumes: Task 2 的 `apps/infrastructure/policy-controller/` 目录（ApplicationSet `template.spec.source.path` = `apps/infrastructure/{{.name}}`）。
- Produces: ApplicationSet 生成 `platform-policy-controller` Application。

**★注意（Task 2 是 multi-source `sources:`，此 ApplicationSet template 用单 `source:`）**：本 ApplicationSet 的 template 用 `source.path` 渲染目录里的 `application.yaml`——即它部署的是一个**声明式 Application CR**（Task 2 的 `application.yaml` 本身），不是直接部署 chart。故 ApplicationSet 生成 `platform-policy-controller`（app-of-apps 外层），其渲染出 Task 2 的 `policy-controller` Application（内层 multi-source）。这是 repo 既有 app-of-apps 模式，无冲突。

- [ ] **Step 1: 加 policy-controller 元素**

在 `argocd/applicationsets/platform.yaml` 的 `list.elements:` 末尾（`monitoring` 元素之后，`:23` 后）追加：

```yaml
          # S2-0: cosign-verified digest admission（policy-controller）
          - name: policy-controller
            namespace: cosign-system
```

- [ ] **Step 2: 校验**

Run:
```bash
cd /Users/rpang/IdeaProjects/k3s
yq eval '.spec.generators[0].list.elements[] | select(.name == "policy-controller") | .namespace' argocd/applicationsets/platform.yaml
```
Expected:
```
cosign-system
```

- [ ] **Step 3: Commit**

```bash
git add argocd/applicationsets/platform.yaml
git commit -m "$(cat <<'EOF'
feat(s2-0): platform ApplicationSet 挂入 policy-controller

list.elements 加 policy-controller/cosign-system。ApplicationSet 生成
platform-policy-controller → 渲染 apps/infrastructure/policy-controller/。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: verify-cip-sync.sh 守门脚本（四 CIP 契约漂移）

**Files:**
- Create: `scripts/image-pin/verify-cip-sync.sh`
- Test: 脚本自带内联自测（对真 CIP 文件跑 + 对篡改副本跑）

**Interfaces:**
- Consumes: `.github/image-pin/allowed-images.yaml`（信任根）+ Task 3 的 4 个 CIP 文件。
- Produces: 可执行脚本，退出码 0 = 契约一致，非 0 = 漂移。可挂 CI（后续 workflow PR，本 plan 不含）。

**契约（脚本必须断言，来自 design §7）**：
1. 信任根每个 repository 恰有 1 个 digest-verify CIP + 1 个 tag-fail CIP（N 仓 → 2N CIP，不多不少）。
2. digest-verify CIP：`images` 恰 1 项、glob == `index.docker.io/<repo>@sha256:**`；`authorities` 恰 1 项、`keyless.identities` 恰 1 项、issuer/subject == `allowed-images.yaml` 派生值；无额外 identity。
3. tag-fail CIP：`images` 恰 1 项、glob == `index.docker.io/<repo>:**`；`authorities` 恰 1 项、唯一 authority 为 `static.action == fail`。
4. 4 份全 `mode: enforce`。

- [ ] **Step 1: 写脚本**

Create `scripts/image-pin/verify-cip-sync.sh`：

```bash
#!/usr/bin/env bash
# 守 S2-0 的 4 个 ClusterImagePolicy 与信任根 allowed-images.yaml 的契约一致性。
#
# 契约（见 docs/p0a-s2-0-cosign-admission-design.md §7）：
#   - 信任根每 repository 恰 1 digest-verify CIP + 1 tag-fail CIP（N 仓 → 2N CIP）。
#   - digest-verify：glob index.docker.io/<repo>@sha256:**；keyless issuer/subject
#     == allowed-images 派生值；images/authorities/keyless.identities 各恰 1 项。
#   - tag-fail：glob index.docker.io/<repo>:**；唯一 authority static.action==fail。
#   - 4 份全 mode: enforce。
#
# 退出 0 = 一致；非 0 = 漂移（打印具体项）。依赖 yq。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWED="${ALLOWED_IMAGES_FILE:-$REPO_ROOT/.github/image-pin/allowed-images.yaml}"
CIP_DIR="${CIP_DIR:-$REPO_ROOT/apps/infrastructure/policy-controller/policies}"
ISSUER="https://token.actions.githubusercontent.com"

fail() { echo "CIP-DRIFT: $*" >&2; exit 1; }

command -v yq >/dev/null || fail "yq 未安装"
[[ -f "$ALLOWED" ]] || fail "信任根不存在: $ALLOWED"
[[ -d "$CIP_DIR" ]] || fail "CIP 目录不存在: $CIP_DIR"

# 校验信任根 issuer 常量
allowed_issuer="$(yq eval '.oidcIssuer' "$ALLOWED")"
[[ "$allowed_issuer" == "$ISSUER" ]] || fail "allowed-images oidcIssuer 非预期: $allowed_issuer"

# 收集所有 CIP（跨全部文件）到临时汇总
mapfile -t CIP_FILES < <(find "$CIP_DIR" -name 'cluster-image-policy-*.yaml' | sort)
[[ ${#CIP_FILES[@]} -gt 0 ]] || fail "未找到任何 CIP 文件"

# 每个 repository 走一遍
repo_count="$(yq eval '.images | length' "$ALLOWED")"
expected_cip=$(( repo_count * 2 ))
actual_cip=${#CIP_FILES[@]}
[[ "$actual_cip" -eq "$expected_cip" ]] || fail "CIP 数量=$actual_cip，期望 2×$repo_count=$expected_cip（N 仓→2N CIP）"

# 提取某 name 的 CIP 文件（在所有文件里找）
cip_field() { # $1=name $2=yq-path
  local name="$1" path="$2" f
  for f in "${CIP_FILES[@]}"; do
    if [[ "$(yq eval '.metadata.name' "$f")" == "$name" ]]; then
      yq eval "$path" "$f"; return 0
    fi
  done
  echo "__MISSING__"
}

i=0
while [[ $i -lt $repo_count ]]; do
  image="$(yq eval ".images[$i].image" "$ALLOWED")"          # docker.io/wontlost/aster-api
  src_repo="$(yq eval ".images[$i].sourceRepo" "$ALLOWED")"  # aster-cloud/aster-api
  wf="$(yq eval ".images[$i].workflowFile" "$ALLOWED")"      # deploy.yml
  ref="$(yq eval ".images[$i].sourceRef" "$ALLOWED")"        # refs/heads/main
  repo="${image#docker.io/}"                                  # wontlost/aster-api
  slug="${repo#wontlost/}"                                    # aster-api
  norm="index.docker.io/${repo}"
  expected_subject="https://github.com/${src_repo}/.github/workflows/${wf}@${ref}"

  dv="wontlost-${slug}"
  tf="wontlost-${slug}-reject-tag"

  # ── digest-verify CIP ──
  [[ "$(cip_field "$dv" '.spec.images | length')" == "1" ]]        || fail "$dv images 非恰 1 项"
  [[ "$(cip_field "$dv" '.spec.images[0].glob')" == "${norm}@sha256:**" ]] || fail "$dv glob 漂移"
  [[ "$(cip_field "$dv" '.spec.authorities | length')" == "1" ]]   || fail "$dv authorities 非恰 1 项"
  [[ "$(cip_field "$dv" '.spec.authorities[0].keyless.identities | length')" == "1" ]] || fail "$dv keyless.identities 非恰 1 项(防 OR 扩权)"
  [[ "$(cip_field "$dv" '.spec.authorities[0].keyless.identities[0].issuer')" == "$ISSUER" ]] || fail "$dv issuer 漂移"
  [[ "$(cip_field "$dv" '.spec.authorities[0].keyless.identities[0].subject')" == "$expected_subject" ]] || fail "$dv subject 漂移（期望 $expected_subject）"
  [[ "$(cip_field "$dv" '.spec.mode')" == "enforce" ]]            || fail "$dv 非 enforce"

  # ── tag-fail CIP ──
  [[ "$(cip_field "$tf" '.spec.images | length')" == "1" ]]        || fail "$tf images 非恰 1 项"
  [[ "$(cip_field "$tf" '.spec.images[0].glob')" == "${norm}:**" ]] || fail "$tf glob 漂移"
  [[ "$(cip_field "$tf" '.spec.authorities | length')" == "1" ]]   || fail "$tf authorities 非恰 1 项"
  [[ "$(cip_field "$tf" '.spec.authorities[0].static.action')" == "fail" ]] || fail "$tf static.action 非 fail"
  [[ "$(cip_field "$tf" '.spec.mode')" == "enforce" ]]            || fail "$tf 非 enforce"

  i=$(( i + 1 ))
done

echo "CIP-SYNC OK: ${actual_cip} 个 CIP 与信任根 ${repo_count} 仓契约一致"
```

- [ ] **Step 2: 加执行权限 + 对真 CIP 跑（应通过）**

Run:
```bash
cd /Users/rpang/IdeaProjects/k3s
chmod +x scripts/image-pin/verify-cip-sync.sh
./scripts/image-pin/verify-cip-sync.sh
echo "exit=$?"
```
Expected:
```
CIP-SYNC OK: 4 个 CIP 与信任根 2 仓契约一致
exit=0
```

- [ ] **Step 3: 篡改副本验证守门（应报错，退出非 0）**

Run（复制到临时目录、篡改一个 subject、跑应失败）：
```bash
cd /Users/rpang/IdeaProjects/k3s
TMP="$(mktemp -d)"
cp apps/infrastructure/policy-controller/policies/cluster-image-policy-*.yaml "$TMP/"
# 篡改 aster-api digest CIP 的 subject（模拟身份漂移）
yq eval -i '.spec.authorities[0].keyless.identities[0].subject = "https://github.com/evil/repo/.github/workflows/x.yml@refs/heads/main"' "$TMP/cluster-image-policy-aster-api.yaml"
CIP_DIR="$TMP" ./scripts/image-pin/verify-cip-sync.sh; echo "exit=$?"
rm -rf "$TMP"
```
Expected:
```
CIP-DRIFT: wontlost-aster-api subject 漂移（期望 ...）
exit=1
```

- [ ] **Step 4: 篡改验证 tag-fail 缺失守门（删一个 tag-fail CIP，应报数量错）**

Run:
```bash
cd /Users/rpang/IdeaProjects/k3s
TMP="$(mktemp -d)"
cp apps/infrastructure/policy-controller/policies/cluster-image-policy-*.yaml "$TMP/"
rm "$TMP/cluster-image-policy-aster-api-reject-tag.yaml"   # 模拟 tag-fail 被误删
CIP_DIR="$TMP" ./scripts/image-pin/verify-cip-sync.sh; echo "exit=$?"
rm -rf "$TMP"
```
Expected:
```
CIP-DRIFT: CIP 数量=3，期望 2×2=4（N 仓→2N CIP）
exit=1
```

- [ ] **Step 5: Commit**

```bash
git add scripts/image-pin/verify-cip-sync.sh
git commit -m "$(cat <<'EOF'
feat(s2-0): verify-cip-sync.sh 守四 CIP 契约漂移

断言 N 仓→2N CIP、digest glob @sha256:**、keyless identity 单项防 OR 扩权、
subject==allowed-images 派生、tag-fail static:action:fail、全 enforce。
自测: 篡改 subject/删 tag-fail 均触发报错退出非 0。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: 运维手册 + 全量 kustomize 校验

**Files:**
- Create: `docs/POLICY_CONTROLLER_RUNBOOK.md`
- Test: 全量 `kubectl kustomize` 渲染无错

**Interfaces:**
- Consumes: Task 1-5 全部产物。
- Produces: 运维手册（贴/摘标签、切 failurePolicy、卸载顺序、标签监控、staging e2e 清单）。

- [ ] **Step 1: 写运维手册**

Create `docs/POLICY_CONTROLLER_RUNBOOK.md`：

```markdown
# policy-controller（S2-0 cosign admission）运维手册

设计：`docs/p0a-s2-0-cosign-admission-design.md`。★S2-0 是 artifact-deployment
policy，**不解锁签字、非 runtime binding 证明**。

## 启用（贴 namespace 标签 = opt-in 主闸）

policy-controller 只拦贴 `policy.sigstore.dev/include=true` 的 namespace。首版只启用 aster-cloud：

    kubectl label namespace aster-cloud policy.sigstore.dev/include=true

★**贴标签前先过 admission smoke-test**（确认 apiserver 能调 webhook；wave 健康门只保证 CRD established + controller Deployment Ready，不保证 webhook 端到端可调）：

    # 在 aster-cloud 提交一个已知已签 digest 的临时 pod，确认放行；提交未签的，确认被拒（enforce）。

## 标签监控（★手工标签的静默失效风险）

namespace 重建后标签消失 → S2-0 静默关闭。必须配告警：

    # 定期断言标签存在，缺失即告警（示例，接入现有 Prometheus/alert）：
    kubectl get ns aster-cloud -o jsonpath='{.metadata.labels.policy\.sigstore\.dev/include}' | grep -q true \
      || echo "ALERT: aster-cloud 缺 policy.sigstore.dev/include 标签，S2-0 已静默关闭"

## failurePolicy 阶段化（首版 Ignore → 达门槛切 Fail）

首版 `webhookConfig.failurePolicy: Ignore`（webhook 故障时放行，避免 outage；但故障期未签镜像会被静默放行 → 依赖 webhook 可用性告警）。

切 `Fail`（故障态也 fail-closed）的门槛：连续观察 ≥7 天 + webhook 可用率 ≥99.9% + admission p99 延迟/错误率在阈内 + 告警演练成功 + break-glass 演练成功。改 `application.yaml` 的 `webhookConfig.failurePolicy: Fail` 并 sync。

## Break-glass 回滚（顺序严格）

1. **摘 opt-in 标签**（唯一 outage-无关的可靠 break-glass，秒级）：

       kubectl label namespace aster-cloud policy.sigstore.dev/include-

2. **临时把两类 webhook 的 failurePolicy 改 Ignore，或删 4 个 webhook config**（chart 出 2 Validating + 2 Mutating；tag→digest 靠 Mutating）——删 backend 前先解除 fail-closed。
3. 从 ApplicationSet/Git 移除 policy-controller 元素或暂停自动同步（否则 selfHeal 重建）。
4. 删 controller、4 个 CIP、2 个 CRD（`clusterimagepolicies` / `trustroots`）。
5. 验证无残留 Validating/Mutating WebhookConfiguration。

★危险点：直接删 Application 时若 Deployment/Service 先于 webhook config 被删、webhook 仍 Fail → 新 admission outage。故顺序 2（含 Mutating）必在 3/4 前。

## staging 动态门清单（本地做不了，上线前必跑）

- 真 Fulcio OIDC 跨身份 fixture 负测（ci.yml 身份签 aster-api → 被拒）。
- webhook 端到端 admission smoke-test（apiserver→webhook TLS/endpoint/网络）。
- tag 四态：已签可解析 tag 通过 / 未签可解析 tag 被拒 / 不可解析 tag → tag-fail 拒 / mutation 后 digest 不命中 tag-fail。
- 绕过面：Pod/Deployment/Job/CronJob/StatefulSet/DaemonSet/init container/ephemeral container（`kubectl debug --image=<未签受控仓镜像>`）全被拦。
- wave 0→2 真 ArgoCD sync（CRD established 后才 apply CIP）。
- 回滚演练（按上面顺序，无级联 outage）。

## 信任根漂移守门

改信任根或 CIP 后跑：`./scripts/image-pin/verify-cip-sync.sh`（应 exit 0）。建议接 CI。
```

- [ ] **Step 2: 全量 kustomize 渲染校验（4 CIP + Application）**

Run:
```bash
cd /Users/rpang/IdeaProjects/k3s
# Application 目录（外层）
kubectl kustomize apps/infrastructure/policy-controller/ >/dev/null && echo "application dir OK"
# policies 目录（内层，恰 4 CIP）
test "$(kubectl kustomize apps/infrastructure/policy-controller/policies/ | yq eval-all '[.] | length' -)" = "4" && echo "policies dir 4 CIP OK"
# 守门脚本仍绿
./scripts/image-pin/verify-cip-sync.sh
```
Expected:
```
application dir OK
policies dir 4 CIP OK
CIP-SYNC OK: 4 个 CIP 与信任根 2 仓契约一致
```

- [ ] **Step 3: Commit**

```bash
git add docs/POLICY_CONTROLLER_RUNBOOK.md
git commit -m "$(cat <<'EOF'
docs(s2-0): policy-controller 运维手册

贴/摘标签 opt-in、标签监控告警、failurePolicy 阶段化门槛、break-glass
卸载顺序(覆盖 2 Validating+2 Mutating webhook)、staging 动态门清单。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: 交叉审查 + PR（禁止自审）

**Files:** 无新增（汇总审查）。

- [ ] **Step 1: 全量本地验证复跑**

Run:
```bash
cd /Users/rpang/IdeaProjects/k3s
./scripts/image-pin/verify-cip-sync.sh
(cd scripts/image-pin/testdata/globcheck && go test ./...)
kubectl kustomize apps/infrastructure/policy-controller/ >/dev/null && echo "app OK"
kubectl kustomize apps/infrastructure/policy-controller/policies/ >/dev/null && echo "policies OK"
# 确认 application.yaml 无占位 digest
! grep -q REPLACE_WITH_PINNED_DIGEST apps/infrastructure/policy-controller/application.yaml && echo "no placeholder digest"
```
Expected: 全绿 + `no placeholder digest`。

- [ ] **Step 2: Codex 交叉审查（禁止自审）**

把全部改动（4 CIP + Application + ApplicationSet + project + 守门脚本 + runbook）交 Codex 审。审查重点：CIP glob/subject 与信任根一致、tag-fail 闭 TOCTOU、multi-source 目录不递归、project 授权最小、failurePolicy/no-match value 正确、arm64、无占位、诚实边界（不称解锁签字）。决策规则：≥90 且「建议通过」→ 合；<80「退回」→ 修；80-89 仔细审。

- [ ] **Step 3: 开 PR（用户确认后）**

```bash
cd /Users/rpang/IdeaProjects/k3s
git push -u origin p0a-s2-0-cosign-admission
gh pr create --title "feat(s2-0): cosign-verified digest 运行时 admission" --body "$(cat <<'EOF'
## S2-0：运行时 admission 强制 cosign-verified digest

补 digest-pin epic 的运行时验签缺口。Sigstore policy-controller（keyless
GitHub OIDC）在 pod admission 强制 aster-cloud ns 内受控两仓只跑 verified digest。

- 4 CIP（2 digest-verify + 2 tag-fail 闭 TOCTOU）
- 单 Application 两阶段 wave 0→2；灰度 namespace opt-in + no-match-policy:allow
- 首版 failurePolicy:Ignore；verify-cip-sync.sh 守四 CIP 契约
- ★不解锁签字、非 runtime binding；是 S2-1 必要控制之一

设计：docs/p0a-s2-0-cosign-admission-design.md（Codex 7 轮审 93/100）。
staging 动态门见 docs/POLICY_CONTROLLER_RUNBOOK.md。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review（对照 design spec）

**Spec coverage**：
- §2 选型（policy-controller/keyless/灰度/arm64）→ Task 2 valuesObject + Task 3 CIP。✓
- §3 组件清单（Application/2 CIP 文件→4、ApplicationSet、project）→ Task 1/2/3/4。✓
- §3b 单 App 两阶段 wave 0→2 + 目录结构防递归 → Task 2/3。✓
- §4 灰度双闸 + failurePolicy 阶段化 + 卸载顺序 → Task 2 valuesObject + Task 6 runbook。✓
- §5 信任根一致性 + verify-cip-sync 四 CIP 契约 → Task 5。✓
- §6 glob @sha256:** + TOCTOU tag-fail → Task 3 + 已存在 globcheck 测试（Task 7 复跑）。✓
- §7 绕过面/tag 四态/跨身份 fixture → Task 6 runbook staging 清单（本地不可做，诚实留 staging）。✓

**Placeholder scan**：Task 2 有一个受控占位 `REPLACE_WITH_PINNED_DIGEST`，但 Step 2 给出取真值命令 + Step 4/Task 7 断言无占位残留 → 非交付占位。✓

**Type consistency**：CIP `metadata.name`（`wontlost-aster-api` / `-reject-tag` 等）在 Task 3 定义、Task 5 脚本 `dv`/`tf` 变量按同规则派生、Task 6 卸载引用一致。glob 形式（`@sha256:**` / `:**`）三处一致。✓
