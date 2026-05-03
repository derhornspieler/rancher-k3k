#!/usr/bin/env bash
set -euo pipefail

# Deploy Rancher on Harvester using k3k
# This script orchestrates the full deployment including TLS cert propagation.
# Re-running this script with updated versions will upgrade existing components.
#
# Usage: ./deploy.sh [-c config_file]
#
# Supports:
#   - Non-interactive mode via config file (-c flag)
#   - Custom PVC sizing (10Gi to 1000Gi+)
#   - Private Helm chart repos (cert-manager, Rancher)
#   - OCI-based Helm registries (oci://harbor.example.com/project/chart)
#   - Private container registries
#   - Private CA certificates
#   - Custom storage classes
#   - In-place upgrades (re-run with new versions)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K3K_NS="rancher-k3k"
K3K_CLUSTER="rancher"
KUBECONFIG_FILE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Kubeconfig is preserved for the user after successful deployment.
cleanup_on_error() {
    if [[ $? -ne 0 && -n "$KUBECONFIG_FILE" && -f "$KUBECONFIG_FILE" ]]; then
        rm -f "$KUBECONFIG_FILE"
    fi
}
trap cleanup_on_error EXIT

# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# --- Config file support ---
CONFIG_FILE=""
while getopts "c:" opt; do
    case $opt in
        c) CONFIG_FILE="$OPTARG" ;;
        *) echo "Usage: $0 [-c config_file]"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [[ -n "$CONFIG_FILE" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
        err "Config file not found: $CONFIG_FILE"
        exit 1
    fi
    log "Loading config from: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Multi-FQDN support: HOSTNAMES takes precedence over HOSTNAME
if [[ -n "${HOSTNAMES:-}" ]]; then
    PRIMARY_HOSTNAME="${HOSTNAMES%%,*}"
    IFS=',' read -ra HOSTNAME_ARRAY <<< "$HOSTNAMES"
else
    PRIMARY_HOSTNAME=""  # Set after HOSTNAME validation below
    HOSTNAME_ARRAY=()
fi

# k3k API hostname(s) — comma-separated, first is primary (used in kubeconfig)
K3K_API_HOSTNAME="${K3K_API_HOSTNAME:-}"
if [[ -n "$K3K_API_HOSTNAME" ]]; then
    PRIMARY_K3K_API="${K3K_API_HOSTNAME%%,*}"
    IFS=',' read -ra K3K_API_ARRAY <<< "$K3K_API_HOSTNAME"
else
    PRIMARY_K3K_API=""
    K3K_API_ARRAY=()
fi
CUSTOM_CA="${CUSTOM_CA:-}"

# prompt_or_default VAR "prompt text" "default_value"
# If VAR is already set (from config file), skip the prompt.
# If no config file, prompt interactively; if config file, use the default.
prompt_or_default() {
    local var_name="$1" prompt_text="$2" default_val="$3"
    if [[ -z "${!var_name:-}" ]]; then
        if [[ -n "$CONFIG_FILE" ]]; then
            printf -v "$var_name" '%s' "$default_val"
        else
            # shellcheck disable=SC2229  # Intentional: dynamic variable name
            read -rp "$prompt_text" "$var_name"
            if [[ -z "${!var_name:-}" ]]; then
                printf -v "$var_name" '%s' "$default_val"
            fi
        fi
    fi
}

# =============================================================================
# Configuration
# =============================================================================
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN} Rancher on k3k - Deployment Configuration${NC}"
echo -e "${CYAN}=============================================${NC}"
echo ""

# --- Required ---
if [[ -z "${HOSTNAME:-}" ]]; then
    if [[ -n "$CONFIG_FILE" ]]; then
        err "HOSTNAME is required but not set in config file"
        exit 1
    fi
    read -rp "Rancher hostname (e.g. rancher.example.com): " HOSTNAME
fi
if [[ -z "$HOSTNAME" ]]; then
    err "Hostname is required"
    exit 1
fi

# Finalize multi-FQDN: if HOSTNAMES was not set, use HOSTNAME
if [[ -z "$PRIMARY_HOSTNAME" ]]; then
    PRIMARY_HOSTNAME="$HOSTNAME"
    HOSTNAME_ARRAY=("$HOSTNAME")
fi

prompt_or_default BOOTSTRAP_PW "Bootstrap password (min 12 chars) [admin1234567]: " "admin1234567"
if [[ ${#BOOTSTRAP_PW} -lt 12 ]]; then
    err "Password must be at least 12 characters"
    exit 1
fi

# --- Storage ---
echo ""
echo -e "${CYAN}Storage Configuration:${NC}"
echo "  10Gi   - Base Rancher (minimum, single node only)"
echo "  50Gi   - Rancher + basic monitoring (default)"
echo "  200Gi  - Rancher + Prometheus + Grafana + Loki"
echo "  500Gi  - Full observability stack with retention"
prompt_or_default PVC_SIZE "PVC size [50Gi]: " "50Gi"
# Strip trailing + (from help text copy-paste) and validate
PVC_SIZE="${PVC_SIZE%+}"
if ! [[ "$PVC_SIZE" =~ ^[0-9]+(Gi|Ti|Mi)$ ]]; then
    err "Invalid PVC size: $PVC_SIZE (use format like 10Gi, 500Gi, 1Ti)"
    exit 1
fi

prompt_or_default STORAGE_CLASS "Storage class [harvester-longhorn]: " "harvester-longhorn"

# --- HA configuration ---
echo ""
echo -e "${CYAN}HA Configuration:${NC}"
echo "  1  - Single server (default, minimal resources)"
echo "  3  - HA cluster (3 server nodes, recommended for production)"
prompt_or_default SERVER_COUNT "k3k server nodes [1]: " "1"
if [[ "$SERVER_COUNT" != "1" && "$SERVER_COUNT" != "3" ]]; then
    err "Server count must be 1 or 3"
    exit 1
fi
RANCHER_REPLICAS="$SERVER_COUNT"

# --- Helm chart sources (optional) ---
echo ""
echo -e "${CYAN}Helm Chart Sources (press Enter for public defaults):${NC}"
echo "  Enter HTTP repo URLs or OCI URIs (oci://harbor.example.com/project/chart)"
prompt_or_default CERTMANAGER_REPO "cert-manager source [https://charts.jetstack.io]: " "https://charts.jetstack.io"
prompt_or_default CERTMANAGER_VERSION "cert-manager version [v1.18.5]: " "v1.18.5"
prompt_or_default RANCHER_REPO "Rancher source [https://releases.rancher.com/server-charts/latest]: " "https://releases.rancher.com/server-charts/latest"
prompt_or_default RANCHER_VERSION "Rancher version [v2.14.1]: " "v2.14.1"
prompt_or_default K3K_REPO "k3k source [https://rancher.github.io/k3k]: " "https://rancher.github.io/k3k"
prompt_or_default K3K_VERSION "k3k version [1.0.2]: " "1.0.2"
# K3S_VERSION pins the k3s image used by k3k server pods inside the vCluster
# (set as spec.version on the Cluster CR). Empty = track host cluster version.
# See docs/runbooks/k3k-vcluster-k8s-upgrade.md for the upgrade procedure.
prompt_or_default K3S_VERSION "vCluster k3s version [v1.34.7-k3s1, blank=track host]: " "v1.34.7-k3s1"

# --- Private registry (optional) ---
echo ""
echo -e "${CYAN}Private Container Registry (press Enter to skip):${NC}"
echo "  Enter the registry host (e.g. harbor.example.com)."
echo "  Sets systemDefaultRegistry for Rancher images."
echo "  For mirror rewrites, also set MIRROR_REGISTRIES_FILE."
if [[ -z "${PRIVATE_REGISTRY+x}" ]]; then
    if [[ -n "$CONFIG_FILE" ]]; then
        PRIVATE_REGISTRY=""
    else
        read -rp "Private registry host []: " PRIVATE_REGISTRY
        PRIVATE_REGISTRY="${PRIVATE_REGISTRY:-}"
    fi
fi

# --- Mirror registries file (optional) ---
echo ""
echo -e "${CYAN}Mirror Registries (press Enter to skip):${NC}"
echo "  File with one upstream registry per line (e.g. docker.io, quay.io)."
echo "  See mirror-registries.example for the format."
echo "  Leave empty for no rewrites (direct internet)."
if [[ -z "${MIRROR_REGISTRIES_FILE+x}" ]]; then
    if [[ -n "$CONFIG_FILE" ]]; then
        MIRROR_REGISTRIES_FILE=""
    else
        read -rp "Mirror registries file []: " MIRROR_REGISTRIES_FILE
        MIRROR_REGISTRIES_FILE="${MIRROR_REGISTRIES_FILE:-}"
    fi
fi

# Validate mirror registries file if provided
if [[ -n "$MIRROR_REGISTRIES_FILE" && ! -f "$MIRROR_REGISTRIES_FILE" ]]; then
    err "Mirror registries file not found: $MIRROR_REGISTRIES_FILE"
    exit 1
fi

# --- Private CA certificate (optional) ---
echo ""
echo -e "${CYAN}Private CA Certificate (press Enter to skip):${NC}"
echo "  Path to a PEM-encoded CA bundle for internal TLS."
echo "  Used when Helm repos or registries use private certificates."
if [[ -z "${PRIVATE_CA_PATH+x}" ]]; then
    if [[ -n "$CONFIG_FILE" ]]; then
        PRIVATE_CA_PATH=""
    else
        read -rp "CA certificate path []: " PRIVATE_CA_PATH
        PRIVATE_CA_PATH="${PRIVATE_CA_PATH:-}"
    fi
fi

# --- CA certificate for Rancher TLS (optional) ---
echo ""
echo -e "${CYAN}CA Certificate for Rancher TLS (press Enter to skip):${NC}"
echo "  Provide a signing CA (intermediate) cert + key for cert-manager CA Issuer."
echo "  This creates a cert-manager CA Issuer and auto-renewing Certificate."
echo "  Set CA_ROOT_PATH to the root CA cert that signed the intermediate"
echo "  for Rancher's /cacerts trust anchor."
if [[ -z "${CA_CERT_PATH+x}" ]]; then
    if [[ -n "$CONFIG_FILE" ]]; then
        CA_CERT_PATH=""
    else
        read -rp "CA certificate path []: " CA_CERT_PATH
        CA_CERT_PATH="${CA_CERT_PATH:-}"
    fi
fi
if [[ -z "${CA_KEY_PATH+x}" ]]; then
    if [[ -n "$CONFIG_FILE" ]]; then
        CA_KEY_PATH=""
    else
        read -rp "CA private key path []: " CA_KEY_PATH
        CA_KEY_PATH="${CA_KEY_PATH:-}"
    fi
fi
if [[ -z "${CA_ROOT_PATH+x}" ]]; then
    if [[ -n "$CONFIG_FILE" ]]; then
        CA_ROOT_PATH=""
    else
        read -rp "Root CA certificate path []: " CA_ROOT_PATH
        CA_ROOT_PATH="${CA_ROOT_PATH:-}"
    fi
fi

# --- Helm repo authentication (optional) ---
echo ""
HELM_REPO_USER="${HELM_REPO_USER:-}"
HELM_REPO_PASS="${HELM_REPO_PASS:-}"
prompt_or_default HELM_AUTH_NEEDED "Do your Helm repos require authentication? (yes/no) [no]: " "no"
if [[ "$HELM_AUTH_NEEDED" == "yes" ]]; then
    echo -e "${CYAN}Helm Repository Authentication:${NC}"
    if [[ -z "$HELM_REPO_USER" ]]; then
        read -rp "Helm repo username: " HELM_REPO_USER
    fi
    if [[ -z "$HELM_REPO_USER" ]]; then
        err "Username is required when authentication is enabled"
        exit 1
    fi
    if [[ -z "$HELM_REPO_PASS" ]]; then
        read -rsp "Helm repo password: " HELM_REPO_PASS
        echo ""
    fi
    if [[ -z "$HELM_REPO_PASS" ]]; then
        err "Password is required when username is set"
        exit 1
    fi
fi

# --- TLS source ---
echo ""
echo -e "${CYAN}TLS Certificate Source:${NC}"
echo "  rancher      - Self-signed (default, no external dependency)"
echo "  letsEncrypt  - Let's Encrypt (requires public DNS)"
echo "  secret       - Provide your own TLS cert"
prompt_or_default TLS_SOURCE "TLS source [rancher]: " "rancher"

# Validate CA cert path if provided
if [[ -n "$PRIVATE_CA_PATH" && ! -f "$PRIVATE_CA_PATH" ]]; then
    err "CA certificate file not found: $PRIVATE_CA_PATH"
    exit 1
fi

# Validate CA cert/key pair for cert-manager CA Issuer
if [[ -n "$CA_CERT_PATH" || -n "$CA_KEY_PATH" ]]; then
    if [[ -z "$CA_CERT_PATH" || -z "$CA_KEY_PATH" ]]; then
        err "Both CA_CERT_PATH and CA_KEY_PATH must be set together"
        exit 1
    fi
    if [[ ! -f "$CA_CERT_PATH" ]]; then
        err "CA certificate file not found: $CA_CERT_PATH"
        exit 1
    fi
    if [[ ! -f "$CA_KEY_PATH" ]]; then
        err "CA private key file not found: $CA_KEY_PATH"
        exit 1
    fi
    if [[ "$TLS_SOURCE" != "secret" ]]; then
        log "CA cert+key provided, overriding TLS_SOURCE to 'secret' (cert-manager CA Issuer)"
        TLS_SOURCE="secret"
    fi
    # Fallback: if no root CA provided, use the signing cert itself (single CA, no hierarchy)
    if [[ -z "${CA_ROOT_PATH:-}" ]]; then
        warn "CA_ROOT_PATH not set — falling back to CA_CERT_PATH for /cacerts."
        warn "Set CA_ROOT_PATH to the root CA that signed the intermediate for proper trust."
        CA_ROOT_PATH="$CA_CERT_PATH"
    elif [[ ! -f "$CA_ROOT_PATH" ]]; then
        err "Root CA certificate not found: $CA_ROOT_PATH"
        exit 1
    fi
fi

# --- Confirm ---
echo ""
echo -e "${CYAN}Configuration Summary:${NC}"
echo "  Hostname:         $PRIMARY_HOSTNAME"
[[ "${#HOSTNAME_ARRAY[@]}" -gt 1 ]] && echo "  All FQDNs:        ${HOSTNAME_ARRAY[*]}"
[[ -n "$PRIMARY_K3K_API" ]] && echo "  k3k API:          ${K3K_API_ARRAY[*]}"
echo "  Password:         ****"
echo "  PVC Size:         $PVC_SIZE"
echo "  Storage Class:    $STORAGE_CLASS"
if [[ "$SERVER_COUNT" -ge 3 ]]; then
    echo "  Server Nodes:     $SERVER_COUNT (HA)"
else
    echo "  Server Nodes:     $SERVER_COUNT"
fi
echo "  cert-manager:     $CERTMANAGER_REPO ($CERTMANAGER_VERSION)$(is_oci "$CERTMANAGER_REPO" && echo ' [OCI]')"
echo "  Rancher:          $RANCHER_REPO ($RANCHER_VERSION)$(is_oci "$RANCHER_REPO" && echo ' [OCI]')"
echo "  k3k:              $K3K_REPO ($K3K_VERSION)$(is_oci "$K3K_REPO" && echo ' [OCI]')"
echo "  TLS Source:       $TLS_SOURCE"
[[ -n "$PRIVATE_REGISTRY" ]] && echo "  Registry:         $PRIVATE_REGISTRY"
[[ -n "$MIRROR_REGISTRIES_FILE" ]] && echo "  Mirror Registries: $MIRROR_REGISTRIES_FILE" || { [[ -n "$PRIVATE_REGISTRY" ]] && echo "  Mirror Registries: none (direct internet)"; }
[[ -n "$PRIVATE_CA_PATH" ]] && echo "  CA Cert:          $PRIVATE_CA_PATH"
[[ -n "$CA_CERT_PATH" ]] && echo "  CA Issuer:        $CA_CERT_PATH (cert-manager CA Issuer)"
[[ -n "${CA_ROOT_PATH:-}" ]] && echo "  CA Root:          $CA_ROOT_PATH"
[[ -n "$HELM_REPO_USER" ]] && echo "  Helm Auth:        $HELM_REPO_USER / ****" || echo "  Helm Auth:        none (public repos)"
echo ""
prompt_or_default CONFIRM "Proceed? (yes/no) [yes]: " "yes"
if [[ "$CONFIRM" != "yes" ]]; then
    log "Aborted."
    exit 0
fi

# =============================================================================
# Compute OCI-derived variables
# =============================================================================
# For each chart source, determine whether it's OCI or HTTP and set the
# template variables accordingly.
if is_oci "$CERTMANAGER_REPO"; then
    CERTMANAGER_CHART="$CERTMANAGER_REPO"       # Full OCI URI goes into spec.chart
    CERTMANAGER_REPO_LINE=""                     # No spec.repo for OCI
else
    CERTMANAGER_CHART="cert-manager"             # Chart name only for HTTP
    CERTMANAGER_REPO_LINE="  repo: ${CERTMANAGER_REPO}"
fi

if is_oci "$RANCHER_REPO"; then
    RANCHER_CHART="$RANCHER_REPO"
    RANCHER_REPO_LINE=""
else
    RANCHER_CHART="rancher"
    RANCHER_REPO_LINE="  repo: ${RANCHER_REPO}"
fi

# =============================================================================
# Build Helm flags for private repos
# =============================================================================
build_helm_repo_flags
build_helm_ca_flags

# Log in to OCI registries on the host cluster (deduplicated by host)
OCI_LOGGED_HOSTS=()
for _repo_var in K3K_REPO CERTMANAGER_REPO RANCHER_REPO; do
    _repo_val="${!_repo_var}"
    if is_oci "$_repo_val"; then
        _host=$(oci_registry_host "$_repo_val")
        # Skip if already logged in to this host
        if [[ ! " ${OCI_LOGGED_HOSTS[*]+"${OCI_LOGGED_HOSTS[*]}"} " == *" ${_host} "* ]]; then
            log "Logging in to OCI registry: $_host"
            helm_registry_login "$_host"
            OCI_LOGGED_HOSTS+=("$_host")
        fi
    fi
done

# =============================================================================
# Build extra Rancher values
# =============================================================================
EXTRA_RANCHER_VALUES=""

if [[ -n "$PRIVATE_REGISTRY" ]]; then
    # Rancher images are all on docker.io, so systemDefaultRegistry needs host/docker.io
    EXTRA_RANCHER_VALUES="${EXTRA_RANCHER_VALUES}    systemDefaultRegistry: \"${PRIVATE_REGISTRY}/docker.io\"\n"
fi

if [[ -n "$PRIVATE_CA_PATH" && "$TLS_SOURCE" != "rancher" ]]; then
    # privateCA tells Rancher to read the tls-ca secret for its cacerts setting.
    # Only needed when TLS_SOURCE=secret (user-provided cert from a private CA).
    # With TLS_SOURCE=rancher, Rancher manages its own self-signed CA automatically;
    # setting privateCA=true would override that with the Harbor root CA, breaking
    # the trust chain for downstream cluster agents.
    EXTRA_RANCHER_VALUES="${EXTRA_RANCHER_VALUES}    privateCA: \"true\"\n"
fi

if [[ -n "$CA_CERT_PATH" && -z "$PRIVATE_CA_PATH" ]]; then
    # CA Issuer mode also needs privateCA so Rancher reads tls-ca for /cacerts.
    # Skip if PRIVATE_CA_PATH already set (the block above handles it).
    EXTRA_RANCHER_VALUES="${EXTRA_RANCHER_VALUES}    privateCA: \"true\"\n"
fi

# Write extra values to a temp file for multi-line sed substitution
if [[ -n "$EXTRA_RANCHER_VALUES" ]]; then
    EXTRA_VALUES_FILE=$(mktemp)
    echo -e "$EXTRA_RANCHER_VALUES" > "$EXTRA_VALUES_FILE"
else
    EXTRA_VALUES_FILE=""
fi

# =============================================================================
# Step 1: Install/upgrade k3k controller via Helm
# =============================================================================
echo ""
log "Step 1/8: Installing k3k controller..."
if is_oci "$K3K_REPO"; then
    # OCI: install directly from OCI URI (no helm repo add)
    if helm status k3k -n k3k-system &>/dev/null; then
        log "k3k already installed, upgrading to $K3K_VERSION..."
        helm upgrade k3k "$K3K_REPO" -n k3k-system --version "$K3K_VERSION" ${HELM_CA_FLAGS[@]+"${HELM_CA_FLAGS[@]}"}
    else
        helm install k3k "$K3K_REPO" -n k3k-system --create-namespace --version "$K3K_VERSION" ${HELM_CA_FLAGS[@]+"${HELM_CA_FLAGS[@]}"}
    fi
else
    # HTTP: add repo then install
    if ! helm repo add k3k "$K3K_REPO" --force-update ${HELM_REPO_FLAGS[@]+"${HELM_REPO_FLAGS[@]}"}; then
        err "Failed to add k3k Helm repo: $K3K_REPO"
        err "Check the URL, credentials, and CA certificate settings"
        exit 1
    fi
    helm repo update k3k
    if helm status k3k -n k3k-system &>/dev/null; then
        log "k3k already installed, upgrading to $K3K_VERSION..."
        helm upgrade k3k k3k/k3k -n k3k-system --version "$K3K_VERSION"
    else
        helm install k3k k3k/k3k -n k3k-system --create-namespace --version "$K3K_VERSION"
    fi
fi
log "Waiting for k3k controller..."
ATTEMPTS=0
while ! kubectl get deploy k3k -n k3k-system &>/dev/null; do
    if [[ $ATTEMPTS -ge 24 ]]; then
        err "Timed out waiting for k3k controller deployment"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done
kubectl wait --for=condition=available deploy/k3k -n k3k-system --timeout=120s
log "k3k controller is ready"

# =============================================================================
# Step 1.5 (optional): Create registry config Secrets for k3k cluster
# =============================================================================
if [[ -n "$PRIVATE_REGISTRY" && -n "$MIRROR_REGISTRIES_FILE" ]]; then
    log "Creating K3s registry config for k3k cluster..."

    # Ensure namespace exists before creating Secrets
    kubectl create namespace "$K3K_NS" --dry-run=client -o yaml | kubectl apply -f -

    # Generate and store registries.yaml
    REGISTRIES_FILE=$(mktemp)
    if build_registries_yaml "$REGISTRIES_FILE"; then
        log "Generated registries.yaml:"
        cat "$REGISTRIES_FILE" | while IFS= read -r line; do echo "    $line"; done
        kubectl -n "$K3K_NS" create secret generic k3s-registry-config \
            --from-file=registries.yaml="$REGISTRIES_FILE" \
            --dry-run=client -o yaml | kubectl apply -f -
    else
        warn "No mirror registries loaded from $MIRROR_REGISTRIES_FILE, skipping registries.yaml"
    fi
    rm -f "$REGISTRIES_FILE"

    # Store CA cert if provided
    if [[ -n "$PRIVATE_CA_PATH" ]]; then
        kubectl -n "$K3K_NS" create secret generic k3s-registry-ca \
            --from-file=ca.crt="$PRIVATE_CA_PATH" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi

    log "Registry config Secrets created in $K3K_NS"
elif [[ -n "$PRIVATE_REGISTRY" ]]; then
    log "Private registry set but no MIRROR_REGISTRIES_FILE — using direct internet (no rewrites)"
fi

# =============================================================================
# Step 1.6: Ensure NGINX ingress controller has SSL passthrough enabled
# =============================================================================
# k3k exposes its API server via ingress with ssl-passthrough annotation.
# RKE2/Harvester NGINX needs --enable-ssl-passthrough in its extraArgs.
# This is idempotent and only activates per-ingress when the annotation is set.
if [[ -n "$PRIMARY_K3K_API" ]]; then
    log "Ensuring NGINX ingress controller has SSL passthrough enabled..."
    CURRENT_ARGS=$(kubectl get helmchartconfig rke2-ingress-nginx -n kube-system \
        -o jsonpath='{.spec.valuesContent}' 2>/dev/null || echo "")
    if ! echo "$CURRENT_ARGS" | grep -q "enable-ssl-passthrough"; then
        log "Patching HelmChartConfig to enable SSL passthrough..."
        # Read current valuesContent, inject the flag, and apply back
        VALS_FILE=$(mktemp)
        kubectl get helmchartconfig rke2-ingress-nginx -n kube-system \
            -o jsonpath='{.spec.valuesContent}' > "$VALS_FILE"
        if grep -q "extraArgs:" "$VALS_FILE"; then
            sed -i '/extraArgs:/a\        enable-ssl-passthrough: "true"' "$VALS_FILE"
        else
            sed -i '/^controller:/a\    extraArgs:\n        enable-ssl-passthrough: "true"' "$VALS_FILE"
        fi
        # Rebuild the HelmChartConfig with the patched values
        PATCH_MANIFEST=$(mktemp)
        cat > "$PATCH_MANIFEST" <<HCCEOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-ingress-nginx
  namespace: kube-system
spec:
  valuesContent: |
$(sed 's/^/    /' "$VALS_FILE")
HCCEOF
        kubectl apply -f "$PATCH_MANIFEST"
        rm -f "$VALS_FILE" "$PATCH_MANIFEST"
        # Wait for the controller pods to restart with new args
        log "Waiting for NGINX controller pods to restart..."
        sleep 5
        kubectl rollout status daemonset/rke2-ingress-nginx-controller -n kube-system --timeout=120s 2>/dev/null || true
        log "NGINX SSL passthrough enabled"
    else
        log "NGINX SSL passthrough already enabled"
    fi
fi

# =============================================================================
# Step 2: Create k3k virtual cluster
# =============================================================================
log "Step 2/8: Creating k3k virtual cluster..."
if kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" &>/dev/null; then
    log "k3k cluster already exists, skipping"
else
    CLUSTER_MANIFEST=$(mktemp)
    sed -e "s|__PVC_SIZE__|${PVC_SIZE}|g" \
        -e "s|__STORAGE_CLASS__|${STORAGE_CLASS}|g" \
        -e "s|__SERVER_COUNT__|${SERVER_COUNT}|g" \
        "$SCRIPT_DIR/rancher-cluster.yaml" > "$CLUSTER_MANIFEST"
    inject_secret_mounts "$CLUSTER_MANIFEST"

    # Inject explicit k3s version pin (or drop the line to track host version)
    if [[ -n "${K3S_VERSION:-}" ]]; then
        sedi "s|^__VERSION_LINE__$|  version: ${K3S_VERSION}|" "$CLUSTER_MANIFEST"
    else
        sedi "/__VERSION_LINE__/d" "$CLUSTER_MANIFEST"
    fi

    # Inject tlsSANs — only k3k API hostname + internal names.
    # Do NOT include Rancher FQDNs here: k3k creates an SSL passthrough ingress
    # from these SANs, which would intercept Rancher traffic. Rancher gets its
    # own ingress via native ingress sync from the vCluster.
    TLS_SANS_BLOCK=""
    for K in "${K3K_API_ARRAY[@]}"; do
        TLS_SANS_BLOCK="${TLS_SANS_BLOCK}    - \"${K}\"\n"
    done
    TLS_SANS_BLOCK="${TLS_SANS_BLOCK}    - k3k-rancher-service\n"
    TLS_SANS_BLOCK="${TLS_SANS_BLOCK}    - k3k-rancher-service.rancher-k3k"
    sedi "s|^__TLS_SANS__$|${TLS_SANS_BLOCK}|" "$CLUSTER_MANIFEST"

    # customCAs: Disabled. k3k's customCAs injects our CA into k3s internal cert
    # generation, but k3s creates certs with SANs (k3k-rancher-server-0, kubernetes,
    # localhost) that violate root CA name constraints. Let k3k generate its own
    # internal CAs; our CA is used only for Rancher leaf certs via cert-manager.
    sedi "/__CUSTOM_CAS__/d" "$CLUSTER_MANIFEST"

    kubectl apply -f "$CLUSTER_MANIFEST"
    rm -f "$CLUSTER_MANIFEST"
fi

log "Waiting for k3k cluster to be ready..."
# HA clusters (3 nodes) need more time for etcd cluster formation
if [[ "$SERVER_COUNT" -ge 3 ]]; then
    MAX_CLUSTER_ATTEMPTS=120
else
    MAX_CLUSTER_ATTEMPTS=60
fi
ATTEMPTS=0
while true; do
    STATUS=$(kubectl get clusters.k3k.io "$K3K_CLUSTER" -n "$K3K_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$STATUS" == "Ready" ]]; then
        break
    fi
    if [[ $ATTEMPTS -ge $MAX_CLUSTER_ATTEMPTS ]]; then
        echo ""
        err "Timed out waiting for k3k cluster. Current status: $STATUS"
        err "Check: kubectl get clusters.k3k.io $K3K_CLUSTER -n $K3K_NS -o yaml"
        err "Check: kubectl get pods -n $K3K_NS"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    echo -n "."
    sleep 5
done
echo ""
log "k3k cluster is Ready"

# =============================================================================
# Step 2.5: Apply PodDisruptionBudget for k3k server StatefulSet
# =============================================================================
# Prevents loss of etcd quorum inside the vCluster during Harvester node
# drains (upgrades, reboots). With minAvailable=2 across 3 server pods,
# at most one server pod can be evicted at a time. See k3k-pdb.yaml.
log "Step 2.5: Applying k3k server PodDisruptionBudget..."
PDB_MANIFEST=$(mktemp)
cp "$SCRIPT_DIR/k3k-pdb.yaml" "$PDB_MANIFEST"
sedi "s|__K3K_NS__|$K3K_NS|g" "$PDB_MANIFEST"
sedi "s|__K3K_CLUSTER__|$K3K_CLUSTER|g" "$PDB_MANIFEST"
kubectl apply -f "$PDB_MANIFEST"
rm -f "$PDB_MANIFEST"

# =============================================================================
# Step 3: Extract kubeconfig
# =============================================================================
log "Step 3/8: Extracting kubeconfig..."
KUBECONFIG_FILE=$(mktemp)

kubectl get secret "k3k-${K3K_CLUSTER}-kubeconfig" -n "$K3K_NS" \
    -o jsonpath='{.data.kubeconfig\.yaml}' | base64 -d > "$KUBECONFIG_FILE"

# Rewrite kubeconfig server URL for external access
CLUSTER_IP=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$KUBECONFIG_FILE")

if [[ -n "$PRIMARY_K3K_API" ]]; then
    # Ingress mode: use primary k3k API hostname on standard port 443
    sedi "s|server: https://${CLUSTER_IP}[^\"]*|server: https://${PRIMARY_K3K_API}|" "$KUBECONFIG_FILE"
    log "Kubeconfig updated: https://${PRIMARY_K3K_API}"
else
    # Fallback: NodePort mode
    NODE_PORT=$(kubectl get svc "k3k-${K3K_CLUSTER}-service" -n "$K3K_NS" \
        -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    if [[ -n "$NODE_PORT" && -n "$NODE_IP" ]]; then
        sedi "s|server: https://${CLUSTER_IP}|server: https://${NODE_IP}:${NODE_PORT}|" "$KUBECONFIG_FILE"
        log "Kubeconfig updated: https://${NODE_IP}:${NODE_PORT}"
    else
        warn "Could not determine NodePort. Using ClusterIP (only works from within the cluster)."
    fi
fi

# k3k API access always uses --insecure-skip-tls-verify because k3s generates
# internal certs with SANs (k3k-rancher-server-0, kubernetes, localhost) that
# violate root CA name constraints. The custom CA is used for Rancher leaf certs
# (which have the configured domain SANs and pass validation), not the k3k API server.
K3K_CMD="kubectl --kubeconfig=$KUBECONFIG_FILE --insecure-skip-tls-verify"
# Retry connectivity check — ingress SSL passthrough may take a few seconds to propagate
ATTEMPTS=0
while ! $K3K_CMD get nodes &>/dev/null; do
    if [[ $ATTEMPTS -ge 12 ]]; then
        err "Cannot connect to k3k cluster after 60s"
        err "Check: $K3K_CMD get nodes"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done
log "Connected to k3k virtual cluster"

# =============================================================================
# Step 3.5 (optional): Install private CA into k3k cluster
# =============================================================================
if [[ -n "$PRIVATE_CA_PATH" && "$TLS_SOURCE" != "rancher" && -z "$CA_CERT_PATH" ]]; then
    # Create tls-ca secret only when Rancher needs a user-provided CA (TLS_SOURCE=secret)
    # and CA_CERT_PATH is NOT set (step 4.5 handles tls-ca in CA Issuer mode).
    # With TLS_SOURCE=rancher, Rancher auto-generates its own CA; injecting only the
    # Harbor root CA here would replace Rancher's CA in the cacerts setting.
    log "Installing private CA certificate into k3k cluster..."
    $K3K_CMD create namespace cattle-system --dry-run=client -o yaml | $K3K_CMD apply -f -
    $K3K_CMD -n cattle-system create secret generic tls-ca \
        --from-file=cacerts.pem="$PRIVATE_CA_PATH" \
        --dry-run=client -o yaml | $K3K_CMD apply -f -
    log "Private CA installed"
fi

# =============================================================================
# Step 3.6 (optional): Create in-cluster auth for HelmChart CRs
# =============================================================================
if [[ -n "$HELM_REPO_USER" ]]; then
    # HTTP charts use basic-auth Secret (spec.authSecret)
    if ! is_oci "$CERTMANAGER_REPO" || ! is_oci "$RANCHER_REPO"; then
        log "Creating Helm repo auth secret (basic-auth) in k3k cluster..."
        $K3K_CMD -n kube-system create secret generic helm-repo-auth \
            --type=kubernetes.io/basic-auth \
            --from-literal=username="$HELM_REPO_USER" \
            --from-literal=password="$HELM_REPO_PASS" \
            --dry-run=client -o yaml | $K3K_CMD apply -f -
        log "Helm repo auth secret (basic-auth) created"
    fi

    # OCI charts use dockerconfigjson Secret (spec.dockerRegistrySecret)
    if is_oci "$CERTMANAGER_REPO" || is_oci "$RANCHER_REPO"; then
        # Extract OCI host from the first OCI chart (typically all share one Harbor)
        _oci_host=""
        is_oci "$CERTMANAGER_REPO" && _oci_host=$(oci_registry_host "$CERTMANAGER_REPO")
        [[ -z "$_oci_host" ]] && is_oci "$RANCHER_REPO" && _oci_host=$(oci_registry_host "$RANCHER_REPO")
        log "Creating Helm OCI auth secret (dockerconfigjson) for $_oci_host..."
        create_oci_auth_secret "$K3K_CMD" "helm-oci-auth" "$_oci_host"
        log "Helm OCI auth secret created"
    fi
fi

if [[ -n "$PRIVATE_CA_PATH" ]]; then
    log "Creating Helm repo CA configmap in k3k cluster..."
    $K3K_CMD -n kube-system create configmap helm-repo-ca \
        --from-file=ca-bundle.crt="$PRIVATE_CA_PATH" \
        --dry-run=client -o yaml | $K3K_CMD apply -f -
    log "Helm repo CA configmap created"
fi

# =============================================================================
# Step 4: Deploy cert-manager
# =============================================================================
log "Step 4/8: Deploying cert-manager..."

CERTMANAGER_MANIFEST=$(mktemp)
sed -e "s|__CERTMANAGER_CHART__|${CERTMANAGER_CHART}|g" \
    -e "s|__CERTMANAGER_VERSION__|${CERTMANAGER_VERSION}|g" \
    "$SCRIPT_DIR/post-install/01-cert-manager.yaml" > "$CERTMANAGER_MANIFEST"

# Inject or remove the repo line (OCI has no spec.repo)
if [[ -n "$CERTMANAGER_REPO_LINE" ]]; then
    sedi "s|^__CERTMANAGER_REPO_LINE__$|${CERTMANAGER_REPO_LINE}|" "$CERTMANAGER_MANIFEST"
else
    sedi "/__CERTMANAGER_REPO_LINE__/d" "$CERTMANAGER_MANIFEST"
fi

# Inject cert-manager HA values (replicaCount for all components)
if [[ "$SERVER_COUNT" -ge 3 ]]; then
    EXTRA_CM_VALUES_FILE=$(mktemp)
    printf '    replicaCount: 3\n' > "$EXTRA_CM_VALUES_FILE"
    printf '    webhook.replicaCount: 3\n' >> "$EXTRA_CM_VALUES_FILE"
    printf '    cainjector.replicaCount: 3\n' >> "$EXTRA_CM_VALUES_FILE"
    TMPFILE=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "__EXTRA_CERTMANAGER_VALUES__" ]]; then
            cat "$EXTRA_CM_VALUES_FILE"
        else
            printf '%s\n' "$line"
        fi
    done < "$CERTMANAGER_MANIFEST" > "$TMPFILE"
    mv "$TMPFILE" "$CERTMANAGER_MANIFEST"
    rm -f "$EXTRA_CM_VALUES_FILE"
else
    sedi "/__EXTRA_CERTMANAGER_VALUES__/d" "$CERTMANAGER_MANIFEST"
fi

inject_helmchart_auth "$CERTMANAGER_MANIFEST" "$CERTMANAGER_REPO"
$K3K_CMD apply -f "$CERTMANAGER_MANIFEST"
rm -f "$CERTMANAGER_MANIFEST"

log "Waiting for cert-manager deployment to be created..."
ATTEMPTS=0
while ! $K3K_CMD get deploy/cert-manager -n cert-manager &>/dev/null; do
    if [[ $ATTEMPTS -ge 60 ]]; then
        err "Timed out waiting for cert-manager deployment to appear"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done
$K3K_CMD wait --for=condition=available deploy/cert-manager -n cert-manager --timeout=300s
$K3K_CMD wait --for=condition=available deploy/cert-manager-webhook -n cert-manager --timeout=300s
log "cert-manager is ready"

# =============================================================================
# Step 4.5 (optional): Create CA Issuer + Certificate for Rancher TLS
# =============================================================================
if [[ -n "$CA_CERT_PATH" ]]; then
    log "Step 4.5: Creating cert-manager CA Issuer for Rancher TLS..."

    # Ensure cattle-system namespace exists
    $K3K_CMD create namespace cattle-system --dry-run=client -o yaml | $K3K_CMD apply -f -

    # Create the CA signing keypair secret
    $K3K_CMD -n cattle-system create secret tls ca-signing-keypair \
        --cert="$CA_CERT_PATH" --key="$CA_KEY_PATH" \
        --dry-run=client -o yaml | $K3K_CMD apply -f -

    # Create the CA Issuer
    $K3K_CMD apply -f - <<'ISSUER_EOF'
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: ca-issuer
  namespace: cattle-system
spec:
  ca:
    secretName: ca-signing-keypair
ISSUER_EOF

    # Create the Certificate CR for Rancher (all FQDNs)
    CERT_MANIFEST=$(mktemp)
    cat > "$CERT_MANIFEST" <<'CERT_HEADER'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: tls-rancher-ingress
  namespace: cattle-system
spec:
  secretName: tls-rancher-ingress
  issuerRef:
    name: ca-issuer
    kind: Issuer
  dnsNames:
CERT_HEADER
    for H in "${HOSTNAME_ARRAY[@]}"; do
        echo "    - \"${H}\"" >> "$CERT_MANIFEST"
    done
    cat >> "$CERT_MANIFEST" <<'CERT_FOOTER'
  duration: 2160h
  renewBefore: 360h
CERT_FOOTER
    $K3K_CMD apply -f "$CERT_MANIFEST"
    rm -f "$CERT_MANIFEST"

    # Create tls-ca secret (Rancher reads this for /cacerts endpoint)
    # Uses CA_ROOT_PATH (root CA cert) as the trust anchor so downstream
    # agents can verify the chain: leaf → intermediate → root.
    $K3K_CMD -n cattle-system create secret generic tls-ca \
        --from-file=cacerts.pem="$CA_ROOT_PATH" \
        --dry-run=client -o yaml | $K3K_CMD apply -f -

    # Wait for the certificate to be issued
    log "Waiting for CA-signed certificate to be issued..."
    $K3K_CMD wait --for=condition=Ready certificate/tls-rancher-ingress -n cattle-system --timeout=120s
    log "CA-signed certificate issued for ${HOSTNAME_ARRAY[*]}"
fi

# =============================================================================
# Step 5: Deploy Rancher
# =============================================================================
log "Step 5/8: Deploying Rancher..."

RANCHER_MANIFEST=$(mktemp)
sed -e "s|__HOSTNAME__|${PRIMARY_HOSTNAME}|g" \
    -e "s|__BOOTSTRAP_PW__|${BOOTSTRAP_PW}|g" \
    -e "s|__RANCHER_CHART__|${RANCHER_CHART}|g" \
    -e "s|__RANCHER_VERSION__|${RANCHER_VERSION}|g" \
    -e "s|__TLS_SOURCE__|${TLS_SOURCE}|g" \
    -e "s|__RANCHER_REPLICAS__|${RANCHER_REPLICAS}|g" \
    "$SCRIPT_DIR/post-install/02-rancher.yaml" > "$RANCHER_MANIFEST"

# Inject or remove the repo line (OCI has no spec.repo)
if [[ -n "$RANCHER_REPO_LINE" ]]; then
    sedi "s|^__RANCHER_REPO_LINE__$|${RANCHER_REPO_LINE}|" "$RANCHER_MANIFEST"
else
    sedi "/__RANCHER_REPO_LINE__/d" "$RANCHER_MANIFEST"
fi

# Inject extra values (private registry, private CA) using line-by-line replacement
# (sed 's' command cannot handle embedded newlines in the replacement string)
if [[ -n "$EXTRA_VALUES_FILE" ]]; then
    TMPFILE=$(mktemp)
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "__EXTRA_RANCHER_VALUES__" ]]; then
            cat "$EXTRA_VALUES_FILE"
        else
            printf '%s\n' "$line"
        fi
    done < "$RANCHER_MANIFEST" > "$TMPFILE"
    mv "$TMPFILE" "$RANCHER_MANIFEST"
    rm -f "$EXTRA_VALUES_FILE"
