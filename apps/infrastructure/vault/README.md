# HashiCorp Vault Setup

Vault is deployed in HA mode with Raft storage for high availability.

## Architecture

- **3 replicas** with Raft consensus for HA
- **Internal TLS** using cert-manager certificates
- **External Ingress** at `vault.aster-lang.cloud`
- **Prometheus metrics** enabled

## Prerequisites

1. Storage class available in cluster
2. DNS record for `vault.aster-lang.cloud` pointing to cluster
3. cert-manager installed (for internal TLS)

## Post-Installation Steps

### 1. Initialize Vault (First Time Only)

```bash
# Initialize on the first pod only
kubectl exec -n vault vault-0 -- vault operator init

# IMPORTANT: Save the unseal keys and root token securely!
# Store them in a secure location (password manager, HSM, etc.)
# Example output:
# Unseal Key 1: xxxxx
# Unseal Key 2: xxxxx
# Unseal Key 3: xxxxx
# Unseal Key 4: xxxxx
# Unseal Key 5: xxxxx
# Initial Root Token: hvs.xxxxx
```

### 2. Unseal All Vault Nodes

After initialization, unseal all nodes in the cluster:

```bash
# Unseal vault-0 (need 3 of 5 keys by default)
kubectl exec -n vault vault-0 -- vault operator unseal <UNSEAL_KEY_1>
kubectl exec -n vault vault-0 -- vault operator unseal <UNSEAL_KEY_2>
kubectl exec -n vault vault-0 -- vault operator unseal <UNSEAL_KEY_3>

# Unseal vault-1
kubectl exec -n vault vault-1 -- vault operator unseal <UNSEAL_KEY_1>
kubectl exec -n vault vault-1 -- vault operator unseal <UNSEAL_KEY_2>
kubectl exec -n vault vault-1 -- vault operator unseal <UNSEAL_KEY_3>

# Unseal vault-2
kubectl exec -n vault vault-2 -- vault operator unseal <UNSEAL_KEY_1>
kubectl exec -n vault vault-2 -- vault operator unseal <UNSEAL_KEY_2>
kubectl exec -n vault vault-2 -- vault operator unseal <UNSEAL_KEY_3>
```

### 3. Join Raft Cluster

After unsealing, join the other nodes to the Raft cluster:

```bash
# Check cluster status
kubectl exec -n vault vault-0 -- vault operator raft list-peers

# Nodes should auto-join via retry_join configuration
# If not, manually join:
kubectl exec -n vault vault-1 -- vault operator raft join https://vault-0.vault-internal:8200
kubectl exec -n vault vault-2 -- vault operator raft join https://vault-0.vault-internal:8200
```

### 4. Enable Kubernetes Auth

```bash
# Port forward to Vault
kubectl port-forward -n vault svc/vault 8200:8200 &

# Set environment (use HTTPS since TLS is enabled)
export VAULT_ADDR='https://vault.aster-lang.cloud'
export VAULT_TOKEN='<ROOT_TOKEN>'

# Enable Kubernetes auth method
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443"
```

### 5. Create Secrets Engine

```bash
# Enable KV secrets engine
vault secrets enable -path=secret kv-v2

# Create infrastructure secrets (for ExternalSecrets)

# Cloudflare API token for cert-manager DNS-01 challenge
vault kv put secret/infrastructure/cloudflare api_token="YOUR_CLOUDFLARE_TOKEN"

# Grafana admin credentials
vault kv put secret/infrastructure/grafana \
    admin_user="admin" \
    admin_password="$(openssl rand -base64 24)"

# Authentik credentials (all required fields)
vault kv put secret/infrastructure/authentik \
    secret_key="$(openssl rand -base64 36)" \
    postgresql_host="postgres.wontlost-data.svc.cluster.local" \
    postgresql_port="5432" \
    postgresql_name="authentik" \
    postgresql_user="authentik" \
    postgresql_password="$(openssl rand -base64 24)" \
    redis_password="$(openssl rand -base64 24)" \
    bootstrap_password="$(openssl rand -base64 16)" \
    bootstrap_email="admin@aster-lang.cloud"

# ArgoCD OIDC client secret (for SSO)
vault kv put secret/infrastructure/argocd \
    oidc_client_secret="YOUR_AUTHENTIK_CLIENT_SECRET"

# Monitoring basic auth (htpasswd format for Traefik)
# Generate with: htpasswd -nb admin yourpassword
vault kv put secret/infrastructure/monitoring \
    basic_auth_users="admin:\$apr1\$xxxxx\$xxxxx"
```

### 6. Create Policy for External Secrets

```bash
# Create policy for External Secrets Operator
cat <<EOF | vault policy write external-secrets -
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["list"]
}
EOF

# Create Kubernetes auth role for ESO
vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets \
    ttl=24h
```

