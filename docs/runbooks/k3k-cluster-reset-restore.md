# Runbook: k3k vCluster Disaster Recovery via cluster-reset-restore

## Scope

Recovers a k3k vCluster from a local etcd snapshot when the cluster is in a
state that **cannot be repaired by simpler procedures** in
[`k3k-rancher-recovery.md`](k3k-rancher-recovery.md). Specifically: when
etcd quorum cannot be restored, when the cluster's only surviving server
PVC has been destroyed, or when leader-election storms make the apiserver
unreachable indefinitely.

**This is a destructive recovery** — it commits to a snapshot's state and
discards any divergence on other server PVCs. Use only when the simpler
recovery scenarios (A–C in `k3k-rancher-recovery.md`) have failed and the
cluster cannot self-recover.

This runbook was written from the **2026-05-03 incident** (Harvester
1.7.1 → 1.8.0 upgrade triggered cascading quorum loss → all 5 server PVCs
ultimately destroyed → recovered from local snapshot pulled defensively
during the incident). See [Lessons learned](#lessons-learned) at the end.

## When to use this runbook

All of the following must be true:

- [ ] k3k cluster has been unreachable for >30 min and is not progressing
- [ ] Scenario C of `k3k-rancher-recovery.md` (spec-patch method) failed or
      cannot apply (e.g., spec.servers cannot be patched to 1 because the
      controller refuses, or scale-down doesn't restore quorum)
- [ ] Scenario D's MinIO restore is unavailable (rancher-backup CRs require
      a working apiserver to query)
- [ ] You have a **verified, recent local etcd snapshot** on a host you
      control (this VM, in `backups/etcd-snapshots-rescue-*/`)
- [ ] You accept losing the gap between snapshot time and now

## Prerequisites

| Item | Required | How to get it |
| ---- | -------- | ------------- |
| `kubectl` configured for `harvester` / `hvst-local` context | yes | already on this VM |
| Local etcd snapshot file (e.g. `etcd-snapshot-k3k-rancher-server-0-XXXXXX`) | yes | `backups/etcd-snapshots-rescue-*/`, sha256-checksummed |
| Saved TLS bundle (`server-tls.tar.gz`) | recommended | same dir as snapshot |
| Saved kubeconfig (`backups/post-rancher-*/kubeconfig-k3k.yaml`) | recommended | for post-recovery verification |
| Cluster admin access to the host RKE2 / Harvester cluster | yes | same as kubectl |
| ~30–60 min of downtime budget | yes | recovery takes that long under load |

## Why simpler procedures fail (and this is needed)

The k3k controller manages a StatefulSet whose pods run k3s server. Each
pod uses the `etcdpod.k3k.io/finalizer` to ensure clean removal from etcd
membership when deleted. **The finalizer requires etcd quorum to clear.**

In a quorum-loss scenario:

1. Pods cannot be cleanly deleted (finalizer hangs)
2. Force-deleting + stripping the finalizer leaves orphan etcd member
   entries
3. Newly recreated pods join etcd, see the orphan members, try to elect
   leader, fail because orphans don't respond
4. **Etcd enters a leader-election storm** — TLS handshakes time out
   because etcd is too busy with raft activity to accept new connections
5. Apiserver returns `503 apiserver not ready` because it can't reach
   etcd
6. Watcher's `check_quorum_loss` cannot help — the underlying issue is
   etcd membership corruption, not just dead pods

The only escape: **reset etcd cluster membership to single-member**, which
requires `k3s server --cluster-reset`. To preserve data, pair it with
`--cluster-reset-restore-path=<snapshot>`.

The k3k pod's entrypoint script (in `rancher/k3s` image) **already
auto-invokes** `k3s server --cluster-reset` when it detects existing
etcd data on a single-server (`spec.servers=1`) cluster. We just need
to tell it which snapshot to restore from — done via the
`k3k-rancher-init-server-config` Secret.

## High-level flow

```text
 1. Verify snapshot integrity (sha256)
 2. Scale spec.servers=1 in cluster CR (smallest the CR allows)
 3. Briefly scale k3k controller to 1 so it regenerates the StatefulSet
    pod template with single-mode entrypoint (case "single", not "ha")
 4. Scale k3k controller back to 0 (so it stops reverting your edits)
 5. Patch StatefulSet replicas=1 directly (k3k controller scaled down,
    can't sync this from cluster CR spec.servers)
 6. Force-clean current server-0 pod (strip etcdpod.k3k.io/finalizer
    + force delete)
 7. Save the now-correct (single-mode) StatefulSet for restore later:
    `kubectl get sts ... -o yaml > /tmp/dr-recovery/sts-single-mode.yaml`
 8. Swap StatefulSet container to alpine sleep (stable pod for cp)
 9. Force-delete current pod, alpine pod takes over with PVC mounted
10. Wipe the PVC clean (rm -rf /var/lib/rancher/k3s/*)
11. Pre-create /var/lib/rancher/k3s/server/db/{etcd,snapshots}/
    - etcd/ must exist with marker file (entrypoint check)
    - snapshots/ holds the snapshot file
12. kubectl cp the snapshot into the snapshots dir
13. Patch init-server-config Secret to add cluster-reset-restore-path
14. kubectl replace --force the saved single-mode StatefulSet
    (restores k3s image with the CORRECT entrypoint case)
15. Force-delete alpine pod, k3s pod takes over with seeded PVC
16. Entrypoint detects existing data → runs k3s --cluster-reset
17. K3s reads config → finds restore-path → restores from snapshot
18. ⚠ IMMEDIATELY patch init-server-config Secret to remove
    cluster-reset-restore-path (use kubectl patch --type=merge with
    the original config; do NOT use kubectl apply, which fails on
    resourceVersion drift)
19. Force-delete pod to pick up clean Secret on next start
20. Wait for apiserver to return HTTP 401 (alive, just unauthenticated)
21. Delete stale PVCs for server-1..N (they have pre-incident data
    that will conflict on join)
22. Scale k3k controller back to 1
23. Scale spec.servers back to original count
24. Wait for new server-1, server-2 to join as fresh members
25. Clean up vCluster's stale node records (server-3, server-4, etc.
    from snapshot era) so Rancher pods can reschedule off them
26. Force-delete orphan Rancher pods pinned to those phantom nodes
27. Clear recovery annotations
28. Verify Rancher reachable (HTTP 200)
```

## Step-by-step procedure

All commands assume `KUBECONFIG` resolves to the **host** Harvester
cluster (`harvester` or `hvst-local` context).

### Step 0: Pre-flight

```bash
NS=rancher-k3k
CLUSTER=rancher
STS=k3k-${CLUSTER}-server          # StatefulSet name
POD0=k3k-${CLUSTER}-server-0        # ordinal-0 pod name
INIT_SECRET=k3k-${CLUSTER}-init-server-config
SNAPDIR=backups/etcd-snapshots-rescue-$(date +%Y%m%d)-NEEDS-PATH-FILL-IN
SNAP_FILE=etcd-snapshot-k3k-rancher-server-0-NEEDS-EPOCH-FILL-IN

# Save the original spec.servers so we know what to scale back to
ORIG_SERVERS=$(kubectl get cluster.k3k.io -n "$NS" "$CLUSTER" \
    -o jsonpath='{.spec.servers}')
echo "Original spec.servers=$ORIG_SERVERS"

# 1. Verify snapshot exists and checksum matches
ls -lh "${SNAPDIR}/${SNAP_FILE}"
sha256sum "${SNAPDIR}/${SNAP_FILE}"
# Should match MANIFEST.txt in same directory

# 2. Confirm cluster is actually unrecoverable
kubectl get pods -n "$NS" -l "cluster=${CLUSTER},role=server" -o wide
# Expect: pods crashlooping, apiserver returning 503, no quorum
curl -sk -o /dev/null -w "HTTP %{http_code}\n" --max-time 10 \
    "https://k3k.hvst-vip.example.com/healthz"
# Expect: 503 "apiserver not ready"

# 3. Backup originals you'll modify
mkdir -p /tmp/dr-recovery
kubectl get secret -n "$NS" "$INIT_SECRET" -o yaml \
    > /tmp/dr-recovery/init-secret-original.yaml
kubectl get sts -n "$NS" "$STS" -o yaml \
    > /tmp/dr-recovery/sts-pre-recovery.yaml
kubectl get cluster.k3k.io -n "$NS" "$CLUSTER" -o yaml \
    > /tmp/dr-recovery/cluster-cr-original.yaml
ls -la /tmp/dr-recovery/
```

### Step 1: Scale spec.servers to 1

```bash
kubectl patch cluster.k3k.io -n "$NS" "$CLUSTER" --type=merge \
    -p '{"spec":{"servers":1}}'
```

> **Note:** The cluster CR validates `spec.servers >= 1`. You **cannot**
> scale to 0 via the cluster CR. The minimum cluster size is 1.

### Step 2: Let k3k controller regenerate the StatefulSet for single mode

This is **the most important fix learned from the second run-through**. The
k3s entrypoint script in the StatefulSet's pod template has a HARDCODED
`case "ha"` (when `spec.servers > 1`) or `case "single"` (when
`spec.servers == 1`) baked in by the k3k controller at template-generation
time. If you saved the StatefulSet during HA mode and try to restore it
later in single mode, the entrypoint runs `start_ha_node()` and tries to
join via the cluster Service IP — which fails because the cluster doesn't
exist yet.

**Fix:** make sure k3k controller runs *while spec.servers=1* so it
generates the StatefulSet with `case "single"` in the entrypoint.

```bash
# Make sure k3k controller is running (not scaled down)
kubectl scale -n k3k-system deploy/k3k --replicas=1
until [ "$(kubectl get pods -n k3k-system -l app=k3k --no-headers \
            2>/dev/null | grep -c Running)" = "1" ]; do
    sleep 3
done

# Wait briefly for it to reconcile the StatefulSet template
sleep 10

# Now save THIS version of the StatefulSet — it has case "single" baked in
kubectl get sts -n "$NS" "$STS" -o yaml \
    > /tmp/dr-recovery/sts-single-mode.yaml

# Verify the entrypoint script ends with case "single"
grep -o 'case "[a-z]*" in' /tmp/dr-recovery/sts-single-mode.yaml | head -1
# Expect:  case "single" in   (NOT  case "ha" in)
```

### Step 3: Scale k3k controller to 0

Now that we have the correct (single-mode) StatefulSet saved, scale the
controller down so it stops reverting our subsequent edits.

```bash
kubectl scale -n k3k-system deploy/k3k --replicas=0
until [ -z "$(kubectl get pods -n k3k-system -l app=k3k --no-headers 2>/dev/null)" ]; do
    sleep 2
done
```

### Step 4: Patch StatefulSet replicas=1 directly

While k3k controller is scaled down, the StatefulSet's `spec.replicas`
won't be synced from the cluster CR's `spec.servers`. Patch directly:

```bash
kubectl patch sts -n "$NS" "$STS" --type=merge \
    -p '{"spec":{"replicas":1}}'
```

### Step 5: Force-clean any stuck server pods

```bash
for P in $(kubectl get pods -n "$NS" -l "cluster=${CLUSTER},role=server" \
        -o jsonpath='{.items[*].metadata.name}'); do
    # Strip etcdpod.k3k.io/finalizer (it can't clear without quorum)
    kubectl patch pod -n "$NS" "$P" --type=merge \
        -p '{"metadata":{"finalizers":null}}' || true
    kubectl delete pod -n "$NS" "$P" --force --grace-period=0 || true
done
```

### Step 6: Swap StatefulSet container to alpine sleep

We need a STABLE pod with the PVC mounted so we can `kubectl cp` the
snapshot in. The k3s pod crashloops too fast for cp to complete (3-second
windows for a 22 MB transfer = guaranteed to fail).

```bash
kubectl patch sts -n "$NS" "$STS" --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/image","value":"alpine:3.20"},
  {"op":"replace","path":"/spec/template/spec/containers/0/command","value":["sh","-c","sleep 3600"]},
  {"op":"remove","path":"/spec/template/spec/containers/0/livenessProbe"},
  {"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"}
]'

# Force-delete the current pod so the new alpine pod takes over
kubectl patch pod -n "$NS" "$POD0" --type=merge \
    -p '{"metadata":{"finalizers":null}}' || true
kubectl delete pod -n "$NS" "$POD0" --force --grace-period=0

# Wait for alpine pod
until kubectl get pod -n "$NS" "$POD0" \
        -o jsonpath='{.status.phase}/{.spec.containers[0].image}' 2>/dev/null \
        | grep -q "Running/alpine"; do
    sleep 3
done
echo "Alpine pod up"
```

### Step 7: Wipe PVC and seed snapshot

```bash
# 1. Wipe any leftover data from prior failed cluster-reset attempts
kubectl exec -n "$NS" "$POD0" -- sh -c \
    'rm -rf /var/lib/rancher/k3s/*'

# 2. Pre-create the directories the entrypoint expects
kubectl exec -n "$NS" "$POD0" -- sh -c \
    'mkdir -p /var/lib/rancher/k3s/server/db/etcd /var/lib/rancher/k3s/server/db/snapshots'

# 3. Place a marker so the entrypoint's "existing data" check fires
kubectl exec -n "$NS" "$POD0" -- sh -c \
    'touch /var/lib/rancher/k3s/server/db/etcd/.dr-placeholder'

# 4. Copy the snapshot in (alpine pod doesn't crash, cp can take its time)
kubectl cp -n "$NS" "${SNAPDIR}/${SNAP_FILE}" \
    "${POD0}:/var/lib/rancher/k3s/server/db/snapshots/${SNAP_FILE}"

# 5. Verify checksum
kubectl exec -n "$NS" "$POD0" -- \
    sha256sum "/var/lib/rancher/k3s/server/db/snapshots/${SNAP_FILE}"
sha256sum "${SNAPDIR}/${SNAP_FILE}"
# These two MUST match
```

### Step 8: Patch init-server-config Secret with restore-path

Add `cluster-reset-restore-path` so the entrypoint's auto-invoked
`k3s server --cluster-reset` will also restore from the snapshot.

**Save the cleaned config NOW for use in Step 11** (before adding the
restore-path). The Step-11 revert path needs this exact content.

```bash
# Pull current init config and save as the "clean" version (no restore-path)
kubectl get secret -n "$NS" "$INIT_SECRET" \
    -o jsonpath='{.data.config\.yaml}' | base64 -d \
    | grep -v '^cluster-reset-restore-path:' \
    > /tmp/dr-recovery/init-config-clean.yaml

# Build the "with-restore-path" version
cp /tmp/dr-recovery/init-config-clean.yaml \
    /tmp/dr-recovery/init-config-with-restore.yaml
echo "cluster-reset-restore-path: /var/lib/rancher/k3s/server/db/snapshots/${SNAP_FILE}" \
    >> /tmp/dr-recovery/init-config-with-restore.yaml

# Patch the Secret with restore-path version
B64=$(base64 -w0 /tmp/dr-recovery/init-config-with-restore.yaml)
kubectl patch secret -n "$NS" "$INIT_SECRET" --type=merge \
    -p "{\"data\":{\"config.yaml\":\"${B64}\"}}"

# Verify it stuck
kubectl get secret -n "$NS" "$INIT_SECRET" -o jsonpath='{.data.config\.yaml}' \
    | base64 -d | tail -2
# Last line should be: cluster-reset-restore-path: ...
```

### Step 9: Force-replace StatefulSet with single-mode version

Restore the saved single-mode StatefulSet. **Do NOT use the
`sts-pre-recovery.yaml` file** (which captured the HA-mode template) —
use `sts-single-mode.yaml` from Step 2.

```bash
kubectl replace --force -f /tmp/dr-recovery/sts-single-mode.yaml

# The alpine pod will be terminated and replaced with a k3s pod
until kubectl get pod -n "$NS" "$POD0" \
        -o jsonpath='{.status.phase}/{.spec.containers[0].image}' 2>/dev/null \
        | grep -q "Running/rancher/k3s"; do
    sleep 3
done
echo "k3s pod up"
```

### Step 10: Watch the restore happen

The entrypoint output is suppressed (`> /dev/null 2>&1`), but you can
watch the bbolt-restore signature in pod logs:

```bash
kubectl logs -n "$NS" "$POD0" -f &
LOG_PID=$!

# Look for these key messages indicating success:
#   "Starting single node setup..."             ← MUST be "single", not "HA"
#   "Existing data found in single node setup. Performing cluster-reset..."
#   "Reconciling bootstrap data between datastore and disk"
#   "Opening etcd MVCC KV backend database at ..."
#   "kvstore restored, current-rev: <number>"   ← restored revision!
#   "Successfully reconciled with local datastore"
#   "Sending HTTP/2.0 503 response ... starting"  ← apiserver booting

# Once you see "kvstore restored, current-rev:" → restore committed.
# Kill the tail and proceed to Step 11 ASAP.
kill $LOG_PID 2>/dev/null
```

### Step 11: ⚠ CRITICAL — Remove cluster-reset-restore-path from Secret

The entrypoint runs `k3s server --cluster-reset` first (with restore),
then runs `k3s server` normally. The normal-start k3s invocation sees
`cluster-reset-restore-path` in config but no `--cluster-reset` CLI flag
and **fatals** with:

```text
Error: invalid flag use; --cluster-reset required with --cluster-reset-restore-path
```

This causes a crash loop until you remove the restore-path. **Use
`kubectl patch --type=merge`** — `kubectl apply -f init-secret-original.yaml`
fails with a resourceVersion drift error after we patched it in Step 8.

```bash
# Patch back to the clean version (the one we saved in Step 8)
B64=$(base64 -w0 /tmp/dr-recovery/init-config-clean.yaml)
kubectl patch secret -n "$NS" "$INIT_SECRET" --type=merge \
    -p "{\"data\":{\"config.yaml\":\"${B64}\"}}"

# Verify (should NOT contain restore-path)
kubectl get secret -n "$NS" "$INIT_SECRET" -o jsonpath='{.data.config\.yaml}' \
    | base64 -d | tail -3
```

### Step 12: Force pod restart to pick up clean Secret

The Secret update propagates to mounted volumes within ~60s. Force a
restart so the next entrypoint invocation reads the cleaned config:

```bash
# Strip finalizer too, in case the previous restore-cycle left one set
kubectl patch pod -n "$NS" "$POD0" --type=merge \
    -p '{"metadata":{"finalizers":null}}' || true
kubectl delete pod -n "$NS" "$POD0" --force --grace-period=0
```

The new pod will:

1. Mount the (now-restored) PVC
2. Run entrypoint, detect existing data
3. Run `k3s server --cluster-reset` (no restore-path now → just normal reset)
4. Continue to safe_mode + start k3s server normally
5. Apiserver comes up serving the restored data

### Step 13: Verify apiserver is alive

```bash
# Tight inline poll (apiserver init can take 60-120s after cluster-reset)
for i in $(seq 1 30); do
    HTTP=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 3 \
        "https://k3k.hvst-vip.example.com/healthz" 2>/dev/null)
    READY=$(kubectl get pod -n "$NS" "$POD0" \
        -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
    echo "[$i] http=$HTTP pod_ready=$READY"
    [ "$HTTP" = "401" ] || [ "$HTTP" = "200" ] && { echo "APISERVER UP"; break; }
    sleep 5
done

# Verify restored data via local kubectl in pod
kubectl exec -n "$NS" "$POD0" -- sh -c '
KUBECONFIG=/var/lib/rancher/k3s/server/cred/admin.kubeconfig kubectl \
    --insecure-skip-tls-verify --server=https://127.0.0.1:6444 get nodes
KUBECONFIG=/var/lib/rancher/k3s/server/cred/admin.kubeconfig kubectl \
    --insecure-skip-tls-verify --server=https://127.0.0.1:6444 get helmcharts -A | head -5
KUBECONFIG=/var/lib/rancher/k3s/server/cred/admin.kubeconfig kubectl \
    --insecure-skip-tls-verify --server=https://127.0.0.1:6444 get pods -n cattle-system
'
# Expect: nodes (including phantoms from snapshot), namespaces, Rancher Helm
# chart, cert-manager — all from snapshot.  We'll clean phantom nodes in
# Step 18 below.
```

### Step 14: Delete stale PVCs for server-1..N

The other server PVCs (if they exist) have stale etcd data from before the
incident. When new server-1 and server-2 pods come up, they'll fail to
join if they mount that stale data.

```bash
for N in 1 2 3 4; do
    kubectl delete pvc -n "$NS" "varlibrancherk3s-k3k-${CLUSTER}-server-${N}" \
        --grace-period=0 --wait=false --ignore-not-found
done
```

### Step 15: Restore k3k controller and scale back up

```bash
kubectl scale -n k3k-system deploy/k3k --replicas=1

# Scale spec.servers back to the original count (saved in Step 0)
kubectl patch cluster.k3k.io -n "$NS" "$CLUSTER" --type=merge \
    -p "{\"spec\":{\"servers\":${ORIG_SERVERS}}}"
```

The k3k controller will create new server-1 and server-2 pods with
**fresh PVCs**. They'll join the restored cluster as new etcd members.

> **Heads up:** the k3k controller may also recreate `server-0` once it
> reconciles (because the StatefulSet template now has the HA-mode
> entrypoint baked in for `spec.servers > 1`). The new server-0 will
> mount the same restored PVC and come back up — just expect one extra
> restart on `server-0`.

### Step 16: Watch new servers join

```bash
# Wait for all servers Ready
until [ "$(kubectl get pods -n "$NS" -l "cluster=${CLUSTER},role=server" \
            -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==true)]}x{end}' \
            | wc -c)" -ge "$ORIG_SERVERS" ]; do
    kubectl get pods -n "$NS" -l "cluster=${CLUSTER},role=server" --no-headers
    sleep 15
done
echo "All ${ORIG_SERVERS} servers Ready"
```

> **Note:** new servers may briefly hit the safe_mode wedge (k3k#836) on
> their first start. The watcher's `check_safe_mode_wedge` scenario will
> auto-recover (`rm /var/lib/rancher/k3s/k3k-node-ip` + delete pod). If
> the watcher is also broken, apply the fix manually per
> `k3k-server-pod-safe-mode-wedge.md`.

### Step 17: Clean up phantom node records and orphan Rancher pods

The restored snapshot has node and pod records from when the cluster ran
more servers than it does now (e.g., we restored from a 5-server snapshot
into a 3-server cluster). The phantom node records have `Status: NotReady`
because no kubelet is reporting for them. Pods scheduled on those phantoms
in the snapshot will be **stuck in Running/Pending forever** with
`Pod-level Ready=False` because:

- Their node has no kubelet posting status updates
- The vCluster's kube-controller-manager won't reconcile pod conditions
  for orphaned-node pods
- This blocks Rancher's Service from getting any Ready endpoints → HTTP
  502/503 forever

```bash
# 1. List vCluster nodes (should match current host pod count)
kubectl exec -n "$NS" "$POD0" -- sh -c '
KC=/var/lib/rancher/k3s/server/cred/admin.kubeconfig
KUBECONFIG=$KC kubectl --insecure-skip-tls-verify get nodes
'

# 2. Delete each NotReady node (the phantom ones from snapshot)
#    e.g. if you scaled down from 5 -> 3, delete server-3 and server-4:
kubectl exec -n "$NS" "$POD0" -- sh -c "
KC=/var/lib/rancher/k3s/server/cred/admin.kubeconfig
KUBECONFIG=\$KC kubectl --insecure-skip-tls-verify delete node \
    k3k-${CLUSTER}-server-3 k3k-${CLUSTER}-server-4 --ignore-not-found
"

# 3. Force-delete any Rancher pods pinned to those phantom nodes
#    (find them, then force-delete)
kubectl exec -n "$NS" "$POD0" -- sh -c "
KC=/var/lib/rancher/k3s/server/cred/admin.kubeconfig
for P in \$(KUBECONFIG=\$KC kubectl --insecure-skip-tls-verify get pods \
        -n cattle-system -l app=rancher \
        -o jsonpath='{range .items[?(@.spec.nodeName==\"k3k-${CLUSTER}-server-3\")]}{.metadata.name} {end}{range .items[?(@.spec.nodeName==\"k3k-${CLUSTER}-server-4\")]}{.metadata.name} {end}'); do
    echo \"force-delete orphan pod \$P\"
    KUBECONFIG=\$KC kubectl --insecure-skip-tls-verify delete pod \
        -n cattle-system \"\$P\" --force --grace-period=0
done
"

# 4. Trigger a Rancher rollout restart to pull fresh pods on real nodes
kubectl exec -n "$NS" "$POD0" -- sh -c '
KC=/var/lib/rancher/k3s/server/cred/admin.kubeconfig
KUBECONFIG=$KC kubectl --insecure-skip-tls-verify rollout restart \
    deploy -n cattle-system rancher
'
```

### Step 18: Clear recovery annotations

```bash
kubectl annotate cluster.k3k.io -n "$NS" "$CLUSTER" \
    k3k.io/etcd-recovery-state- \
    k3k.io/etcd-original-servers- \
    k3k.io/etcd-recovery-started- \
    --overwrite=false 2>/dev/null || true
```

### Step 19: Verify Rancher

```bash
curl -sk -o /dev/null -w "HTTP %{http_code}  total %{time_total}s\n" --max-time 10 \
    "https://rancher.example.com/healthz"
# Expect: HTTP 200

curl -sk -o /dev/null -w "HTTP %{http_code}\n" --max-time 10 \
    "https://rancher.example.com/"
# Expect: HTTP 200 (login page)
```

Rancher pods inside the vCluster may take 2–5 min to become Ready after
the apiserver starts serving (they wait for kube-apiserver, then for
their leader-election leases). Be patient before declaring failure.

## Verification checklist

After recovery completes:

- [ ] All `spec.servers` server pods Ready (e.g., 3/3)
- [ ] Cluster CR `phase: Ready`
- [ ] No recovery annotations on cluster CR
- [ ] HTTP 200 on `https://rancher.<domain>/healthz`
- [ ] HTTP 200 on `https://rancher.<domain>/`
- [ ] `kubectl --context k3k-rancher get nodes` returns expected nodes
- [ ] `kubectl --context k3k-rancher get clusters.management.cattle.io`
      shows downstream clusters (Harvester, RKE2)
- [ ] Downstream cluster agents reconnect within 5 min (cattle-cluster-agent
      pods Ready in each downstream)
- [ ] Cert-manager Issuers reconcile (no stuck CertificateRequests)

## Lessons learned

### Run 1 (2026-05-03 ~17:35 UTC) — initial incident

**What went right:**

1. **Pre-incident snapshot pull saved the cluster.** At 17:42 UTC we
   defensively copied all 5 etcd snapshots from server-0 to this VM
   *before* anything destructive. The PVC was destroyed 50 min later;
   the local copy was the only path to recovery.
2. **Multiple safety layers worked.** PV reclaim policy was patched to
   Retain; CSI VolumeSnapshot was created. Neither was actually used
   (the file copy was), but they were cheap insurance.
3. **The watcher detected the quorum loss correctly** — it just couldn't
   act fast enough due to apiserver latency under load (each kubectl
   call inside the watcher took 29s).

**What went wrong:**

1. **Etcd member-removal during scale-down didn't actually happen.** We
   scaled spec.servers from 5 to 3, the StatefulSet pods were deleted,
   but the **etcd member entries for the deleted pods were never
   removed** (k3k controller didn't trigger the etcdctl member remove).
   This left orphan members that caused the quorum-loss storm.
2. **Cluster CR rejected `spec.servers=0`.** We needed to scale to 0 to
   safely re-seed the PVC; CR validation forced minimum of 1, which
   complicated the recovery.
3. **k3k entrypoint's auto-invoked cluster-reset doesn't accept config
   override at runtime.** The restore-path had to be in the Secret
   *before* the pod started, and *removed* before the next start to
   avoid the "--cluster-reset required" FATAL.
4. **kubectl cp into a CrashLoopBackOff pod failed reliably.** 3-second
   Running windows are too short for a 22 MB transfer. The
   image-swap-to-alpine pattern was needed.
5. **PVC reclaim policy `Retain` doesn't fully protect Longhorn data.**
   The PV was Retain, but the underlying Longhorn volume was deleted
   anyway during a reconcile cascade. **Local file copies are the only
   100%-safe backup.**

### Run 2 (2026-05-03 ~22:46 UTC) — post-restart safe-mode wedge

User stopped all 3 k3k server pods cleanly; on restart, all 3 entered
the safe-mode IP-patch wedge (k3k#836) simultaneously because each pod's
new IP differed from its persisted `k3k-node-ip` file. None could
complete safe_mode (each waiting for another to confirm via Node list)
→ no etcd quorum ever formed.

Recovery used this runbook again. **Three new bugs in v1 of this runbook
were uncovered and fixed in v2 (the version you're reading now):**

1. **STS-restore Step (old Step 7) used the wrong saved StatefulSet.**
   The original v1 saved the STS *before* the recovery began, while
   `spec.servers` was still > 1, so the saved template had the entrypoint
   `case "ha"` baked in. Restoring that into a single-server recovery
   ran `start_ha_node()` which tried to join via Service IP and failed
   with `failed to validate token: failed to get CA certs: connection
   refused`. **Fix:** new Step 2 brings k3k controller back briefly
   *while spec.servers=1* so it regenerates the STS with `case "single"`,
   then save THAT version for use in Step 9.
2. **StatefulSet `spec.replicas` doesn't sync from cluster CR's
   `spec.servers`** while the k3k controller is scaled down. The runbook
   was relying on the controller to do it. **Fix:** new Step 4 patches
   `spec.replicas=1` directly.
3. **Step 9's `kubectl apply -f init-secret-original.yaml` failed**
   with a resourceVersion drift error because we patched the secret in
   Step 8. **Fix:** Step 11 now uses `kubectl patch --type=merge` with
   the cleaned config (which was saved in Step 8 before adding the
   restore-path, so it survives the resourceVersion drift).

Also discovered in run 2:

1. **Phantom node records cause Pod-level `Ready=False` indefinitely.**
   The restored snapshot had nodes for server-3, server-4 (from a
   pre-scale-down moment). Rancher pods scheduled on those phantom nodes
   had their containers running but Pod Ready stuck at False because no
   kubelet was reporting for those nodes. EndpointSlice empty → 502/503
   from host nginx. **Fix:** new Step 17 deletes phantom nodes and
   force-deletes pods pinned to them, then triggers a Rancher rollout
   restart.

### Watcher gaps still open

1. **Apiserver-503 detection.** The watcher's existing scenarios trigger
   on pod-level signals (CrashLoopBackOff, Failed) but don't catch
   "all pods Ready, apiserver returns 503 indefinitely." This was the
   actual symptom of the orphan-etcd-member quorum storm.
2. **Cluster-reset triggering.** No watcher scenario triggers
   cluster-reset when other recovery paths fail. The recovery in this
   runbook is fully manual.
3. **Apiserver-call retry on `ServiceUnavailable`.** Slow apiserver
   returns intermittent `ServiceUnavailable` errors that cause watcher
   PVC lookups to fail with "not found", short-circuiting recovery
   actions. Add retry-with-backoff on apiserver errors.
4. **Phantom-node cleanup.** No watcher scenario detects
   `NotReady kubelet-stale` nodes after a snapshot restore and prunes
   them. Currently a manual Step 17.
5. **Multi-pod safe-mode wedge race.** When ALL servers boot into
   safe_mode simultaneously (e.g., after a clean cluster shutdown), none
   can complete safe_mode (the check requires another server to register
   the IP via the Node list). The watcher's `check_safe_mode_wedge`
   handles individual pods after FATAL, but waiting for all 3 to FATAL
   serially adds 6+ minutes. Consider a "primary-promotion" scenario:
   if N pods are all safe-mode-stuck and none has Ready, deterministically
   pick server-0 to bypass safe_mode (rm node-ip file early).

### Procedural changes adopted after this incident

- **Pre-Harvester-upgrade snapshot pull is now required**, formalized as
  the first step in `harvester-upgrade-checklist.md`.
- **Two new watcher scenarios were added** (in the same session):
  `check_quorum_loss` (with finalizer-strip) and `check_safe_mode_wedge`.
- **Rebalance guard math fixed**: `ceil(N/M)` instead of
  `< server_count`, so 5-on-3-node topologies actually rebalance.
- **PV reclaim policy `Retain` is documented as best-effort**, not a
  guarantee against Longhorn-side deletion.
- **This runbook is v2** — incorporates run-2 fixes (STS-restore via
  k3k-controller-regenerated single-mode template, direct STS replicas
  patch, kubectl-patch-not-apply for revert, phantom-node cleanup).

## Recovery artifacts retained

After this runbook completes, keep:

- `/tmp/dr-recovery/` — original Secret/StatefulSet/Cluster CR for
  rollback or post-mortem
- `backups/etcd-snapshots-rescue-*/` — the snapshot bundle that saved
  the cluster
- The active container's `/var/log/k3s.log` (capture before any restart)
- `kubectl get events -A --sort-by=.lastTimestamp > events-during-dr.txt`

Once cluster is verified healthy and stable for 24h, you may archive or
delete `/tmp/dr-recovery/`. The snapshot bundle in `backups/` should be
retained until at least the next scheduled snapshot is verified.

## See also

- [`k3k-rancher-recovery.md`](k3k-rancher-recovery.md) — try Scenarios A–C
  first; this runbook is Scenario D's local-snapshot variant
- [`k3k-server-pod-safe-mode-wedge.md`](k3k-server-pod-safe-mode-wedge.md)
  — single-pod IP-patch wedge (k3k#836); may fire on new server pods
  during this recovery
- [`harvester-upgrade-checklist.md`](harvester-upgrade-checklist.md) —
  pre-flight that should prevent needing this runbook in the first place
- [`k3k-vcluster-k8s-upgrade.md`](k3k-vcluster-k8s-upgrade.md) —
  vCluster k8s version upgrades (separate concern)
- Upstream: [k3k#522](https://github.com/rancher/k3k/issues/522) (server
  affinity), [k3k#678](https://github.com/rancher/k3k/issues/678) (etcd
  deadlock), [k3k#836](https://github.com/rancher/k3k/issues/836)
  (safe-mode wedge)
