# Domain Strategy

This document outlines the domain allocation strategy for the K3s cluster.

## Domain Overview

| Domain | Purpose | Target Audience |
|--------|---------|-----------------|
| `aster-lang.cloud` | Infrastructure & Cloud Services | DevOps, Internal |
| `aster-lang.dev` | Developer Tools & APIs | Developers, Public |
| `wontlost.com` | Company/Personal Brand | Public |
| `ezymeta.com` | Product/Service | Public |

## Subdomain Allocation

### aster-lang.cloud (Infrastructure)

Internal/DevOps services - consider restricting access via Authentik.

| Subdomain | Service | Status |
|-----------|---------|--------|
| `auth.aster-lang.cloud` | Authentik (SSO/IdP) | Active |
| `vault.aster-lang.cloud` | HashiCorp Vault | Active |
| `argocd.aster-lang.cloud` | ArgoCD Dashboard | Active |
| `grafana.aster-lang.cloud` | Grafana Monitoring | Active |
| `prometheus.aster-lang.cloud` | Prometheus Metrics | Active |
| `alertmanager.aster-lang.cloud` | Alert Manager | Active |
| `traefik.aster-lang.cloud` | Traefik Dashboard | Future |
| `longhorn.aster-lang.cloud` | Longhorn Storage UI | Future |

## Multi-Domain Services

Some services are accessible via multiple domains for flexibility:

### ArgoCD (Multi-Domain)

| Domain | Purpose |
|--------|---------|
| `argocd.aster-lang.cloud` | Primary (infrastructure) |
| `argocd.aster-lang.dev` | Developer access |
| `argocd.ezymeta.com` | Product team access |

All domains route to the same ArgoCD instance. SSO redirect URIs are configured for all three.

### aster-lang.dev (Developer)

Public-facing developer resources.

| Subdomain | Service | Status |
|-----------|---------|--------|
| `policy.aster-lang.dev` | Policy API (Production) | Active |
| `staging-api.aster-lang.dev` | Policy API (Staging) | Future |
| `docs.aster-lang.dev` | Documentation | Future |
| `playground.aster-lang.dev` | Online Playground | Future |
| `registry.aster-lang.dev` | Package Registry | Future |

### wontlost.com (Company)

Company/personal brand presence.

| Subdomain | Service | Status |
|-----------|---------|--------|
| `wontlost.com` / `www.wontlost.com` | Main Website | Future |
| `data.wontlost.com` | Data Service | Active |
| `app.wontlost.com` | Web Application | Future |
| `status.wontlost.com` | Status Page | Future |

### ezymeta.com (Product)

Product/service domain.

| Subdomain | Service | Status |
|-----------|---------|--------|
| `ezymeta.com` / `www.ezymeta.com` | Product Website | Future |
| `app.ezymeta.com` | Product Application | Future |
| `api.ezymeta.com` | Product API | Future |

## DNS Configuration (Cloudflare)

### Option A: Wildcard DNS (Recommended)

Create wildcard A records pointing to your K3s load balancer IP:

```
*.aster-lang.cloud  → <K3S_LB_IP>
*.aster-lang.dev    → <K3S_LB_IP>
*.wontlost.com      → <K3S_LB_IP>
*.ezymeta.com       → <K3S_LB_IP>
```

### Option B: Individual DNS Records

Create specific A records for each subdomain as needed.

## TLS Certificates

Using cert-manager with Cloudflare DNS-01 challenge for wildcard certificates:

| Certificate | Domains | Secret Name |
|-------------|---------|-------------|
| aster-lang-cloud-wildcard | `*.aster-lang.cloud`, `aster-lang.cloud` | `aster-lang-cloud-tls` |
| aster-lang-dev-wildcard | `*.aster-lang.dev`, `aster-lang.dev` | `aster-lang-dev-tls` |
| wontlost-wildcard | `*.wontlost.com`, `wontlost.com` | `wontlost-com-tls` |
| ezymeta-wildcard | `*.ezymeta.com`, `ezymeta.com` | `ezymeta-com-tls` |

## Security Zones

### Public Zone
- `aster-lang.dev` - Public APIs and documentation
- `wontlost.com` - Public website
- `ezymeta.com` - Public product

### Protected Zone (Authentik SSO)
- `aster-lang.cloud` - Infrastructure services protected by Authentik forward auth

## Implementation Priority

1. **Phase 1: Infrastructure** (Current)
   - cert-manager with Cloudflare DNS-01
   - Wildcard certificates for all domains
   - ArgoCD at `argocd.aster-lang.cloud`
   - Authentik at `auth.aster-lang.cloud`
   - Vault at `vault.aster-lang.cloud`

2. **Phase 2: Developer Services**
   - Policy API at `api.aster-lang.dev`
   - Documentation at `docs.aster-lang.dev`

3. **Phase 3: Public Services**
   - Main websites for `wontlost.com` and `ezymeta.com`
   - Product applications
