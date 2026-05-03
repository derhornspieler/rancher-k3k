# Runbook: Recovering a Failed k3k + Rancher Cluster

## Overview

This runbook covers recovery procedures for a k3k (Kubernetes-in-Kubernetes) cluster running Rancher that has failed or become degraded. The k3k cluster is deployed as a vCluster on Harvester with etcd data stored in 40Gi PVCs.

Common failure scenarios:

1. **Etcd quorum deadlock** — all server pods crash after restart with stale etcd peer IPs
2. **Automated recovery failure** — the ingress-watcher tried to auto-recover but timed out
3. **Corrupted etcd data** — cluster restart fails due to corrupt etcd state
4. **Cluster state loss** — Rancher data unrecoverable, restore from MinIO backup needed

---

## Prerequisites

Before starting recovery:

- [ ] Access to the Harvester host cluster with `kubectl` context `harvester`
- [ ] Backup kubeconfig at `~/.kube/config.bak.*` (if you lost the original)
- [ ] Helm 3+ installed (for restoring Rancher if needed)
- [ ] `jq` installed (for parsing JSON)
- [ ] All commands run as a user with write access to `~/.kube/`

### Verify Access

```bash
# Verify Harvester context exists
kubectl config current-context
# Should return: harvester

# Verify access to k3k namespace
kubectl get namespaces | grep rancher-k3k

# Verify k3k cluster CR exists
kubectl get clusters.k3k.io -n rancher-k3k rancher -o yaml | head -20
```

If any step fails, restore your kubeconfig from backup:

```bash
# Find backup kubeconfig
ls -ltr ~/.kube/config.bak.*

# Restore it
cp ~/.kube/config.bak.YYYYMMDD ~/.kube/config
```

---

## Step 1: Assess the Situation

### Check k3k Cluster Status

```bash
NS="rancher-k3k"
CLUSTER="rancher"

# Get full cluster CR with annotations
kubectl get clusters.k3k.io "$CLUSTER" -n "$NS" -o yaml
```

Look for these annotations in the output:

- `k3k.io/etcd-recovery-state` — recovery state (scaling-down, resetting, scaling-up, failed, or missing)
- `k3k.io/etcd-original-servers` — original server count before recovery
- `k3k.io/etcd-recovery-started` — ISO 8601 timestamp when recovery began

Expected output structure:

```yaml
metadata:
  annotations:
    k3k.io/etcd-recovery-state: "failed"
    k3k.io/etcd-original-servers: "3"
    k3k.io/etcd-recovery-started: "2026-02-26T12:00:00Z"
  name: rancher
  namespace: rancher-k3k
spec:
  servers: 1  # Will be lower if recovery downscaled
  ...
status:
  phase: Degraded  # or Updating, Ready, etc.
  readyServers: 0
  ...
```

### Check Pod Status

```bash
# Get all server pods
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" -o wide
```

Expected statuses by scenario:

| Scenario | Pod Status | Ready | Restarts |
|----------|-----------|-------|----------|
| Healthy | Running | 1/1 | 0-1 |
| Deadlock | CrashLoopBackOff | 0/1 | 10+ |
| Recovery in progress | Various | Mixed | Higher |

### Check Pod Logs for Error Messages

```bash
# Get the last 20 lines of logs from each server pod
for POD in $(kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" \
    -o jsonpath='{.items[*].metadata.name}'); do
  echo "=== $POD (current logs) ==="
  kubectl logs "$POD" -n "$NS" --tail=20 2>/dev/null || echo "(no logs)"

  echo "=== $POD (previous logs) ==="
  kubectl logs "$POD" -n "$NS" --previous --tail=20 2>/dev/null || echo "(no previous logs)"
  echo ""
done
```

Look for these key error messages:

- **Etcd quorum deadlock**: `timed out waiting for node to change IP`
- **Flannel crash**: `unable to initialize network policy controller`
- **DNS resolution**: `no such host`, `connection refused`
- **Memory pressure**: `OOMKilled`, `MemoryLimit exceeded`

