# k3s GitOps 评审报告
日期：2025-12-14 22:39 NZST（Codex）

- **总体评分**：58 / 100
- **技术质量评估**：应用自管理和 GitOps 结构清晰，但 AppProject、ApplicationSet 与组件文件夹之间存在断层，关键基础设施无法被成功部署。
- **安全性评估**：Vault、External Secrets、ArgoCD 多处将 TLS/密钥交互降级为明文和手动操作，缺少系统化的密钥生命周期管理。

## 5 层次审查
- **数据结构层**：`argocd/self → argocd → ApplicationSets → apps/*` 的链路清晰，但 `apps/infrastructure/cert-manager` 的 Kustomize 只输出证书对象，导致 Helm Application 无法被 AppSet 捕获。
- **特殊场景层**：Cloudflare Token、Vault 初始化、证书复制等前提完全依赖人工脚本，没有 Sync Wave 或 Health Check，遇到缺失 Secret 时 ArgoCD 会无限重试。
- **复杂度层**：大量 “App 内再声明 Application” 的双层模式叠加手写 Kustomize，导致调试复杂且不易看出依赖顺序。
- **破坏性变更层**：AppProject 过度收紧 `sourceRepos`，一旦新增 Helm 仓库就会被拒绝，同步中断；Vault 默认 `standalone+file`，切换到 Raft 会与现有 PVC/Ingress 不兼容。
- **可行性层**：cert-manager/external-secrets/authentik/vault 的资源限制均远低于生产需求，且 Vault/ESO 之间是 HTTP，集群中只要有 Pod 可达 `vault` Service 就能窃取 JWT。

## 详细发现（按严重度）
1. **[Critical] AppProject 未授权外部 Helm 仓库，基础设施应用全部被拒绝**  
   - 位置：`argocd/projects/infrastructure.yaml:8-12` 引用的仓库只有 k3s、Traefik、Jetstack、Argo Helm。`vault`、`external-secrets`、`authentik` 分别需要 `https://helm.releases.hashicorp.com`、`https://charts.external-secrets.io`、`https://charts.goauthentik.io`，目前都不在白名单。  
   - 影响：通过 `infrastructure-apps` 生成的所有 Application 在首次 Sync 就会报 `application spec invalid: source repo <...> is not permitted`，即使值文件正确也永远无法部署。  
   - 建议：在 AppProject 中补全所有需要的 chart repo（或在 `sourceRepos` 中添加 `'*'` 并配合严格的 Destination/ClusterResource 白名单），同时在 README 中记录添加新仓库的流程。

2. **[Critical] cert-manager Helm Application 未被 ApplicationSet 渲染，导致控制面永远缺失**  
   - 位置：`argocd/applicationsets/infrastructure.yaml:10-32` 为每个组件指向 `apps/infrastructure/<name>`，而 `apps/infrastructure/cert-manager/kustomization.yaml:11-13` 只包含 `cluster-issuers.yaml` 和 `wildcard-certificates.yaml`。`application.yaml` 与 `config-application.yaml` 没有被 Kustomize 引用。  
   - 影响：`infra-cert-manager` 应用只会下发 Certificate/ClusterIssuer CR，却没有任何资源真正安装 Jetstack Helm Chart；`cert-manager-config` Application 也不会出现。集群内没有 cert-manager 控制器，所有证书同步都会失败。  
   - 建议：拆分目录（例如 `chart/` 与 `config/`），或在 `kustomization.yaml` 的 `resources` 中显式加入 `application.yaml` 与 `config-application.yaml`，确保 AppSet 能渲染 Helm Application；同时给配置 App 设置 `sync-wave`/`dependsOn` 以保证顺序。

