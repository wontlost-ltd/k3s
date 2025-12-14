# cert-manager Setup

cert-manager automates TLS certificate management using Let's Encrypt with Cloudflare DNS-01 challenge.

## Features

- Automatic certificate issuance and renewal
- Wildcard certificates for all domains
- Cloudflare DNS-01 challenge (works behind firewalls, supports wildcards)
- Both staging and production Let's Encrypt issuers

## Domains Configured

| Domain | Certificate Secret | Purpose |
|--------|-------------------|---------|
| `*.aster-lang.cloud` | `aster-lang-cloud-tls` | Infrastructure services |
| `*.aster-lang.dev` | `aster-lang-dev-tls` | Developer APIs |
| `*.wontlost.com` | `wontlost-com-tls` | Company website |
| `*.ezymeta.com` | `ezymeta-com-tls` | Product services |

## Prerequisites

### 1. Create Cloudflare API Token

1. Go to [Cloudflare API Tokens](https://dash.cloudflare.com/profile/api-tokens)
2. Click **Create Token**
3. Use the **Edit zone DNS** template, or create custom:
   - **Permissions**: Zone → DNS → Edit
   - **Zone Resources**: Include → All zones (or select specific zones)
4. Copy the generated token

### 2. Create Kubernetes Secret

```bash
# Create cert-manager namespace if not exists
kubectl create namespace cert-manager

# Create Cloudflare API token secret
kubectl create secret generic cloudflare-api-token \
  --from-literal=api-token=YOUR_CLOUDFLARE_API_TOKEN \
  -n cert-manager

# Verify secret
kubectl get secret cloudflare-api-token -n cert-manager
```

### 3. Configure DNS Records (Cloudflare)

Create wildcard A records pointing to your K3s load balancer IP:

```bash
# Get your K3s external IP
kubectl get nodes -o wide

# In Cloudflare DNS, create:
# Type: A, Name: *, Content: <K3S_IP>, Proxy: DNS only (grey cloud)
```

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `*` | `<K3S_IP>` | DNS only |
| A | `@` | `<K3S_IP>` | DNS only |

Repeat for each domain: `aster-lang.cloud`, `aster-lang.dev`, `wontlost.com`, `ezymeta.com`

## Deployment Order

ArgoCD deploys in this order:

1. **cert-manager** (Helm chart via `application.yaml`)
2. **cert-manager-config** (ClusterIssuers + Certificates via `config-application.yaml`)

## Usage in Applications

### Option 1: Reference Wildcard Certificate (Recommended)

Use the pre-created wildcard certificate in your Ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  namespace: my-namespace
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - my-app.aster-lang.dev
      secretName: aster-lang-dev-tls  # Reference wildcard cert
  rules:
    - host: my-app.aster-lang.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

**Note**: You may need to copy the TLS secret to your namespace or use a secret reflector.

### Option 2: Per-Ingress Certificate (Auto-created)

Let cert-manager create a certificate automatically:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod  # Auto-create cert
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - my-app.aster-lang.dev
      secretName: my-app-tls  # cert-manager creates this
  rules:
    - host: my-app.aster-lang.dev
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

## Copying Wildcard Certificates to Other Namespaces

### Manual Copy

```bash
# Copy certificate secret to another namespace
kubectl get secret aster-lang-dev-tls -n cert-manager -o yaml | \
  sed 's/namespace: cert-manager/namespace: aster-policy/' | \
  kubectl apply -f -
```

### Using Reflector (Automated)

Install [Reflector](https://github.com/emberstack/kubernetes-reflector) for automatic secret replication:

```bash
# Install Reflector via Helm
helm repo add emberstack https://emberstack.github.io/helm-charts
helm install reflector emberstack/reflector -n cert-manager
```

The wildcard certificates are already annotated for Reflector.

## Verification

### Check ClusterIssuers

```bash
kubectl get clusterissuers
# NAME                  READY   AGE
# letsencrypt-prod      True    5m
# letsencrypt-staging   True    5m
```

### Check Certificates

```bash
kubectl get certificates -n cert-manager
# NAME                       READY   SECRET                  AGE
# aster-lang-cloud-wildcard  True    aster-lang-cloud-tls    5m
# aster-lang-dev-wildcard    True    aster-lang-dev-tls      5m
# wontlost-com-wildcard      True    wontlost-com-tls        5m
# ezymeta-com-wildcard       True    ezymeta-com-tls         5m

# Check certificate details
kubectl describe certificate aster-lang-cloud-wildcard -n cert-manager
```

### Check Certificate Secrets

```bash
kubectl get secrets -n cert-manager | grep tls
# aster-lang-cloud-tls   kubernetes.io/tls   2      5m
# aster-lang-dev-tls     kubernetes.io/tls   2      5m
# wontlost-com-tls       kubernetes.io/tls   2      5m
# ezymeta-com-tls        kubernetes.io/tls   2      5m
```

## Troubleshooting

### Certificate Not Ready

```bash
# Check certificate status
kubectl describe certificate <cert-name> -n cert-manager

# Check certificate request
kubectl get certificaterequest -n cert-manager
kubectl describe certificaterequest <request-name> -n cert-manager

# Check orders (ACME)
kubectl get orders -n cert-manager
kubectl describe order <order-name> -n cert-manager

# Check challenges
kubectl get challenges -n cert-manager
kubectl describe challenge <challenge-name> -n cert-manager
```

### DNS Challenge Failed

```bash
# Verify Cloudflare API token works
kubectl get secret cloudflare-api-token -n cert-manager -o jsonpath='{.data.api-token}' | base64 -d

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager --tail=100
```

### Common Issues

1. **"DNS problem: NXDOMAIN"**: DNS record not propagated, wait 5-10 minutes
2. **"Unauthorized"**: Cloudflare API token invalid or lacks permissions
3. **"Rate limited"**: Too many certificate requests, use staging issuer for testing

## Switching to Staging (for Testing)

Replace `letsencrypt-prod` with `letsencrypt-staging` in your Certificate or Ingress:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
```

Staging certificates are not trusted by browsers but have no rate limits.
