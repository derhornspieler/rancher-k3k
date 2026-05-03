# Runbook: Rancher Upgrade — v2.13.x → v2.14.1

## Scope

Upgrades the Rancher control plane running inside the k3k vCluster from
`v2.13.x` to `v2.14.1`. Does **not** touch the k3k operator, k3s version, or
downstream cluster agents — those are tracked separately
(`docs/upstream-tracking.md`, `docs/runbooks/k3k-stuck-k8s-upgrade.md`).

This runbook is for operators upgrading an already-deployed cluster. For
greenfield deploys, the new default is wired into `deploy.sh` and
`deploy.conf.example`.

## What changed in 2.14 that matters here

| Change | Impact on this deployment |
|--------|---------------------------|
| **Kubernetes API Aggregation Layer required** on management cluster | k3s enables `kube-aggregator` by default — verify before upgrade |
| **Embedded Cluster API removed**, auto-migrates to Rancher Turtles | We don't use embedded CAPI; downstream clusters are imported (Harvester, RKE2). Migration should be a no-op but watch for Turtles install logs |
| **CAAPF disabled by default** | Not used here |
| **Kubernetes 1.32 support removed** | k3k vCluster runs 1.34.x — fine |
| **Supported management-cluster K8s**: 1.33.11, 1.34.7, 1.35.4 | Current k3k is 1.34.3. Upstream lists 1.34.7 as the tested patch — verify Rancher pods schedule and reconcile cleanly; bump k3s in k3k if needed |
| **Default `ingress-nginx` timeout annotations no longer injected** | We use Traefik inside the vCluster; host nginx is pass-through. Low impact, but check ingress reconciliation post-upgrade |
| Helm 3.18+ required | HelmChart controller in k3s is unaffected; only matters for out-of-band `helm` invocations |
| CVE-2026-25705 (UI extensions) / CVE-2026-41050 (Fleet impersonation) | Fleet is disabled (`features: fleet=false`); UI extensions require admin. Already mitigated |

