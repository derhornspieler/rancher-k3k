# Native k3k Ingress Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate from custom ingress-watcher/reconciler to k3k native ingress sync, expose the k3k API via ingress with private CA, support multiple FQDNs, disable Traefik inside the vCluster, and strip the watcher down to only etcd recovery + pod rebalancing.

**Architecture:** The k3k cluster CR gets native ingress sync enabled and Traefik disabled. The Rancher Helm chart is configured with `ingressClassName: nginx` so the synced ingress works directly on the host NGINX controller. The k3k API server is exposed via ingress with SSL passthrough instead of NodePort. `deploy.conf` gains multi-FQDN support via `HOSTNAMES` (comma-separated), and `CUSTOM_CA=true` triggers k3k `spec.customCAs` configuration. Manual host-side ingress/service/TLS-copy steps are removed from `deploy.sh`. The ingress-watcher loses its ingress reconciliation and flannel scenarios, keeping only etcd HA recovery and pod rebalancing.

**Tech Stack:** Bash (deploy.sh/lib.sh), Kubernetes YAML (k3k CRDs, ingress, RBAC), Helm (Rancher chart values), cert-manager (CA Issuer + Certificate CR)

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `deploy.conf` | Modify | Add `HOSTNAMES`, `K3K_API_HOSTNAME`, `CUSTOM_CA` fields |
| `deploy.sh` | Modify | Multi-FQDN support, remove Steps 6/7/8 ingress parts, add customCAs, change expose mode |
| `rancher-cluster.yaml` | Modify | Enable ingress sync, disable Traefik, expose via ingress, add customCAs, add tlsSANs |
| `post-install/02-rancher.yaml` | Modify | Add `ingressClassName` and multi-FQDN Helm values |
| `host-ingress.yaml` | Delete | Replaced by k3k native ingress sync |
| `ingress-reconciler.yaml` | Modify | Remove ingress/flannel scenarios, keep etcd + rebalancing RBAC |
| `ingress-watcher.yaml` | Modify | Remove `reconcile_ingress()` and flannel scenario, keep etcd + rebalancing |
| `post-install/04-k3k-api-ingress.yaml` | Create | SSL passthrough ingress for k3k API server |

---

### Task 1: Update deploy.conf with new fields

**Files:**
- Modify: `deploy.conf`

- [ ] **Step 1: Add multi-FQDN and k3k API hostname fields**

Add to `deploy.conf`:
```bash
# Comma-separated list of all FQDNs for Rancher (first is primary)
# Used in: cert-manager dnsNames, Rancher ingress rules, k3k tlsSANs
HOSTNAMES="rancher.hvst-vip.aegisgroup.ch"

# k3k API server hostname (exposed via ingress with SSL passthrough)
K3K_API_HOSTNAME="k3k.hvst-vip.aegisgroup.ch"

# Use private CA for k3k API server TLS (uses CA_CERT_PATH/CA_KEY_PATH)
CUSTOM_CA="true"
```

The existing `HOSTNAME` field stays for backward compatibility. If `HOSTNAMES` is set, it takes precedence. If not, `HOSTNAMES` defaults to `$HOSTNAME`.

- [ ] **Step 2: Verify deploy.conf is valid bash**

Run: `bash -n deploy.conf`
Expected: No output (clean parse)

- [ ] **Step 3: Commit**

```bash
git add deploy.conf
git commit -m "feat: add multi-FQDN, k3k API hostname, and custom CA fields to deploy.conf"
```

---

### Task 2: Update rancher-cluster.yaml template

**Files:**
- Modify: `rancher-cluster.yaml`

- [ ] **Step 1: Enable ingress sync, disable Traefik, switch to ingress expose, add customCAs and tlsSANs placeholders**