3. **[High] Vault 通过 Ingress 对外暴露但服务端强制禁用 TLS，机密数据在集群内部明文传输**  
   - 位置：`apps/infrastructure/vault/application.yaml:17-114` 中 `server.standalone.config` 将 `listener "tcp" { tls_disable = 1 }`，同时 Ingress `vault.aster-lang.cloud` 直接回源 HTTP。  
   - 影响：虽然入口由 Traefik/Let's Encrypt 终止 TLS，但集群内到 Vault Pod 的所有流量（含 Root Token、封印密钥、动态凭证）均为明文，任何能抓取 Node 网络的实体都能窃取。  
   - 建议：开启 Vault TLS（配置 Pod 级证书/自动颁发），或至少启用 mTLS/`tls_disable = 0` 并将 Ingress 以 HTTPS 反向代理；同时考虑用 Raft HA 代替单副本 file storage，提高可用性。

4. **[High] External Secrets 与 Vault 之间同样使用 HTTP，ServiceAccount JWT 暴露**  
   - 位置：`apps/infrastructure/external-secrets/vault-secretstore.yaml:18-39` 指向 `http://vault.vault.svc.cluster.local:8200`，且依赖 Vault `kubernetes` auth。  
   - 影响：ESO 控制器会携带自身 ServiceAccount JWT 调用 Vault，如果任一工作负载能够被诱导访问或嗅探该 Service，则可以窃得 Token 与 Vault session，进一步读取所有密钥。  
   - 建议：启用 Vault TLS 并在 ClusterSecretStore 中配置 `caBundle`/`tlsConfig`；若短期无法启用 TLS，应至少启用 Vault Namespaces/Policies 限制访问范围，并通过 NetworkPolicy 保护 `vault` 服务。

5. **[Medium] Wildcard 证书依赖 EmberStack Reflector，但仓库内没有同一个 GitOps 定义**  
   - 位置：`apps/infrastructure/cert-manager/wildcard-certificates.yaml:27-95` 使用 `reflector.v1.k8s.emberstack.com/*` 注解；`apps/infrastructure/cert-manager/README.md:154-160` 才提到需要手动执行 `helm install reflector ...`。  
   - 影响：在纯 GitOps 环境中并不会安装 Reflector，导致证书 Secret 无法同步至 `argocd/vault/authentik/...`，Ingress TLS 会持续报错。  
   - 建议：把 Reflector 纳入基础设施 ApplicationSet，或改用 cert-manager CSI/External Secrets 等方式同步证书，避免人工步骤。

6. **[Medium] 组件资源限制远低于官方建议，健康检查缺失**  
   - 位置：`apps/infrastructure/cert-manager/application.yaml:22-47`、`apps/infrastructure/external-secrets/application.yaml:23-52`、`apps/infrastructure/authentik/application.yaml:48-82` 均把核心控制器限制在 64~128Mi/100m 范围。  
   - 影响：一旦证书/Secret 数量或并发稍高，Pods 容易 OOM 或被 kubelet 限制 CPU，Argo 会频繁触发自我修复，与 GitOps sync 相互干扰。  
   - 建议：参照各项目官方 `values.yaml` 建议，将 requests/limits 提升到至少 250Mi/500m，并为关键 Deployment 添加 `livenessProbe`/`readinessProbe`，便于 Argo 健康状态评估。

## 改进建议
- 扩展 AppProject 的 `sourceRepos` 并建立统一的 `values` 模板库，减少新增组件时的摩擦。  
- 将 Helm 应用与后置 CRDs 拆分为两个独立目录（或显式记录在 Kustomize 中），并使用 `argocd.argoproj.io/sync-wave`/`dependsOn` 来描述顺序，避免当前的“App 套 App”黑盒。  
- 把 Vault、External Secrets、Reflector、Cloudflare API Token 等依赖全部纳入 GitOps 仓库（Secret 通过 External Secrets / SOPS），并禁止手动 `kubectl apply` 模式。  
- 制定 TLS 策略：控制面全部开启 Pod 内 TLS，Ingress 仅负责对外证书；对 Secret 流转链路补齐审计与 NetworkPolicy。  
- 根据生产负载重新评估资源请求，对关键组件添加监控与告警（可在 Helm values 中开启 Prometheus metrics）。

## Critical Issues
- AppProject 阻止外部 Helm 仓库 → 所有基础设施应用无法同步。  
- cert-manager Helm Application 未被任何 Application 管理 → 集群没有证书控制器。  
- Vault/ESO 明文交互 → 凭证与密钥在集群内可被窃取。
