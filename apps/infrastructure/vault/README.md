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

