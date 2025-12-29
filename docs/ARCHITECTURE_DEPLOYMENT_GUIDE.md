# K3s GitOps Architecture Deployment Guide

## Overview

This document provides a comprehensive guide to deploying the K3s GitOps architecture from scratch, including migrating from an existing manually-managed cluster to a self-managed ArgoCD app-of-apps pattern.

### Architecture Summary

```
                                    +------------------+
                                    |   GitHub Repo    |
                                    |  wontlost-ltd/k3s|
                                    +--------+---------+
                                             |
                                             v
                              +-----------------------------+
                              |         ArgoCD              |
                              |    (Self-Managed via        |
                              |     App-of-Apps Pattern)    |
                              +-------------+---------------+
                                            |
              +-----------------------------+-----------------------------+
              |                             |                             |
              v                             v                             v
    +------------------+          +------------------+          +------------------+
    | Infrastructure   |          | Secrets Mgmt     |          | Business Apps    |
    | Project          |          | Project          |          | Projects         |
    +------------------+          +------------------+          +------------------+
    | - cert-manager   |          | - vault          |          | - aster-policy   |
    | - cloudnative-pg |          | - external-secrets|         | - wontlost-data  |
    | - monitoring     |          +------------------+          +------------------+
    | - authentik      |
    | - shared-redis   |
    | - kube-system    |
    | - reflector      |
    | - bootstrap      |
    +------------------+
```

### Target Namespace Structure

| Namespace | Purpose | Components |
|-----------|---------|------------|
| `argocd` | GitOps orchestration | ArgoCD (self-managed), Ingress |
| `vault` | Secrets storage | HashiCorp Vault (HA) |
| `external-secrets` | Secrets sync | External Secrets Operator |
| `cert-manager` | TLS certificates | cert-manager, ClusterIssuers |
| `authentik` | Identity/SSO | Authentik Server, Worker |
| `monitoring` | Observability | Prometheus, Grafana, Alertmanager |
| `data-services` | Shared databases | PostgreSQL (CloudNativePG), Redis |
| `cnpg-system` | DB operator | CloudNativePG operator |
| `reflector` | Secret replication | Reflector |
| `kube-system` | K3s core | CoreDNS, Traefik, metrics-server |
| `aster-policy` | Business app | Policy API |
| `wontlost-data` | Business app | Data Service |

---

## Phase 0: Pre-requisites and Planning

### 0.1 Infrastructure Requirements

- **K3s Cluster**: v1.28+ with 3+ nodes (HA recommended)
- **Storage**: Local-path provisioner or equivalent
- **Load Balancer**: MetalLB or K3s built-in servicelb
- **DNS**: Wildcard DNS pointing to cluster (e.g., `*.aster-lang.cloud`)
- **GitHub**: Private repository with deploy key or GitHub App

### 0.1.1 Understanding K3s Built-in Components

> **Important for newcomers:** K3s comes pre-installed with several components that we enhance rather than replace:

| Component | K3s Default | Our Enhancement |
|-----------|-------------|-----------------|
| **Traefik** | Pre-installed in `kube-system` | We patch it with security hardening (securityContext, NetworkPolicies) |
| **CoreDNS** | Pre-installed in `kube-system` | No changes needed |
| **Local-path provisioner** | Pre-installed | Default StorageClass for PVCs |
| **Metrics-server** | Pre-installed | No changes needed |

**Do NOT uninstall these components!** The `kube-system` application in this repo only patches them.

### 0.2 Current State Analysis

Based on your cluster output, here's what exists:

| Current Namespace | Current Components | Target Namespace |
|-------------------|-------------------|------------------|
| `argocd` | ArgoCD (manually installed) | `argocd` (self-managed) |
| `cert-manager` | cert-manager | `cert-manager` (keep) |
| `kube-system` | CoreDNS, Traefik, metrics-server | `kube-system` (enhance) |
| `wontlost` | Vault | `vault` |
| `wontlost` | External Secrets | `external-secrets` |
| `wontlost` | Authentik | `authentik` |
| `wontlost` | Prometheus stack | `monitoring` |
| `wontlost` | PostgreSQL | `data-services` (CloudNativePG) |
| `wontlost` | Redis | `data-services` (shared-redis) |
| (missing) | - | `cnpg-system` |
| (missing) | - | `reflector` |
| (missing) | - | `aster-policy` |
| (missing) | - | `wontlost-data` |

### 0.3 Data Backup Requirements

**CRITICAL: Backup all persistent data before proceeding!**

```bash
# 1. Backup Vault data
kubectl exec -n wontlost vault-0 -- vault operator raft snapshot save /tmp/vault-snapshot.snap
kubectl cp wontlost/vault-0:/tmp/vault-snapshot.snap ./backups/vault-snapshot-$(date +%Y%m%d).snap

# 2. Backup PostgreSQL
kubectl exec -n wontlost wontlost-data-postgresql-0 -- pg_dumpall -U postgres > ./backups/postgres-backup-$(date +%Y%m%d).sql

# 3. Backup Prometheus data (optional - can be regenerated)
# PV data is typically not critical

# 4. Export Authentik configuration
# Login to Authentik UI > System > Blueprints > Export

# 5. Backup ArgoCD applications list
kubectl get applications -n argocd -o yaml > ./backups/argocd-apps-$(date +%Y%m%d).yaml
kubectl get appprojects -n argocd -o yaml > ./backups/argocd-projects-$(date +%Y%m%d).yaml

# 6. Backup all secrets (encrypted)
kubectl get secrets -A -o yaml > ./backups/all-secrets-$(date +%Y%m%d).yaml
```

