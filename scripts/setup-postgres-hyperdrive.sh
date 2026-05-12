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
PG_PASSWORD="2sJI9ZLdiIDJg1I7xpREWdx9MEShCVVZ"

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

    if echo "$existing" | jq -e '.result[] | select(.name == "aster-api-postgres")' > /dev/null 2>&1; then
        log_warn "Hyperdrive config 'aster-api-postgres' already exists"
        hyperdrive_id=$(echo "$existing" | jq -r '.result[] | select(.name == "aster-api-postgres") | .id')
        log_info "Hyperdrive ID: ${hyperdrive_id}"
        return 0
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
