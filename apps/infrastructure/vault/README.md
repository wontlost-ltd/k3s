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
vault kv put secret/infrastructure/cloudflare api_token="YOUR_CLOUDFLARE_TOKEN"
vault kv put secret/infrastructure/authentik \
    secret_key="$(openssl rand -base64 32)" \
    postgres_password="$(openssl rand -base64 24)"
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