### 0.4 Required Secrets in Vault

Ensure these secrets exist in Vault before deployment:

```
secret/data/infrastructure/argocd
  - repo-url
  - repo-ssh-key (or github-app-id, github-app-installation-id, github-app-private-key)
  - oidc.authentik.clientSecret

secret/data/infrastructure/authentik
  - secret-key
  - postgres-password
  - redis-password
  - admin-password (optional)

secret/data/infrastructure/monitoring
  - basic_auth_users (htpasswd format)
  - grafana-admin-password

secret/data/infrastructure/postgres
  - superuser-password
  - authentik-password
  - grafana-password
  - policy-api-password

secret/data/infrastructure/postgres-backup
  - ACCESS_KEY_ID
  - SECRET_ACCESS_KEY

secret/data/infrastructure/cloudflare
  - api-token (for DNS-01 challenges)

secret/data/apps/aster-policy
  - database-url
  - redis-url
  - api-key

secret/data/apps/wontlost-data
  - database-url
  - api-key
```

---

## Phase 1: Cleanup Existing Resources

### 1.1 Pre-cleanup Verification

```bash
# Verify you have admin access
kubectl auth can-i '*' '*' --all-namespaces

# Check current state
kubectl get all -A | tee /tmp/current-state.txt

# Verify backups are complete
ls -la ./backups/
```

### 1.2 Remove Existing ArgoCD (Non-self-managed)

```bash
# Delete all ArgoCD Applications first (to prevent cascade deletion issues)
kubectl delete applications --all -n argocd

# Wait for applications to be deleted
kubectl get applications -n argocd

# Delete ArgoCD namespace
kubectl delete namespace argocd --wait=true

# Verify cleanup
kubectl get all -n argocd
```

### 1.3 Remove Components from wontlost Namespace

**Order matters! Delete in reverse dependency order:**

```bash
# Step 1: Delete External Secrets resources (depends on Vault)
kubectl delete externalsecrets --all -n wontlost
kubectl delete secretstores --all -n wontlost
kubectl delete clustersecretstores --all

# Step 2: Delete monitoring stack (has many CRDs)
kubectl delete prometheus --all -n wontlost
kubectl delete alertmanager --all -n wontlost
kubectl delete servicemonitors --all -n wontlost
kubectl delete prometheusrules --all -n wontlost

# Step 3: Scale down Authentik
kubectl scale deployment authentik-server --replicas=0 -n wontlost
kubectl scale deployment authentik-worker --replicas=0 -n wontlost

# Step 4: Delete Helm releases (if using Helm)
helm list -n wontlost
helm uninstall prometheus -n wontlost
helm uninstall vault -n wontlost
helm uninstall authentik -n wontlost
helm uninstall external-secrets -n wontlost

# Step 5: Delete remaining resources
kubectl delete deployments --all -n wontlost
kubectl delete statefulsets --all -n wontlost
kubectl delete daemonsets --all -n wontlost
kubectl delete services --all -n wontlost
kubectl delete configmaps --all -n wontlost
kubectl delete secrets --all -n wontlost
kubectl delete pvc --all -n wontlost  # WARNING: This deletes persistent data!

# Step 6: Delete the namespace
kubectl delete namespace wontlost --wait=true
```

### 1.4 Clean Up CRDs (Optional - Only if reinstalling operators)

```bash
# Only run if you want a completely fresh install
# WARNING: This removes all custom resources!

# External Secrets CRDs
kubectl delete crd externalsecrets.external-secrets.io
kubectl delete crd secretstores.external-secrets.io
kubectl delete crd clustersecretstores.external-secrets.io
kubectl delete crd clusterexternalsecrets.external-secrets.io

# Prometheus Operator CRDs
kubectl delete crd alertmanagerconfigs.monitoring.coreos.com
kubectl delete crd alertmanagers.monitoring.coreos.com
kubectl delete crd podmonitors.monitoring.coreos.com
kubectl delete crd probes.monitoring.coreos.com
kubectl delete crd prometheusagents.monitoring.coreos.com
kubectl delete crd prometheuses.monitoring.coreos.com
kubectl delete crd prometheusrules.monitoring.coreos.com
kubectl delete crd scrapeconfigs.monitoring.coreos.com
kubectl delete crd servicemonitors.monitoring.coreos.com
kubectl delete crd thanosrulers.monitoring.coreos.com
```

### 1.5 Verify Clean State

```bash
# Should only show kube-system, cert-manager, default
kubectl get namespaces

# Should show minimal resources
kubectl get all -A

# Verify no orphaned CRs
kubectl get externalsecrets -A
kubectl get prometheuses -A
```

---

## Phase 2: Bootstrap ArgoCD (Self-Managed)

### 2.1 Create ArgoCD Namespace and Repository Secret