Replace the current `rancher-cluster.yaml` content. Key changes:
- `spec.expose` changes from `nodePort: {}` to `ingress: { ingressClassName: nginx, annotations: { nginx.ingress.kubernetes.io/ssl-passthrough: "true" } }`
- `spec.sync.ingresses.enabled: true` added
- `serverArgs` adds `--disable=traefik`
- `spec.tlsSANs` placeholder added (`__TLS_SANS__`)
- `spec.customCAs` placeholder added (`__CUSTOM_CAS__`)

Updated template:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: rancher-k3k
---
apiVersion: k3k.io/v1beta1
kind: Cluster
metadata:
  name: rancher
  namespace: rancher-k3k
spec:
  mode: virtual
  servers: __SERVER_COUNT__
  agents: 0
  clusterCIDR: 10.42.0.0/16
  serviceCIDR: 10.43.0.0/16

  persistence:
    type: dynamic
    storageClassName: __STORAGE_CLASS__
    storageRequestSize: __PVC_SIZE__

  serverArgs:
    - "--disable-network-policy"
    - "--disable=traefik"
__EXTRA_SERVER_ARGS__

__SECRET_MOUNTS__

  # Expose k3k API via ingress (SSL passthrough, firewall-friendly port 443)
  expose:
    ingress:
      ingressClassName: nginx
      annotations:
        nginx.ingress.kubernetes.io/ssl-passthrough: "true"

  # TLS Subject Alternative Names for the k3k API server certificate
  tlsSANs:
__TLS_SANS__

  # Sync ingresses from vCluster to host (replaces manual host-ingress.yaml)
  sync:
    ingresses:
      enabled: true
    services:
      enabled: true
    secrets:
      enabled: true
    configMaps:
      enabled: true
    persistentVolumeClaims:
      enabled: true

__CUSTOM_CAS__
```

- [ ] **Step 2: Commit**

```bash
git add rancher-cluster.yaml
git commit -m "feat: enable native ingress sync, disable Traefik, expose API via ingress"
```

---

### Task 3: Update deploy.sh — multi-FQDN support and new cluster template injection

**Files:**
- Modify: `deploy.sh`

- [ ] **Step 1: Add HOSTNAMES parsing near the top of deploy.sh (after config loading)**

After the `source "$CONFIG_FILE"` block (~line 64), add:
```bash
# Multi-FQDN support: HOSTNAMES takes precedence over HOSTNAME
if [[ -z "${HOSTNAMES:-}" ]]; then
    HOSTNAMES="${HOSTNAME}"
fi
# First hostname is the primary (used for Rancher ingress.hostname)
PRIMARY_HOSTNAME="${HOSTNAMES%%,*}"
# Build array for iteration
IFS=',' read -ra HOSTNAME_ARRAY <<< "$HOSTNAMES"

# k3k API hostname defaults
K3K_API_HOSTNAME="${K3K_API_HOSTNAME:-}"
```

Update all subsequent references from `$HOSTNAME` to `$PRIMARY_HOSTNAME` throughout the script.

- [ ] **Step 2: Update Step 2 (cluster creation) to inject tlsSANs, customCAs**

Replace the cluster manifest injection block (~line 486-493) with:
```bash
CLUSTER_MANIFEST=$(mktemp)
sed -e "s|__PVC_SIZE__|${PVC_SIZE}|g" \
    -e "s|__STORAGE_CLASS__|${STORAGE_CLASS}|g" \
    -e "s|__SERVER_COUNT__|${SERVER_COUNT}|g" \
    "$SCRIPT_DIR/rancher-cluster.yaml" > "$CLUSTER_MANIFEST"
inject_secret_mounts "$CLUSTER_MANIFEST"

# Inject tlsSANs (all Rancher FQDNs + k3k API hostname + internal names)
TLS_SANS_BLOCK=""
for H in "${HOSTNAME_ARRAY[@]}"; do
    TLS_SANS_BLOCK="${TLS_SANS_BLOCK}    - \"${H}\"\n"
done
if [[ -n "$K3K_API_HOSTNAME" ]]; then
    TLS_SANS_BLOCK="${TLS_SANS_BLOCK}    - \"${K3K_API_HOSTNAME}\"\n"