### Check StatefulSet Configuration

```bash
# Get StatefulSet managing server pods
kubectl get statefulset -n "$NS" -l "cluster=$CLUSTER,role=server" -o yaml | head -50
```

Look for:

- Replica count (should match `spec.servers` on Cluster CR)
- PVC names and sizes
- InitContainers (may be added by recovery procedures)
- Pod template configuration

### Check PVC Status

```bash
# Get PVCs for the vCluster
kubectl get pvc -n "$NS" -l "cluster=$CLUSTER" -o wide
```

Expected output:

```
NAME                              STATUS   VOLUME    CAPACITY   ACCESS MODES
data-rancher-server-0             Bound    pvc-xxxx   40Gi       RWO
data-rancher-server-1             Bound    pvc-xxxx   40Gi       RWO
data-rancher-server-2             Bound    pvc-xxxx   40Gi       RWO
```

If any PVC is `Pending`, the underlying storage may be full or unavailable:

```bash
# Get storage pool status
kubectl get storageclass
kubectl get pv | grep rancher-k3k
```

---

## Step 2: Diagnose Recovery State

Use this flowchart to determine your next action:

```
START: Assess k3k cluster
│
├─ All pods Running + Cluster phase=Ready?
│  └─ YES: Cluster is healthy — STOP. Go to "Post-Recovery Verification"
│
├─ Recovery annotations present (etcd-recovery-state)?
│  │
│  ├─ State = "failed"?
│  │  └─ YES: Go to "Recovery Failed — Manual Intervention"
│  │
│  ├─ State = "scaling-down" or "scaling-up"?
│  │  └─ YES: Go to "Recovery In Progress — Wait or Resume"
│  │
│  └─ State = "resetting"?
│     └─ YES: Go to "Recovery In Progress — Wait or Resume"
│
├─ All pods CrashLoopBackOff + "timed out waiting for node to change IP"?
│  └─ YES: Go to "Etcd Quorum Deadlock — Auto-Recovery Failed"
│
├─ Some pods CrashLoopBackOff with network error?
│  └─ YES: Go to "Partial Cluster Failure"
│
└─ Other error (check logs)?
   └─ YES: Go to "Cluster Corruption or Unknown Failure"
```

---

## Step 3: Follow Recovery Procedure for Your Scenario

### Scenario A: Recovery Already In Progress (state = scaling-down/resetting/scaling-up)

The ingress-watcher detected the deadlock and started recovery. Monitor progress:

```bash
# Watch pod status
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" -w

# Watch cluster phase
kubectl get clusters.k3k.io "$CLUSTER" -n "$NS" -w

# Watch watcher logs
kubectl logs -l app=ingress-watcher -n "$NS" -f --tail=50
```

**Wait up to 10 minutes for recovery to complete.** The state machine progresses:

1. `scaling-down` (1-2 min) — old pods terminate
2. `resetting` (2-5 min) — etcd cluster-reset runs on server-0
3. `scaling-up` (3-5 min) — new servers rejoin as etcd members
4. Annotations removed, cluster Ready

Once all pods are Ready:

```bash
# Verify Rancher is accessible
curl -sk https://<rancher-url>/ping
# Should return "pong"
```

If recovery is still running after 10 minutes or recovery state = `failed`, proceed to **Scenario B**.

---

### Scenario B: Etcd Quorum Deadlock — Auto-Recovery Failed (state = failed)

The ingress-watcher detected the deadlock but recovery timed out or failed. Clear the failed state and retry manually:

```bash
NS="rancher-k3k"
CLUSTER="rancher"

# 1. Check what state timed out
kubectl get clusters.k3k.io "$CLUSTER" -n "$NS" \
  -o jsonpath='{.metadata.annotations.k3k\.io/etcd-recovery-state}'
# Output: failed

# 2. Check watcher logs for the exact error
kubectl logs -l app=ingress-watcher -n "$NS" --tail=50
```

Now use the **Manual Recovery — Spec Patch Method** below:

```bash
# 3. Clear the failed recovery annotations
kubectl annotate clusters.k3k.io "$CLUSTER" -n "$NS" --overwrite \
  "k3k.io/etcd-recovery-state=" \
  "k3k.io/etcd-original-servers=" \
  "k3k.io/etcd-recovery-started="
# Note: Use '=' (not '-') to clear all three in one command

# 4. Verify annotations are cleared
kubectl get clusters.k3k.io "$CLUSTER" -n "$NS" \
  -o jsonpath='{.metadata.annotations}' | jq .
```

Now follow **Manual Recovery — Spec Patch Method** (below).

---

### Scenario C: Etcd Quorum Deadlock — Manual Recovery (Spec Patch Method)

Use this when:

- Auto-recovery failed and you've cleared the failed state (Scenario B), or
- Auto-recovery didn't trigger and you need to recover manually

This is the **recommended** manual procedure. It triggers the same `cluster-reset` mechanism that auto-recovery uses.

#### Procedure

```bash
NS="rancher-k3k"
CLUSTER="rancher"

# 1. Verify the deadlock
echo "=== Checking pod status ==="
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS"
# All should show CrashLoopBackOff

echo "=== Checking for etcd timeout error ==="
kubectl logs "${CLUSTER}-server-0" -n "$NS" --previous --tail=5
# Should contain: "timed out waiting for node to change IP"

# 2. Set recovery annotations (for tracking)
ORIGINAL_SERVERS=$(kubectl get clusters.k3k.io "$CLUSTER" -n "$NS" \
  -o jsonpath='{.spec.servers}' 2>/dev/null || echo "3")
echo "Original server count: $ORIGINAL_SERVERS"

kubectl annotate clusters.k3k.io "$CLUSTER" -n "$NS" --overwrite \
  "k3k.io/etcd-recovery-state=scaling-down" \
  "k3k.io/etcd-original-servers=$ORIGINAL_SERVERS" \
  "k3k.io/etcd-recovery-started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 3. Scale down to 1 server
echo "Scaling down to 1 server..."
kubectl patch clusters.k3k.io "$CLUSTER" -n "$NS" --type=merge \
  -p '{"spec":{"servers":1}}'

# 4. Wait for server-0 to become Ready (may take 2-5 minutes)
echo "Waiting for server-0 to become Ready..."
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" -w &
WATCH_PID=$!

# Use a timeout loop instead of relying on -w
TIMEOUT=300  # 5 minutes
ELAPSED=0
INTERVAL=5

while [ $ELAPSED -lt $TIMEOUT ]; do
  READY=$(kubectl get pod "${CLUSTER}-server-0" -n "$NS" \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")

  if [ "$READY" = "true" ]; then
    echo "✓ server-0 is Ready"
    break
  fi

  echo "  Waiting... ($ELAPSED/${TIMEOUT}s)"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

kill $WATCH_PID 2>/dev/null || true

if [ "$READY" != "true" ]; then
  echo "ERROR: server-0 did not become Ready after 5 minutes"
  echo "Check pod logs:"
  kubectl logs "${CLUSTER}-server-0" -n "$NS" --tail=30
  exit 1
fi

# 5. Wait for Cluster CR to show Ready
echo "Waiting for Cluster CR to show Ready..."
ELAPSED=0
TIMEOUT=300

while [ $ELAPSED -lt $TIMEOUT ]; do
  PHASE=$(kubectl get clusters.k3k.io "$CLUSTER" -n "$NS" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  if [ "$PHASE" = "Ready" ]; then
    echo "✓ Cluster phase is Ready"
    break
  fi

  echo "  Current phase: $PHASE ($ELAPSED/${TIMEOUT}s)"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ "$PHASE" != "Ready" ]; then
  echo "ERROR: Cluster did not reach Ready phase after 5 minutes"
  echo "Current phase: $PHASE"
  kubectl get clusters.k3k.io "$CLUSTER" -n "$NS" -o yaml | tail -50
  exit 1
fi

# 6. Scale back to original server count
echo "Scaling back to $ORIGINAL_SERVERS servers..."
kubectl patch clusters.k3k.io "$CLUSTER" -n "$NS" --type=merge \
  -p "{\"spec\":{\"servers\":${ORIGINAL_SERVERS}}}"

# 7. Wait for all servers to be Ready
echo "Waiting for all $ORIGINAL_SERVERS servers to be Ready..."
ELAPSED=0
TIMEOUT=600  # 10 minutes

while [ $ELAPSED -lt $TIMEOUT ]; do
  READY_COUNT=$(kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' \
    | grep -c "true" || echo "0")

  if [ "$READY_COUNT" -ge "$ORIGINAL_SERVERS" ]; then
    echo "✓ All $ORIGINAL_SERVERS servers are Ready"
    break
  fi

  echo "  Ready count: $READY_COUNT/$ORIGINAL_SERVERS ($ELAPSED/${TIMEOUT}s)"
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ "$READY_COUNT" -lt "$ORIGINAL_SERVERS" ]; then
  echo "ERROR: Not all servers became Ready"
  kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" -o wide
  exit 1
fi

# 8. Clean up annotations
echo "Cleaning up recovery annotations..."
kubectl annotate clusters.k3k.io "$CLUSTER" -n "$NS" \
  k3k.io/etcd-recovery-state- \
  k3k.io/etcd-original-servers- \
  k3k.io/etcd-recovery-started-

# 9. Verify Rancher is healthy
echo "Verifying Rancher is healthy..."
RANCHER_URL=$(kubectl get clusters.k3k.io "$CLUSTER" -n "$NS" \
  -o jsonpath='{.spec.serverArgs}' | grep -oP '(?<=--tls-san=).*?(?=\s|$)' | head -1)

if [ -z "$RANCHER_URL" ]; then
  RANCHER_URL="rancher.example.com"  # Fallback
fi

curl -sk "https://${RANCHER_URL}/ping" || echo "WARNING: Could not verify Rancher health"
```