## Readiness Verification for Dependencies

Before External Secrets Operator can pull secrets from Vault, verify that Vault is properly initialized and unsealed.

### Quick Health Check

```bash
# Check all Vault pods are ready
kubectl get pods -n vault -l app.kubernetes.io/name=vault

# Verify Vault is unsealed (should show "Sealed: false")
kubectl exec -n vault vault-0 -- vault status | grep -E "^(Initialized|Sealed)"

# Expected output:
# Initialized     true
# Sealed          false
```

### Verify ClusterSecretStore Connection

```bash
# Check if ESO can connect to Vault
kubectl get clustersecretstore vault-backend -o jsonpath='{.status.conditions[0]}' | jq

# Expected output should show "Ready" status
```

### Verify ExternalSecrets are Syncing

```bash
# List all ExternalSecrets and their sync status
kubectl get externalsecrets --all-namespaces

# Check a specific ExternalSecret
kubectl get externalsecret -n cert-manager cloudflare-api-token -o jsonpath='{.status.conditions[*].type}'
```

### Pre-flight Checklist

Before deploying applications that depend on ExternalSecrets:

1. **Vault Initialized**: `vault operator init` has been run
2. **Vault Unsealed**: All 3 nodes show `Sealed: false`
3. **Raft Cluster Healthy**: `vault operator raft list-peers` shows 3 peers
4. **Kubernetes Auth Enabled**: `vault auth list` shows `kubernetes/`
5. **KV Engine Enabled**: `vault secrets list` shows `secret/`
6. **ESO Policy Created**: `vault policy list` shows `external-secrets`
7. **ClusterSecretStore Ready**: `kubectl get clustersecretstore` shows Ready

## Auto-Unseal Options

For production environments, configure auto-unseal to avoid manual intervention:

### Option 1: Google Cloud KMS

```hcl
seal "gcpckms" {
  project     = "your-project"
  region      = "global"
  key_ring    = "vault-keyring"
  crypto_key  = "vault-unseal-key"
}
```

### Option 2: AWS KMS

```hcl
seal "awskms" {
  region     = "us-east-1"
  kms_key_id = "alias/vault-unseal-key"
}
```

### Option 3: Azure Key Vault

```hcl
seal "azurekeyvault" {
  tenant_id  = "your-tenant-id"
  vault_name = "your-vault-name"
  key_name   = "vault-unseal-key"
}
```

To enable auto-unseal, update the Vault Helm values in `application.yaml`.

## Backup and Recovery

### Create Backup

```bash
# Snapshot the Raft storage
kubectl exec -n vault vault-0 -- vault operator raft snapshot save /tmp/vault-backup.snap

# Copy snapshot locally
kubectl cp vault/vault-0:/tmp/vault-backup.snap ./vault-backup-$(date +%Y%m%d).snap
```

### Restore from Backup

```bash
# Copy snapshot to pod
kubectl cp ./vault-backup.snap vault/vault-0:/tmp/vault-backup.snap

# Restore snapshot (WARNING: This will overwrite current data)
kubectl exec -n vault vault-0 -- vault operator raft snapshot restore /tmp/vault-backup.snap
```

## Monitoring

Vault exposes Prometheus metrics at `/v1/sys/metrics`. The ServiceMonitor is configured to scrape these automatically.

Key metrics to watch:
- `vault_core_unsealed` - Unseal status
- `vault_raft_leader` - Raft leader status
- `vault_secret_kv_count` - Number of secrets

## Troubleshooting

### Check Vault Status

```bash
kubectl exec -n vault vault-0 -- vault status
```

### Check Raft Peers

```bash
kubectl exec -n vault vault-0 -- vault operator raft list-peers
```

### View Logs

```bash
kubectl logs -n vault vault-0 -f
```

### Pod Not Starting

1. Check TLS certificates are created:
   ```bash
   kubectl get certificate -n vault
   kubectl get secret vault-internal-tls -n vault
   ```

2. Check PVC is bound:
   ```bash
   kubectl get pvc -n vault
   ```

## Authentik Vault Integration

### Blueprint (for Authentik)

