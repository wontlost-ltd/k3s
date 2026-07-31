#!/bin/bash
# Setup PostgreSQL access via Cloudflare Hyperdrive
# This script configures Cloudflare Tunnel private network and creates Hyperdrive

set -euo pipefail

# Configuration
ACCOUNT_ID="61ecb24622cdc5ba2552851054bba5ce"
TUNNEL_ID="7a86c1b5-5b7b-484e-9203-7df53026b076"
CF_API_TOKEN="${CF_API_TOKEN:-}"

# PostgreSQL connection details (from Vault)
PG_HOST="postgres-tunnel-svc.data-services.svc.cluster.local"
PG_PORT="5432"
PG_DATABASE="aster_api"
PG_USER="aster_api_user"
PG_PASSWORD="${PG_PASSWORD:-}"

# K8s Service CIDR (for private network route)
SERVICE_CIDR="10.43.0.0/16"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."

    if [[ -z "$CF_API_TOKEN" ]]; then
        log_error "CF_API_TOKEN environment variable is not set"
        log_info "Set it with: export CF_API_TOKEN=<your-cloudflare-api-token>"
        exit 1
    fi

    # ★PG_PASSWORD 必须由环境提供（此前硬编码在本文件，随 public 仓泄露）。
    #   取值来源：Vault data-services/aster-api-db（与 ExternalSecret 同源）。
    if [[ -z "$PG_PASSWORD" ]]; then
        log_error "PG_PASSWORD environment variable is not set"
        log_info "Get it from Vault: vault kv get -field=password data-services/aster-api-db"
        log_info "Then: export PG_PASSWORD=<value>"
        exit 1
    fi

    if ! command -v curl &> /dev/null; then
        log_error "curl is required but not installed"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq is required but not installed"
        exit 1
    fi

    log_info "Prerequisites check passed"
}

add_private_network_route() {
    log_info "Adding private network route to Cloudflare Tunnel..."

    # Check if route already exists
    existing_routes=$(curl -s "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/teamnet/routes" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")

    if echo "$existing_routes" | jq -e ".result[] | select(.network == \"${SERVICE_CIDR}\")" > /dev/null 2>&1; then
        log_warn "Private network route for ${SERVICE_CIDR} already exists"
        return 0
    fi

    # Add the route
    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/teamnet/routes" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"network\": \"${SERVICE_CIDR}\",
            \"tunnel_id\": \"${TUNNEL_ID}\",
            \"comment\": \"k3s Service network for PostgreSQL Hyperdrive access\"
        }")

    if echo "$response" | jq -e '.success == true' > /dev/null 2>&1; then
        log_info "Private network route added successfully"
        echo "$response" | jq '.result'
    else
        log_error "Failed to add private network route"
        echo "$response" | jq '.errors'
        exit 1
    fi
}