fi
TLS_SANS_BLOCK="${TLS_SANS_BLOCK}    - k3k-rancher-service\n"
TLS_SANS_BLOCK="${TLS_SANS_BLOCK}    - k3k-rancher-service.rancher-k3k\n"
sedi "s|^__TLS_SANS__$|${TLS_SANS_BLOCK}|" "$CLUSTER_MANIFEST"

# Inject customCAs if enabled
if [[ "${CUSTOM_CA:-}" == "true" && -n "$CA_CERT_PATH" ]]; then
    # Create the CA secrets on the host cluster for k3k to mount
    kubectl -n "$K3K_NS" create secret tls k3k-server-ca \
        --cert="$CA_CERT_PATH" --key="$CA_KEY_PATH" \
        --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n "$K3K_NS" create secret tls k3k-etcd-server-ca \
        --cert="$CA_CERT_PATH" --key="$CA_KEY_PATH" \
        --dry-run=client -o yaml | kubectl apply -f -

    CUSTOM_CAS_BLOCK="  customCAs:\n    enabled: true\n    sources:\n      serverCA:\n        secretName: k3k-server-ca\n      etcdServerCA:\n        secretName: k3k-etcd-server-ca"
    sedi "s|^__CUSTOM_CAS__$|${CUSTOM_CAS_BLOCK}|" "$CLUSTER_MANIFEST"
else
    sedi "/__CUSTOM_CAS__/d" "$CLUSTER_MANIFEST"
fi

kubectl apply -f "$CLUSTER_MANIFEST"
rm -f "$CLUSTER_MANIFEST"
```

- [ ] **Step 3: Update Step 3 (kubeconfig extraction) for ingress-based access**

Replace the NodePort kubeconfig rewrite (~line 532-543) with:
```bash
if [[ -n "$K3K_API_HOSTNAME" ]]; then
    # Ingress mode: use the k3k API hostname on standard port 443
    CLUSTER_IP=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$KUBECONFIG_FILE")
    sedi "s|server: https://${CLUSTER_IP}|server: https://${K3K_API_HOSTNAME}|" "$KUBECONFIG_FILE"
    log "Kubeconfig updated: https://${K3K_API_HOSTNAME}"