```yaml
# This blueprint creates the OAuth2/OIDC provider and application for Vault
#
# To apply this blueprint:
# 1. Log into Authentik Admin at https://auth.aster-lang.cloud/if/admin/
# 2. Go to System > Blueprints > Create
# 3. Paste this content as "File (yaml)" type
# 4. Or create manually following the steps below
#
# MANUAL SETUP STEPS:
# ===================
#
# Step 1: Create OAuth2 Provider
# - Go to Applications > Providers > Create
# - Select "OAuth2/OpenID Provider"
# - Name: Vault
# - Authorization flow: default-provider-authorization-implicit-consent
# - Client type: Confidential
# - Client ID: vault
# - Client Secret: ****************
# - Redirect URIs:
#     https://vault.aster-lang.cloud/ui/vault/auth/Authentik/oidc/callback
#     http://localhost:8250/oidc/callback
# - Signing Key: authentik Self-signed Certificate
# - Scopes: openid, email, profile
# - Subject mode: Based on the User's hashed ID
#
# Step 2: Create Application
# - Go to Applications > Applications > Create
# - Name: Vault
# - Slug: vault
# - Provider: Vault (created above)
# - Launch URL: https://vault.aster-lang.cloud
#
# Step 3: Create Groups (Optional but recommended)
# - Go to Directory > Groups
# - Create: vault-admins (full admin access to Vault)
# - Create: vault-operators (manage secrets, limited admin)
# - Create: vault-users (read-only access)
#
# ===================
```

> Note: The blueprint block above contains a client secret in plaintext. Treat it as sensitive data — rotate it and store it securely (Vault, secret manager, or similar) before using in production.

### Manual Setup Steps

1. Create the OAuth2/OpenID Provider in Authentik

   - Go to: Applications > Providers > Create
   - Provider type: OAuth2/OpenID Provider
   - Name: Vault
   - Authorization flow: default-provider-authorization-implicit-consent
   - Client type: Confidential
   - Client ID: `vault`
   - Client Secret: (generate a secure secret and store it in Vault or a secret manager)
   - Redirect URIs (add both):

     ```text
     https://vault.aster-lang.cloud/ui/vault/auth/Authentik/oidc/callback
     http://localhost:8250/oidc/callback
     ```

   - Signing Key: authentik Self-signed Certificate
   - Scopes: `openid`, `email`, `profile`
   - Subject mode: Based on the User's hashed ID

2. Create the Application in Authentik

   - Go to: Applications > Applications > Create
   - Name: Vault
   - Slug: `vault`
   - Provider: select the `Vault` provider created above
   - Launch URL: `https://vault.aster-lang.cloud`

3. Create Groups (optional, recommended)

   - Go to: Directory > Groups
   - Create groups with intended privileges:
     - `vault-admins` — full admin access to Vault
     - `vault-operators` — manage secrets and day-to-day operations
     - `vault-users` — read-only access

4. Configure Vault to use Authentik as an OIDC provider

   - In Vault (example):

     ```bash
     vault write auth/oidc/config \
       oidc_discovery_url="https://auth.aster-lang.cloud/if/" \
       oidc_client_id="vault" \
       oidc_client_secret="<YOUR_CLIENT_SECRET>" \
       default_role="vault"
     ```

   - Create an OIDC role mapping Vault policies to Authentik groups/users as needed.


---

## Raft 快照备份（`raft-snapshot.yaml`）

### 为什么需要

**Vault 此前零备份**，而 PG 有完整 PITR（每小时 barman → 同一个 bucket）。
这是最不对称的一处风险：

> 备份做得最好的组件（PG）依赖着备份做得最差的组件（Vault）——
> PG 的密码、TLS 证书都存在 Vault 里。`master-2` 磁盘损坏时，
> PG 备份恢复得出来，但**解不开**。

Vault 的数据在 `local-path` PV 上、绑死 `master-2`（PV nodeAffinity），
单副本、无处漂移。快照是**唯一的兜底**。

### 一次性前置（人工，需 Vault 特权 token）

自动化不能代劳这两步 —— 它们需要能写 policy/auth 的 token，
而那种 token 一旦交给 CronJob，本身就成了新的风险面。

**1. 建只读快照 policy 与 K8s auth role**

```bash
# 用你自己的特权 token 执行（token 不要进任何文件）
vault policy write raft-snapshot - <<'POLICY'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
POLICY

vault write auth/kubernetes/role/raft-snapshot \
  bound_service_account_names=vault-snapshot \
  bound_service_account_namespaces=vault \
  policies=raft-snapshot \
  ttl=10m
```

★该 policy 是**只读单路径**：只能拉快照，不能读任何 secret、不能改配置。
即便 token 泄露，攻击者拿到的是「能备份」而非「能读密钥」。

**2. 建 bucket 凭据 Secret**

```bash
kubectl -n vault create secret generic vault-backup-credentials \
  --from-literal=ACCESS_KEY_ID='<OCI S3 兼容 access key>' \
  --from-literal=SECRET_ACCESS_KEY='<secret>'
```

★用 `create` **不要用 `apply`**：`apply` 会把明文写进
`last-applied-configuration` 注解，等于多存一份可读副本
（本集群的 unseal-keys Secret 曾因此留下 330 字节明文，见 k3s#488）。

### ★凭据来源：已决定**复用** PG 那对 key（2026-09-05）

我最初建议「另建一对 key」，查证后发现该建议考虑不周：