else
    sedi "/__EXTRA_RANCHER_VALUES__/d" "$RANCHER_MANIFEST"
fi

# Inject HelmChart auth/CA references
inject_helmchart_auth "$RANCHER_MANIFEST" "$RANCHER_REPO"

$K3K_CMD apply -f "$RANCHER_MANIFEST"
rm -f "$RANCHER_MANIFEST"

log "Waiting for Rancher deployment to be created (Helm chart installing)..."
ATTEMPTS=0
while ! $K3K_CMD get deploy/rancher -n cattle-system &>/dev/null; do
    if [[ $ATTEMPTS -ge 90 ]]; then
        err "Timed out waiting for Rancher deployment to appear"
        err "Check HelmChart status: kubectl get helmcharts -A"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done
log "Rancher deployment found, waiting for pods to be ready..."
$K3K_CMD wait --for=condition=available deploy/rancher -n cattle-system --timeout=600s
log "Rancher is running"

# --- Zero-downtime protections (HA only) ---
# The Rancher Helm chart hardcodes strategy maxUnavailable=1 for multi-replica
# deployments and ships no PDB. We layer two protections on top:
#   1. PDB (minAvailable = replicas-1) — prevents voluntary disruptions (drains,
#      evictions) from taking down more than one pod at a time.
#   2. Deployment strategy patch (maxUnavailable=0, maxSurge=1) — ensures a new
#      pod is fully Ready before its predecessor is terminated.
# On re-deploy (version upgrade), helm re-renders the Deployment and resets the
# strategy to chart defaults during the rollout. The PDB persists independently
# and still protects against concurrent disruptions. After the rollout the patch
# is re-applied for subsequent changes (config edits, manual restarts, etc.).
if [[ "$SERVER_COUNT" -ge 3 ]]; then
    log "Applying zero-downtime protections for HA ($RANCHER_REPLICAS replicas)..."

    PDB_MIN=$((RANCHER_REPLICAS - 1))
    PDB_MANIFEST=$(mktemp)
    sed "s|__PDB_MIN_AVAILABLE__|${PDB_MIN}|g" \
        "$SCRIPT_DIR/post-install/03-rancher-ha.yaml" > "$PDB_MANIFEST"
    $K3K_CMD apply -f "$PDB_MANIFEST"
    rm -f "$PDB_MANIFEST"

    $K3K_CMD -n cattle-system patch deploy/rancher --type=strategic -p \
        '{"spec":{"strategy":{"rollingUpdate":{"maxUnavailable":0,"maxSurge":1}}}}'

    log "PDB (minAvailable=${PDB_MIN}) and rolling update strategy (maxUnavailable=0) applied"
