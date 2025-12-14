# K3s Infrastructure

This repository manages Kubernetes resources for the K3s cluster using ArgoCD with Projects and ApplicationSets.

## Table of Contents

- [Domain Strategy](#domain-strategy)
- [Structure](#structure)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Clean Installation](#clean-installation)
  - [Step 0: Uninstall Existing ArgoCD](#step-0-uninstall-existing-argocd-if-applicable)
  - [Step 1: Install Fresh ArgoCD](#step-1-install-fresh-argocd)
  - [Step 2: Configure Repository Access](#step-2-configure-repository-access)
  - [Step 3: Enable Self-Management](#step-3-enable-self-management)
  - [Step 4: Verify Installation](#step-4-verify-installation)
- [Daily Operations](#daily-operations)
- [GitHub Actions CI/CD](#github-actions-cicd)
- [Infrastructure Components](#infrastructure-components)
  - [Shared Data Services](#shared-data-services)
  - [cert-manager & TLS](#cert-manager--tls)
  - [HashiCorp Vault](#hashicorp-vault)
  - [External Secrets Operator](#external-secrets-operator)
  - [Authentik (SSO/IdP)](#authentik-ssoidp)
- [Upgrading ArgoCD](#upgrading-argocd)
- [Troubleshooting](#troubleshooting)
- [Security Notes](#security-notes)

## Domain Strategy

This cluster manages four domains with distinct purposes:

| Domain | Purpose | Example Services |
|--------|---------|------------------|
| `aster-lang.cloud` | Infrastructure & DevOps | ArgoCD, Vault, Authentik, Grafana |
| `aster-lang.dev` | Developer APIs & Tools | Policy API, Documentation |
| `wontlost.com` | Company/Personal | Main website, Applications |
| `ezymeta.com` | Product/Service | Product website, APIs |

### Service URLs

| Service | URL | Status |
|---------|-----|--------|
| ArgoCD | `https://argocd.aster-lang.cloud` | Active |
| Authentik (SSO) | `https://auth.aster-lang.cloud` | Active |
| Vault | `https://vault.aster-lang.cloud` | Active |
| Policy API | `https://policy.aster-lang.dev` | Active |

### TLS Certificates

All domains use **Let's Encrypt** with **Cloudflare DNS-01** challenge for wildcard certificates:

- `*.aster-lang.cloud` - Infrastructure services
- `*.aster-lang.dev` - Developer services
- `*.wontlost.com` - Company services
- `*.ezymeta.com` - Product services

For detailed domain allocation, see [docs/DOMAIN_STRATEGY.md](docs/DOMAIN_STRATEGY.md).

## Structure

```
k3s/
├── argocd/                          # ArgoCD configuration
│   ├── self/                        # ArgoCD self-management
│   │   ├── argocd-install.yaml     # ArgoCD installation (Helm chart argo-cd v7.9.0)
│   │   ├── argocd-config.yaml      # ArgoCD config (projects, applicationsets)
│   │   └── kustomization.yaml      # Self-management bootstrap
│   ├── projects/                    # Project definitions (RBAC boundaries)
│   │   ├── infrastructure.yaml     # Shared infrastructure project
│   │   ├── tls-management.yaml     # TLS/cert-manager project
│   │   ├── secrets-management.yaml # External Secrets project
│   │   ├── identity.yaml           # Authentik SSO project
│   │   ├── aster-lang.yaml         # aster-lang.dev applications
│   │   └── wontlost.yaml           # wontlost.com applications
│   ├── applicationsets/             # Dynamic app generators
│   │   ├── tls-management.yaml     # cert-manager ApplicationSet
│   │   ├── secrets-management.yaml # Vault, ESO, bootstrap ApplicationSet
│   │   ├── identity.yaml           # Authentik ApplicationSet
│   │   ├── data-services.yaml      # Shared PostgreSQL/Redis ApplicationSet
│   │   ├── platform.yaml           # Monitoring, observability ApplicationSet
│   │   ├── aster-lang.yaml         # Scans apps/aster-lang/*
│   │   └── wontlost.yaml           # Scans apps/wontlost/*
│   ├── ingress.yaml                # ArgoCD UI ingress (argocd.aster-lang.cloud)
│   ├── kustomization.yaml          # Config kustomization (projects + appsets + ingress)
│   ├── sso-config.yaml             # ArgoCD SSO configuration (Authentik OIDC)
│   └── repo-secret.yaml.sample     # Repository credentials template (DO NOT COMMIT REAL SECRETS)
├── docs/                            # Documentation
│   ├── DOMAIN_STRATEGY.md          # Domain allocation strategy
│   └── ARGOCD_SSO_SETUP.md         # ArgoCD SSO setup guide
├── apps/                            # Application manifests
│   ├── aster-lang/                  # aster-lang.cloud applications
│   │   └── policy/                  # -> Creates "aster-policy" app in "aster-policy" namespace
│   ├── wontlost/                    # wontlost.com applications
│   │   └── data/                    # -> Creates "wontlost-data" app in "wontlost-data" namespace
│   └── infrastructure/              # Shared infrastructure (organized by function)
│       ├── cert-manager/            # -> Creates "cert-manager" app
│       ├── reflector/               # -> Creates "reflector" app (cert replication)
│       ├── vault/                   # -> Creates "vault" and "vault-config" apps
│       │   ├── application.yaml    # Vault Helm chart
│       │   ├── config-application.yaml  # Internal TLS certs (sync-wave: -4)
│       │   └── internal-tls.yaml   # cert-manager Certificate
│       ├── external-secrets/        # -> Creates "external-secrets" and "eso-config" apps
│       │   ├── application.yaml    # ESO Helm chart
│       │   ├── config-application.yaml  # ClusterSecretStore (sync-wave: -3)
│       │   └── vault-secretstore.yaml  # Vault backend config
│       ├── bootstrap/               # -> Creates "bootstrap" app (ExternalSecrets)
│       ├── cloudnative-pg/          # -> Creates "cloudnative-pg" app (PostgreSQL operator)
│       ├── postgres-cluster/        # -> Creates "postgres-cluster" app (shared PostgreSQL)
│       │   └── manifests/          # CloudNativePG Cluster CR
│       ├── shared-redis/            # -> Creates "shared-redis" app (Bitnami Redis HA)
│       ├── authentik/               # -> Creates "authentik" app (uses shared data layer)
│       └── monitoring/              # -> Creates "monitoring" app (kube-prometheus-stack)
└── README.md
```

## How It Works

1. **Self-Management**: ArgoCD manages its own installation via `argocd/self/`
2. **Projects** define security boundaries and allowed source repos/destinations
3. **ApplicationSets** scan `apps/<project>/*` directories and auto-create ArgoCD Applications
4. Adding a new app is as simple as creating a new folder under `apps/<project>/`

### Sync-Wave Order (Infrastructure Dependencies)

Infrastructure components deploy in this order via sync-waves:

| Wave | Component | Description |
|------|-----------|-------------|
| -10 | cert-manager | TLS certificate management |
| -8 | cloudnative-pg | CloudNativePG operator (PostgreSQL operator) |
| -6 | reflector | Secret/ConfigMap replication |
| -4 | vault-config | Vault internal TLS certificates |
| -2 | vault | HashiCorp Vault (HA with Raft) |
| 0 | external-secrets | External Secrets Operator |
| 2 | eso-config | ClusterSecretStore for Vault |
| 3 | bootstrap | ExternalSecrets for all namespaces |
| 4 | postgres-cluster | Shared PostgreSQL cluster (3 instances HA) |
| 4 | shared-redis | Shared Redis with Sentinel (HA) |
| 5 | authentik | SSO/Identity Provider (uses shared data layer) |
| 6 | monitoring | Prometheus, Grafana, Alertmanager |

### Self-Management Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      ArgoCD Cluster                         │
│                                                             │
│  ┌─────────────┐     manages      ┌─────────────────────┐   │
│  │   argocd    │ ───────────────► │  ArgoCD Install     │   │
│  │   (App)     │                  │  (Helm argo-cd)     │   │
│  └─────────────┘                  └─────────────────────┘   │
│         │                                                   │
│         │ manages                                           │
│         ▼                                                   │
│  ┌─────────────┐     manages      ┌─────────────────────┐   │
│  │argocd-config│ ───────────────► │  Projects +         │   │
│  │   (App)     │                  │  ApplicationSets    │   │
│  └─────────────┘                  └─────────────────────┘   │
│                                            │                │
│                                            │ generates      │
│                                            ▼                │
│                                   ┌─────────────────────┐   │
│                                   │  aster-policy       │   │
│                                   │  wontlost-data      │   │
│                                   │  cert-manager       │   │
│                                   │  vault, monitoring  │   │
│                                   └─────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Naming Convention

| Directory | ArgoCD App Name | Namespace |
|-----------|-----------------|-----------|
| `apps/aster-lang/policy` | `aster-policy` | `aster-policy` |
| `apps/wontlost/data` | `wontlost-data` | `wontlost-data` |
| `apps/infrastructure/cert-manager` | `cert-manager` | `cert-manager` |
| `apps/infrastructure/vault` | `vault` | `vault` |
| `apps/infrastructure/vault` (config) | `vault-config` | `vault` |
| `apps/infrastructure/authentik` | `authentik` | `authentik` |
| `apps/infrastructure/external-secrets` | `external-secrets` | `external-secrets` |
| `apps/infrastructure/external-secrets` (config) | `eso-config` | `external-secrets` |
| `apps/infrastructure/cloudnative-pg` | `cloudnative-pg` | `cnpg-system` |
| `apps/infrastructure/postgres-cluster` | `postgres-cluster` | `data-services` |
| `apps/infrastructure/shared-redis` | `shared-redis` | `data-services` |
| `apps/infrastructure/monitoring` | `monitoring` | `monitoring` |

## Prerequisites

Before starting, ensure you have:

- [ ] K3s cluster running with kubectl access
- [ ] GitHub Personal Access Token (PAT) with `repo` scope for private repository access
- [ ] This repository cloned and pushed to GitHub

### Generate GitHub PAT

1. Go to GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate new token with `repo` scope (full control of private repositories)
3. Save the token securely - you'll need it in Step 2

## Clean Installation

### Step 0: Uninstall Existing ArgoCD (if applicable)

If you have an existing ArgoCD installation, remove it first to avoid conflicts.

#### Check Current Installation

```bash
# Check if ArgoCD namespace exists
kubectl get namespace argocd

# Check if installed via Helm
helm list -n argocd

# Check existing ArgoCD pods
kubectl get pods -n argocd
```

#### Option A: Uninstall Helm-based ArgoCD

```bash
# List Helm releases
helm list -n argocd

# Uninstall ArgoCD Helm release
helm uninstall argocd -n argocd

# Wait for resources to be removed
sleep 10

# Verify Helm release is gone
helm list -n argocd
```

#### Option B: Uninstall Manifest-based ArgoCD

```bash
# Delete all ArgoCD resources
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

#### Clean Up Namespace and CRDs

```bash
# Delete ArgoCD namespace (this removes all resources in it)
kubectl delete namespace argocd --grace-period=0 --force

# If namespace is stuck in Terminating state, run:
kubectl get namespace argocd -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f -

# Remove ArgoCD CRDs (Custom Resource Definitions)
kubectl get crd | grep argoproj.io | awk '{print $1}' | xargs -r kubectl delete crd

# Verify cleanup
kubectl get crd | grep argoproj
kubectl get namespace argocd
```

#### Clean Up Related Resources (Optional)

```bash
# Remove any ArgoCD-managed applications' namespaces if starting fresh
# WARNING: This will delete all resources in these namespaces!
# kubectl delete namespace aster-policy --grace-period=0 --force
# kubectl delete namespace wontlost-data --grace-period=0 --force

# Remove cluster-wide ArgoCD resources
kubectl delete clusterrole argocd-application-controller argocd-server 2>/dev/null
kubectl delete clusterrolebinding argocd-application-controller argocd-server 2>/dev/null
```

### Step 1: Install Fresh ArgoCD

> **Note**: This installs ArgoCD from raw manifests for initial bootstrap. Once self-management
> is enabled (Step 3), ArgoCD will manage itself via the Helm chart defined in
> `argocd/self/argocd-install.yaml` with HA configuration.

```bash
# Create ArgoCD namespace
kubectl create namespace argocd

# Install ArgoCD using official manifests (bootstrap only)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for all pods to be ready (this may take 1-2 minutes)
echo "Waiting for ArgoCD pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

# Verify installation
kubectl get pods -n argocd
```

Expected output:
```
NAME                                                READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                     1/1     Running   0          60s
argocd-applicationset-controller-xxxxxxxxx-xxxxx    1/1     Running   0          60s
argocd-dex-server-xxxxxxxxx-xxxxx                   1/1     Running   0          60s
argocd-notifications-controller-xxxxxxxxx-xxxxx     1/1     Running   0          60s
argocd-redis-xxxxxxxxx-xxxxx                        1/1     Running   0          60s
argocd-repo-server-xxxxxxxxx-xxxxx                  1/1     Running   0          60s
argocd-server-xxxxxxxxx-xxxxx                       1/1     Running   0          60s
```

### Step 2: Configure Repository Access

Since this is a private repository, ArgoCD needs credentials to access it.

#### Option A: Using GitHub Personal Access Token (Recommended for simplicity)

```bash
# Create secret for private repo access
# Replace ghp_YOUR_GITHUB_TOKEN with your actual GitHub PAT
kubectl create secret generic k3s-repo-creds -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/wontlost-ltd/k3s.git \
  --from-literal=username=wontlost-ltd \
  --from-literal=password=ghp_YOUR_GITHUB_TOKEN

# Label the secret so ArgoCD recognizes it as repository credentials
kubectl label secret k3s-repo-creds -n argocd argocd.argoproj.io/secret-type=repository

# Verify secret was created
kubectl get secret k3s-repo-creds -n argocd
```

#### Option B: Using GitHub App (Recommended for production)

```bash
# Create secret using GitHub App credentials
kubectl create secret generic k3s-repo-creds -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://github.com/wontlost-ltd/k3s.git \
  --from-literal=githubAppID=YOUR_APP_ID \
  --from-literal=githubAppInstallationID=YOUR_INSTALLATION_ID \
  --from-file=githubAppPrivateKey=/path/to/private-key.pem

kubectl label secret k3s-repo-creds -n argocd argocd.argoproj.io/secret-type=repository
```

#### Option C: Using SSH Key

```bash
# Create secret using SSH key
kubectl create secret generic k3s-repo-creds -n argocd \
  --from-literal=type=git \
  --from-literal=url=git@github.com:wontlost-ltd/k3s.git \
  --from-file=sshPrivateKey=/path/to/id_rsa

kubectl label secret k3s-repo-creds -n argocd argocd.argoproj.io/secret-type=repository
```

### Step 3: Enable Self-Management

Now enable ArgoCD to manage itself and all configurations from this Git repository.

```bash
# Make sure this repository is pushed to GitHub first!
# cd /path/to/k3s && git add . && git commit -m "Initial setup" && git push

# Apply self-management configuration
# Option A: If you have the repo cloned locally
kubectl apply -k /path/to/k3s/argocd/self/

# Option B: Apply directly from GitHub (after pushing)
kubectl apply -k https://github.com/wontlost-ltd/k3s.git/argocd/self
```

This creates two ArgoCD Applications:
- **argocd**: Manages ArgoCD installation itself (points to upstream argoproj/argo-cd)
- **argocd-config**: Manages Projects and ApplicationSets (points to this repository)

### Step 4: Verify Installation

```bash
# Check ArgoCD Applications
kubectl get applications -n argocd

# Expected output:
# NAME            SYNC STATUS   HEALTH STATUS
# argocd          Synced        Healthy
# argocd-config   Synced        Healthy

# Check Projects were created
kubectl get appprojects -n argocd

# Expected output:
# NAME             AGE
# aster-lang       1m
# default          5m
# infrastructure   1m
# wontlost         1m

# Check ApplicationSets were created
kubectl get applicationsets -n argocd

# Expected output:
# NAME                  AGE
# aster-lang-apps       1m
# infrastructure-apps   1m
# wontlost-apps         1m
```

### Step 5: Access ArgoCD UI

#### Option A: Port Forward (for local access)

```bash
# Start port forwarding in background
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Get admin password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "ArgoCD Admin Password: $ARGOCD_PASSWORD"

# Open browser
echo "Open https://localhost:8080"
echo "Username: admin"
echo "Password: $ARGOCD_PASSWORD"
```

#### Option B: Expose via Ingress (for remote access)

Create ingress for ArgoCD:

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  rules:
  - host: argocd.your-domain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOF

# Disable TLS on ArgoCD server (Traefik handles TLS)
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
```

#### Option C: NodePort (quick access without domain)

```bash
# Expose as NodePort
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort", "ports": [{"port": 443, "nodePort": 30443, "name": "https"}]}}'

# Access via https://<node-ip>:30443
echo "Access ArgoCD at: https://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'):30443"
```

## Daily Operations

### Add a New Application

Simply create a directory under `apps/<project>/` and add your Kubernetes manifests:

```bash
# Example: Add a new app "api" under aster-lang project
mkdir -p apps/aster-lang/api

# Add deployment manifest
cat > apps/aster-lang/api/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
        - name: api
          image: your-image:tag
          ports:
            - containerPort: 8080
EOF

# Add service manifest
cat > apps/aster-lang/api/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: api
  ports:
    - port: 80
      targetPort: 8080
EOF

# Commit and push - ArgoCD will auto-detect and create the app
git add .
git commit -m "Add api application"
git push
```

ArgoCD will automatically:
1. Detect the new directory via ApplicationSet
2. Create an Application named `aster-api`
3. Create namespace `aster-api`
4. Deploy all manifests in the directory

### Remove an Application

```bash
# Simply delete the directory
rm -rf apps/aster-lang/api

# Commit and push
git add .
git commit -m "Remove api application"
git push
```

ArgoCD will automatically delete the Application and all its resources.

### Sync an Application Manually

```bash
# Via CLI
argocd app sync aster-policy

# Via kubectl
kubectl patch application aster-policy -n argocd --type merge -p '{"operation": {"initiatedBy": {"username": "admin"}, "sync": {}}}'
```

## GitHub Actions CI/CD

This section explains how to set up GitHub Actions for automated CI/CD with ArgoCD using the GitOps pattern.

### CI/CD Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                              GitOps CI/CD Flow                             │
│                                                                            │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌───────────┐ │
│  │ Application  │    │   GitHub     │    │   GitHub     │    │   K3s     │ │
│  │    Repo      │───►│   Actions    │───►│  Container   │    │  Cluster  │ │
│  │ (aster-lang) │    │   (CI/CD)    │    │  Registry    │    │           │ │
│  └──────────────┘    └──────────────┘    └──────────────┘    └───────────┘ │
│         │                   │                   │                   ▲      │
│         │                   │                   │                   │      │
│         │                   ▼                   │                   │      │
│         │            ┌──────────────┐           │                   │      │
│         │            │     k3s      │           │                   │      │
│         └───────────►│     Repo     │◄──────────┘                   │      │
│          (update     │  (manifests) │                               │      │
│           image tag) └──────────────┘                               │      │
│                             │                                       │      │
│                             │ (git push triggers)                   │      │
│                             ▼                                       │      │
│                      ┌──────────────┐         (auto-sync)           │      │
│                      │   ArgoCD     │───────────────────────────────┘      │
│                      └──────────────┘                                      │
└────────────────────────────────────────────────────────────────────────────┘
```

### Prerequisites for GitHub Actions

1. **GitHub Container Registry (GHCR)** - Free with GitHub account
2. **GitHub Personal Access Token** or **GitHub App** for cross-repo access
3. **Repository Secrets** configured in both repos

### Step 1: Configure GitHub Secrets

#### In your Application Repository (e.g., `aster-lang`)

Go to **Settings → Secrets and variables → Actions → New repository secret**

| Secret Name | Description | Example |
|-------------|-------------|---------|
| `GHCR_TOKEN` | GitHub PAT with `write:packages` scope | `ghp_xxxxxxxxxxxx` |
| `K3S_REPO_TOKEN` | GitHub PAT with `repo` scope for k3s repo | `ghp_xxxxxxxxxxxx` |

#### In this k3s Repository

| Secret Name | Description | Example |
|-------------|-------------|---------|
| `GHCR_TOKEN` | GitHub PAT with `read:packages` scope | `ghp_xxxxxxxxxxxx` |

### Step 2: Create CI Workflow (Build & Push Image)

Create `.github/workflows/ci.yml` in your **application repository** (e.g., `aster-lang`):

```yaml
name: CI - Build and Push

on:
  push:
    branches: [main]
    paths:
      - 'src/**'
      - 'Dockerfile'
      - 'package.json'
      - 'pom.xml'
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository_owner }}/policy-api

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    outputs:
      image_tag: ${{ steps.meta.outputs.version }}
      image_digest: ${{ steps.build.outputs.digest }}

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract metadata for Docker
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,prefix=
            type=ref,event=branch
            type=ref,event=pr
            type=raw,value=latest,enable=${{ github.ref == 'refs/heads/main' }}

      - name: Build and push Docker image
        id: build
        uses: docker/build-push-action@v5
        with:
          context: .
          push: ${{ github.event_name != 'pull_request' }}
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Output image info
        run: |
          echo "Image Tags: ${{ steps.meta.outputs.tags }}"
          echo "Image Digest: ${{ steps.build.outputs.digest }}"

  update-manifest:
    needs: build
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest

    steps:
      - name: Checkout k3s repository
        uses: actions/checkout@v4
        with:
          repository: wontlost-ltd/k3s
          token: ${{ secrets.K3S_REPO_TOKEN }}
          path: k3s

      - name: Update image tag in manifest
        run: |
          cd k3s
          # Update the image tag in deployment
          IMAGE_TAG="${{ needs.build.outputs.image_tag }}"
          sed -i "s|image: ghcr.io/.*/policy-api:.*|image: ghcr.io/${{ github.repository_owner }}/policy-api:${IMAGE_TAG}|g" \
            apps/aster-lang/policy/deployment.yaml

          echo "Updated image tag to: ${IMAGE_TAG}"
          cat apps/aster-lang/policy/deployment.yaml | grep "image:"

      - name: Commit and push changes
        run: |
          cd k3s
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"

          git add .
          git diff --staged --quiet || git commit -m "chore: update policy-api image to ${{ needs.build.outputs.image_tag }}

          Triggered by: ${{ github.repository }}@${{ github.sha }}
          Workflow: ${{ github.workflow }}
          Run: ${{ github.run_id }}"

          git push
```

### Step 3: Create CD Workflow (Sync ArgoCD)

Create `.github/workflows/cd.yml` in this **k3s repository** to optionally trigger ArgoCD sync:

```yaml
name: CD - Sync ArgoCD

on:
  push:
    branches: [main]
    paths:
      - 'apps/**'
  workflow_dispatch:
    inputs:
      app_name:
        description: 'Application to sync (leave empty for all)'
        required: false
        type: string

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      changed_apps: ${{ steps.changes.outputs.apps }}
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 2

      - name: Detect changed apps
        id: changes
        run: |
          if [ "${{ github.event_name }}" == "workflow_dispatch" ] && [ -n "${{ inputs.app_name }}" ]; then
            echo "apps=[\"${{ inputs.app_name }}\"]" >> $GITHUB_OUTPUT
          else
            # Get changed directories under apps/
            CHANGED=$(git diff --name-only HEAD~1 HEAD -- apps/ | \
              grep -oP 'apps/[^/]+/[^/]+' | \
              sort -u | \
              sed 's|apps/||' | \
              jq -R -s -c 'split("\n") | map(select(length > 0))')
            echo "apps=${CHANGED}" >> $GITHUB_OUTPUT
          fi
          echo "Changed apps: ${CHANGED:-${{ inputs.app_name }}}"

  notify-argocd:
    needs: detect-changes
    if: needs.detect-changes.outputs.changed_apps != '[]'
    runs-on: ubuntu-latest
    steps:
      - name: Log detected changes
        run: |
          echo "The following apps were updated:"
          echo '${{ needs.detect-changes.outputs.changed_apps }}' | jq -r '.[]'
          echo ""
          echo "ArgoCD will automatically sync these changes."
          echo "No manual intervention required with automated sync policy."

      # Optional: Trigger ArgoCD sync via webhook (if you want immediate sync)
      # - name: Trigger ArgoCD Sync
      #   run: |
      #     curl -X POST \
      #       -H "Authorization: Bearer ${{ secrets.ARGOCD_TOKEN }}" \
      #       https://argocd.your-domain.com/api/v1/applications/aster-policy/sync
```

### Step 4: Create Reusable Workflow for Multiple Apps

Create `.github/workflows/build-push-update.yml` for reusable builds:

```yaml
name: Reusable - Build, Push, Update

on:
  workflow_call:
    inputs:
      app_name:
        required: true
        type: string
        description: 'Application name (e.g., policy-api)'
      app_path:
        required: true
        type: string
        description: 'Path in k3s repo (e.g., aster-lang/policy)'
      dockerfile:
        required: false
        type: string
        default: 'Dockerfile'
        description: 'Dockerfile path'
      context:
        required: false
        type: string
        default: '.'
        description: 'Docker build context'
    secrets:
      K3S_REPO_TOKEN:
        required: true

env:
  REGISTRY: ghcr.io

jobs:
  build-and-update:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout application repository
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to Container Registry
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Generate image tag
        id: tag
        run: |
          SHORT_SHA=$(echo ${{ github.sha }} | cut -c1-7)
          TIMESTAMP=$(date +%Y%m%d%H%M%S)
          TAG="${SHORT_SHA}-${TIMESTAMP}"
          echo "tag=${TAG}" >> $GITHUB_OUTPUT
          echo "Generated tag: ${TAG}"

      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: ${{ inputs.context }}
          file: ${{ inputs.dockerfile }}
          push: true
          tags: |
            ${{ env.REGISTRY }}/${{ github.repository_owner }}/${{ inputs.app_name }}:${{ steps.tag.outputs.tag }}
            ${{ env.REGISTRY }}/${{ github.repository_owner }}/${{ inputs.app_name }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Checkout k3s repository
        uses: actions/checkout@v4
        with:
          repository: wontlost-ltd/k3s
          token: ${{ secrets.K3S_REPO_TOKEN }}
          path: k3s

      - name: Update manifest
        run: |
          cd k3s
          MANIFEST_PATH="apps/${{ inputs.app_path }}/deployment.yaml"

          if [ -f "$MANIFEST_PATH" ]; then
            # Update image tag using yq (more reliable than sed)
            NEW_IMAGE="${{ env.REGISTRY }}/${{ github.repository_owner }}/${{ inputs.app_name }}:${{ steps.tag.outputs.tag }}"

            # Using sed for simplicity (install yq if needed for complex manifests)
            sed -i "s|image:.*${{ inputs.app_name }}:.*|image: ${NEW_IMAGE}|g" "$MANIFEST_PATH"

            echo "Updated $MANIFEST_PATH with image: ${NEW_IMAGE}"
          else
            echo "Warning: Manifest not found at $MANIFEST_PATH"
            exit 1
          fi

      - name: Commit and push
        run: |
          cd k3s
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"

          git add .
          if git diff --staged --quiet; then
            echo "No changes to commit"
          else
            git commit -m "chore(${{ inputs.app_name }}): update image to ${{ steps.tag.outputs.tag }}

            Source: ${{ github.repository }}@${{ github.sha }}
            Workflow: ${{ github.workflow }}
            Run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"
            git push
          fi
```

### Step 5: Use Reusable Workflow

In your application repo, create `.github/workflows/deploy.yml`:

```yaml
name: Deploy

on:
  push:
    branches: [main]
    paths:
      - 'src/**'
      - 'Dockerfile'

jobs:
  deploy:
    uses: ./.github/workflows/build-push-update.yml
    with:
      app_name: policy-api
      app_path: aster-lang/policy
    secrets:
      K3S_REPO_TOKEN: ${{ secrets.K3S_REPO_TOKEN }}
```

### Step 6: Setup GitHub Container Registry Permissions

For private images, create `imagePullSecrets` in your cluster:

```bash
# Create GHCR pull secret
kubectl create secret docker-registry ghcr-pull-secret \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GITHUB_USERNAME \
  --docker-password=ghp_YOUR_TOKEN \
  --docker-email=your-email@example.com \
  -n aster-policy

# Reference in deployment
# spec:
#   template:
#     spec:
#       imagePullSecrets:
#         - name: ghcr-pull-secret
```

Or create it in all namespaces using a script:

```bash
#!/bin/bash
NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
for ns in $NAMESPACES; do
  kubectl create secret docker-registry ghcr-pull-secret \
    --docker-server=ghcr.io \
    --docker-username=YOUR_GITHUB_USERNAME \
    --docker-password=ghp_YOUR_TOKEN \
    --docker-email=your-email@example.com \
    -n $ns --dry-run=client -o yaml | kubectl apply -f -
done
```

### Alternative: ArgoCD Image Updater

Instead of GitHub Actions updating manifests, you can use **ArgoCD Image Updater** for automatic image updates:

#### Install ArgoCD Image Updater

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml
```

#### Configure Application for Auto-Update

Add annotations to your ArgoCD Application:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: aster-policy
  namespace: argocd
  annotations:
    argocd-image-updater.argoproj.io/image-list: policy-api=ghcr.io/wontlost-ltd/policy-api
    argocd-image-updater.argoproj.io/policy-api.update-strategy: latest
    argocd-image-updater.argoproj.io/write-back-method: git
spec:
  # ... rest of application spec
```

### Workflow Comparison

| Approach | Pros | Cons |
|----------|------|------|
| **GitHub Actions (Update Manifest)** | Full control, audit trail in Git, works with any registry | Requires cross-repo token, more complex setup |
| **ArgoCD Image Updater** | Automatic, no cross-repo access needed | Less control, requires additional component |
| **Manual Updates** | Simple, explicit control | Slow, error-prone |

### Complete Example: Multi-App CI/CD

Here's a complete example for a monorepo with multiple services:

```yaml
# .github/workflows/ci-cd.yml
name: CI/CD Pipeline

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      policy-api: ${{ steps.filter.outputs.policy-api }}
      web-app: ${{ steps.filter.outputs.web-app }}
    steps:
      - uses: actions/checkout@v4
      - uses: dorny/paths-filter@v2
        id: filter
        with:
          filters: |
            policy-api:
              - 'services/policy-api/**'
            web-app:
              - 'services/web-app/**'

  build-policy-api:
    needs: detect-changes
    if: needs.detect-changes.outputs.policy-api == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build and Push
        uses: docker/build-push-action@v5
        with:
          context: services/policy-api
          push: ${{ github.event_name == 'push' }}
          tags: ghcr.io/${{ github.repository_owner }}/policy-api:${{ github.sha }}

  build-web-app:
    needs: detect-changes
    if: needs.detect-changes.outputs.web-app == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build and Push
        uses: docker/build-push-action@v5
        with:
          context: services/web-app
          push: ${{ github.event_name == 'push' }}
          tags: ghcr.io/${{ github.repository_owner }}/web-app:${{ github.sha }}

  update-manifests:
    needs: [build-policy-api, build-web-app]
    if: always() && github.event_name == 'push' && (needs.build-policy-api.result == 'success' || needs.build-web-app.result == 'success')
    runs-on: ubuntu-latest
    steps:
      - name: Checkout k3s repo
        uses: actions/checkout@v4
        with:
          repository: wontlost-ltd/k3s
          token: ${{ secrets.K3S_REPO_TOKEN }}

      - name: Update policy-api manifest
        if: needs.build-policy-api.result == 'success'
        run: |
          sed -i "s|image: ghcr.io/.*/policy-api:.*|image: ghcr.io/${{ github.repository_owner }}/policy-api:${{ github.sha }}|" \
            apps/aster-lang/policy/deployment.yaml

      - name: Update web-app manifest
        if: needs.build-web-app.result == 'success'
        run: |
          sed -i "s|image: ghcr.io/.*/web-app:.*|image: ghcr.io/${{ github.repository_owner }}/web-app:${{ github.sha }}|" \
            apps/aster-lang/web/deployment.yaml

      - name: Commit and push
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add .
          git diff --staged --quiet || git commit -m "chore: update images from ${{ github.repository }}@${{ github.sha }}"
          git push
```

### Debugging GitHub Actions

```yaml
# Add these steps for debugging

- name: Debug - Print environment
  run: |
    echo "Event: ${{ github.event_name }}"
    echo "Ref: ${{ github.ref }}"
    echo "SHA: ${{ github.sha }}"
    echo "Repository: ${{ github.repository }}"

- name: Debug - List files
  run: |
    ls -la
    find . -name "*.yaml" -type f

- name: Debug - Show manifest content
  run: cat apps/aster-lang/policy/deployment.yaml
```

## Infrastructure Components

This section describes the shared infrastructure services deployed via ArgoCD.

### Shared Data Services

The cluster provides a shared data layer using CloudNativePG for PostgreSQL and Bitnami Redis for caching/sessions.

#### Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Shared Data Layer (data-services namespace)       │
│                                                                          │
│  ┌───────────────────────────────┐    ┌───────────────────────────────┐ │
│  │     CloudNativePG Cluster     │    │       Redis Sentinel HA       │ │
│  │    (shared-postgres)          │    │      (shared-redis)           │ │
│  │                               │    │                               │ │
│  │  ┌─────────┐ ┌─────────┐     │    │  ┌────────┐  ┌─────────────┐  │ │
│  │  │ Primary │ │Replica 1│     │    │  │ Master │  │ Sentinel x3 │  │ │
│  │  └─────────┘ └─────────┘     │    │  └────────┘  └─────────────┘  │ │
│  │              ┌─────────┐     │    │  ┌──────────┐ ┌──────────┐    │ │
│  │              │Replica 2│     │    │  │ Replica 1│ │ Replica 2│    │ │
│  │              └─────────┘     │    │  └──────────┘ └──────────┘    │ │
│  │                               │    │                               │ │
│  │  Databases:                   │    │  Features:                    │ │
│  │  - authentik                  │    │  - Password auth              │ │
│  │  - grafana                    │    │  - Automatic failover         │ │
│  │  - policy_api                 │    │  - Persistence enabled        │ │
│  └───────────────────────────────┘    └───────────────────────────────┘ │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
          │                                       │
          ▼                                       ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           Applications                                   │
│                                                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │
│  │  Authentik  │  │   Grafana   │  │ Policy API  │  │  Future Apps │    │
│  │  (Identity) │  │(Monitoring) │  │   (API)     │  │              │    │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Components

| Component | Technology | HA Configuration |
|-----------|------------|------------------|
| PostgreSQL | CloudNativePG | 3 instances (1 primary + 2 replicas) |
| Redis | Bitnami Redis | Master + 2 replicas + Sentinel |

#### Vault Secrets Configuration

Before deploying, configure the following secrets in Vault:

```bash
# PostgreSQL superuser credentials
vault kv put secret/data-services/postgres \
    superuser_username="postgres" \
    superuser_password="<secure-password>" \
    host="shared-postgres-rw.data-services.svc.cluster.local" \
    port="5432"

# Authentik database credentials
vault kv put secret/data-services/authentik-db \
    database="authentik" \
    username="authentik_user" \
    password="<secure-password>"

# Grafana database credentials
vault kv put secret/data-services/grafana-db \
    database="grafana" \
    username="grafana_user" \
    password="<secure-password>"

# Policy API database credentials
vault kv put secret/data-services/policy-api-db \
    database="policy_api" \
    username="policy_api_user" \
    password="<secure-password>"

# Redis credentials
vault kv put secret/data-services/redis \
    password="<secure-password>" \
    host="shared-redis-master.data-services.svc.cluster.local" \
    port="6379"
```

#### Connecting Applications

Applications connect to the shared data layer via:

**PostgreSQL:**
```yaml
env:
  - name: DATABASE_HOST
    value: shared-postgres-rw.data-services.svc.cluster.local
  - name: DATABASE_PORT
    value: "5432"
  - name: DATABASE_NAME
    valueFrom:
      secretKeyRef:
        name: my-app-postgres-credentials
        key: database
```

**Redis:**
```yaml
env:
  - name: REDIS_HOST
    value: shared-redis-master.data-services.svc.cluster.local
  - name: REDIS_PORT
    value: "6379"  # Redis master port (Sentinel handles failover automatically)
```

#### Verify Data Services

```bash
# Check CloudNativePG operator
kubectl get pods -n cnpg-system

# Check PostgreSQL cluster
kubectl get clusters -n data-services
kubectl get pods -n data-services -l cnpg.io/cluster=shared-postgres

# Check Redis cluster
kubectl get pods -n data-services -l app.kubernetes.io/name=redis

# Check cluster status
kubectl cnpg status shared-postgres -n data-services
```

### cert-manager & TLS

cert-manager provides automatic TLS certificate management using Let's Encrypt with Cloudflare DNS-01 challenge.

#### Prerequisites

1. Create Cloudflare API Token at https://dash.cloudflare.com/profile/api-tokens
   - Permissions: Zone → DNS → Edit
   - Zone Resources: Include → All zones

2. Create the secret:

```bash
kubectl create namespace cert-manager

kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN \
  -n cert-manager
```

3. Configure DNS (in Cloudflare):

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `*` | `<K3S_IP>` | DNS only |
| A | `@` | `<K3S_IP>` | DNS only |

Repeat for all domains: `aster-lang.cloud`, `aster-lang.dev`, `wontlost.com`, `ezymeta.com`

#### Verify Certificates

```bash
# Check ClusterIssuers
kubectl get clusterissuers

# Check Certificates
kubectl get certificates -n cert-manager

# Check Certificate secrets
kubectl get secrets -n cert-manager | grep tls
```

For detailed instructions, see [apps/infrastructure/cert-manager/README.md](apps/infrastructure/cert-manager/README.md).

### HashiCorp Vault

Vault provides centralized secrets management for all applications in the cluster.

#### Quick Start

```bash
# 1. ArgoCD will deploy Vault automatically via apps/infrastructure/vault/application.yaml

# 2. After deployment, initialize Vault (first time only)
VAULT_POD=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n vault $VAULT_POD -- vault operator init

# IMPORTANT: Save the unseal keys and root token securely!

# 3. Unseal Vault (required after init or pod restart)
kubectl exec -n vault $VAULT_POD -- vault operator unseal <UNSEAL_KEY_1>
kubectl exec -n vault $VAULT_POD -- vault operator unseal <UNSEAL_KEY_2>
kubectl exec -n vault $VAULT_POD -- vault operator unseal <UNSEAL_KEY_3>
```

#### Enable Kubernetes Auth

```bash
# Port forward to Vault
kubectl port-forward -n vault svc/vault 8200:8200 &

export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='<ROOT_TOKEN>'

# Enable Kubernetes auth
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"

# Enable KV secrets engine
vault secrets enable -path=secret kv-v2
```

#### Usage with Applications

Add Vault Agent Injector annotations to deployments:

```yaml
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "policy-api"
    vault.hashicorp.com/agent-inject-secret-config: "secret/data/apps/policy-api"
```

For detailed instructions, see [apps/infrastructure/vault/README.md](apps/infrastructure/vault/README.md).

### External Secrets Operator

External Secrets Operator (ESO) syncs secrets from Vault to Kubernetes, enabling centralized secrets management.

#### Architecture

```
Vault (secret/apps/policy-api) → External Secrets Operator → K8s Secret (policy-api-secrets)
                                                                      ↓
                                                               Your Application
```

#### Prerequisites

Configure Vault for External Secrets:

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN='<ROOT_TOKEN>'

# Create policy for external-secrets
vault policy write external-secrets - <<EOF
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

# Create role for external-secrets
vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets \
    ttl=1h
```

#### Store Secrets in Vault

```bash
# Store application secrets
vault kv put secret/apps/policy-api \
    database_url="postgresql://user:pass@postgres:5432/policy" \
    api_key="your-api-key" \
    jwt_secret="your-jwt-secret"
```

#### Create ExternalSecret

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
  dataFrom:
    - extract:
        key: apps/policy-api    # Fetches all keys from this Vault path
```

#### Verify

```bash
# Check ExternalSecrets
kubectl get externalsecrets -A

# Check synced secrets
kubectl get secrets -A -l "reconcile.external-secrets.io/created-by"
```

For detailed instructions, see [apps/infrastructure/external-secrets/README.md](apps/infrastructure/external-secrets/README.md).

### Authentik (SSO/IdP)

Authentik provides SSO, user management, and authentication for all applications.

#### Prerequisites

1. PostgreSQL database (using shared PostgreSQL in `wontlost-data` namespace)
2. DNS record for `auth.aster-lang.cloud`

#### Pre-Installation: Create Secrets

```bash
# Create namespace
kubectl create namespace authentik

# Generate secret key
AUTHENTIK_SECRET_KEY=$(openssl rand -base64 36)

# Create PostgreSQL database (if not exists)
# Connect to PostgreSQL and run:
# CREATE DATABASE authentik;
# CREATE USER authentik WITH ENCRYPTED PASSWORD 'your-password';
# GRANT ALL PRIVILEGES ON DATABASE authentik TO authentik;

# Create Kubernetes secret
kubectl create secret generic authentik-secrets -n authentik \
  --from-literal=AUTHENTIK_SECRET_KEY="$AUTHENTIK_SECRET_KEY" \
  --from-literal=AUTHENTIK_POSTGRESQL__HOST="postgres.wontlost-data.svc.cluster.local" \
  --from-literal=AUTHENTIK_POSTGRESQL__PORT="5432" \
  --from-literal=AUTHENTIK_POSTGRESQL__NAME="authentik" \
  --from-literal=AUTHENTIK_POSTGRESQL__USER="authentik" \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="your-secure-password" \
  --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="admin-initial-password" \
  --from-literal=AUTHENTIK_BOOTSTRAP_EMAIL="admin@aster-lang.cloud"
```

#### Access Authentik

After ArgoCD deploys Authentik:

```bash
# Access UI
open https://auth.aster-lang.cloud

# Initial setup URL
open https://auth.aster-lang.cloud/if/flow/initial-setup/
```

#### OAuth2/OIDC Endpoints

Use these endpoints when integrating applications:

| Endpoint | URL |
|----------|-----|
| Authorization | `https://auth.aster-lang.cloud/application/o/authorize/` |
| Token | `https://auth.aster-lang.cloud/application/o/token/` |
| User Info | `https://auth.aster-lang.cloud/application/o/userinfo/` |
| JWKS | `https://auth.aster-lang.cloud/application/o/<app-slug>/jwks/` |

#### Protect Applications with Forward Auth

Create Traefik middleware for Authentik forward auth:

```yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authentik-auth
  namespace: aster-policy
spec:
  forwardAuth:
    address: http://authentik-server.authentik.svc.cluster.local/outpost.goauthentik.io/auth/traefik
    trustForwardHeader: true
    authResponseHeaders:
      - X-authentik-username
      - X-authentik-groups
      - X-authentik-email
```

For detailed instructions, see [apps/infrastructure/authentik/README.md](apps/infrastructure/authentik/README.md).

### Infrastructure Directory Structure

```
apps/infrastructure/
├── cert-manager/
│   ├── application.yaml         # cert-manager Helm chart
│   ├── config-application.yaml  # ClusterIssuers + Certificates
│   ├── cluster-issuers.yaml     # Let's Encrypt with Cloudflare DNS-01
│   ├── wildcard-certificates.yaml # Wildcard certs for all domains
│   └── README.md
├── vault/
│   ├── application.yaml         # Vault Helm chart
│   └── README.md
├── external-secrets/
│   ├── application.yaml         # External Secrets Operator Helm chart
│   ├── config-application.yaml  # ClusterSecretStore configuration
│   ├── vault-secretstore.yaml   # Vault backend connection
│   ├── examples/                # ExternalSecret templates
│   └── README.md
├── bootstrap/
│   ├── kustomization.yaml       # ExternalSecrets for all apps
│   ├── postgres-external-secret.yaml  # PostgreSQL credentials
│   ├── redis-external-secret.yaml     # Redis credentials
│   └── authentik-external-secret.yaml # Authentik secrets
├── cloudnative-pg/
│   ├── application.yaml         # CloudNativePG operator Helm chart
│   └── kustomization.yaml
├── postgres-cluster/
│   ├── application.yaml         # PostgreSQL cluster ArgoCD app
│   ├── kustomization.yaml
│   └── manifests/
│       ├── cluster.yaml         # CloudNativePG Cluster CR (3 instances)
│       └── kustomization.yaml
├── shared-redis/
│   ├── application.yaml         # Bitnami Redis Helm chart (Sentinel HA)
│   └── kustomization.yaml
└── authentik/
    ├── application.yaml         # Authentik Helm chart (uses shared data layer)
    ├── kustomization.yaml
    └── README.md
```

## Upgrading ArgoCD

With self-management enabled, upgrading ArgoCD is done via Git:

### Check Current Version

```bash
kubectl get pods -n argocd -o jsonpath='{.items[0].spec.containers[0].image}' | cut -d: -f2
```

### Upgrade Process

```bash
# 1. Edit argocd/self/argocd-install.yaml
# Change targetRevision from v2.13.2 to desired version (e.g., v2.14.0)
sed -i 's/targetRevision: v2.13.2/targetRevision: v2.14.0/' argocd/self/argocd-install.yaml

# 2. Commit and push
git add argocd/self/argocd-install.yaml
git commit -m "Upgrade ArgoCD to v2.14.0"
git push

# 3. ArgoCD will detect the change and upgrade itself!
# Monitor the upgrade
kubectl get pods -n argocd -w
```

### Check Available Versions

```bash
# List recent ArgoCD releases
curl -s https://api.github.com/repos/argoproj/argo-cd/releases | jq -r '.[0:10] | .[].tag_name'
```

## Troubleshooting

### ArgoCD Pods Not Starting

```bash
# Check pod status
kubectl get pods -n argocd

# Check pod events
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-server

# Check logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=100
```

### Application Stuck in "Unknown" or "Progressing"

```bash
# Check application status
kubectl get application <app-name> -n argocd -o yaml

# Force refresh
argocd app get <app-name> --refresh

# Check repo server logs (handles Git operations)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100
```

### Repository Connection Failed

```bash
# Test repository connectivity
argocd repo list

# Check repo server can reach GitHub
kubectl exec -n argocd deployment/argocd-repo-server -- git ls-remote https://github.com/wontlost-ltd/k3s.git

# Verify secret is correct
kubectl get secret k3s-repo-creds -n argocd -o yaml
```

### Namespace Stuck in Terminating

```bash
# Get namespace JSON and remove finalizers
kubectl get namespace <namespace> -o json | \
  jq '.spec.finalizers = []' | \
  kubectl replace --raw "/api/v1/namespaces/<namespace>/finalize" -f -
```

### Reset ArgoCD Admin Password

```bash
# Generate new password hash (replace 'newpassword' with your password)
ARGOCD_PASSWORD_HASH=$(htpasswd -nbBC 10 "" newpassword | tr -d ':\n' | sed 's/$2y/$2a/')

# Patch the secret
kubectl -n argocd patch secret argocd-secret -p "{\"stringData\": {\"admin.password\": \"$ARGOCD_PASSWORD_HASH\", \"admin.passwordMtime\": \"$(date +%FT%T%Z)\"}}"

# Restart ArgoCD server
kubectl rollout restart deployment argocd-server -n argocd
```

### Complete Reset (Nuclear Option)

If everything is broken, start fresh:

```bash
# Delete everything
kubectl delete namespace argocd --force --grace-period=0
kubectl get crd | grep argoproj.io | awk '{print $1}' | xargs -r kubectl delete crd

# Wait a moment
sleep 30

# Start from Step 1
```

## Security Notes

- **Repository Credentials**: Never commit real credentials to Git. Use `kubectl create secret` as shown above.
- **Project Isolation**: Each Project restricts which namespaces and repos apps can use.
- **Infrastructure Project**: Has broader permissions for cluster-wide resources - use carefully.
- **Self-Managed Prune**: ArgoCD self-management has `prune: false` for safety - manual cleanup may be needed after upgrades.
- **RBAC**: Consider enabling ArgoCD RBAC for multi-user environments.

## References

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [ArgoCD GitHub Repository](https://github.com/argoproj/argo-cd)
- [ApplicationSet Documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/application-set/)
- [K3s Documentation](https://docs.k3s.io/)
