# External Secrets Operator

External Secrets Operator (ESO) synchronizes secrets from HashiCorp Vault to Kubernetes Secrets, enabling centralized secrets management.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Secrets Flow                                     │
│                                                                          │
│  ┌──────────────┐     ┌──────────────────┐     ┌──────────────────────┐ │
│  │  HashiCorp   │────►│ External Secrets │────►│  Kubernetes Secret   │ │
│  │    Vault     │     │    Operator      │     │  (auto-generated)    │ │
│  │              │     │                  │     │                      │ │
│  │ secret/data/ │     │ ExternalSecret   │     │ policy-api-secrets   │ │
│  │ apps/policy  │     │ (your manifest)  │     │ (in your namespace)  │ │
│  └──────────────┘     └──────────────────┘     └──────────────────────┘ │
│        ▲                                                │               │
│        │                                                │               │
│        │ Store secrets                                  │ Mount as env  │
│        │ (one time)                                     │ or volume     │
│        │                                                ▼               │
│  ┌──────────────┐                              ┌──────────────────────┐ │
│  │   DevOps     │                              │   Your Application   │ │
│  │   Team       │                              │   (Pod)              │ │
│  └──────────────┘                              └──────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### 1. Vault Must Be Ready

Before using External Secrets, ensure Vault is:
- Initialized and unsealed
- Kubernetes auth method enabled
- KV-v2 secrets engine mounted at `secret/`
- Policy and role configured for external-secrets

### 2. Configure Vault for External Secrets

```bash
# Port forward to Vault
kubectl port-forward -n vault svc/vault 8200:8200 &

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='<ROOT_TOKEN>'

# 1. Enable Kubernetes auth (if not already)
vault auth enable kubernetes

# 2. Configure Kubernetes auth
vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443"

# 3. Create policy for external-secrets
vault policy write external-secrets - <<EOF
# Read all secrets under secret/
path "secret/data/*" {
  capabilities = ["read"]
}

path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

# 4. Create role for external-secrets service account
vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets \
    ttl=1h
```

### 3. Store Secrets in Vault

```bash
# Example: Store Policy API secrets
vault kv put secret/apps/policy-api \
    database_url="postgresql://user:pass@postgres:5432/policy" \
    database_password="super-secret-password" \
    api_key="your-api-key-here" \
    jwt_secret="your-jwt-secret"

# Example: Store Authentik secrets
vault kv put secret/infrastructure/authentik \
    secret_key="$(openssl rand -base64 36)" \
    postgresql_host="postgres.wontlost-data.svc.cluster.local" \
    postgresql_port="5432" \
    postgresql_name="authentik" \
    postgresql_user="authentik" \
    postgresql_password="authentik-db-password" \
    bootstrap_password="admin-initial-password" \
    bootstrap_email="admin@aster-lang.cloud"

# Example: Store shared database credentials
vault kv put secret/infrastructure/postgres \
    host="postgres.wontlost-data.svc.cluster.local" \
    port="5432" \
    username="postgres" \
    password="postgres-admin-password"

# Verify secrets
vault kv get secret/apps/policy-api
```

## Usage

### Basic ExternalSecret

Create an `ExternalSecret` in your application's namespace to sync secrets from Vault:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-secrets
  namespace: my-namespace
spec:
  refreshInterval: 1h                    # How often to sync
  secretStoreRef:
    name: vault-backend                  # Reference to ClusterSecretStore
    kind: ClusterSecretStore
  target:
    name: my-app-secrets                 # Name of K8s Secret to create
    creationPolicy: Owner
  data:
    - secretKey: DATABASE_URL            # Key in K8s Secret
      remoteRef:
        key: apps/my-app                 # Vault path (relative to secret/)
        property: database_url           # Key in Vault secret
```

### Fetch All Keys from Vault Path

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-secrets
  namespace: my-namespace
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: ClusterSecretStore
  target:
    name: my-app-secrets
  dataFrom:
    - extract:
        key: apps/my-app                 # Fetches ALL keys from this path
```

### Sync to Multiple Namespaces (ClusterExternalSecret)

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterExternalSecret
metadata:
  name: shared-db-credentials
spec:
  namespaceSelector:
    matchLabels:
      database-access: "true"            # Sync to namespaces with this label
  refreshTime: 1h
  externalSecretSpec:
    secretStoreRef:
      name: vault-backend
      kind: ClusterSecretStore
    target:
      name: db-credentials
    dataFrom:
      - extract:
          key: infrastructure/postgres
