# k3s GitOps 评审报告
日期：2025-12-14 23:07 NZST（Codex）

- **总体评分**：62 / 100
- **技术质量评估**：App-of-Apps 链路（self → argocd-config → ApplicationSets → apps/*）设计清晰，但组件目录同时包含 Helm 应用、配置 Application 与原生 CRD，导致依赖顺序与所有权管理复杂且易出错。
- **安全性评估**：Vault/External Secrets 在 YAML 中启用了 TLS，但 AppProject 权限放开、前置 Secret 全靠人工以及 Vault 初始化缺乏自动化，使最小权限与密钥生命周期难以落地。

## 5 层次审查
- **数据结构层**：`argocd/applicationsets/infrastructure.yaml:10-33` 直接把 `apps/infrastructure/*` 目录交给 ApplicationSet，同一目录内既有二级 Application 又有 ClusterIssuer/Secret/Issuer，Argo 缺少过滤能力。
- **特殊场景层**：Cloudflare API Token、Vault 内部 TLS、External Secrets 的 Kubernetes Auth 均依赖手工步骤（如 `apps/infrastructure/cert-manager/cluster-issuers.yaml:1-37` 的注释），没有 `dependsOn` 或自动校验，缺项就会永远 OutOfSync。
- **复杂度层**：每个基础设施目录都在同一级别混合 `application.yaml`、`config-application.yaml` 及真实资源，AppSet 一次性 apply 后同一资源由多层 Application 同时管理，调试与回滚路径不透明。
- **破坏性变更层**：`argocd/projects/infrastructure.yaml:8-31` 仅允许特定 source repo 却对 destination/resource 使用 `*`，新增仓库会被拒绝，同步失败；误配置又能修改全集群，缺乏最小权限。
- **可行性层**：Vault TLS 配置与 External Secrets HTTPS 线路（`apps/infrastructure/vault/application.yaml:17-105`、`apps/infrastructure/external-secrets/vault-secretstore.yaml:18-48`）在文件层面齐备，但 Vault 初始化、Cloudflare Token、Authentik Secret 等关键路径仍需人工脚本，GitOps 难以收敛。

## 详细发现
### Critical
1. **AppProject 未允许 ArgoCD 官方仓库，导致自托管 Application 无法落地**
   - 证据：`argocd/self/argocd-install.yaml:8-23` 的 `repoURL` 指向 `https://github.com/argoproj/argo-cd.git`，而 `argocd/projects/infrastructure.yaml:8-22` 的 `sourceRepos` 中缺少该仓库。
   - 影响：`argocd` Application 会被 controller 拒绝（"repository is not permitted"），自管理流程在第一层即失败，后续 ApplicationSet 无法生效。
   - 建议：在基础设施 AppProject 中补充该仓库或采用通配策略，并把新增源仓库的白名单检查纳入 PR/CI。

### High
1. **ApplicationSet 直接 apply 目录，CRD/Secret 在 Helm 安装完成前即被创建**
   - 证据：`argocd/applicationsets/infrastructure.yaml:10-33` 将 `path` 设为整个组件目录，而 `apps/infrastructure/cert-manager/` 同时包含 `cluster-issuers.yaml`、`wildcard-certificates.yaml` 与 `application.yaml`。
   - 影响：`infra-cert-manager` 初次同步就会创建 ClusterIssuer/Certificate，此时 cert-manager 控制器和 CRD 尚不存在，报 "no matches for kind"；之后 `cert-manager-config` Application 再次管理相同资源，造成所有权冲突与重复 sync。
   - 建议：为每个组件新增 `kustomization.yaml` 或拆分子目录，仅向 ApplicationSet 暴露 `*-application.yaml`，其余资源交由配置 Application 管理，并配合 `argocd.argoproj.io/sync-wave` / `dependsOn` 明确顺序。

2. **缺少跨组件波次与依赖，Vault 与 External Secrets 配置在 cert-manager 可用前即被套用**
   - 证据：`apps/infrastructure/vault/internal-tls.yaml:6-85`、`apps/infrastructure/external-secrets/vault-secretstore.yaml:12-48` 均依赖 cert-manager CRD 与 Vault TLS Secret，但 `infra-vault`、`infra-external-secrets` 与 `infra-cert-manager` 之间没有上层波次或 `dependsOn`。
   - 影响：新集群中 Vault TLS Issuer、ClusterSecretStore 会在 cert-manager 准备好之前反复失败，整个 ApplicationSet 卡在 `Degraded` 状态，需要人工多次重试。
   - 建议：在 ApplicationSet 模板中为各组件设置 `argocd.argoproj.io/sync-wave`（例如 cert-manager:-2、Vault TLS:-1、Vault:0、ESO:+1），并使用 Argo 2.4+ 的 `spec.syncPolicy` `dependsOn` 表达跨应用依赖。

### Medium
1. **关键前置 Secret/配置仍靠人工脚本，GitOps 无法自动达成所需状态**
   - 证据：`apps/infrastructure/cert-manager/cluster-issuers.yaml:4-17` 需要手动创建 `cloudflare-api-token`；`apps/infrastructure/authentik/application.yaml:26-33` 要求 `authentik-secrets`；`apps/infrastructure/external-secrets/vault-secretstore.yaml:4-10` 依赖管理员先启用 Vault Kubernetes Auth。
   - 影响：缺失任一前置条件都会让 Application 永远 `OutOfSync/Degraded`，且真实值不在 Git 中，破坏审计闭环。
   - 建议：将这些敏感值迁移到 External Secrets/SOPS，或提供自动 bootstrap Job，并为缺失依赖场景添加 HealthCheck/警示。

2. **Infrastructure AppProject 权限放开到集群级，缺乏最小权限隔离**
   - 证据：`argocd/projects/infrastructure.yaml:24-31` 将 destination namespace、clusterResourceWhitelist、namespaceResourceWhitelist 全部设置为 `*`。
   - 影响：任意误配置的 Application 都能修改所有命名空间与集群资源，错误难以限制在局部。
   - 建议：依据功能域拆分 AppProject（如 networking/security/platform），并限定允许的 namespace/kind，配合 Argo RBAC 提升安全性。

### Low
1. **多个核心组件资源请求偏低且监控关闭，容量规划困难**
   - 证据：cert-manager（`apps/infrastructure/cert-manager/application.yaml:22-47`）与 external-secrets（`apps/infrastructure/external-secrets/application.yaml:23-52`）仅请求 100m/128Mi，Vault injector（`apps/infrastructure/vault/application.yaml:21-45`）上限 256Mi，metrics 亦被关闭。
   - 影响：证书或密钥同步出现峰值时容易 OOM/Throttle，虽然 Argo 会自愈，但续期可能抖动。
   - 建议：参考官方 sizing（≥250m/512Mi）重新设定 requests/limits，并在 Helm values 中开启 Prometheus metrics 便于监控。

## 改进建议
1. 在 `infrastructure` AppProject 补充 ArgoCD 官方 repo，并把新增 source repo 的白名单校验纳入 CI。
2. 为 `apps/infrastructure/*` 补充 `kustomization.yaml` 或拆分子目录，仅由 ApplicationSet 下发二级 Application，使用 `argocd.argoproj.io/sync-wave` 与 `dependsOn` 描述依赖。
3. 将 Cloudflare Token、Vault 初始化、Authentik Secret 等前置步骤 GitOps 化（External Secrets、SOPS、初始化 Job），确保集群可以自动收敛。
4. 重新划分 AppProject 权限边界，限定目的 namespace 与允许的 kind，配合 Argo/RBAC 实现最小权限。
5. 根据真实负载提升 cert-manager、Vault、External Secrets 的资源请求并开启 metrics，配合监控与告警完善容量规划。

## Progress Since Last Review
| Issue | Previous Status | Current Status |
|-------|-----------------|----------------|
| AppProject missing Helm repos | Critical | **Fixed** |
| cert-manager Helm not managed | Critical | **Fixed** |
| Vault/ESO plaintext traffic | Critical | **Fixed** |
| Reflector not in GitOps | Medium | **Fixed** |
| Resource limits too low | Medium | **Partially Fixed** |
| ArgoCD official repo missing | Not identified | **New Critical** |
| Sync wave dependencies | Not identified | **New High** |