```bash
# Create namespace
kubectl create namespace argocd

# Create repository credential secret
# Option A: SSH Key
kubectl create secret generic argocd-repo-creds \
  --namespace argocd \
  --from-file=sshPrivateKey=/path/to/deploy-key \
  --from-literal=url=git@github.com:wontlost-ltd/k3s.git \
  --from-literal=type=git

# Option B: GitHub App (recommended)
kubectl create secret generic argocd-repo-creds \
  --namespace argocd \
  --from-literal=url=https://github.com/wontlost-ltd/k3s.git \
  --from-literal=type=git \
  --from-literal=githubAppID=YOUR_APP_ID \
  --from-literal=githubAppInstallationID=YOUR_INSTALLATION_ID \
  --from-file=githubAppPrivateKey=/path/to/private-key.pem

# Label the secret for ArgoCD to recognize
kubectl label secret argocd-repo-creds -n argocd \
  argocd.argoproj.io/secret-type=repository
```

### 2.2 Install ArgoCD via Helm (Initial Bootstrap)

```bash
# Add ArgoCD Helm repo
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Install ArgoCD with minimal config (will be replaced by self-managed)
helm install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --set configs.params."server\.insecure"=true \
  --wait

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Port-forward to access UI
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

### 2.3 Create AppProjects

```bash
# Apply AppProjects first (ArgoCD needs them before Applications)
kubectl apply -f argocd/projects/infrastructure.yaml
kubectl apply -f argocd/projects/secrets-management.yaml
kubectl apply -f argocd/projects/aster-lang.yaml
kubectl apply -f argocd/projects/wontlost.yaml
kubectl apply -f argocd/projects/identity.yaml
kubectl apply -f argocd/projects/data-services.yaml
kubectl apply -f argocd/projects/tls-management.yaml

# Verify projects
kubectl get appprojects -n argocd
```

### 2.4 Apply Root Application (App of Apps)

```bash
# Apply the root application - this is the ONLY manual apply needed!
# It will create argocd (sync-wave 0) and argocd-config (sync-wave 1)
kubectl apply -f argocd/bootstrap/root-app.yaml

# Wait for sync (this may take 2-3 minutes as ArgoCD upgrades itself)
kubectl get applications -n argocd -w

# Expected applications:
# NAME            SYNC STATUS   HEALTH STATUS
# root-app        Synced        Healthy
# argocd          Synced        Healthy
# argocd-config   Synced        Healthy

# Verify ArgoCD is healthy
kubectl get pods -n argocd
```

### 2.5 Apply Root ApplicationSets

```bash
# Apply ApplicationSets that will create all other applications
kubectl apply -f argocd/applicationsets/infrastructure.yaml
kubectl apply -f argocd/applicationsets/secrets-management.yaml
kubectl apply -f argocd/applicationsets/business-apps.yaml

# Verify ApplicationSets
kubectl get applicationsets -n argocd

# Watch applications being created
kubectl get applications -n argocd -w
```

---

## Phase 2.5: Bootstrap Critical Dependencies (IMPORTANT!)

> **🐔🥚 The Chicken-and-Egg Problem**
>
> This architecture has circular dependencies that require manual bootstrapping:
> - **ExternalSecrets** needs **Vault** to pull secrets
> - **Vault** needs **cert-manager** for TLS certificates
> - **cert-manager** needs **Cloudflare API token** (stored in Vault) for DNS challenges
> - **ArgoCD OIDC** needs **Authentik** which needs **PostgreSQL** credentials (from Vault)
>
> **Solution:** We manually bootstrap the first link in this chain, then ArgoCD handles the rest.

### 2.6 Understanding the Bootstrap Sequence

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        MANUAL BOOTSTRAP PHASE                          │
├─────────────────────────────────────────────────────────────────────────┤
│  1. Create Cloudflare API token secret (for cert-manager DNS-01)       │
│  2. Wait for cert-manager to issue Vault TLS certificate               │
│  3. Initialize and unseal Vault                                        │
│  4. Configure Vault policies and AppRole for ESO                       │
│  5. Create Vault authentication secret for ESO                         │
│  6. Populate Vault with required secrets                               │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      ARGOCD HANDLES AUTOMATICALLY                       │
├─────────────────────────────────────────────────────────────────────────┤
│  → ClusterSecretStore connects to Vault                                │
│  → ExternalSecrets pull credentials from Vault                         │
│  → PostgreSQL, Redis, Authentik start with correct credentials         │
│  → ArgoCD OIDC connects to Authentik                                   │
│  → All remaining applications deploy                                   │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.7 Create Cloudflare API Token Secret (For cert-manager)

cert-manager needs a Cloudflare API token to solve DNS-01 challenges for TLS certificates.

```bash
# Create the secret manually (before Vault/ESO are ready)
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN

# Verify
kubectl get secret cloudflare-api-token -n cert-manager
```

> **Getting a Cloudflare API Token:**
> 1. Login to Cloudflare Dashboard → My Profile → API Tokens
> 2. Create Token → Use template "Edit zone DNS"
> 3. Permissions: Zone - DNS - Edit
> 4. Zone Resources: Include - Specific zone - your-domain.com
> 5. Copy the generated token

### 2.8 Wait for Vault TLS Certificate

After ApplicationSets deploy cert-manager and Vault, wait for the internal TLS certificate:

```bash
# Watch cert-manager deploy
kubectl get pods -n cert-manager -w

# Check for Vault's internal TLS certificate
kubectl get certificate -n vault -w

# Should show:
# NAME                 READY   SECRET               AGE
# vault-internal-tls   True    vault-internal-tls   2m