**Expected output from successful recovery:**

```
Original server count: 3
Scaling down to 1 server...
Waiting for server-0 to become Ready...
✓ server-0 is Ready
✓ Cluster phase is Ready
Scaling back to 3 servers...
Waiting for all 3 servers to be Ready...
✓ All 3 servers are Ready
Cleaning up recovery annotations...
Verifying Rancher is healthy...
pong
```

---

### Scenario D: Cluster Corruption or Data Loss (MinIO Restore)

If etcd data is corrupted and cannot be recovered with `cluster-reset`, restore from MinIO backup.

#### When to Use MinIO Backup

- `cluster-reset` fails with etcd data corruption errors
- PVC is corrupted beyond repair (e.g., CRC errors from storage)
- You need to recover to a known-good state from yesterday

#### Prerequisites

- MinIO credentials (from `deploy.conf` or environment)
- Access to MinIO S3 bucket `rancher-backups`
- Backup timestamp (from MinIO listing or previous backup logs)

#### Procedure

```bash
NS="rancher-k3k"
CLUSTER="rancher"
MINIO_BUCKET="rancher-backups"
MINIO_ENDPOINT="minio.example.com:9000"

# 1. List available backups in MinIO
echo "=== Available backups in MinIO ==="
aws s3api list-objects-v2 \
  --bucket "$MINIO_BUCKET" \
  --endpoint-url "https://${MINIO_ENDPOINT}" \
  --region minio \
  --query 'Contents[].{Key:Key, Size:Size, LastModified:LastModified}' \
  --output table
# Note: Requires AWS CLI configured with MinIO credentials
# If you don't have AWS CLI, use the MinIO web console at https://minio.example.com

# 2. Choose the most recent backup before the failure
# Format: rancher-backups/YYYY-MM-DD/HHMMSS-<backup-name>.tar.gz
BACKUP_KEY="rancher-backups/2026-02-25/120000-rancher-backup.tar.gz"

# 3. Scale k3k controller to 0 (prevent it from fighting recovery)
echo "Stopping k3k controller..."
kubectl scale deployment k3k-controller-manager -n k3k-system --replicas=0

# Verify controller is stopped
kubectl get pods -n k3k-system
# Should show no running k3k controller pods

# 4. Delete all server pods and PVCs
echo "Deleting server pods and PVCs..."
kubectl delete pods -l "cluster=$CLUSTER,role=server" -n "$NS" --grace-period=0 --force
kubectl delete pvc -l "cluster=$CLUSTER" -n "$NS"

# Wait for PVCs to be deleted
kubectl get pvc -n "$NS" -l "cluster=$CLUSTER" -w

# 5. Download backup from MinIO and restore etcd data
echo "Downloading backup from MinIO..."
BACKUP_DIR="/tmp/rancher-backup-restore"
mkdir -p "$BACKUP_DIR"

# Option A: Using AWS CLI (if configured)
aws s3api get-object \
  --bucket "$MINIO_BUCKET" \
  --key "$BACKUP_KEY" \
  --endpoint-url "https://${MINIO_ENDPOINT}" \
  --region minio \
  "$BACKUP_DIR/backup.tar.gz"

# Option B: Using MinIO mc client
# mc alias set minio https://minio.example.com <access-key> <secret-key>
# mc cp "minio/$MINIO_BUCKET/$BACKUP_KEY" "$BACKUP_DIR/backup.tar.gz"

# 6. Extract backup
echo "Extracting backup..."
cd "$BACKUP_DIR"
tar -xzf backup.tar.gz

# Backup should contain etcd snapshot or RKE2 backup
# Look for: etcd-snapshot-*.db or rancher-data/

# 7. Create new PVCs with extracted etcd data
echo "Creating new PVCs..."
for i in 0 1 2; do
  kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-${CLUSTER}-server-${i}
  namespace: ${NS}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: harvester-longhorn
  resources:
    requests:
      storage: 40Gi
EOF
done

# Wait for PVCs to be Bound
kubectl get pvc -n "$NS" -l "cluster=$CLUSTER" -w

# 8. Copy etcd data to PVC (using kubectl cp or debug pod)
# This requires mounting the PVC and copying the backup data
# See "Restore etcd data to PVC" section in backup-restore.md

# 9. Scale k3k controller back up
echo "Restarting k3k controller..."
kubectl scale deployment k3k-controller-manager -n k3k-system --replicas=1

# 10. Watch for cluster recovery
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" -w
kubectl get clusters.k3k.io "$CLUSTER" -n "$NS" -w
```

