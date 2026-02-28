#!/usr/bin/env bash
# =============================================================================
# sync-to-public.sh — Export, scrub, verify, and sync rancher-k3k to public repo
# =============================================================================
# Automates the sanitization pipeline for publishing rancher-k3k files to the
# harvester-experimental-addons public repo:
#   Working copy → rsync (exclude secrets) → scrub domains → scrub IPs
#   → verify (hard gate) → sync to repo → optionally commit + push
#
# Usage:
#   ./scripts/sync-to-public.sh              # sync + verify + show diff (safe)
#   ./scripts/sync-to-public.sh --push       # sync + verify + commit + push
#   ./scripts/sync-to-public.sh --verify-only # verify existing repo subdir
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Bootstrap
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
die() { log_error "$@"; exit 1; }

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
PUBLIC_REPO_DIR="/home/rocky/code/harvester-experimental-addons"
PUBLIC_SUBDIR="rancher-k3k"
TARGET_DIR="${PUBLIC_REPO_DIR}/${PUBLIC_SUBDIR}"
TARGET_BRANCH="feat/k3k-addon-and-deploy-scripts"
STAGING_DIR="$(mktemp -d "/tmp/k3k-sync-XXXXXX")"

trap 'rm -rf "${STAGING_DIR}"' EXIT

# -----------------------------------------------------------------------------
# CLI Flags
# -----------------------------------------------------------------------------
DO_PUSH=false
VERIFY_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push)        DO_PUSH=true; shift ;;
    --verify-only) VERIFY_ONLY=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--push] [--verify-only]"
      echo ""
      echo "  (default)      Sync + verify + show diff"
      echo "  --push         Sync + verify + commit + push"
      echo "  --verify-only  Just verify existing repo subdir"
      exit 0
      ;;
    *) die "Unknown flag: $1" ;;
  esac
done

# -----------------------------------------------------------------------------
# Verify-only mode
# -----------------------------------------------------------------------------
if $VERIFY_ONLY; then
  if [[ ! -d "$TARGET_DIR" ]]; then
    die "Target directory not found at ${TARGET_DIR}"
  fi
  log_info "Running verification on existing repo subdir..."
  STAGING_DIR="$TARGET_DIR"
  trap - EXIT
fi

# =============================================================================
# STEP 0: Validate environment
# =============================================================================
if ! $VERIFY_ONLY; then

log_info "Step 0: Validating environment..."

if [[ ! -d "$PUBLIC_REPO_DIR/.git" ]]; then
  die "Public repo not found at ${PUBLIC_REPO_DIR} (or not a git repo)"
fi

