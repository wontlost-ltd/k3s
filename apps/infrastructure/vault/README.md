# HashiCorp Vault Setup

## Prerequisites

1. Storage class available in cluster
2. DNS record for `vault.aster-lang.cloud` pointing to cluster

## Post-Installation Steps

### 1. Initialize Vault (First Time Only)

```bash
# Get vault pod name
VAULT_POD=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

# Initialize Vault
kubectl exec -n vault $VAULT_POD -- vault operator init

# IMPORTANT: Save the unseal keys and root token securely!
# Example output:
# Unseal Key 1: xxxxx
# Unseal Key 2: xxxxx
# Unseal Key 3: xxxxx
# Unseal Key 4: xxxxx
# Unseal Key 5: xxxxx
# Initial Root Token: hvs.xxxxx
```

### 2. Unseal Vault

After initialization or pod restart, Vault needs to be unsealed:

```bash
# Unseal (need 3 of 5 keys by default)
kubectl exec -n vault $VAULT_POD -- vault operator unseal <UNSEAL_KEY_1>
kubectl exec -n vault $VAULT_POD -- vault operator unseal <UNSEAL_KEY_2>
kubectl exec -n vault $VAULT_POD -- vault operator unseal <UNSEAL_KEY_3>
```

### 3. Enable Kubernetes Auth

```bash
# Port forward to Vault
kubectl port-forward -n vault svc/vault 8200:8200 &

# Set environment
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='<ROOT_TOKEN>'

# Enable Kubernetes auth method
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443"
```

### 4. Create Secrets Engine

```bash
# Enable KV secrets engine
vault secrets enable -path=secret kv-v2

# Create a sample secret
vault kv put secret/apps/policy-api \
    database_url="postgresql://user:pass@host:5432/db" \
    api_key="your-api-key"
```

### 5. Create Policy for Applications

```bash
# Create policy file
cat <<EOF | vault policy write policy-api -
path "secret/data/apps/policy-api" {
  capabilities = ["read"]
}
EOF

# Create Kubernetes auth role
vault write auth/kubernetes/role/policy-api \
    bound_service_account_names=policy-api \
    bound_service_account_namespaces=aster-policy \
    policies=policy-api \
    ttl=24h
```

## Using Vault in Applications

### Option 1: Vault Agent Injector (Recommended)

Add annotations to your deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: policy-api
spec:
  template:
    metadata:
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "policy-api"
        vault.hashicorp.com/agent-inject-secret-config: "secret/data/apps/policy-api"
        vault.hashicorp.com/agent-inject-template-config: |
          {{- with secret "secret/data/apps/policy-api" -}}
          export DATABASE_URL="{{ .Data.data.database_url }}"
          export API_KEY="{{ .Data.data.api_key }}"
          {{- end }}
    spec:
      serviceAccountName: policy-api
      containers:
        - name: policy-api
          command: ["/bin/sh", "-c"]
          args: ["source /vault/secrets/config && exec /app/start.sh"]
```

### Option 2: External Secrets Operator

Install External Secrets Operator and create ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: policy-api-secrets
  namespace: aster-policy
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: policy-api-secrets
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: secret/data/apps/policy-api
        property: database_url
```

## Auto-Unseal with Transit (Production)

For production, consider using auto-unseal with cloud KMS or Vault Transit.

## Backup

```bash
# Backup Vault data
kubectl exec -n vault $VAULT_POD -- vault operator raft snapshot save /tmp/vault-backup.snap
kubectl cp vault/$VAULT_POD:/tmp/vault-backup.snap ./vault-backup.snap
```