# If certificate is not ready, check:
kubectl describe certificate vault-internal-tls -n vault
kubectl get certificaterequest -n vault
kubectl get challenges -n vault  # For DNS-01 challenges
```

### 2.9 Initialize and Unseal Vault (First Time Only)

> **⚠️ CRITICAL:** Save the unseal keys and root token securely! Loss = total data loss.

```bash
# Check Vault status (should show "sealed")
kubectl exec -n vault vault-0 -- vault status

# Initialize Vault (ONLY on first install!)
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3

# OUTPUT - SAVE THIS SECURELY:
# Unseal Key 1: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# Unseal Key 2: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# Unseal Key 3: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# Unseal Key 4: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# Unseal Key 5: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# Initial Root Token: hvs.xxxxxxxxxxxxxxxxxxxxxxxxxxxx

# Unseal Vault (need 3 of 5 keys)
kubectl exec -n vault vault-0 -- vault operator unseal <key1>
kubectl exec -n vault vault-0 -- vault operator unseal <key2>
kubectl exec -n vault vault-0 -- vault operator unseal <key3>

# For HA setup, unseal other replicas too
kubectl exec -n vault vault-1 -- vault operator unseal <key1>
kubectl exec -n vault vault-1 -- vault operator unseal <key2>
kubectl exec -n vault vault-1 -- vault operator unseal <key3>

kubectl exec -n vault vault-2 -- vault operator unseal <key1>
kubectl exec -n vault vault-2 -- vault operator unseal <key2>
kubectl exec -n vault vault-2 -- vault operator unseal <key3>

# Verify all pods are unsealed
kubectl exec -n vault vault-0 -- vault status
# Should show: Sealed = false
```

### 2.10 Configure Vault for External Secrets Operator

ESO needs an AppRole to authenticate with Vault.

```bash
# Login to Vault with root token
kubectl exec -n vault vault-0 -- vault login <root-token>

# Enable KV secrets engine (version 2)
kubectl exec -n vault vault-0 -- vault secrets enable -path=secret kv-v2

# Create policy for ESO
kubectl exec -n vault vault-0 -- sh -c 'cat <<EOF | vault policy write external-secrets -
path "secret/data/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF'

# Enable AppRole auth method
kubectl exec -n vault vault-0 -- vault auth enable approle

# Create AppRole for ESO
kubectl exec -n vault vault-0 -- vault write auth/approle/role/external-secrets \
  token_policies="external-secrets" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=0 \
  secret_id_num_uses=0

# Get Role ID
kubectl exec -n vault vault-0 -- vault read auth/approle/role/external-secrets/role-id
# OUTPUT: role_id = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Generate Secret ID
kubectl exec -n vault vault-0 -- vault write -f auth/approle/role/external-secrets/secret-id
# OUTPUT: secret_id = xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Create the Kubernetes secret for ESO to use
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic vault-approle \
  --namespace external-secrets \
  --from-literal=role-id=<role-id-from-above> \
  --from-literal=secret-id=<secret-id-from-above>

# Verify
kubectl get secret vault-approle -n external-secrets
```

### 2.11 Populate Required Secrets in Vault

Before other applications can start, Vault must contain their secrets:

```bash
# Login if session expired
kubectl exec -n vault vault-0 -- vault login <root-token>

# ─────────────────────────────────────────────────────────────
# Infrastructure Secrets
# ─────────────────────────────────────────────────────────────

# Cloudflare (for cert-manager DNS-01 - can be managed by ESO after bootstrap)
kubectl exec -n vault vault-0 -- vault kv put secret/infrastructure/cloudflare \
  api-token="YOUR_CLOUDFLARE_API_TOKEN"

# PostgreSQL superuser
kubectl exec -n vault vault-0 -- vault kv put secret/data-services/postgres \
  host="shared-postgres-rw.data-services.svc.cluster.local" \
  port="5432" \
  superuser-password="$(openssl rand -base64 32)"

# Redis
kubectl exec -n vault vault-0 -- vault kv put secret/data-services/redis \
  host="shared-redis-master.data-services.svc.cluster.local" \
  port="6379" \
  password="$(openssl rand -base64 32)"

# ─────────────────────────────────────────────────────────────
# Application Database Credentials
# ─────────────────────────────────────────────────────────────

# Authentik database
kubectl exec -n vault vault-0 -- vault kv put secret/data-services/authentik-db \
  database="authentik" \
  username="authentik" \
  password="$(openssl rand -base64 32)"

# Grafana database
kubectl exec -n vault vault-0 -- vault kv put secret/data-services/grafana-db \
  database="grafana" \
  username="grafana" \
  password="$(openssl rand -base64 32)"

# Policy API database
kubectl exec -n vault vault-0 -- vault kv put secret/data-services/policy-api-db \
  database="policy_api" \
  username="policy_api" \
  password="$(openssl rand -base64 32)"

# Wontlost database
kubectl exec -n vault vault-0 -- vault kv put secret/data-services/wontlost-db \
  database="wontlost" \
  username="wontlost" \
  password="$(openssl rand -base64 32)"

# ─────────────────────────────────────────────────────────────
# Application Secrets
# ─────────────────────────────────────────────────────────────

# Authentik
kubectl exec -n vault vault-0 -- vault kv put secret/infrastructure/authentik \
  secret-key="$(openssl rand -base64 64)" \
  admin-password="$(openssl rand -base64 16)"

# Grafana admin
kubectl exec -n vault vault-0 -- vault kv put secret/infrastructure/grafana \
  admin-user="admin" \
  admin-password="$(openssl rand -base64 16)"