fi

# Create additional vCluster ingresses for extra Rancher FQDNs.
# The Rancher Helm chart only supports a single hostname. Extra FQDNs need
# their own ingress rules inside the vCluster so Traefik routes them to Rancher.
if [[ "${#HOSTNAME_ARRAY[@]}" -gt 1 ]]; then
    log "Creating vCluster ingress rules for additional FQDNs..."
    for H in "${HOSTNAME_ARRAY[@]}"; do
        [[ "$H" == "$PRIMARY_HOSTNAME" ]] && continue
        $K3K_CMD apply -f - <<EXTRA_INGRESS_EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rancher-$(echo "$H" | tr '.' '-')
  namespace: cattle-system
  annotations:
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "30"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "1800"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "1800"
spec:
  ingressClassName: traefik
  rules:
    - host: "${H}"
      http:
        paths:
          - path: /
            pathType: ImplementationSpecific
            backend:
              service:
                name: rancher
                port:
                  number: 80
  tls:
    - hosts:
        - "${H}"
      secretName: tls-rancher-ingress
EXTRA_INGRESS_EOF
        log "  Added vCluster ingress for ${H}"
    done
fi

# =============================================================================
# Step 5.5: Copy TLS certificate to host cluster for Rancher ingress
# =============================================================================
# k3k's ingress sync is not yet functional (v1.0.2) — the syncer doesn't
# copy ingresses/services from the vCluster to the host. We manually copy
# the TLS cert and create the host ingress for Rancher. The k3k API server
# is separately exposed via its own SSL passthrough ingress (created by k3k).
log "Step 5.5: Copying Rancher TLS certificate to host cluster..."