**OCI 每个用户最多只能有 2 把 Customer Secret Key**，而现有的
`postgres-backup-credentials-in-k3s` 已占 1 把。再建一把就用满配额 ——
而轮换的标准做法是「先建新的 → 切换 → 再删旧的」，需要临时占 2 把。
**用满之后 PG 那把也失去轮换空间**，等于用一个隔离换掉两个可轮换性。

三个选项权衡后选了复用：

| | 做法 | 代价 |
|---|---|---|
| **A ★已选** | 复用现有 key | 配额留 1 把余量给轮换；但 PG 备份与 Vault 快照共用凭据 |
| B | 新建第二把 | 隔离达成；但配额用满，两把都失去轮换空间 |
| C | 建专用 IAM 用户 + 独立 key | 真隔离且各自可轮换；但要多维护一个用户/组/policy |

**选 A 的理由**：隔离可以之后再补，而**备份缺口是现在就存在的风险**。
不完美的备份远好于没有备份。

实际操作（值全程在管道里，不落盘、不进任何会话）：

```bash
kubectl -n data-services get secret postgres-backup-credentials -o json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps({
      'apiVersion':'v1','kind':'Secret','type':'Opaque',
      'metadata':{'name':'vault-backup-credentials','namespace':'vault'},
      'data':{k:d['data'][k] for k in ('ACCESS_KEY_ID','SECRET_ACCESS_KEY')}}))" \
  | kubectl create -f -
```

已核验：两键 sha256 与源一致、无 `last-applied-configuration` 注解。

### ⚠️ 遗留风险（已知并接受）

1. **共用凭据**：一把 key 泄露同时影响 PG 备份与 Vault 快照
2. **★key 挂在个人账号下**（`ryan.pang@wontlost.com`）——
   人员变动会直接断掉备份链路。服务凭据不应绑在自然人身上。

★两条都指向同一个正解：**建专用 IAM 服务用户**（上表选项 C）。
建议排期做，届时 PG 与 Vault 各用一把、各自可轮换、且不依赖任何个人账号。

### 验证

```bash
kubectl -n vault create job vault-snap-test --from=cronjob/vault-raft-snapshot
kubectl -n vault logs job/vault-snap-test -c snapshot   # initContainer：取快照
kubectl -n vault logs job/vault-snap-test -c upload     # 主容器：上传+回读校验
```

预期：快照大小 ≥1KiB、远端 ContentLength 与本地一致、Job `succeeded=1`。

### ★恢复演练（尚未做，建议排期）

**备份没验证过恢复 = 不知道有没有备份。**
本条是已知缺口：目前只验证了「能产出快照并上传」，
**未验证「快照能恢复出一个可用的 Vault」**。

恢复大致流程（需独立环境，勿在生产演练）：

```bash
aws --endpoint-url "$S3_ENDPOINT" s3 cp \
  "s3://bucket-backup/vault/vault-raft-<TS>.snap" ./restore.snap
vault operator raft snapshot restore -force ./restore.snap
```

★注意：恢复后的 Vault 仍需用**当时的 unseal key** 解封 ——
快照不含 unseal key。故 unseal key 的保管与快照同等重要。

### ★OCI S3 兼容层不支持 chunked encoding（踩过的坑）

`aws-cli` 1.45+ 默认对 PutObject 计算 checksum，走 chunked encoding，
而 **OCI Object Storage 的 S3 兼容层不支持**：

```
An error occurred (NotImplemented) when calling the PutObject operation:
AWS chunked encoding not supported.
```

★**这条只在真正上传时才暴露** —— 认证、列桶、`head-object` 全部正常，
所以极容易误判成凭据或权限问题，往错误方向排查很久。

修法（已写进清单）：

```yaml
- name: AWS_REQUEST_CHECKSUM_CALCULATION
  value: when_required
- name: AWS_RESPONSE_CHECKSUM_VALIDATION
  value: when_required
```

实测：设置后上传成功且回读 ContentLength 一致（70000 / 70000）。

★**今后任何往 OCI 传对象的 Job 都要带这两个变量。**
（CNPG 的 barman 走的是另一条实现路径，不受影响 —— 所以
「PG 备份能成功」并不能证明 aws-cli 也能成功。）

### 两容器设计的由来

`hashicorp/vault` 镜像**没有** `aws`/`curl`/`openssl`，只有 BusyBox `wget`，
而 BusyBox `wget` 不支持 `--ca-certificate`，无法带内部 CA 调 Vault API。
`alpine/k8s` 镜像有 `aws` 但**没有** `vault` CLI。

故：initContainer 用 vault 取快照 → `emptyDir` → 主容器用 aws 上传。
不自建镜像是因为那要维护一条构建链，收益不抵成本。