# Monitoring basic auth (htpasswd format)
# Generate: htpasswd -nb admin <password> | openssl base64
kubectl exec -n vault vault-0 -- vault kv put secret/infrastructure/monitoring \
  basic_auth_users="admin:\$apr1\$xxxxx\$xxxxxxxxxxxxxxxxxxxxx"

# ─────────────────────────────────────────────────────────────
# ArgoCD Repository Credentials (if using Vault for repo creds)
# ─────────────────────────────────────────────────────────────

# For GitHub App authentication
kubectl exec -n vault vault-0 -- vault kv put secret/infrastructure/argocd \
  repo-url="https://github.com/wontlost-ltd/k3s.git" \
  github-app-id="YOUR_APP_ID" \
  github-app-installation-id="YOUR_INSTALLATION_ID" \
  github-app-private-key="$(cat /path/to/private-key.pem)"

# Verify all secrets
kubectl exec -n vault vault-0 -- vault kv list secret/
kubectl exec -n vault vault-0 -- vault kv list secret/infrastructure/
kubectl exec -n vault vault-0 -- vault kv list secret/data-services/
```

### 2.12 Configure Cloudflare Tunnel (Optional - For External Access)

> **Why Cloudflare Tunnel?** Instead of exposing your cluster's IP directly to the internet, Cloudflare Tunnel creates an outbound-only connection to Cloudflare's edge network. This provides DDoS protection, hides your origin IP, and eliminates the need for firewall port forwarding.

#### Step 1: Create Tunnel in Cloudflare Dashboard

1. Go to **Cloudflare Dashboard** → **Zero Trust** → **Networks** → **Tunnels**
2. Click **Create a tunnel** → Select **Cloudflared** connector
3. Name it: `k8s-tunnel` (or your preferred name)
4. **Save the tunnel token** - you'll need it for the next step

#### Step 2: Store Tunnel Token in Vault

```bash
# Store the tunnel token in Vault
kubectl exec -n vault vault-0 -- vault kv put secret/infrastructure/cloudflare-tunnel \
  token="YOUR_TUNNEL_TOKEN_HERE"

# Verify
kubectl exec -n vault vault-0 -- vault kv get secret/infrastructure/cloudflare-tunnel
```

#### Step 3: Configure Public Hostnames in Cloudflare

In **Cloudflare Dashboard** → **Zero Trust** → **Tunnels** → Your tunnel → **Public Hostname**, add entries:

| Public hostname | Service | Notes |
|-----------------|---------|-------|
| `argocd.your-domain.com` | `http://argocd-server.argocd.svc.cluster.local:80` | ArgoCD UI |
| `grafana.your-domain.com` | `http://prometheus-grafana.monitoring.svc.cluster.local:80` | Grafana UI |
| `vault.your-domain.com` | `https://vault.vault.svc.cluster.local:8200` | Vault UI (note: HTTPS) |
| `auth.your-domain.com` | `http://authentik-server.authentik.svc.cluster.local:80` | Authentik SSO |

> **Important:** For Vault, set **Origin Server Name** to `vault.vault.svc.cluster.local` in TLS settings since Vault uses internal TLS.

#### Step 4: Verify Tunnel Deployment

After ArgoCD deploys the cloudflare-tunnel application:

```bash
# Check cloudflared pods
kubectl get pods -n cloudflare

# Check tunnel logs
kubectl logs -n cloudflare -l app.kubernetes.io/name=cloudflared

# Verify external access
curl -v https://argocd.your-domain.com/
```

### 2.13 Create ArgoCD OIDC Secret (For Authentik SSO)

> **Note:** This secret will be replaced by ExternalSecret once Authentik is running, but we need a placeholder initially.

```bash
# Create placeholder OIDC secret (ArgoCD needs this to start properly)
kubectl create secret generic argocd-oidc-secret \
  --namespace argocd \
  --from-literal=oidc.authentik.clientSecret="placeholder-will-be-replaced"

# Label it for ArgoCD
kubectl label secret argocd-oidc-secret -n argocd \
  app.kubernetes.io/part-of=argocd

# After Authentik is running, update with real secret:
# 1. Login to Authentik → Applications → argocd → Provider
# 2. Copy Client Secret
# 3. Store in Vault: vault kv put secret/infrastructure/argocd oidc.authentik.clientSecret="real-secret"
# 4. ExternalSecret will sync it automatically
```

### 2.14 Verify Bootstrap is Complete

```bash
# All these should return results:
kubectl get secret vault-approle -n external-secrets          # ESO auth
kubectl get secret cloudflare-api-token -n cert-manager       # DNS challenge
kubectl get secret argocd-oidc-secret -n argocd               # OIDC placeholder

# Vault should be unsealed and contain secrets
kubectl exec -n vault vault-0 -- vault status | grep Sealed   # Should be: false
kubectl exec -n vault vault-0 -- vault kv list secret/        # Should list paths

# ClusterSecretStore should be ready (after ESO syncs)
kubectl get clustersecretstore vault-backend                   # Should show Ready
```

---

## Phase 3: Deploy Infrastructure Components

### 3.1 Deployment Order (Sync Waves)

The sync-wave annotations control deployment order:

| Wave | Components | Description |
|------|------------|-------------|
| -1 | NetworkPolicies | Security first |
| 0 | cert-manager | TLS foundation |
| 1 | Vault | Secrets storage |
| 2 | External Secrets + ClusterSecretStore | Secrets sync |
| 3 | Bootstrap ExternalSecrets | Pull secrets from Vault |
| 4 | CloudNativePG, Shared Redis | Database infrastructure |
| 5 | Authentik, Monitoring | Applications |
| 6 | Business Apps | Final layer |

### 3.2 Monitor Deployment Progress

```bash
# Watch all applications
watch kubectl get applications -n argocd

# Check specific application status
kubectl describe application <app-name> -n argocd

# View sync status
argocd app list

# Check events for errors
kubectl get events -n argocd --sort-by='.lastTimestamp'
```

### 3.3 Verify Each Component

#### Vault
```bash
# Check pods
kubectl get pods -n vault

# Check Vault status
kubectl exec -n vault vault-0 -- vault status

# Initialize if needed (new installation only)
kubectl exec -n vault vault-0 -- vault operator init

# Unseal Vault (required after restarts)
kubectl exec -n vault vault-0 -- vault operator unseal <key1>
kubectl exec -n vault vault-0 -- vault operator unseal <key2>
kubectl exec -n vault vault-0 -- vault operator unseal <key3>
```

#### External Secrets
```bash
# Check operator
kubectl get pods -n external-secrets

# Check ClusterSecretStore
kubectl get clustersecretstores

# Verify connection to Vault
kubectl describe clustersecretstore vault-backend
```

#### PostgreSQL (CloudNativePG)
```bash
# Check operator
kubectl get pods -n cnpg-system

# Check cluster status
kubectl get clusters -n data-services

# Check PostgreSQL pods
kubectl get pods -n data-services -l cnpg.io/cluster=shared-postgres

# Connect to verify
kubectl exec -it -n data-services shared-postgres-1 -- psql -U postgres -c "\l"
```

#### Monitoring
```bash
# Check all monitoring pods
kubectl get pods -n monitoring

# Verify Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Open http://localhost:9090/targets

# Check Grafana
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open http://localhost:3000
```

#### Authentik
```bash
# Check pods
kubectl get pods -n authentik

# Get admin password (if ExternalSecret)
kubectl get secret -n authentik authentik-secrets -o jsonpath='{.data.admin-password}' | base64 -d

# Test login
kubectl port-forward -n authentik svc/authentik-server 9000:80
# Open http://localhost:9000
```

---

## Phase 4: Configure Ingress and TLS

### 4.1 Verify cert-manager

```bash
# Check cert-manager pods
kubectl get pods -n cert-manager

# Check ClusterIssuers
kubectl get clusterissuers

# Check certificates
kubectl get certificates -A

# Check certificate secrets
kubectl get secrets -A | grep tls
```

### 4.2 Apply Ingress Resources

```bash
# ArgoCD ingress
kubectl apply -f argocd/ingress.yaml

# Verify ingress
kubectl get ingress -n argocd

# Check certificate status
kubectl describe certificate -n argocd
```

### 4.3 Test Endpoints

```bash
# Test ArgoCD
curl -v https://argocd.aster-lang.cloud/

# Test Grafana
curl -v https://grafana.aster-lang.cloud/

# Test Authentik
curl -v https://auth.aster-lang.cloud/

# Test Vault
curl -v https://vault.aster-lang.cloud/v1/sys/health
```

---

## Phase 5: Data Migration (If Applicable)

### 5.1 Migrate Vault Data

```bash
# If restoring from backup
kubectl cp ./backups/vault-snapshot-YYYYMMDD.snap vault/vault-0:/tmp/
kubectl exec -n vault vault-0 -- vault operator raft snapshot restore /tmp/vault-snapshot-YYYYMMDD.snap
```

### 5.2 Migrate PostgreSQL Data

```bash
# Get new PostgreSQL credentials
NEW_PG_HOST="shared-postgres-rw.data-services.svc.cluster.local"
NEW_PG_PASSWORD=$(kubectl get secret -n data-services postgres-superuser-credentials -o jsonpath='{.data.password}' | base64 -d)

# Copy backup to new cluster
kubectl cp ./backups/postgres-backup-YYYYMMDD.sql data-services/shared-postgres-1:/tmp/

# Restore
kubectl exec -it -n data-services shared-postgres-1 -- psql -U postgres -f /tmp/postgres-backup-YYYYMMDD.sql
```

### 5.3 Migrate Authentik Configuration

```bash
# Import blueprint via UI or API
# Login to Authentik > System > Blueprints > Import
```

---

## Phase 6: Post-Deployment Verification

### 6.1 Health Checks

```bash
# All pods should be Running/Completed
kubectl get pods -A | grep -v Running | grep -v Completed

# All applications should be Synced/Healthy
kubectl get applications -n argocd

# No pending PVCs
kubectl get pvc -A | grep -v Bound

# No failed jobs
kubectl get jobs -A | grep -v "1/1"
```

### 6.2 Security Verification

```bash
# Verify NetworkPolicies exist
kubectl get networkpolicies -A

# Verify pods have security context
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: runAsNonRoot={.spec.securityContext.runAsNonRoot}{"\n"}{end}'

# Verify no privileged containers
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: privileged={.spec.containers[*].securityContext.privileged}{"\n"}{end}'
```

### 6.3 Functional Tests