ATTEMPTS=0
while ! $K3K_CMD get secret tls-rancher-ingress -n cattle-system &>/dev/null; do
    if [[ $ATTEMPTS -ge 30 ]]; then
        err "Timed out waiting for tls-rancher-ingress secret"
        exit 1
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 5
done

TLS_CRT=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.crt}' | base64 -d)
TLS_KEY=$($K3K_CMD -n cattle-system get secret tls-rancher-ingress -o jsonpath='{.data.tls\.key}' | base64 -d)

kubectl -n "$K3K_NS" create secret tls tls-rancher-ingress \
    --cert=<(echo "$TLS_CRT") --key=<(echo "$TLS_KEY") \
    --dry-run=client -o yaml | kubectl apply -f -

log "TLS certificate copied to host cluster"

# =============================================================================
# Step 5.6: Migrate legacy resources (from pre-native-sync deployments)
# =============================================================================
# Previous versions used different resource names. Clean up old resources
# to prevent routing conflicts and duplicate reconciliation loops.
# Uses --ignore-not-found so this is a no-op on fresh deployments.
LEGACY_CLEANED=false

# Old ingress/service (rancher-k3k-ingress → rancher-ingress, rancher-k3k-traefik → rancher-traefik)
if kubectl get ingress rancher-k3k-ingress -n "$K3K_NS" &>/dev/null; then
    log "Migrating: removing legacy ingress rancher-k3k-ingress..."
    kubectl delete ingress rancher-k3k-ingress -n "$K3K_NS" --ignore-not-found
    LEGACY_CLEANED=true