**Important**: This procedure requires deeper knowledge of etcd backup formats and MinIO restoration. For detailed steps, see [Universal Backup and Restore](../universal-backup-restore.md).

Consider reaching out to the platform team if you're unsure about any step.

---

### Scenario E: Partial Cluster Failure (Some Pods Running)

If some server pods are running but others are stuck in CrashLoopBackOff (not all pods failing):

```bash
NS="rancher-k3k"
CLUSTER="rancher"

# 1. Check which pods are healthy
echo "=== Pod Status ==="
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" -o wide

# 2. Check logs on crashing pods only
for POD in $(kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" \
    -o jsonpath='{range .items[?(@.status.phase=="CrashLoopBackOff")]}{.metadata.name}{"\n"}{end}'); do
  echo "=== $POD logs ==="
  kubectl logs "$POD" -n "$NS" --previous --tail=20
done

# 3. Likely causes: network plugin issue, storage issue, or node resource constraint
# Check node resources
kubectl get nodes -o wide
kubectl describe nodes | grep -A 10 "Allocated resources"

# 4. If issue is network (flannel): patch with disable-network-policy
kubectl patch clusters.k3k.io "$CLUSTER" -n "$NS" --type=merge \
  -p '{"spec":{"serverArgs":["--disable-network-policy"]}}'

# 5. If issue is node capacity: cordon the problematic node and force reschedule
PROBLEM_NODE="harvester-node-2"
kubectl cordon "$PROBLEM_NODE"
kubectl delete pods -l "cluster=$CLUSTER,role=server" -n "$NS" --grace-period=30
# Pods will reschedule to uncordoned nodes

# 6. Monitor recovery
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" -w
```