```bash
# Test ExternalSecret sync
kubectl get externalsecrets -A
kubectl describe externalsecret -n argocd argocd-repo-creds

# Test PostgreSQL connectivity
kubectl run -it --rm pg-test --image=postgres:16 --restart=Never -- \
  psql -h shared-postgres-rw.data-services.svc.cluster.local -U postgres -c "SELECT version();"

# Test Vault auth
kubectl exec -n vault vault-0 -- vault token lookup
```

### 6.4 Monitoring Verification

```bash
# Check Prometheus targets
# All targets should be UP at http://prometheus.aster-lang.cloud/targets

# Check Grafana datasources
# Prometheus datasource should be configured

# Check Alertmanager
# Alerts should be routed correctly
```

---

## Troubleshooting

### Common Issues

#### ArgoCD Application Stuck in "Progressing"
```bash
# Check sync status
argocd app get <app-name>

# Force sync
argocd app sync <app-name> --force

# Check for resource issues
kubectl describe application <app-name> -n argocd
```

#### ExternalSecret Not Syncing
```bash
# Check ClusterSecretStore status
kubectl describe clustersecretstore vault-backend

# Check ExternalSecret status
kubectl describe externalsecret <name> -n <namespace>

# Verify Vault token
kubectl get secret -n external-secrets vault-token -o yaml
```

#### PostgreSQL Not Starting
```bash
# Check operator logs
kubectl logs -n cnpg-system -l app.kubernetes.io/name=cloudnative-pg

# Check cluster events
kubectl describe cluster shared-postgres -n data-services

# Check PVC binding
kubectl get pvc -n data-services
```

#### Certificate Not Issuing
```bash
# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager

# Check certificate status
kubectl describe certificate <name> -n <namespace>

# Check CertificateRequest
kubectl get certificaterequests -A

# Check Order and Challenge
kubectl get orders -A
kubectl get challenges -A
```

### Recovery Procedures

#### Recover ArgoCD Admin Password
```bash
# Reset admin password
kubectl -n argocd patch secret argocd-secret \
  -p '{"stringData": {"admin.password": "'$(htpasswd -bnBC 10 "" newpassword | tr -d ':\n')'"}}'

# Restart ArgoCD server
kubectl rollout restart deployment argocd-server -n argocd
```

#### Force Application Deletion
```bash
# Remove finalizer if stuck
kubectl patch application <app-name> -n argocd \
  --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'
```

---

## Maintenance Procedures

### Vault Maintenance

```bash
# Take snapshot
kubectl exec -n vault vault-0 -- vault operator raft snapshot save /tmp/backup.snap
kubectl cp vault/vault-0:/tmp/backup.snap ./backups/vault-$(date +%Y%m%d).snap

# Check raft peers
kubectl exec -n vault vault-0 -- vault operator raft list-peers
```

### Database Maintenance

```bash
# Manual backup
kubectl exec -it -n data-services shared-postgres-1 -- pg_dumpall -U postgres > backup.sql

# Check cluster health
kubectl get clusters -n data-services -o wide

# Switchover (promote standby)
kubectl cnpg promote shared-postgres -n data-services
```

### ArgoCD Maintenance

```bash
# Sync all applications
argocd app sync --all

# Refresh application manifests
argocd app get <app-name> --refresh

# Hard refresh (clear cache)
argocd app get <app-name> --hard-refresh
```

---

## Appendix

### A. File Structure Reference

```
k3s/
├── argocd/
│   ├── bootstrap/
│   │   └── root-app.yaml            # Single entry point - only manual apply needed
│   ├── apps/
│   │   ├── kustomization.yaml       # Includes argocd + argocd-config
│   │   ├── argocd.yaml              # ArgoCD Helm chart (sync-wave: 0)
│   │   └── argocd-config.yaml       # Projects, ApplicationSets (sync-wave: 1)
│   ├── applicationsets/
│   │   ├── infrastructure.yaml      # Infrastructure apps
│   │   ├── secrets-management.yaml  # Vault, External Secrets
│   │   └── business-apps.yaml       # Business applications
│   ├── projects/
│   │   ├── infrastructure.yaml
│   │   ├── secrets-management.yaml
│   │   ├── aster-lang.yaml
│   │   ├── wontlost.yaml
│   │   ├── identity.yaml
│   │   ├── data-services.yaml
│   │   └── tls-management.yaml
│   ├── ingress.yaml
│   └── kustomization.yaml
├── apps/
│   ├── infrastructure/
│   │   ├── authentik/
│   │   ├── bootstrap/
│   │   ├── cert-manager/
│   │   ├── cloudnative-pg/
│   │   ├── external-secrets/
│   │   ├── kube-system/
│   │   ├── monitoring/
│   │   ├── postgres-cluster/
│   │   ├── reflector/
│   │   ├── shared-redis/
│   │   ├── vault/
│   │   └── *-network-policies/
│   ├── aster-lang/
│   │   └── policy/
│   └── wontlost/
│       └── data/
└── docs/
    └── ARCHITECTURE_DEPLOYMENT_GUIDE.md
```

### B. Port Reference