```

Then label namespaces that need the secret:
```bash
kubectl label namespace aster-policy database-access=true
kubectl label namespace authentik database-access=true
```

### Use Secrets in Your Application

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: policy-api
spec:
  template:
    spec:
      containers:
        - name: policy-api
          image: ghcr.io/wontlost-ltd/policy-api:latest
          # Option 1: Environment variables from secret
          envFrom:
            - secretRef:
                name: policy-api-secrets
          # Option 2: Individual environment variables
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: policy-api-secrets
                  key: DATABASE_URL
          # Option 3: Mount as volume
          volumeMounts:
            - name: secrets
              mountPath: /etc/secrets
              readOnly: true
      volumes:
        - name: secrets
          secret:
            secretName: policy-api-secrets
```

## Vault Path Convention

Organize secrets in Vault with a clear hierarchy:

```
secret/
├── apps/                    # Application secrets
│   ├── policy-api/         # Policy API secrets
│   │   ├── database_url
│   │   ├── api_key
│   │   └── jwt_secret
│   ├── web-app/            # Web application secrets
│   └── ...
├── infrastructure/          # Infrastructure secrets
│   ├── authentik/          # Authentik SSO secrets
│   ├── postgres/           # Shared database credentials
│   ├── redis/              # Redis credentials
│   └── ...
└── domains/                 # Domain-specific secrets (optional)
    ├── aster-lang/
    ├── wontlost/
    └── ezymeta/
```

## Verification

### Check External Secrets Operator

```bash
# Check ESO pods
kubectl get pods -n external-secrets

# Check ClusterSecretStore
kubectl get clustersecretstores
kubectl describe clustersecretstore vault-backend

# Check ExternalSecrets
kubectl get externalsecrets -A
kubectl describe externalsecret my-app-secrets -n my-namespace
```

### Check Synced Secrets

```bash
# List secrets created by ESO
kubectl get secrets -A -l "reconcile.external-secrets.io/created-by"

# Check specific secret
kubectl get secret policy-api-secrets -n aster-policy -o yaml

# Decode secret value
kubectl get secret policy-api-secrets -n aster-policy -o jsonpath='{.data.DATABASE_URL}' | base64 -d
```

## Troubleshooting

### ExternalSecret Status "SecretSyncedError"

```bash
# Check ExternalSecret events
kubectl describe externalsecret <name> -n <namespace>

# Common causes:
# 1. Vault path doesn't exist
# 2. Missing Vault permissions
# 3. Vault is sealed
# 4. ClusterSecretStore not ready
```

### ClusterSecretStore Not Ready

```bash
# Check status
kubectl describe clustersecretstore vault-backend

# Check ESO controller logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=100

# Common causes:
# 1. Vault service not reachable
# 2. Kubernetes auth not configured in Vault
# 3. Service account doesn't have correct role
```

### Vault Authentication Failed

```bash
# Verify Vault role exists
vault read auth/kubernetes/role/external-secrets

# Verify policy
vault policy read external-secrets

# Test manually from ESO pod (using HTTPS)
kubectl exec -it -n external-secrets deploy/external-secrets -- sh
# Inside pod:
# curl -k https://vault.vault.svc.cluster.local:8200/v1/sys/health
```

### TLS Certificate Issues

```bash
# Check Vault internal CA certificate
kubectl get secret -n vault vault-internal-ca -o jsonpath='{.data.ca\.crt}' | base64 -d

# Check Vault server certificate
kubectl get secret -n vault vault-internal-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout

# Verify certificate issuers are ready
kubectl get issuers -n vault
kubectl get certificates -n vault
```

## Security Best Practices

1. **Least Privilege**: Create specific policies for each application instead of using a global read policy
2. **Rotation**: Set appropriate `refreshInterval` (1h default) to pick up rotated secrets
3. **Audit**: Enable Vault audit logging to track secret access
4. **Namespaces**: Use `ClusterExternalSecret` sparingly; prefer per-namespace `ExternalSecret`

## Migration from Manual Secrets

To migrate from manually created secrets to External Secrets:

1. Store current secret values in Vault
2. Create ExternalSecret pointing to Vault path
3. Update deployments to use the new secret name (if different)
4. Delete old manual secret after verification

```bash
# Example: Migrate authentik-secrets
# 1. Get current secret values
kubectl get secret authentik-secrets -n authentik -o yaml

# 2. Store in Vault (see above)

# 3. Create ExternalSecret (use examples/authentik-secret.yaml.example)

# 4. Verify new secret is created
kubectl get secret authentik-secrets -n authentik

# 5. Restart pods to pick up new secret
kubectl rollout restart deployment -n authentik
```

## Examples

See the `examples/` directory for ready-to-use ExternalSecret templates:

- `policy-api-secret.yaml.example` - Application secrets
- `authentik-secret.yaml.example` - Infrastructure secrets
- `database-credentials.yaml.example` - Shared secrets across namespaces