fi
if kubectl get svc rancher-k3k-traefik -n "$K3K_NS" &>/dev/null; then
    log "Migrating: removing legacy service rancher-k3k-traefik..."
    kubectl delete svc rancher-k3k-traefik -n "$K3K_NS" --ignore-not-found
    LEGACY_CLEANED=true
fi

# Old watcher/reconciler (ingress-watcher → k3k-watcher, ingress-reconciler CronJob removed)
if kubectl get deploy ingress-watcher -n "$K3K_NS" &>/dev/null; then
    log "Migrating: removing legacy ingress-watcher deployment..."
    kubectl delete deploy ingress-watcher -n "$K3K_NS" --ignore-not-found
    LEGACY_CLEANED=true
fi
if kubectl get cronjob ingress-reconciler -n "$K3K_NS" &>/dev/null; then
    log "Migrating: removing legacy ingress-reconciler CronJob..."
    kubectl delete cronjob ingress-reconciler -n "$K3K_NS" --ignore-not-found
    LEGACY_CLEANED=true
fi

# Old RBAC resources (ingress-reconciler → k3k-watcher)
for RESOURCE in "rolebinding/ingress-reconciler" "role/ingress-reconciler" "sa/ingress-reconciler"; do
    if kubectl get "$RESOURCE" -n "$K3K_NS" &>/dev/null; then
        kubectl delete "$RESOURCE" -n "$K3K_NS" --ignore-not-found
        LEGACY_CLEANED=true
    fi