Upstream references: [v2.14.1 release notes](https://github.com/rancher/rancher/releases/tag/v2.14.1),
[bug #53854 (RKE2 1.35 upgrade websocket failure)](https://github.com/rancher/rancher/issues/53854).
The 53854 failure mode is RKE2-on-K8s-1.35-specific and does not affect this
k3k-on-K8s-1.34 deployment.

## Pre-flight checks

All commands run against the host cluster (`harvester` context) unless noted.
Replace `KUBECONFIG=…` with whatever resolves the `harvester` context locally.

### 1. Backup is fresh and restorable

```bash
# Most recent rancher-backup CR should be <24h old and Completed
kubectl get backups.resources.cattle.io -A \
  --sort-by=.metadata.creationTimestamp
```

If older than 24h, force a fresh backup:

```bash
./backup.sh    # captures full state + writes manifest to MinIO
```

Verify the latest object exists in S3:

```bash
mc ls aegis-backup/rancher-backups/ | tail -5
```

### 2. Aggregation Layer is enabled inside the vCluster

```bash
# k3k vCluster context
kubectl --context=k3k-rancher api-versions | grep apiregistration.k8s.io
# Expect: apiregistration.k8s.io/v1
```

If missing, the upgrade will fail to register the Rancher extension API server.
k3s ships with kube-aggregator on by default; absence indicates a
`--disable=apiserver-aggregator` somewhere in `serverArgs` (we don't set it).

### 3. K8s version on the management cluster

```bash
kubectl --context=k3k-rancher version --short
# Expect: Server v1.34.x
```

Rancher 2.14.1 is tested against 1.34.7. **Pre-bump the vCluster K8s to
1.34.7-k3s1 before the Rancher chart upgrade** — see
[`k3k-vcluster-k8s-upgrade.md`](k3k-vcluster-k8s-upgrade.md) for the
procedure. Do **not** use the Rancher UI's "Kubernetes Version" upgrade —
that drives `system-upgrade-controller`, which fails on k3k vClusters
([`k3k-stuck-k8s-upgrade.md`](k3k-stuck-k8s-upgrade.md)).

### 4. PDB and replica health

```bash
kubectl get pdb -n rancher-k3k k3k-rancher-server
# ALLOWED DISRUPTIONS: 1, MIN AVAILABLE: 2

kubectl get pods -n rancher-k3k -l role=server -o wide
# All 3 server pods Ready, one per Harvester node
```

```bash
# Inside the vCluster
kubectl --context=k3k-rancher get deploy -n cattle-system rancher
# Replicas 3/3, strategy RollingUpdate with maxUnavailable=0
```

### 5. Helm chart is reachable

```bash
# If using public repo
curl -sfI https://releases.rancher.com/server-charts/latest/rancher-2.14.1.tgz

# If using Harbor pull-through
helm pull oci://harbor.example.com/charts/rancher --version v2.14.1
```

## Upgrade procedure

Rancher is managed by the in-cluster HelmChart controller, not by direct
`helm` calls. The upgrade is a `version:` bump on the
`HelmChart/rancher` CR in `kube-system`.

### 1. Patch the HelmChart CR

```bash
kubectl --context=k3k-rancher -n kube-system \
  patch helmchart rancher --type merge \
  -p '{"spec":{"version":"v2.14.1"}}'
```

The HelmChart controller picks up the change within ~30s and runs
`helm upgrade` via a Job in `kube-system` named `helm-install-rancher-…`.

### 2. Watch the install job

```bash
kubectl --context=k3k-rancher -n kube-system \
  logs -f -l helmcharts.helm.cattle.io/chart=rancher --tail=200
```

Expect: `Release "rancher" has been upgraded.` and exit 0.

### 3. Watch the rollout

The Rancher Deployment uses `maxUnavailable=0` + the HA PDB — pods replace one
at a time, new pod must be Ready before the old is terminated. With 3
replicas, expect ~3–5 minutes total.

```bash
kubectl --context=k3k-rancher -n cattle-system rollout status deploy/rancher
```

Watch for the embedded-CAPI → Turtles migration in the new pod logs:

```bash
kubectl --context=k3k-rancher -n cattle-system \
  logs -l app=rancher --tail=500 | grep -iE 'turtles|capi|migration'
```

## Post-upgrade verification

### Functional checks

```bash
# Rancher version (UI About page or API)
curl -sk https://${HOSTNAME}/v3/settings/server-version | jq .value
# Expect: "v2.14.1"

# All cattle-system pods Ready
kubectl --context=k3k-rancher -n cattle-system get pods

# Downstream clusters still connected
kubectl --context=k3k-rancher get clusters.management.cattle.io
# Expect: all show Ready=True
```

### Smoke tests

1. Log in to the UI as `admin`. Confirm bootstrap-password flow is not
   triggered (it shouldn't be — the upgrade preserves auth).
2. Open both downstream clusters (Harvester, rke2-prod). Confirm node lists
   render and `kubectl` via Rancher API proxy works:

   ```bash
   kubectl --context=rke2-prod get nodes
   kubectl --context=harvester get nodes
   ```

3. Confirm cert-manager-issued Rancher TLS cert is unchanged (chart upgrade
   should not rotate it):

   ```bash
   kubectl --context=k3k-rancher -n cattle-system \
     get secret tls-rancher-ingress \
     -o jsonpath='{.metadata.annotations.cert-manager\.io/certificate-name}'
   ```

4. Trigger an on-demand backup and confirm it completes:

   ```bash
   kubectl --context=k3k-rancher \
     create -f - <<'EOF'
   apiVersion: resources.cattle.io/v1
   kind: Backup
   metadata:
     generateName: post-upgrade-verify-
   spec:
     resourceSetName: rancher-resource-set
     storageLocation:
       s3:
         credentialSecretName: rancher-backup-s3
         credentialSecretNamespace: cattle-resources-system
         bucketName: rancher-backups
         endpoint: backup.example.com
   EOF
   ```

## Rollback

If verification fails or pods crashloop, roll the chart version back. The
HelmChart controller does not retain helm release history beyond what helm
itself stores, so rollback is by re-patching the CR to the prior version:

```bash
kubectl --context=k3k-rancher -n kube-system \
  patch helmchart rancher --type merge \
  -p '{"spec":{"version":"v2.13.3"}}'
```

If the chart upgrade left the cluster in a state the controller can't
reconcile (CRD schema regression, API server crash), restore from the
pre-upgrade backup:

```bash
./rancher-restore.sh \
  --backup-file rancher-backup-<timestamp>.tar.gz \
  --rancher-version v2.13.3
```

The restore replays the backup tarball into a freshly redeployed vCluster.
See [`docs/backup-restore.md`](../backup-restore.md) for the full procedure.

## Known gotchas

- **HelmChart Job retries**: if the install job's first attempt fails, the
  controller backs off and retries. Don't `kubectl delete` the helmchart CR
  to "reset" — that uninstalls Rancher. Patch a new `version:` to override.
- **Turtles install adds new CRDs** (`*.turtles.cattle.io`): expect them to
  appear during the upgrade. Don't delete them.
- **Ingress reconcile**: this repo's `ingress-watcher` and
  `ingress-reconciler` watch for the Rancher ingress and rebuild it if
  pruned. After upgrade, confirm a single ingress exists in `cattle-system`
  with the expected hostname.