---

## Step 4: Post-Recovery Verification

Once the cluster is back to Running + Ready state, verify functionality:

```bash
NS="rancher-k3k"
CLUSTER="rancher"

# 1. Verify all server pods are Running and Ready
echo "=== Pod Status ==="
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS"
# Expected: All pods Running, 1/1 Ready, 0 restarts

# 2. Verify cluster phase is Ready
echo "=== Cluster Status ==="
kubectl get clusters.k3k.io "$CLUSTER" -n "$NS" -o jsonpath='{.status.phase}'
# Expected: Ready

# 3. Verify etcd is healthy (if you have k3k kubeconfig)
echo "=== Etcd Member Health ==="
kubectl exec -it "${CLUSTER}-server-0" -n "$NS" -- sh -c \
  'ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
    --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
    --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
    member list -w table' 2>/dev/null || echo "(requires k3k kubeconfig)"

# 4. Verify Rancher is accessible and healthy
HOSTNAME="rancher.example.com"
echo "=== Rancher Health Check ==="
curl -sk "https://${HOSTNAME}/ping"
# Expected: pong

curl -sk "https://${HOSTNAME}/v1/management.cattle.io.clusters" \
  -H "Authorization: Bearer <API_TOKEN>" | jq '.data | length'
# Shows number of managed clusters (if API token available)

# 5. Verify Rancher UI loads
echo "=== Rancher UI Check ==="
echo "Open https://${HOSTNAME} in a browser and verify the login page loads"
echo "Log in with admin credentials and verify dashboard is accessible"

# 6. Verify downstream clusters are connected
echo "=== Downstream Cluster Status ==="
# In Rancher UI: Admin > Clusters
# Look for clusters with status "Active" or "Updating" (not "Pending" or "Error")

# 7. Verify certificates are valid
echo "=== Certificate Health ==="
kubectl get secret tls-rancher-ingress -n "$NS" -o yaml | grep tls.crt | head -1
# Should exist. Check expiration:
echo "Cert expiration:"
kubectl get secret tls-rancher-ingress -n "$NS" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | \
  openssl x509 -noout -enddate 2>/dev/null || echo "(manual check required)"

# 8. Verify ingress-watcher is running
echo "=== Ingress Watcher Status ==="
kubectl get pods -l app=ingress-watcher -n "$NS"
# Should be Running, 1/1 Ready

kubectl logs -l app=ingress-watcher -n "$NS" --tail=10
# Should show no recent errors
```

If all checks pass, recovery is complete.

---

## Step 5: Restore from Backup (If Needed)

If Rancher data was lost or you need to restore configurations:

1. **Rancher settings** (stored in Rancher database — restored automatically on k3k restart)
2. **Imported clusters** (registration tokens change — must re-import via Rancher UI)
3. **API tokens** (recreate via terraform-setup.sh or Rancher UI)
4. **Custom configurations** (restore from backup if available)

See [Universal Backup and Restore](../universal-backup-restore.md) for detailed procedures.

---

## Troubleshooting

### Problem: server-0 stays in CrashLoopBackOff during scaling-down

**Symptoms**: `kubectl get pods` shows server-0 still CrashLoopBackOff after patching `spec.servers=1`.

**Diagnosis**:

```bash
# Check what the crash is (may not be etcd-related)
kubectl logs rancher-server-0 -n rancher-k3k --previous --tail=50
```

**Solution**:

If the crash is not related to etcd (`timed out waiting for node to change IP`):

```bash
# Force delete the pod
kubectl delete pod rancher-server-0 -n rancher-k3k --grace-period=0 --force

# Check if it starts fresh
kubectl get pods -l cluster=rancher,role=server -n rancher-k3k -w
```

If server-0 still crashes after fresh restart, the PVC data may be corrupted:

```bash
# Delete the PVC and let StatefulSet recreate it (loses data)
kubectl delete pvc data-rancher-server-0 -n rancher-k3k

# Pod will restart with a clean PVC
kubectl get pods -l cluster=rancher,role=server -n rancher-k3k -w

# After recovery, restore from MinIO backup (Scenario D)
```

---

### Problem: Recovery stuck in scaling-up (pods not reaching Ready)

**Symptoms**: Recovery state = `scaling-up`, but some pods remain NotReady after 5+ minutes.

**Diagnosis**:

```bash
# Check cluster phase
kubectl get clusters.k3k.io rancher -n rancher-k3k -o jsonpath='{.status.phase}'

# Describe the stuck pod
kubectl describe pod rancher-server-1 -n rancher-k3k | tail -30
# Look for conditions like PvcNotBound, ImagePullBackOff, Pending
```

**Solutions**:

| Condition | Fix |
|-----------|-----|
| `PvcNotBound` | PVC provisioning failed — check storage class: `kubectl describe pvc data-rancher-server-1 -n rancher-k3k` |
| `ImagePullBackOff` | K3s image pull failed — check registry: `kubectl logs rancher-server-1 -n rancher-k3k \| grep -i image` |
| `Pending` | Pod waiting for resources — check node capacity: `kubectl describe nodes` |
| CSI error | Storage driver panic — wait 2-3 min for cloud controller to update nodes, then retry |

---

### Problem: Cluster reaches Ready but Rancher UI is slow or unresponsive

**Symptoms**: Cluster phase=Ready, pods Running, but `curl /ping` times out or returns errors.

**Diagnosis**:

```bash
# Check Rancher pod logs
kubectl get pods -n cattle-system -n k3k-rancher 2>/dev/null || echo "Use k3k kubeconfig"

# Check Rancher CPU/memory usage
kubectl top pods -n cattle-system --kubeconfig=<path-to-k3k-kubeconfig> 2>/dev/null

# Check etcd latency from inside k3k
kubectl exec rancher-server-0 -n rancher-k3k -- \
  sh -c 'ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cert=/var/lib/rancher/k3s/server/tls/etcd/server-client.crt \
    --key=/var/lib/rancher/k3s/server/tls/etcd/server-client.key \
    --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
    endpoint health'
```

**Solutions**:

- If etcd reports "unhealthy" — cluster may still be recovering. Wait 5-10 min and retry.
- If Rancher pod is OOMKilled — increase memory limit in k3k deployment config.
- If etcd latency is high — check disk I/O: `kubectl describe node <node>` for any IOBound conditions.

---

### Problem: Kubeconfig lost or Harvester context unavailable

**Symptoms**: `kubectl config current-context` returns error or wrong context.

**Solution**:

```bash
# Restore from backup
ls -ltr ~/.kube/config.bak.*
cp ~/.kube/config.bak.YYYYMMDD ~/.kube/config

# Verify context
kubectl config get-contexts
kubectl config use-context harvester

# Test access
kubectl get namespaces | grep rancher-k3k
```

---

### Problem: After recovery, Rancher upstream cluster is unreachable

**Symptoms**: Rancher UI shows "Error" next to the upstream cluster, or `kubectl get clusters --kubeconfig=<k3k>` shows ClusterUnavailable.

**Diagnosis**:

This is expected immediately after etcd recovery — the cluster registration tokens change. Downstream clusters need to be re-imported.

**Solution**:

1. Log into Rancher UI
2. Admin > Clusters
3. For each disconnected cluster, delete it and re-import:
   - Click cluster name > Delete
   - Rancher > Cluster Management > Import Existing
   - Follow the import instructions (typically a `kubectl apply` of a registration manifest)

This reconnects the cluster within 1-2 minutes.

---

### Problem: Pod logs show "unable to initialize network policy controller"

**Symptoms**: Pod CrashLoopBackOff with flannel/network policy errors.

**Solution** (described in ingress-watcher.yaml):

