# Runbook: k3k Stuck Kubernetes Upgrade

## Symptom

One or more k3k vCluster server nodes show `SchedulingDisabled` after a Kubernetes version upgrade was attempted via the Rancher UI. The upgrade plan shows `DeadlineExceeded` and the cluster appears stuck.

```
NAME                   STATUS                     ROLES                AGE   VERSION
k3k-rancher-server-0   Ready                      control-plane,etcd   8d    v1.34.3+k3s1
k3k-rancher-server-1   Ready,SchedulingDisabled   control-plane,etcd   8d    v1.34.3+k3s1
k3k-rancher-server-2   Ready                      control-plane,etcd   8d    v1.34.3+k3s1
```

Upgrade plan status:
```
k3s-master-plan   rancher/k3s-upgrade   v1.34.5+k3s1   False   DeadlineExceeded
```

## Root Cause

**k3k vClusters cannot be upgraded via system-upgrade-controller or the Rancher UI.**

The `rancher/k3s-upgrade` image replaces the k3s binary on a real host and restarts the service. In a k3k vCluster, k3s runs inside a container where the binary is baked into the image. The upgrade job:

1. Cordons the node
2. Attempts to replace the binary inside the container
3. Times out (DeadlineExceeded) because the replacement doesn't work
4. Leaves the node cordoned

To upgrade k8s in a k3k vCluster, upgrade the k3k operator/controller image instead.

## Impact

- Cordoned node(s) won't accept new pod scheduling
- If the upgrade retries across nodes, multiple nodes may become cordoned
- etcd quorum is at risk if 2+ of 3 nodes are cordoned and pods get evicted
- Rancher remains functional (pods already running continue to serve)

## Prerequisites

- `kubectl` access to the Harvester host cluster (`--context harvester`)
- vCluster kubeconfig (extract from `k3k-rancher-kubeconfig` secret) or `kubectl exec` into server-0

## Recovery Procedure

### Step 1: Take a backup first

If rancher-backup operator is installed:
```bash
K3K_KUBECTL="kubectl --kubeconfig=$KUBECONFIG_FILE --insecure-skip-tls-verify"
$K3K_KUBECTL apply -f - <<EOF
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: pre-recovery-backup-$(date +%Y%m%d-%H%M%S)
spec:
  resourceSetName: rancher-resource-set-full
  encryptionConfigSecretName: backup-encryption
  storageLocation:
    s3:
      bucketName: rancher-backups
      endpoint: backup.example.com
      credentialSecretName: s3-credentials
      credentialSecretNamespace: cattle-resources-system
      endpointCA: "<base64-root-ca>"
EOF
```

If not, take an etcd snapshot directly:
```bash
kubectl --context harvester exec k3k-rancher-server-0 -n rancher-k3k -- k3s etcd-snapshot save
```

### Step 2: Revert the Kubernetes version in Rancher

The version is stored in `clusters.management.cattle.io/local`. Patch it back to the running version:

```bash
$K3K_KUBECTL patch clusters.management.cattle.io local --type=merge \
  -p '{"spec":{"k3sConfig":{"kubernetesVersion":"v1.34.3+k3s1"}}}'
```

Replace `v1.34.3+k3s1` with whatever version `kubectl get nodes` shows in the VERSION column.

### Step 3: Scale down the system-upgrade-controller

Rancher's internal controller recreates the upgrade plans as long as the desired version differs. Even after reverting the version, scaling down SUC prevents any race:

```bash
$K3K_KUBECTL scale deploy system-upgrade-controller -n cattle-system --replicas=0
```

### Step 4: Delete the stuck upgrade plans

```bash
$K3K_KUBECTL delete plan k3s-master-plan k3s-worker-plan -n cattle-system
```

If plans reappear, wait 30 seconds for Rancher to reconcile the version revert from Step 2. Plans may be recreated at the corrected version and immediately show as complete.

### Step 5: Kill any active upgrade jobs

```bash
$K3K_KUBECTL delete jobs -n cattle-system -l plan.upgrade.cattle.io/name=k3s-master-plan
```

### Step 6: Uncordon all nodes

```bash
$K3K_KUBECTL uncordon k3k-rancher-server-0
$K3K_KUBECTL uncordon k3k-rancher-server-1
$K3K_KUBECTL uncordon k3k-rancher-server-2
```

### Step 7: Verify

```bash
# All nodes should be Ready (no SchedulingDisabled)
$K3K_KUBECTL get nodes

# All Rancher pods should be Running
$K3K_KUBECTL get pods -n cattle-system

# No active upgrade plans targeting a different version
$K3K_KUBECTL get plans.upgrade.cattle.io -n cattle-system

# Downstream clusters connected
$K3K_KUBECTL get clusters.management.cattle.io
```

## Prevention

1. **Keep system-upgrade-controller scaled to 0** on k3k vClusters. It cannot work.
2. **Educate platform admins**: the Rancher UI "Kubernetes Version" dropdown does NOT work for k3k clusters. It triggers the system-upgrade-controller which cannot replace binaries inside containers.
3. **To upgrade k8s**: upgrade the k3k operator Helm chart (which uses a newer k3s image), not the Rancher UI version selector.

## Related

- [rancher/k3k#678](https://github.com/rancher/k3k/issues/678) — etcd deadlock after full restart
- `docs/etcd-quorum-recovery.md` — if the stuck upgrade caused quorum loss
- `docs/runbooks/k3k-rancher-recovery.md` — general k3k recovery procedures