done

if $LEGACY_CLEANED; then
    log "Legacy resource migration complete"
fi

# =============================================================================
# Step 5.7: Create host ingress for Rancher
# =============================================================================
log "Step 5.7: Creating host cluster ingress for Rancher..."

# Create a service targeting Traefik (port 443) inside the k3k server pods.
# k3k-rancher-service maps to port 6443 (k3s API); Traefik listens on 443.
kubectl apply -f - <<'SVC_EOF'
apiVersion: v1
kind: Service
metadata:
  name: rancher-traefik
  namespace: rancher-k3k
spec:
  type: ClusterIP
  selector:
    cluster: rancher
    role: server
  ports:
    - name: http
      port: 80
      targetPort: 80
    - name: https
      port: 443
      targetPort: 443
SVC_EOF

# Build Rancher host ingress pointing to Traefik inside vCluster (HTTPS backend)
RANCHER_INGRESS=$(mktemp)
cat > "$RANCHER_INGRESS" <<'INGRESS_HEADER'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: rancher-ingress
  namespace: rancher-k3k
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "30"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "1800"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "1800"
spec:
  ingressClassName: nginx
  tls:
INGRESS_HEADER
for H in "${HOSTNAME_ARRAY[@]}"; do
    echo "    - hosts:" >> "$RANCHER_INGRESS"
    echo "        - \"${H}\"" >> "$RANCHER_INGRESS"
    echo "      secretName: tls-rancher-ingress" >> "$RANCHER_INGRESS"
