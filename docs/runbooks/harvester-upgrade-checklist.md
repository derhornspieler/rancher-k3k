# Runbook: Harvester Upgrade Checklist (host-cluster impact on k3k + Rancher)

## Scope

Pre- and post-upgrade verification for the **host Harvester / RKE2 cluster**
that hosts the k3k vCluster and Rancher. Focused on the components this repo
modifies on the host:

- `HelmChartConfig/rke2-ingress-nginx` (the **`--enable-ssl-passthrough`**
  patch — required for the k3k API server ingress)
- The host NGINX ingress controller (DaemonSet
  `rke2-ingress-nginx-controller` in `kube-system`)

This runbook does **not** cover the Harvester upgrade procedure itself
(use Harvester's official upgrade flow). It covers what to check on either
side of that flow so that Rancher and k3k stay reachable on port 443.

For vCluster / Rancher / k3s upgrades inside the vCluster, see
`docs/runbooks/k3k-vcluster-k8s-upgrade.md` and
`docs/runbooks/rancher-upgrade-v2-14.md`.

## Why this matters

`deploy.sh` Step 1.6 patches `HelmChartConfig/rke2-ingress-nginx` in
`kube-system` to add `controller.extraArgs.enable-ssl-passthrough: "true"`.
That flag is what lets the k3k API server ingress (annotated with
`nginx.ingress.kubernetes.io/ssl-passthrough: "true"`) terminate TLS at the
vCluster apiserver instead of at the host ingress.

If the Harvester upgrade reapplies its own bundled `HelmChartConfig` and
clobbers our `valuesContent`, the DaemonSet will roll out without the flag
and the k3k API ingress will fail TLS handshakes (clients will see the host
NGINX self-signed default cert, not the vCluster apiserver cert).

Recovery is fast — `scripts/ensure-ssl-passthrough.sh` is idempotent and
restores the patch in under a minute — but the failure is silent until you
try to use the kubeconfig, so this checklist exists to catch it eagerly.

## Pre-upgrade snapshot

Run against the **host cluster** (`harvester` context):

```bash
mkdir -p /tmp/harvester-upgrade-snapshot
cd /tmp/harvester-upgrade-snapshot

# 1. The HelmChartConfig (our patch surface)
kubectl get helmchartconfig rke2-ingress-nginx -n kube-system -o yaml \
  > hcc-rke2-ingress-nginx.pre.yaml

# 2. The DaemonSet (live source of truth for active args)
kubectl get ds rke2-ingress-nginx-controller -n kube-system -o yaml \
  > ds-rke2-ingress-nginx-controller.pre.yaml

# 3. Confirm the flag is currently active on the running pods
kubectl get ds rke2-ingress-nginx-controller -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].args}' \
  | tr ',' '\n' | grep -- '--enable-ssl-passthrough' \
  && echo "OK: ssl-passthrough is active pre-upgrade" \
  || echo "WARN: ssl-passthrough was already missing — fix before upgrading"

# 4. Functional test — k3k apiserver should answer with its own cert
#    Replace <PRIMARY_K3K_API> with the value from deploy.conf
echo | openssl s_client -connect <PRIMARY_K3K_API>:443 \
        -servername <PRIMARY_K3K_API> 2>/dev/null \
  | openssl x509 -noout -subject -issuer
# Expect: subject contains "kube-apiserver" or the vCluster CA-issued name,
# NOT "Kubernetes Ingress Controller Fake Certificate"
```

Also note the current ingress-nginx **chart version** so you can spot a bump:

```bash
kubectl get helmchart rke2-ingress-nginx -n kube-system \
  -o jsonpath='{.spec.version}{"\n"}'
```

## Run the Harvester upgrade

Follow Harvester's documented upgrade procedure (out of scope here). The
upgrade will roll the host nodes; expect the ingress DaemonSet to recreate
its pods.

## Post-upgrade verification

Run against the **host cluster** once the upgrade reports complete:

### 1. Did the patch survive?

```bash
./scripts/ensure-ssl-passthrough.sh --check
```

Exit code `0` means both the HelmChartConfig and the live DaemonSet still
have the flag. Exit code `1` means at least one is missing — proceed to
**Recovery** below.

### 2. Diff against the pre-upgrade snapshot

```bash
kubectl get helmchartconfig rke2-ingress-nginx -n kube-system -o yaml \
  > /tmp/harvester-upgrade-snapshot/hcc-rke2-ingress-nginx.post.yaml

diff -u /tmp/harvester-upgrade-snapshot/hcc-rke2-ingress-nginx.pre.yaml \
        /tmp/harvester-upgrade-snapshot/hcc-rke2-ingress-nginx.post.yaml
```

A clean diff (only `resourceVersion` / managed-fields changes) means
Harvester left the customization alone. Any change to `spec.valuesContent`
is a red flag — read it carefully.

### 3. Confirm the chart version (and that the flag is still supported)

```bash
NEW_VER=$(kubectl get helmchart rke2-ingress-nginx -n kube-system \
            -o jsonpath='{.spec.version}')
echo "ingress-nginx chart version: $NEW_VER"

# Spot-check that --enable-ssl-passthrough still appears in the controller args
kubectl get ds rke2-ingress-nginx-controller -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].args}' \
  | tr ',' '\n' | grep ssl-passthrough
```

If the chart bumped a major version, skim the
[ingress-nginx changelog](https://github.com/kubernetes/ingress-nginx/blob/main/changelog/)
for any rename/removal of `--enable-ssl-passthrough` (it has been stable for
many releases, but verify).

### 4. Functional test — end-to-end TLS through the host ingress

```bash
# k3k apiserver
echo | openssl s_client -connect <PRIMARY_K3K_API>:443 \
        -servername <PRIMARY_K3K_API> 2>/dev/null \
  | openssl x509 -noout -subject -issuer

# Rancher UI (separate ingress, no passthrough — should show Rancher leaf cert)
echo | openssl s_client -connect <PRIMARY_HOSTNAME>:443 \
        -servername <PRIMARY_HOSTNAME> 2>/dev/null \
  | openssl x509 -noout -subject -issuer

# kubectl through the k3k apiserver ingress
kubectl --context k3k-rancher get nodes
```

All three should succeed. If `kubectl --context k3k-rancher` returns a TLS
error (`x509: certificate signed by unknown authority` despite the right
CA being trusted, or `tls: failed to verify certificate`), SSL passthrough
is almost certainly broken — the host NGINX is presenting its own cert
instead of passing the vCluster apiserver's cert through.

## Recovery — patch was clobbered

```bash
# 1. Restore the patch (idempotent)
./scripts/ensure-ssl-passthrough.sh

# 2. Verify
./scripts/ensure-ssl-passthrough.sh --check

# 3. Re-run the functional test from step 4 above
```

The script writes a HelmChartConfig with our `enable-ssl-passthrough` flag
merged into whatever `valuesContent` Harvester now ships. The
helm-controller reconciles within ~30s and the DaemonSet rolls out the new
args.

If `--check` still reports failure after the script completes, capture
diagnostics and escalate:

```bash
kubectl describe helmchartconfig rke2-ingress-nginx -n kube-system
kubectl describe helmchart rke2-ingress-nginx -n kube-system
kubectl logs -n kube-system -l app.kubernetes.io/name=helm-controller --tail=200
kubectl describe ds rke2-ingress-nginx-controller -n kube-system
```

A common gotcha: if Harvester now manages the `HelmChartConfig` via its own
controller (not the k3s helm-controller), an `ownerReference` may revert
our changes. In that case the long-term fix is to wrap our patch in a
`ManagedChart` or equivalent Harvester-native customization rather than
fighting the reconciler — file an issue on this repo and link the upstream
docs you found.

## See also

- `deploy.sh` Step 1.6 — original inline implementation (still authoritative
  for fresh deploys)
- `scripts/ensure-ssl-passthrough.sh` — standalone form of the same patch
- `docs/runbooks/rancher-upgrade-v2-14.md` — vCluster-side Rancher upgrade
- `docs/runbooks/k3k-vcluster-k8s-upgrade.md` — vCluster k8s upgrade
- Upstream: [k3k API ingress mode](https://github.com/rancher/k3k) (the
  feature that makes this patch necessary)
