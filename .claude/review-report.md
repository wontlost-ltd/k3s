# k3s GitOps 评审报告
日期：2025-12-14 23:47 NZST（Codex）

- **总体评分**：78 / 100
- **技术质量评估**：App-of-Apps 体系（`argocd/self` → `argocd-config` → ApplicationSets → apps/*）保持一致性，kustomization 现已仅输出 Application 资源，sync-wave 覆盖主要依赖，但空目录与额外嵌套层仍让聚合应用缺少可观测信号。
- **安全性评估**：基础设施 AppProject 已允许所有必需 Helm/Git 源（`argocd/projects/infrastructure.yaml:8-23`），Vault/ESO 的 TLS 信任链也在 Git 中描述（`apps/infrastructure/vault/internal-tls.yaml:6-85` + `apps/infrastructure/external-secrets/vault-secretstore.yaml:18-47`），但该项目依旧对目的命名空间与资源类型完全放开（`argocd/projects/infrastructure.yaml:24-31`），且多条密钥链路依赖手工操作，整体安全评分中等。

## 5 层评审
1. **数据结构层**：`argocd/self/argocd-install.yaml:1-23` 与 `argocd/self/argocd-config.yaml:1-24` 构成自托管根，项目/应用集通过 `argocd/kustomization.yaml` 统一下发；`argocd/applicationsets/infrastructure.yaml:10-33` 再按目录生成 `infra-*` 应用，`apps/infrastructure/cert-manager/kustomization.yaml:1-8` 这类 kustomization 仅包含二级 Application，结构清晰无循环依赖。
2. **特殊场景层**：基础设施组件均设置 sync-wave（如 `cert-manager` -10、`cert-manager-config` -8、`reflector` -6、`vault-config` -4、`vault` -2、`external-secrets` 0、`external-secrets-config` 2、`authentik` 4），大大降低 CRD 先后顺序问题；但 Cloudflare API Token、Vault 初始化、Authentik 配置 Secret 仍需人工创建，Argo 无法得知缺失前置条件。
3. **复杂度层**：ApplicationSet 生成的 `infra-*` 应用本身只再创建其他 Application（`argocd/applicationsets/infrastructure.yaml:15-33` + `apps/infrastructure/*/kustomization.yaml`），形成 4 层 App-of-Apps。这样虽可共享模板，但调试链路长、应用健康状态很难定位根因。
4. **破坏性变更层**：AppProject 现已将 Argo 官方仓库列入白名单（`argocd/projects/infrastructure.yaml:14-17`），避免再出现“仓库未授权”错误；不过目的命名空间、clusterResource 与 namespaceResource 仍是 `*`，一旦某个 Helm values 写错就可能影响整个集群，RBAC 控制面尚未细化。
5. **可行性层**：Vault 内部 CA/服务器证书（`apps/infrastructure/vault/internal-tls.yaml:6-85`）与 ESO 信任链（`apps/infrastructure/external-secrets/vault-secretstore.yaml:18-47`）闭环，Ingress/TLS 也由 cert-manager 提供。但 Vault 仍是单副本 file-storage、手动初始化（`apps/infrastructure/vault/application.yaml:24-105`、`apps/infrastructure/vault/README.md:10-85`），加上资源请求偏低、metrics 关闭（`apps/infrastructure/cert-manager/application.yaml:25-55`、`apps/infrastructure/external-secrets/application.yaml:23-65`），生产弹性有限。

## 详细发现
### Critical
- 无。关键链路均已具备基础防护，未发现立即导致集群宕机的设置。

### High
1. **多个核心组件仍需手工 Secret/配置，GitOps 无法闭环**  
   - 证据：Cloudflare Token 仅提供模板需人工 apply（`apps/infrastructure/cert-manager/cloudflare-secret.yaml.template:1-24`）；Authentik 依赖手工创建的 `authentik-secrets`（`apps/infrastructure/authentik/application.yaml:25-35`）；Vault 安装后要人工 init/unseal/配置 auth（`apps/infrastructure/vault/README.md:10-85`）。  
   - 影响：当这些 Secret 缺失时，Argo 只能显示 `OutOfSync/Degraded` 而无法自愈，实际状态与 Git 永远不一致，CI/CD 也无法验证。  
   - 建议：把 Cloudflare、Authentik、Vault bootstrap 移交到 External Secrets 或一次性 Job，并为缺失依赖提供自定义健康检查，确保集群可以自动收敛。
2. **Infrastructure AppProject 对目标集群完全放开，缺乏最小权限边界**  
   - 证据：`argocd/projects/infrastructure.yaml:24-31` 将 `destinations`、`clusterResourceWhitelist`、`namespaceResourceWhitelist` 全部配置为 `*`。  
   - 影响：任何误提交或被接管的基础设施应用都能修改全集群任意资源；一旦 repo 凭证泄露，攻击者即可借 Helm 值覆盖系统命名空间。  
   - 建议：按网络/TLS/身份等职能拆分多个 AppProject，并限制 namespace、group/kind；同时在 Argo RBAC 中仅授予团队对应 project 的权限。

### Medium
1. **空目录也被 ApplicationSet 纳管，生成失败的占位应用**  
   - 证据：`apps/aster-lang/policy` 与 `apps/wontlost/data` 目录仅有 `.gitkeep`，但 `argocd/applicationsets/aster-lang.yaml:10-29` 与 `wontlost.yaml:10-29` 会照样创建 `aster-policy`、`wontlost-data` 应用。  
   - 影响：这些应用永远报错或保持 Unknown，噪声掩盖真实告警，也让自动化验证误判失败。  
   - 建议：在 ApplicationSet generator 中增加 `files: [{path: kustomization.yaml}]` 过滤，或将空目录移出 `apps/*`，待有实现时再新增。
2. **App-of-Apps 层级过深，调试与回滚复杂**  
   - 证据：ApplicationSet 模板（`argocd/applicationsets/infrastructure.yaml:15-33`）只应用到目录中的 Application 清单（例如 `apps/infrastructure/cert-manager/kustomization.yaml:1-8`），最终形成“self → argocd-config → infra-* → 实际 Helm App”的链路。  
   - 影响：任何一层失败都会在 Dashboard 上出现多个 `Degraded`，且必须逐层排查；rollback 也需多次 `sync --prune`，运维成本高。  
   - 建议：对只有单一 Helm 应用的组件（如 reflector、authentik）改用 ApplicationSet 直接实例化 Helm Application；仅在确需拆分 config/helm 时再创建子 Application。

### Low
1. **关键控制面的 observability 与资源冗余不足**  
   - 证据：cert-manager 与 external-secrets 明确关闭 metrics（`apps/infrastructure/cert-manager/application.yaml:25-55`、`apps/infrastructure/external-secrets/application.yaml:23-65`），CPU/Mem 请求依旧是 100m/128Mi 级别；Vault injector 也只有 128Mi（`apps/infrastructure/vault/application.yaml:24-75`）。  
   - 影响：续期高峰或 Vault 大量注入时容易触发 OOM/Throttle，却缺少可观测指标。  
   - 建议：打开 Prometheus Service/ServiceMonitor，参考官方 sizing 将 requests 调整至 250m/512Mi 起步。
2. **Vault 仍为单副本 file storage + 手动解密流程**  
   - 证据：Helm values 固定 `standalone.enabled=true` 且 `dataStorage.storageClass=null`（`apps/infrastructure/vault/application.yaml:53-89`），README 仅记录人工 init/unseal（`apps/infrastructure/vault/README.md:10-38`），无 auto-unseal 或 HA 方案。  
   - 影响：节点重启或 dataDir 损坏会造成长时间不可用，也难以满足生产级 SLA。  
   - 建议：规划 Raft HA（3 个 server pods）、使用 KMS/Transit auto-unseal，并明确 storageClass/backup 流程。

## 与上次评审对比（上一得分：62）
| 关注点 | 上次状态 | 当前状态 | 说明 |
| --- | --- | --- | --- |
| AppProject 允许 Argo 官方仓库 | ❌ 拒绝 `github.com/argoproj/argo-cd.git` | ✅ `argocd/projects/infrastructure.yaml:14-17` 已加入 | 自托管 Application 可以正常同步 |
| ApplicationSet 直接 apply CRD | ❌ Helm/CRD 混在同级目录 | ✅ kustomization 仅输出 Application（`apps/infrastructure/cert-manager/kustomization.yaml:1-8`） | 解决重复管理问题 |
| Sync-wave 顺序 | ⚠️ 仅个别组件设置 | ✅ 全链路设置 -10→4（多文件引用） | 依赖顺序清晰 |
| 秘密/前置依赖自动化 | ⚠️ 需人工 | ⚠️ 仍需人工（Cloudflare/Vault/Authentik） | 仍是最主要差距 |

## 改进建议
1. 使用 External Secrets + Vault/Cloudflare API 自动注入所有前置 Secret，并为缺失场景编写健康检查脚本，保证 GitOps 能独立收敛。
2. 将 Infrastructure AppProject 拆分并限制 namespace/kind/cluster 访问范围，同时在 Argo RBAC 层绑定对应项目组，降低误操作 blast radius。
3. 调整 ApplicationSet 生成规则：空目录不纳管，单实例组件直接由 ApplicationSet 输出 Helm Application，减少一层 `infra-*` 中间应用。
4. 提升 cert-manager、Vault、ESO 的 request/limit 并开启 metrics/ServiceMonitor，建立容量与延迟告警。
5. 为 Vault 规划 HA 与 auto-unseal（Raft + KMS/Transit）并把初始化流程脚本化，让 TLS/ESO 流程在灾难恢复时可重复执行。