done
cat >> "$RANCHER_INGRESS" <<'INGRESS_RULES_HEADER'
  rules:
INGRESS_RULES_HEADER
for H in "${HOSTNAME_ARRAY[@]}"; do
    cat >> "$RANCHER_INGRESS" <<INGRESS_RULE
    - host: "${H}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: rancher-traefik
                port:
                  number: 443
INGRESS_RULE
done
kubectl apply -f "$RANCHER_INGRESS"
rm -f "$RANCHER_INGRESS"

log "Host ingress created for ${HOSTNAME_ARRAY[*]}"

# =============================================================================
# Step 6: Deploy k3k-watcher
# =============================================================================
log "Step 6/8: Deploying k3k-watcher..."

kubectl apply -f "$SCRIPT_DIR/k3k-watcher-rbac.yaml"
kubectl apply -f "$SCRIPT_DIR/k3k-watcher.yaml"

log "k3k-watcher deployed (etcd recovery + pod rebalancing)"

# =============================================================================
# Step 7: Configure Rancher backup (optional, requires Vault + S3)
# =============================================================================
if [[ -n "${BACKUP_S3_ENDPOINT:-}" ]]; then
    log "Step 7/8: Configuring Rancher backup..."

    BACKUP_S3_BUCKET="${BACKUP_S3_BUCKET:-rancher-backups}"
    BACKUP_VAULT_S3_PATH="${BACKUP_VAULT_S3_PATH:-kv/services/backup/rancher-backup}"
    BACKUP_VAULT_ENCRYPTION_PATH="${BACKUP_VAULT_ENCRYPTION_PATH:-kv/services/backup/rancher-backup-encryption}"
    BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 2 * * *}"
    BACKUP_RETENTION="${BACKUP_RETENTION:-7}"
    BACKUP_NS="cattle-resources-system"

    # Resolve CA path: explicit > CA_ROOT_PATH > CA_CERT_PATH
    BACKUP_CA_PATH="${BACKUP_S3_CA_PATH:-${CA_ROOT_PATH:-${CA_CERT_PATH:-}}}"

    # --- 7.1 Vault auth check ---
    export VAULT_ADDR="${VAULT_ADDR:-https://vault.example.com}"
    if ! vault token lookup &>/dev/null; then
        err "Vault auth failed — cannot fetch backup credentials"
        err "Set VAULT_ADDR and authenticate with 'vault login' before running deploy.sh"
        exit 1
    fi

    # --- 7.2 Fetch S3 credentials from Vault ---
    info "Fetching S3 credentials from Vault (${BACKUP_VAULT_S3_PATH})..."
    BACKUP_S3_ACCESS_KEY=$(vault_kv_get "$BACKUP_VAULT_S3_PATH" "access-key")
    BACKUP_S3_SECRET_KEY=$(vault_kv_get "$BACKUP_VAULT_S3_PATH" "secret-key")
    if [[ -z "$BACKUP_S3_ACCESS_KEY" || -z "$BACKUP_S3_SECRET_KEY" ]]; then
        err "Failed to fetch S3 credentials from Vault path: ${BACKUP_VAULT_S3_PATH}"
        exit 1
    fi

    # --- 7.3 Fetch encryption key from Vault ---
    info "Fetching encryption key from Vault (${BACKUP_VAULT_ENCRYPTION_PATH})..."
    BACKUP_ENCRYPTION_KEY=$(vault_kv_get "$BACKUP_VAULT_ENCRYPTION_PATH" "encryption-key")
    if [[ -z "$BACKUP_ENCRYPTION_KEY" ]]; then
        err "Failed to fetch encryption key from Vault path: ${BACKUP_VAULT_ENCRYPTION_PATH}"
        exit 1
    fi

    # --- 7.4 Install rancher-backup operator into vCluster ---
    K3K_HELM="helm --kubeconfig=$KUBECONFIG_FILE --kube-insecure-skip-tls-verify"
    K3K_KUBECTL="kubectl --kubeconfig=$KUBECONFIG_FILE --insecure-skip-tls-verify"

    if ! $K3K_KUBECTL get deploy rancher-backup -n "$BACKUP_NS" &>/dev/null; then
        info "Installing rancher-backup operator..."
        $K3K_HELM repo add rancher-charts https://charts.rancher.io --force-update 2>/dev/null || true
        $K3K_HELM repo update rancher-charts 2>/dev/null || true

        if ! $K3K_HELM status rancher-backup-crd -n "$BACKUP_NS" &>/dev/null; then
            $K3K_HELM install rancher-backup-crd rancher-charts/rancher-backup-crd \
                -n "$BACKUP_NS" --create-namespace
        fi
        if ! $K3K_HELM status rancher-backup -n "$BACKUP_NS" &>/dev/null; then
            $K3K_HELM install rancher-backup rancher-charts/rancher-backup \
                -n "$BACKUP_NS"
        fi
    else
        log "rancher-backup operator already installed"
    fi

    # --- 7.5 Wait for operator ---
    info "Waiting for rancher-backup operator..."
    $K3K_KUBECTL wait --for=condition=available deploy/rancher-backup \
        -n "$BACKUP_NS" --timeout=120s

    # --- 7.6 Create secrets ---
    $K3K_KUBECTL apply -f - <<BACKUP_S3_EOF
apiVersion: v1
kind: Secret
metadata:
  name: s3-credentials
  namespace: ${BACKUP_NS}
type: Opaque
stringData:
  accessKey: "${BACKUP_S3_ACCESS_KEY}"
  secretKey: "${BACKUP_S3_SECRET_KEY}"
BACKUP_S3_EOF

    $K3K_KUBECTL apply -f - <<BACKUP_ENC_EOF
apiVersion: v1
kind: Secret
metadata:
  name: backup-encryption
  namespace: ${BACKUP_NS}
type: Opaque
stringData:
  encryption-provider-config.yaml: |
    apiVersion: apiserver.config.k8s.io/v1
    kind: EncryptionConfiguration
    resources:
      - resources:
          - secrets
        providers:
          - aescbc:
              keys:
                - name: key1
                  secret: "${BACKUP_ENCRYPTION_KEY}"
          - identity: {}