# Ensure we're on the right branch
CURRENT_BRANCH=$(git -C "$PUBLIC_REPO_DIR" branch --show-current 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" != "$TARGET_BRANCH" ]]; then
  log_warn "Public repo is on '${CURRENT_BRANCH}', expected '${TARGET_BRANCH}'"
  read -rp "Switch to ${TARGET_BRANCH}? (yes/no) [yes]: " SWITCH
  SWITCH="${SWITCH:-yes}"
  if [[ "$SWITCH" == "yes" ]]; then
    git -C "$PUBLIC_REPO_DIR" checkout "$TARGET_BRANCH" || die "Failed to switch branch"
  else
    die "Aborting — wrong branch"
  fi
fi

log_ok "Environment validated (branch: ${TARGET_BRANCH})"
echo ""

# =============================================================================
# STEP 1: rsync working copy to staging (excluding secrets)
# =============================================================================
log_info "Step 1: Exporting working copy to staging dir..."

rsync -a --delete \
  --exclude='.git/' \
  --exclude='.claude/' \
  --exclude='scripts/' \
  --exclude='kubeconfig*' \
  --exclude='terraform.tfvars' \
  --exclude='merged.*' \
  --exclude='backups/' \
  --exclude='*.tfstate' \
  --exclude='*.tfstate.backup' \
  --exclude='*.tfplan' \
  --exclude='.terraform/' \
  --exclude='.terraform.lock.hcl' \
  --exclude='*.pem' \
  --exclude='*.key' \
  --exclude='*.p12' \
  --exclude='*.pfx' \
  --exclude='*.jks' \
  --exclude='.DS_Store' \
  --exclude='deploy.conf' \
  "${REPO_ROOT}/" "${STAGING_DIR}/"

log_ok "Exported to ${STAGING_DIR}"

# =============================================================================
# STEP 2: Scrub domain/org references
# =============================================================================
log_info "Step 2: Scrubbing domain and organization references..."

# Order matters — most specific patterns first
find "${STAGING_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sh' \
  -o -name '*.md' -o -name '*.json' -o -name '*.toml' -o -name '*.txt' \
  -o -name '*.conf' \) -print0 \
  | xargs -0 -r sed -i \
    -e 's|harbor\.aegisgroup\.ch|harbor.example.com|g' \
    -e 's|rancher-test\.hvst-vip\.aegisgroup\.ch|rancher-test.example.com|g' \
    -e 's|rancher\.hvst-vip\.aegisgroup\.ch|rancher.example.com|g' \
    -e 's|hvst-vip\.aegisgroup\.ch|hvst-vip.example.com|g' \
    -e 's|aegisgroup\.ch|example.com|g' \
    -e 's|aegis-group|example|g' \
    -e 's|aegisgroup|example|g'

log_ok "Domain/org references scrubbed"

# --- Scrub absolute paths that reveal username/system layout ---
log_info "Step 2b: Scrubbing absolute paths..."

find "${STAGING_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sh' \
  -o -name '*.md' -o -name '*.json' -o -name '*.toml' -o -name '*.txt' \
  -o -name '*.conf' \) -print0 \
  | xargs -0 -r sed -i \
    -e 's|/home/rocky/data/rancher-k3k/|./|g' \
    -e 's|/home/rocky/code/rancher-k3k/|./|g' \
    -e 's|/home/rocky/code/PKI/[^"'"'"'[:space:]]*-key\.pem|/path/to/signing-ca-key.pem|g' \
    -e 's|/home/rocky/code/PKI/[^"'"'"'[:space:]]*\.pem|/path/to/signing-ca.pem|g' \
    -e 's|/home/rocky/[^"'"'"'[:space:]]*||g'

log_ok "Absolute paths scrubbed"

# --- Strip CI badge lines referencing private repo ---
log_info "Step 2c: Stripping private-repo CI badges..."

find "${STAGING_DIR}" -name 'README.md' -print0 \
  | xargs -0 -r sed -i '/\[!\[.*\](https:\/\/github\.com\/derhornspieler\//d'

log_ok "Private-repo CI badges stripped"

# =============================================================================
# STEP 3: Scrub private IP addresses
# =============================================================================
log_info "Step 3: Scrubbing private IP addresses..."

# Replace real private IPs with RFC 5737 documentation addresses
find "${STAGING_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.sh' \
  -o -name '*.md' -o -name '*.json' -o -name '*.toml' -o -name '*.txt' \
  -o -name '*.conf' \) -print0 \
  | xargs -0 -r sed -i \
    -e 's|172\.16\.2\.|203.0.113.|g' \
    -e 's|172\.16\.3\.|203.0.113.|g'

log_ok "Private IPs scrubbed"

fi  # end of !VERIFY_ONLY

# =============================================================================
# STEP 4: Verification gate (HARD GATE)
# =============================================================================
echo ""
log_info "Step 4: Running verification checks..."
echo -e "${BOLD}============================================================${NC}"

ISSUES=0

GREP_INCLUDES=(--include='*.yaml' --include='*.yml' --include='*.sh'
  --include='*.md' --include='*.json' --include='*.toml' --include='*.txt'
  --include='*.conf')

# --- Check for domain references ---
if grep -riq "${GREP_INCLUDES[@]}" "aegisgroup" "${STAGING_DIR}" 2>/dev/null; then
  count=$(grep -ric "${GREP_INCLUDES[@]}" "aegisgroup" "${STAGING_DIR}" 2>/dev/null | awk -F: '{s+=$NF} END {print s}')
  log_error "LEAK: 'aegisgroup' found (${count} occurrences)"
  grep -rin "${GREP_INCLUDES[@]}" "aegisgroup" "${STAGING_DIR}" 2>/dev/null | head -10
  ((ISSUES++))
fi

# --- Check for private IPs ---
if grep -rqE "${GREP_INCLUDES[@]}" '172\.16\.[0-9]+\.[0-9]+' "${STAGING_DIR}" 2>/dev/null; then
  log_error "LEAK: Private IP 172.16.x.x found"
  grep -rnE "${GREP_INCLUDES[@]}" '172\.16\.[0-9]+\.[0-9]+' "${STAGING_DIR}" 2>/dev/null | head -5
  ((ISSUES++))
fi

# --- Check for home directory paths ---
if grep -rqE "${GREP_INCLUDES[@]}" '/home/rocky' "${STAGING_DIR}" 2>/dev/null; then
  count=$(grep -rcE "${GREP_INCLUDES[@]}" '/home/rocky' "${STAGING_DIR}" 2>/dev/null | awk -F: '{s+=$NF} END {print s}')
  log_error "LEAK: '/home/rocky' paths found (${count} occurrences)"
  grep -rnE "${GREP_INCLUDES[@]}" '/home/rocky' "${STAGING_DIR}" 2>/dev/null | head -10
  ((ISSUES++))
fi

# --- Check for GitHub username in non-git-remote contexts ---
if grep -riq "${GREP_INCLUDES[@]}" 'derhornspieler' "${STAGING_DIR}" 2>/dev/null; then
  count=$(grep -ric "${GREP_INCLUDES[@]}" 'derhornspieler' "${STAGING_DIR}" 2>/dev/null | awk -F: '{s+=$NF} END {print s}')
  log_error "LEAK: 'derhornspieler' found (${count} occurrences)"
  grep -rin "${GREP_INCLUDES[@]}" 'derhornspieler' "${STAGING_DIR}" 2>/dev/null | head -10
  ((ISSUES++))
fi

# --- Check for hyphenated domain variant ---
if grep -riq "${GREP_INCLUDES[@]}" 'aegis-group' "${STAGING_DIR}" 2>/dev/null; then
  count=$(grep -ric "${GREP_INCLUDES[@]}" 'aegis-group' "${STAGING_DIR}" 2>/dev/null | awk -F: '{s+=$NF} END {print s}')
  log_error "LEAK: 'aegis-group' found (${count} occurrences)"
  grep -rin "${GREP_INCLUDES[@]}" 'aegis-group' "${STAGING_DIR}" 2>/dev/null | head -10
  ((ISSUES++))
fi

# --- Check for forbidden files ---
declare -a FORBIDDEN_FILES=(
  "kubeconfig*"
  "*.tfvars"
  "*.tfstate"
  "*.tfplan"
  "*.pem"
  "*.key"
  "*.p12"
  "*.pfx"
  "*.jks"
  "merged.*"
)

for pattern in "${FORBIDDEN_FILES[@]}"; do
  found=$(find "${STAGING_DIR}" -name "$pattern" 2>/dev/null)
  if [[ -n "$found" ]]; then
    log_error "LEAK: Forbidden file found: ${pattern}"
    echo "$found"
    ((ISSUES++))
  fi
done

# --- Check for private key material in file contents ---
log_info "  Scanning for private key material in file contents..."
declare -a KEY_HEADERS=(
  "BEGIN PRIVATE KEY"
  "BEGIN RSA PRIVATE KEY"
  "BEGIN EC PRIVATE KEY"
  "BEGIN OPENSSH PRIVATE KEY"
  "BEGIN DSA PRIVATE KEY"
  "BEGIN ENCRYPTED PRIVATE KEY"
)

for header in "${KEY_HEADERS[@]}"; do
  if grep -rql "$header" "${STAGING_DIR}" 2>/dev/null; then
    log_error "LEAK: Private key header '${header}' found in:"
    grep -rln "$header" "${STAGING_DIR}" 2>/dev/null | head -5
    ((ISSUES++))
  fi
done

# --- Check for base64-encoded private keys (common in kubeconfig) ---
if grep -rqE "${GREP_INCLUDES[@]}" 'client-key-data:' "${STAGING_DIR}" 2>/dev/null; then
  log_error "LEAK: Embedded client-key-data found (likely kubeconfig)"
  grep -rln "${GREP_INCLUDES[@]}" 'client-key-data:' "${STAGING_DIR}" 2>/dev/null | head -5
  ((ISSUES++))
fi

echo -e "${BOLD}============================================================${NC}"

if [[ $ISSUES -gt 0 ]]; then
  die "Verification FAILED: ${ISSUES} issue(s) found. Fix before publishing!"
fi

log_ok "All verification checks passed (0 issues)"
echo ""

# If verify-only, stop here
if $VERIFY_ONLY; then
  exit 0
fi

# =============================================================================
# STEP 5: Sync staging to repo subdir
# =============================================================================
log_info "Step 5: Syncing to ${TARGET_DIR}..."

# Preserve files that only exist in the repo (backup-server/, CLAUDE.md)
rsync -a --delete \
  --exclude='backup-server/' \
  --exclude='CLAUDE.md' \
  "${STAGING_DIR}/" "${TARGET_DIR}/"

log_ok "Repo subdir updated"

# =============================================================================
# STEP 6: Show diff or commit + push
# =============================================================================
echo ""

if $DO_PUSH; then
  log_info "Step 6: Committing and pushing..."
  # Stage selectively — exclude backup-server/ (contains local terraform state)
  git -C "${PUBLIC_REPO_DIR}" add "${PUBLIC_SUBDIR}/" \
    ':!'"${PUBLIC_SUBDIR}"'/backup-server/'
  if git -C "${PUBLIC_REPO_DIR}" diff --cached --quiet; then
    log_warn "No changes to commit"
  else
    echo ""
    log_info "Changes to be committed:"
    git -C "${PUBLIC_REPO_DIR}" diff --cached --stat
    echo ""
    read -rp "Commit message [feat: sync rancher-k3k updates]: " COMMIT_MSG
    COMMIT_MSG="${COMMIT_MSG:-feat: sync rancher-k3k updates}"
    git -C "${PUBLIC_REPO_DIR}" commit -m "${COMMIT_MSG}"
    git -C "${PUBLIC_REPO_DIR}" push origin "${TARGET_BRANCH}"
    log_ok "Pushed to origin/${TARGET_BRANCH}"
  fi
else
  log_info "Changes in repo subdir (use --push to commit+push):"
  echo -e "${BOLD}------------------------------------------------------------${NC}"
  git -C "${PUBLIC_REPO_DIR}" add "${PUBLIC_SUBDIR}/" \
    ':!'"${PUBLIC_SUBDIR}"'/backup-server/'
  git -C "${PUBLIC_REPO_DIR}" diff --cached --stat || true
  echo -e "${BOLD}------------------------------------------------------------${NC}"
  # Unstage so git status shows changes on next run
  git -C "${PUBLIC_REPO_DIR}" reset HEAD -- "${PUBLIC_SUBDIR}/" >/dev/null 2>&1 || true
fi

echo ""
log_ok "Done! Repo: ${PUBLIC_REPO_DIR} (branch: ${TARGET_BRANCH})"