create_hyperdrive() {
    log_info "Checking for existing Hyperdrive configuration..."

    # List existing Hyperdrive configs
    existing=$(curl -s "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/hyperdrive/configs" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json")

    # ★已存在则**更新**而非跳过（2026-07-31）：原实现只 log 一句就 return 0，
    #   于是密码轮换后 Hyperdrive 里存的仍是旧连接串——而 Hyperdrive 的凭据存在
    #   Cloudflare 侧、**不读 Vault**，ExternalSecret 刷新对它无效。
    #
    # ★只改 password，其余 origin 字段从线上读回后原样回填。
    #   原因：PATCH 的 origin 是**整体替换**，漏字段即丢配置。而本脚本顶部那几个
    #   PG_* 默认值早已与线上不符（实测线上 host=postgres.aster-lang.dev、
    #   database=aster_cloud，且带 access_client_id —— 走 Cloudflare Tunnel + Access
    #   service token；脚本里却是集群内 svc DNS + aster_api + 无 Access）。
    #   若按脚本默认值整体覆盖，Hyperdrive 会指向**边缘侧根本解析不到**的内网域名
    #   并丢掉 Access 凭据 = 生产直接断，比不轮换更糟。
    if echo "$existing" | jq -e '.result[] | select(.name == "aster-api-postgres")' > /dev/null 2>&1; then
        hyperdrive_id=$(echo "$existing" | jq -r '.result[] | select(.name == "aster-api-postgres") | .id')
        log_warn "Hyperdrive 'aster-api-postgres' 已存在（ID: ${hyperdrive_id}）→ 仅更新密码"

        # 取线上现有 origin，注入新密码，其余字段照搬（含 access_client_id）。
        # access_client_secret 读不回来（API 不回显），故仅在本次未提供时保持不变——
        # 若线上启用了 Access，必须显式提供 ACCESS_CLIENT_SECRET，否则拒绝执行。
        current_origin=$(echo "$existing" | jq -c --arg n "aster-api-postgres" \
            '.result[] | select(.name == $n) | .origin')
        has_access=$(echo "$current_origin" | jq -r '.access_client_id // empty')

        if [[ -n "$has_access" && -z "${ACCESS_CLIENT_SECRET:-}" ]]; then
            log_error "线上 origin 启用了 Cloudflare Access（access_client_id=${has_access}）"
            log_error "但 API 不回显 access_client_secret，整体 PATCH 会把它清空 → 生产断连。"
            log_error "请提供：export ACCESS_CLIENT_SECRET='<Access service token secret>' 后重跑。"
            exit 1
        fi

        new_origin=$(echo "$current_origin" | jq -c \
            --arg pw "${PG_PASSWORD}" \
            --arg acs "${ACCESS_CLIENT_SECRET:-}" \
            '.password = $pw | if $acs != "" then .access_client_secret = $acs else . end')

        log_info "保留线上 origin: host=$(echo "$current_origin" | jq -r .host) db=$(echo "$current_origin" | jq -r .database) user=$(echo "$current_origin" | jq -r .user)"

        update_response=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/hyperdrive/configs/${hyperdrive_id}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"origin\": ${new_origin}}")

        if echo "$update_response" | jq -e '.success == true' > /dev/null 2>&1; then
            log_info "Hyperdrive 密码已更新（密码轮换后请务必跑到这一步）"
            return 0
        fi
        log_error "更新 Hyperdrive 失败"
        echo "$update_response" | jq '.errors'
        exit 1
    fi

    log_info "Creating Hyperdrive configuration..."

    response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/hyperdrive/configs" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"aster-api-postgres\",
            \"origin\": {
                \"database\": \"${PG_DATABASE}\",
                \"host\": \"${PG_HOST}\",
                \"port\": ${PG_PORT},
                \"scheme\": \"postgresql\",
                \"user\": \"${PG_USER}\",
                \"password\": \"${PG_PASSWORD}\",
                \"access_client_id\": null,
                \"access_client_secret\": null
            },
            \"caching\": {
                \"disabled\": false,
                \"max_age\": 60,
                \"stale_while_revalidate\": 15
            }
        }")

    if echo "$response" | jq -e '.success == true' > /dev/null 2>&1; then
        log_info "Hyperdrive configuration created successfully"
        hyperdrive_id=$(echo "$response" | jq -r '.result.id')
        log_info "Hyperdrive ID: ${hyperdrive_id}"
        echo ""
        log_info "Connection string for Vercel:"
        echo "  DATABASE_URL=postgresql://${PG_USER}:<password>@${hyperdrive_id}.hyperdrive.cloudflare.com:5432/${PG_DATABASE}"
        echo ""
    else
        log_error "Failed to create Hyperdrive configuration"
        echo "$response" | jq '.errors'
        exit 1
    fi
}

print_summary() {
    echo ""
    echo "=========================================="
    echo "  PostgreSQL Hyperdrive Setup Complete"
    echo "=========================================="
    echo ""
    echo "Configuration:"
    echo "  Account ID:  ${ACCOUNT_ID}"
    echo "  Tunnel ID:   ${TUNNEL_ID}"
    echo "  Service CIDR: ${SERVICE_CIDR}"
    echo ""
    echo "PostgreSQL:"
    echo "  Internal Host: ${PG_HOST}"
    echo "  Database:      ${PG_DATABASE}"
    echo "  User:          ${PG_USER}"
    echo ""
    echo "Next Steps:"
    echo "  1. Deploy the updated k8s manifests:"
    echo "     argocd app sync postgres-cluster"
    echo ""
    echo "  2. Set DATABASE_URL in Vercel:"
    echo "     vercel env add DATABASE_URL"
    echo ""
    echo "  3. Test the connection from your Vercel app"
    echo ""
}

main() {
    echo "=========================================="
    echo "  PostgreSQL Hyperdrive Setup Script"
    echo "=========================================="
    echo ""

    check_prerequisites
    add_private_network_route
    create_hyperdrive
    print_summary
}

main "$@"