BACKUP_ENC_EOF
    log "Backup secrets created"

    # --- 7.7 Build endpointCA ---
    ENDPOINT_CA_B64=""
    if [[ -n "$BACKUP_CA_PATH" && -f "$BACKUP_CA_PATH" ]]; then
        ENDPOINT_CA_B64=$(base64 -w0 "$BACKUP_CA_PATH")
    fi

    # Build the endpointCA line (empty if no CA)
    ENDPOINT_CA_LINE=""
    if [[ -n "$ENDPOINT_CA_B64" ]]; then
        ENDPOINT_CA_LINE="      endpointCA: \"${ENDPOINT_CA_B64}\""
    fi

    # --- 7.8 Create one-time verification backup ---
    VERIFY_BACKUP="rancher-backup-verify-$(date +%Y%m%d-%H%M%S)"
    info "Creating verification backup: ${VERIFY_BACKUP}..."

    $K3K_KUBECTL apply -f - <<BACKUP_VERIFY_EOF
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: ${VERIFY_BACKUP}
spec:
  resourceSetName: rancher-resource-set-full
  encryptionConfigSecretName: backup-encryption
  storageLocation:
    s3:
      bucketName: ${BACKUP_S3_BUCKET}
      endpoint: ${BACKUP_S3_ENDPOINT}
      credentialSecretName: s3-credentials
      credentialSecretNamespace: ${BACKUP_NS}
${ENDPOINT_CA_LINE}
BACKUP_VERIFY_EOF

    # --- 7.9 Wait for verification backup ---
    info "Waiting for verification backup to complete (timeout 600s)..."
    ELAPSED=0
    while [[ $ELAPSED -lt 600 ]]; do
        BACKUP_STATUS=$($K3K_KUBECTL get backup "$VERIFY_BACKUP" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$BACKUP_STATUS" == "True" ]]; then
            BACKUP_FILE=$($K3K_KUBECTL get backup "$VERIFY_BACKUP" \
                -o jsonpath='{.status.filename}' 2>/dev/null)
            log "Verification backup complete: ${BACKUP_FILE}"
            break
        elif [[ "$BACKUP_STATUS" == "False" ]]; then
            BACKUP_MSG=$($K3K_KUBECTL get backup "$VERIFY_BACKUP" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
            err "Verification backup FAILED: ${BACKUP_MSG}"
            err "Fix S3/Vault/TLS config and re-run deploy.sh"
            exit 1
        fi
        sleep 10
        ELAPSED=$((ELAPSED + 10))
    done

    if [[ $ELAPSED -ge 600 ]]; then
        err "Verification backup timed out after 600s"
        exit 1
    fi

    # --- 7.10 Create scheduled backup ---
    info "Creating scheduled backup (schedule: ${BACKUP_SCHEDULE}, retention: ${BACKUP_RETENTION})..."

    # Delete any existing scheduled backup CR to allow updates
    $K3K_KUBECTL delete backup rancher-scheduled-backup 2>/dev/null || true

    $K3K_KUBECTL apply -f - <<BACKUP_SCHED_EOF
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: rancher-scheduled-backup
spec:
  resourceSetName: rancher-resource-set-full
  encryptionConfigSecretName: backup-encryption
  schedule: "${BACKUP_SCHEDULE}"
  retentionCount: ${BACKUP_RETENTION}
  storageLocation:
    s3:
      bucketName: ${BACKUP_S3_BUCKET}
      endpoint: ${BACKUP_S3_ENDPOINT}
      credentialSecretName: s3-credentials
      credentialSecretNamespace: ${BACKUP_NS}
${ENDPOINT_CA_LINE}
BACKUP_SCHED_EOF

    log "Scheduled backup configured (${BACKUP_SCHEDULE}, retain ${BACKUP_RETENTION})"
else
    warn "Step 7/8: BACKUP_S3_ENDPOINT not set — skipping backup configuration"
fi

# =============================================================================
# Step 8: Merge kubeconfig
# =============================================================================
log "Step 8/8: Merging kubeconfig with default config..."

K3K_RENAMED=$(mktemp)
cp "$KUBECONFIG_FILE" "$K3K_RENAMED"

# Get original context/cluster/user names from k3k kubeconfig
OLD_CTX=$(kubectl --kubeconfig="$K3K_RENAMED" config current-context 2>/dev/null || echo "default")
OLD_CLUSTER=$(kubectl --kubeconfig="$K3K_RENAMED" config view --raw -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || echo "default")
OLD_USER=$(kubectl --kubeconfig="$K3K_RENAMED" config view --raw -o jsonpath='{.contexts[0].context.user}' 2>/dev/null || echo "default")

log "Renaming context '${OLD_CTX}' -> 'rancher-k3k'"

# Rename context (native kubectl support)
kubectl --kubeconfig="$K3K_RENAMED" config rename-context "$OLD_CTX" rancher-k3k 2>/dev/null || true

# Update context to reference rancher-k3k cluster and user
kubectl --kubeconfig="$K3K_RENAMED" config set-context rancher-k3k --cluster=rancher-k3k --user=rancher-k3k >/dev/null

# Rename cluster and user entry names (no native kubectl rename for these)
if [[ -n "$OLD_CLUSTER" && "$OLD_CLUSTER" != "rancher-k3k" ]]; then
    sedi "s|  name: ${OLD_CLUSTER}$|  name: rancher-k3k|" "$K3K_RENAMED"
    sedi "s|^- name: ${OLD_CLUSTER}$|- name: rancher-k3k|" "$K3K_RENAMED"
fi
if [[ -n "$OLD_USER" && "$OLD_USER" != "rancher-k3k" ]]; then
    sedi "s|  name: ${OLD_USER}$|  name: rancher-k3k|" "$K3K_RENAMED"
    sedi "s|^- name: ${OLD_USER}$|- name: rancher-k3k|" "$K3K_RENAMED"
fi

# k3k API always needs insecure-skip-tls-verify (k3s internal cert SANs
# don't match root CA name constraints — see Step 3 comment)
kubectl --kubeconfig="$K3K_RENAMED" config set-cluster rancher-k3k --insecure-skip-tls-verify=true >/dev/null

# Merge k3k config with default kubeconfig
DATESTAMP=$(date +%Y%m%d)
MERGED_KUBECONFIG="$(pwd)/merged.kubeconfig_${DATESTAMP}"

if [[ -f "$HOME/.kube/config" ]]; then
    export KUBECONFIG="$HOME/.kube/config:$K3K_RENAMED"
    kubectl config view --flatten > "$MERGED_KUBECONFIG"
    export KUBECONFIG=""
    log "Merged kubeconfig: ${MERGED_KUBECONFIG}"
else
    warn "No default kubeconfig at ~/.kube/config, saving k3k config standalone"
    cp "$K3K_RENAMED" "$MERGED_KUBECONFIG"
fi

rm -f "$K3K_RENAMED"
log "Context 'rancher-k3k' ready in merged kubeconfig"

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN} Rancher deployed successfully!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo -e " Rancher URL:   https://${PRIMARY_HOSTNAME}"
for H in "${HOSTNAME_ARRAY[@]}"; do
    [[ "$H" != "$PRIMARY_HOSTNAME" ]] && echo -e "                https://${H}"
done
if [[ -n "$PRIMARY_K3K_API" ]]; then
    echo -e " k3k API:       https://${PRIMARY_K3K_API}"
    for K in "${K3K_API_ARRAY[@]}"; do
        [[ "$K" != "$PRIMARY_K3K_API" ]] && echo -e "                https://${K}"
    done
fi
echo -e " Password:      ${BOOTSTRAP_PW}"
echo -e " PVC Size:      ${PVC_SIZE}"
[[ -n "$PRIVATE_REGISTRY" ]] && echo -e " Registry:      ${PRIVATE_REGISTRY}"
echo ""
echo -e " k3k kubeconfig:    ${KUBECONFIG_FILE}"
echo -e " Merged kubeconfig: ${MERGED_KUBECONFIG}"
echo ""
echo " To use the merged kubeconfig:"
echo "   export KUBECONFIG=${MERGED_KUBECONFIG}"
echo "   kubectl config use-context rancher-k3k"
echo "   kubectl get pods -A"
echo ""
echo " To access k3k cluster directly:"
echo "   kubectl --kubeconfig=${KUBECONFIG_FILE} --insecure-skip-tls-verify get pods -A"
echo ""
echo " To destroy:"
echo "   $(dirname "$0")/destroy.sh"
echo ""