```bash
NS="rancher-k3k"
CLUSTER="rancher"

# Patch the cluster with --disable-network-policy
kubectl patch clusters.k3k.io "$CLUSTER" -n "$NS" --type=merge \
  -p '{"spec":{"serverArgs":["--disable-network-policy"]}}'

# Delete the problematic pod to reset backoff timer
kubectl delete pod rancher-server-0 -n "$NS" --grace-period=0

# Monitor recovery
kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" -w
```

The cluster will restart without network policies enabled. Re-enable them later when the issue is resolved.

---

## Known Issues

### Issue: BusyBox date -d cannot parse ISO 8601 timestamps

**Context**: The etcd auto-recovery script (ingress-watcher.yaml) uses `date -d` to parse timestamps. In BusyBox, this fails with ISO 8601 format (T separator, Z suffix).

**Status**: Fixed in current version. The `parse_epoch()` helper function handles both formats:

```bash
parse_epoch() { local ts="${1/T/ }"; date -d "${ts%Z}" +%s 2>/dev/null || echo "0"; }
```

This converts `2026-02-26T12:00:00Z` to `2026-02-26 12:00:00` before passing to `date -d`.

---

### Issue: k3k upstream issue #678 — etcd deadlock with simultaneous pod restarts

**Context**: When all k3k server pods restart simultaneously (e.g., after Harvester shutdown), their IPs change and etcd can't form quorum.

**Workaround**: The ingress-watcher implements automated detection and recovery. See **Scenario B** (Auto-Recovery) or **Scenario C** (Manual Recovery).

**Status**: Open in k3k upstream. This runbook includes all known workarounds.

---

## When to Escalate

Contact the platform team if:

- All recovery procedures above have been attempted and the cluster remains unrecoverable
- Multiple PVCs show I/O errors or storage corruption
- MinIO backup is unavailable or corrupted
- Rancher data must be recovered from backups older than 7 days
- The failure appears to be due to infrastructure issues (storage, network, hardware failure)

Gather this information for escalation:

```bash
# Collect diagnostic data
NS="rancher-k3k"
CLUSTER="rancher"

echo "=== Cluster CR ===" > /tmp/k3k-recovery-diag.txt
kubectl get clusters.k3k.io "$CLUSTER" -n "$NS" -o yaml >> /tmp/k3k-recovery-diag.txt

echo -e "\n=== Pod Status ===" >> /tmp/k3k-recovery-diag.txt
kubectl get pods -n "$NS" -o wide >> /tmp/k3k-recovery-diag.txt

echo -e "\n=== Pod Logs ===" >> /tmp/k3k-recovery-diag.txt
for POD in $(kubectl get pods -l "cluster=$CLUSTER,role=server" -n "$NS" \
    -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- $POD (current) ---" >> /tmp/k3k-recovery-diag.txt
  kubectl logs "$POD" -n "$NS" --tail=50 >> /tmp/k3k-recovery-diag.txt 2>&1

  echo "--- $POD (previous) ---" >> /tmp/k3k-recovery-diag.txt
  kubectl logs "$POD" -n "$NS" --previous --tail=50 >> /tmp/k3k-recovery-diag.txt 2>&1
done

echo -e "\n=== StatefulSet ===" >> /tmp/k3k-recovery-diag.txt
kubectl get statefulset -n "$NS" -o yaml >> /tmp/k3k-recovery-diag.txt

echo -e "\n=== PVCs ===" >> /tmp/k3k-recovery-diag.txt
kubectl get pvc -n "$NS" -o wide >> /tmp/k3k-recovery-diag.txt

echo "Diagnostic data saved to /tmp/k3k-recovery-diag.txt"
```

Share the diagnostic file with the platform team.

---

## Related Documentation

- [Etcd Quorum Recovery](etcd-quorum-recovery.md) — Detailed technical explanation of the deadlock mechanism
- [Certificate Recovery](../certificate-change-recovery.md) — If TLS certificates need to be updated
- [Universal Backup and Restore](../universal-backup-restore.md) — Full backup/restore including Rancher data
- [Backup and Restore](../backup-restore.md) — Metadata-only backup for PVC resize workflows