| Service | Port | Protocol | Description |
|---------|------|----------|-------------|
| ArgoCD Server | 8080 | HTTP | Web UI (internal) |
| ArgoCD Server | 443 | HTTPS | Web UI (via Ingress) |
| Vault | 8200 | HTTP/HTTPS | API/UI |
| Vault | 8201 | TCP | Cluster communication |
| PostgreSQL | 5432 | TCP | Database |
| Redis | 6379 | TCP | Cache |
| Prometheus | 9090 | HTTP | Metrics UI |
| Grafana | 3000 | HTTP | Dashboard UI |
| Alertmanager | 9093 | HTTP | Alerts UI |
| Authentik | 9000 | HTTP | SSO/Identity |
| Traefik | 80 | HTTP | Ingress |
| Traefik | 443 | HTTPS | Ingress |

### C. Quick Command Reference

```bash
# ArgoCD CLI
argocd login argocd.aster-lang.cloud --grpc-web
argocd app list
argocd app sync <app>
argocd app delete <app>

# Vault CLI
kubectl exec -n vault vault-0 -- vault status
kubectl exec -n vault vault-0 -- vault kv list secret/

# PostgreSQL
kubectl exec -it -n data-services shared-postgres-1 -- psql -U postgres

# Logs
kubectl logs -n <namespace> -l app=<label> -f
kubectl logs -n <namespace> <pod> --previous

# Debug
kubectl run -it --rm debug --image=alpine -- sh
kubectl run -it --rm debug --image=busybox -- sh
```

---

## Checklist Summary

### Pre-deployment
- [ ] Backup all data (Vault, PostgreSQL, Authentik)
- [ ] Verify DNS configuration (wildcard `*.aster-lang.cloud` → cluster IP)
- [ ] Prepare GitHub credentials (SSH key or GitHub App)
- [ ] Document current Vault secrets
- [ ] Obtain Cloudflare API token (Zone - DNS - Edit permissions)

### Cleanup (If Migrating)
- [ ] Delete ArgoCD applications
- [ ] Delete ArgoCD namespace
- [ ] Delete wontlost namespace resources
- [ ] Verify clean state

### Deployment
- [ ] Create ArgoCD namespace and repo secret
- [ ] Install ArgoCD via Helm (bootstrap)
- [ ] Apply AppProjects
- [ ] Apply root-app (App of Apps): `kubectl apply -f argocd/bootstrap/root-app.yaml`
- [ ] Verify all three apps synced: root-app, argocd, argocd-config
- [ ] Monitor deployment progress

### 🐔🥚 Bootstrap (Critical - See Phase 2.5)
- [ ] Create Cloudflare API token secret in cert-manager namespace
- [ ] Wait for cert-manager pods to be Running
- [ ] Wait for Vault TLS certificate (`vault-internal-tls`) to be Ready
- [ ] Initialize Vault (`vault operator init`) - **SAVE UNSEAL KEYS SECURELY!**
- [ ] Unseal all Vault pods (3 keys each for vault-0, vault-1, vault-2)
- [ ] Enable KV-v2 secrets engine at `secret/`
- [ ] Create ESO policy (`external-secrets`)
- [ ] Enable AppRole auth method
- [ ] Create AppRole for ESO and get role-id/secret-id
- [ ] Create `vault-approle` secret in external-secrets namespace
- [ ] Populate Vault with required secrets:
  - [ ] `secret/infrastructure/cloudflare` (api-token)
  - [ ] `secret/infrastructure/cloudflare-tunnel` (token) - if using Cloudflare Tunnel
  - [ ] `secret/data-services/postgres` (host, port, superuser-password)
  - [ ] `secret/data-services/redis` (password)
  - [ ] `secret/infrastructure/authentik` (secret-key, postgres-password)
  - [ ] `secret/infrastructure/argocd` (repo credentials, oidc.authentik.clientSecret)
  - [ ] `secret/infrastructure/monitoring` (basic_auth_users, grafana credentials)
- [ ] Create ArgoCD OIDC placeholder secret (if using Authentik SSO)
- [ ] Verify ClusterSecretStore status is Valid
- [ ] Verify ExternalSecrets are syncing (SecretSynced condition)

### ☁️ Cloudflare Tunnel (Optional - For External Access)
- [ ] Create tunnel in Cloudflare Zero Trust Dashboard
- [ ] Save tunnel token securely
- [ ] Store tunnel token in Vault (`secret/infrastructure/cloudflare-tunnel`)
- [ ] Configure public hostnames in Cloudflare Dashboard:
  - [ ] ArgoCD → `http://argocd-server.argocd.svc.cluster.local:80`
  - [ ] Grafana → `http://prometheus-grafana.monitoring.svc.cluster.local:80`
  - [ ] Vault → `https://vault.vault.svc.cluster.local:8200`
  - [ ] Authentik → `http://authentik-server.authentik.svc.cluster.local:80`
- [ ] Verify cloudflared pods are running (`kubectl get pods -n cloudflare`)
- [ ] Test external access via Cloudflare Tunnel URLs

### Verification
- [ ] All pods Running
- [ ] All applications Synced/Healthy
- [ ] Ingress working with TLS
- [ ] Vault unsealed and accessible
- [ ] PostgreSQL cluster healthy
- [ ] Monitoring stack operational
- [ ] Authentik SSO working
- [ ] Business apps deployed

### Post-deployment
- [ ] Test all endpoints (ArgoCD, Grafana, Vault, Authentik)
- [ ] Verify security (NetworkPolicies, securityContext)
- [ ] Configure alerting
- [ ] Document any deviations
- [ ] Schedule regular backups
- [ ] Store Vault unseal keys in secure location (HSM, 1Password, etc.)