else
    # Fallback: NodePort mode
    NODE_PORT=$(kubectl get svc "k3k-${K3K_CLUSTER}-service" -n "$K3K_NS" \
        -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    CLUSTER_IP=$(sed -n 's/.*server: https:\/\/\([^:]*\).*/\1/p' "$KUBECONFIG_FILE")
    if [[ -n "$NODE_PORT" && -n "$NODE_IP" ]]; then
        sedi "s|server: https://${CLUSTER_IP}|server: https://${NODE_IP}:${NODE_PORT}|" "$KUBECONFIG_FILE"
        log "Kubeconfig updated: https://${NODE_IP}:${NODE_PORT}"
    fi
fi
```

Also update the `--insecure-skip-tls-verify` handling. When using private CA, we can set the CA in the kubeconfig instead:
```bash
if [[ "${CUSTOM_CA:-}" == "true" && -n "$CA_ROOT_PATH" ]]; then
    kubectl --kubeconfig="$KUBECONFIG_FILE" config set-cluster \
        "$(kubectl --kubeconfig="$KUBECONFIG_FILE" config view -o jsonpath='{.clusters[0].name}')" \
        --certificate-authority="$CA_ROOT_PATH" --embed-certs=true >/dev/null
    K3K_CMD="kubectl --kubeconfig=$KUBECONFIG_FILE"
else
    K3K_CMD="kubectl --kubeconfig=$KUBECONFIG_FILE --insecure-skip-tls-verify"
fi
```

- [ ] **Step 4: Update Step 4.5 (cert-manager Certificate CR) for multi-FQDN**

Replace the Certificate CR dnsNames block (~line 685-700) with:
```bash
    # Build dnsNames list from all hostnames
    DNS_NAMES=""
    for H in "${HOSTNAME_ARRAY[@]}"; do
        DNS_NAMES="${DNS_NAMES}    - \"${H}\"\n"
    done

    $K3K_CMD apply -f - <<CERT_EOF
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
$(echo -e "$DNS_NAMES")  duration: 2160h
  renewBefore: 360h
CERT_EOF
```

- [ ] **Step 5: Update Step 5 (Rancher Helm values) — add ingressClassName: nginx**

In the Rancher Helm values injection, add `ingress.ingressClassName`:
```bash
# Add to the EXTRA_VALUES_FILE or inline set values:
    ingress.ingressClassName: nginx
```

This must be set in `post-install/02-rancher.yaml` (see Task 4).

- [ ] **Step 6: Remove Steps 6, 7, and the ingress parts of Step 8**

Delete or skip:
- **Step 6** (Copy TLS certificate to host cluster) — k3k secret sync handles this
- **Step 7** (Create host ingress) — k3k ingress sync handles this
- **Step 8** ingress-reconciler CronJob deployment line — CronJob is being removed

Keep in Step 8:
- ServiceAccount, Role, RoleBinding, ClusterRole, ClusterRoleBinding (needed for watcher)
- ingress-watcher deployment

Replace the step numbering to reflect fewer steps (e.g., 7 steps instead of 9).

- [ ] **Step 7: Update Step 9 (kubeconfig merge) — remove insecure-skip-tls-verify when using custom CA**

When `CUSTOM_CA=true`, don't set `--insecure-skip-tls-verify` on the cluster entry. The CA is already embedded.

- [ ] **Step 8: Commit**

```bash
git add deploy.sh
git commit -m "feat: multi-FQDN support, native ingress sync, k3k API via ingress, custom CA"
```

---

### Task 4: Update Rancher Helm chart template for nginx ingressClassName

**Files:**
- Modify: `post-install/02-rancher.yaml`

- [ ] **Step 1: Add ingressClassName to Rancher Helm values**

Add to the `set:` block:
```yaml
    ingress.ingressClassName: nginx
```

This tells the Rancher Helm chart to create its ingress with `ingressClassName: nginx` instead of the default `traefik`. When k3k syncs this ingress to the host, it will match the host's NGINX ingress controller.

Also add a multi-hostname placeholder for additional ingress hosts. The Rancher chart supports `extraHostnames` (or we can use `ingress.extraRules` via valuesContent). Add:
```yaml
__EXTRA_HOSTNAMES__
```

- [ ] **Step 2: Commit**

```bash
git add post-install/02-rancher.yaml
git commit -m "feat: set ingressClassName to nginx for native sync compatibility"
```

---

### Task 5: Delete host-ingress.yaml

**Files:**
- Delete: `host-ingress.yaml`

- [ ] **Step 1: Remove the file**

```bash
git rm host-ingress.yaml
```

This file defined the manually-managed host-side NGINX ingress and `rancher-k3k-traefik` service. Both are now handled by k3k's native ingress and service sync.

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: remove host-ingress.yaml, replaced by native k3k ingress sync"
```

---

### Task 6: Strip ingress-watcher.yaml to etcd recovery + pod rebalancing only

**Files:**
- Modify: `ingress-watcher.yaml`

- [ ] **Step 1: Remove the `reconcile_ingress()` function**

Delete the entire `reconcile_ingress()` function (lines ~78-131 in current file) and all calls to it (in the pod-ready handler and after etcd recovery success).

- [ ] **Step 2: Remove the flannel crash recovery scenario**

Delete the flannel detection block from the main watcher loop. This is the section that checks for `CrashLoopBackOff`, looks for "unable to initialize network policy controller" in logs, and deletes pods. The safe_mode in k3k's template.go (PR #598) handles this natively.

- [ ] **Step 3: Remove ingress-related hardcoded YAML**

Remove the embedded Service and Ingress YAML from within the watcher script (the `rancher-k3k-traefik` service and `rancher-k3k-ingress` definitions).

- [ ] **Step 4: Update the `__HOSTNAME__` placeholder usage**

The watcher no longer needs `__HOSTNAME__` since it doesn't create ingresses. Remove the sed placeholder and any HOSTNAME references. The watcher only needs `CLUSTER`, `NS`, and state management variables.

- [ ] **Step 5: Verify remaining scenarios work independently**

The watcher should now contain only:
1. `recover_etcd_quorum()` — with the `parse_epoch()` fix
2. `check_pod_balance()` — HA pod rebalancing
3. The main watch loop that calls these two functions

- [ ] **Step 6: Commit**

```bash
git add ingress-watcher.yaml
git commit -m "refactor: strip watcher to etcd recovery + pod rebalancing only

Native k3k ingress sync replaces reconcile_ingress().
Flannel crash recovery handled by k3k safe_mode (PR #598)."
```

---

### Task 7: Strip ingress-reconciler.yaml to RBAC + watcher support only

**Files:**
- Modify: `ingress-reconciler.yaml`

- [ ] **Step 1: Remove the CronJob entirely**

Delete the `CronJob` resource from the file. The CronJob was a safety net for ingress reconciliation and flannel recovery — both now handled natively.

- [ ] **Step 2: Update RBAC — remove ingress/service permissions**

Remove from the Role rules:
```yaml
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get", "create", "patch"]
  - apiGroups: [""]
    resources: ["services"]
    verbs: ["get", "create", "patch"]
```

Keep:
```yaml
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "delete"]
  - apiGroups: ["k3k.io"]
    resources: ["clusters"]
    verbs: ["get", "patch"]
```

These are still needed for etcd recovery (patch clusters, delete pods) and rebalancing (list/delete pods).

- [ ] **Step 3: Rename the file to `k3k-watcher-rbac.yaml`**

Since it no longer contains the ingress-reconciler CronJob, rename for clarity:
```bash
git mv ingress-reconciler.yaml k3k-watcher-rbac.yaml
```

Update `deploy.sh` Step 8 reference from `ingress-reconciler.yaml` to `k3k-watcher-rbac.yaml`.

- [ ] **Step 4: Rename the watcher file for clarity**

```bash
git mv ingress-watcher.yaml k3k-watcher.yaml
```

Update `deploy.sh` Step 8 reference accordingly. The file is no longer primarily about ingress.

- [ ] **Step 5: Commit**

```bash
git add k3k-watcher-rbac.yaml k3k-watcher.yaml deploy.sh
git commit -m "refactor: rename ingress-watcher/reconciler to k3k-watcher

CronJob removed (native sync replaces it).
RBAC stripped to pods + clusters only.
File names reflect actual purpose."
```

---

### Task 8: Update deploy.sh step numbering and cleanup

**Files:**
- Modify: `deploy.sh`

- [ ] **Step 1: Renumber steps**

New step flow:
1. Install/upgrade k3k controller
2. Create k3k virtual cluster (with tlsSANs, customCAs, ingress sync, no Traefik)
3. Extract kubeconfig (ingress-based URL or NodePort fallback)
4. Deploy cert-manager
5. Create CA Issuer + multi-FQDN Certificate
6. Deploy Rancher (with `ingressClassName: nginx`)
7. Deploy k3k-watcher (RBAC + watcher deployment only)
8. Merge kubeconfig

Steps removed: old 6 (TLS copy), old 7 (host ingress), CronJob from old 8.

- [ ] **Step 2: Update the final output block**

Update the success message to show:
- Rancher URL with all FQDNs
- k3k API URL (`https://k3k.hvst-vip.aegisgroup.ch` instead of NodePort)
- Remove `--insecure-skip-tls-verify` from examples when custom CA is used

- [ ] **Step 3: Commit**

```bash
git add deploy.sh
git commit -m "chore: renumber deploy steps, update output for ingress-based access"
```

---

### Task 9: Clean up host cluster resources from old deployment

**Files:**
- Modify: `destroy.sh` (if needed)

- [ ] **Step 1: Add cleanup for legacy resources**

When migrating an existing deployment, the old manually-created resources need removal. Add to `destroy.sh` or create a one-time migration script:
```bash
# Remove legacy host-side resources (replaced by native k3k sync)
kubectl delete ingress rancher-k3k-ingress -n rancher-k3k --ignore-not-found
kubectl delete svc rancher-k3k-traefik -n rancher-k3k --ignore-not-found
kubectl delete cronjob ingress-reconciler -n rancher-k3k --ignore-not-found
# Legacy TLS secret copy (now synced natively)
kubectl delete secret tls-rancher-ingress -n rancher-k3k --ignore-not-found
```

- [ ] **Step 2: Test destroy.sh still works**

Run: `bash -n destroy.sh`
Expected: Clean parse

- [ ] **Step 3: Commit**

```bash
git add destroy.sh
git commit -m "chore: clean up legacy host-side ingress/service/TLS resources"
```

---

### Task 10: Integration test — full redeploy on live cluster

- [ ] **Step 1: Clean up legacy resources from current deployment**

```bash
kubectl --context harvester delete ingress rancher-k3k-ingress -n rancher-k3k --ignore-not-found
kubectl --context harvester delete svc rancher-k3k-traefik -n rancher-k3k --ignore-not-found
kubectl --context harvester delete cronjob ingress-reconciler -n rancher-k3k --ignore-not-found
```

- [ ] **Step 2: Run deploy.sh with updated config**

```bash
KUBECONFIG=~/.kube/config.bak.20260228_062301 kubectl config use-context harvester
./deploy.sh -c deploy.conf
```

- [ ] **Step 3: Verify k3k API accessible via ingress**

```bash
kubectl --context rancher-k3k get nodes
# Should work via https://k3k.hvst-vip.aegisgroup.ch (no high port)
```

- [ ] **Step 4: Verify Rancher accessible via all FQDNs**

```bash
curl -sk https://rancher.hvst-vip.aegisgroup.ch/healthz
# Add additional FQDNs once DNS CNAMEs are created
```

- [ ] **Step 5: Verify native ingress sync is working**

```bash
# Check that k3k synced the Rancher ingress to the host namespace
kubectl --context harvester get ingress -n rancher-k3k -l k3k.io/clusterName=rancher
```

- [ ] **Step 6: Verify no Traefik inside vCluster**

```bash
kubectl --context rancher-k3k get pods -n kube-system -l app.kubernetes.io/name=traefik
# Expected: No resources found
```

- [ ] **Step 7: Verify watcher only has 2 scenarios**

```bash
kubectl --context harvester logs -l app=k3k-watcher -n rancher-k3k --tail=5
# Should show etcd + rebalancing checks only, no ingress reconciliation
```

- [ ] **Step 8: Verify TLS certificate has all SANs**

```bash
echo | openssl s_client -connect rancher.hvst-vip.aegisgroup.ch:443 -servername rancher.hvst-vip.aegisgroup.ch 2>/dev/null | openssl x509 -noout -text | grep DNS
# Should list all FQDNs from HOSTNAMES
```

- [ ] **Step 9: Commit final state**

```bash
git add -A
git commit -m "feat: complete migration to native k3k ingress sync

- k3k API exposed via ingress (SSL passthrough) on port 443
- Native ingress sync replaces manual host-side ingress/service
- Traefik disabled inside vCluster (single-tier ingress)
- Multi-FQDN support via HOSTNAMES in deploy.conf
- Private CA for k3k API server TLS via spec.customCAs
- Watcher stripped to etcd recovery + pod rebalancing only
- Flannel recovery removed (handled by k3k safe_mode PR #598)"
```
