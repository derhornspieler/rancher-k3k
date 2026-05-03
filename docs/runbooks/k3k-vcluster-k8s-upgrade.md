# SOP: Upgrade Kubernetes Version on the Rancher k3k vCluster

## Purpose

Upgrade the Kubernetes version running inside the **rancher k3k vCluster**
(where Rancher itself runs). This is independent of the Harvester host
cluster — only the k3k server StatefulSet rolls.

For the failure mode that motivates this runbook (cordoned nodes, stuck
upgrade plan), see [`k3k-stuck-k8s-upgrade.md`](k3k-stuck-k8s-upgrade.md).

## What this is NOT

| Operation | Where |
|-----------|-------|
| Upgrading Harvester host's K8s | Harvester upgrade procedure |
| Upgrading the k3k operator/chart | `helm upgrade k3k …` (separate runbook) |
| Upgrading downstream cluster K8s (RKE2/Harvester guest clusters) | Rancher UI is correct for those — they have real systemd-managed nodes |

This runbook only covers the k3s version inside the **rancher vCluster**.

## Why we cannot use the Rancher UI / system-upgrade-controller

The UI's "Kubernetes Version" upgrade creates a `Plan` CR for
**system-upgrade-controller (SUC)**. SUC runs `rancher/k3s-upgrade`, which:

1. Cordons the node
2. Mounts the host filesystem
3. Replaces `/usr/local/bin/k3s` (binary on disk)
4. Restarts `k3s.service` via systemd

**This assumes k3s is installed as a systemd service on a real node.** In a
k3k vCluster, k3s is the entrypoint of a `rancher/k3s:vX.Y.Z-k3s1` container
running as a Pod. There is no `/usr/local/bin/k3s` to swap and no systemd to
restart. SUC's job hits `DeadlineExceeded`, leaves the node
`SchedulingDisabled`, and quorum starts to wobble.

**The correct lever is `Cluster.spec.version` on the k3k Cluster CR.** The
k3k controller uses that value to template the StatefulSet's container image.
Patching it triggers a normal rolling update of the StatefulSet pods — new
pods come up running the new k3s image, old pods terminate, PDB enforces
quorum throughout.

## Prerequisites

1. PDB is in place and healthy:

   ```bash
   kubectl --context=harvester -n rancher-k3k get pdb k3k-rancher-server
   # ALLOWED DISRUPTIONS: 1, MIN AVAILABLE: 2
   ```

2. All 3 server pods Ready, distributed across distinct Harvester nodes:

   ```bash
   kubectl --context=harvester -n rancher-k3k get pods -l role=server -o wide
   ```

3. Recent backup (<24h) of the rancher vCluster state (Step 7 backup pipeline):

   ```bash
   kubectl --context=k3k-rancher get backups.resources.cattle.io \
     -A --sort-by=.metadata.creationTimestamp | tail -3
   ```

4. Target k3s image tag exists. K3s tags use **dash-k3s1** in the image
   registry (`v1.34.7-k3s1`), not the upstream plus-form (`v1.34.7+k3s1`):

   ```bash
   skopeo inspect docker://rancher/k3s:v1.34.7-k3s1 | jq .Digest
   # or via Harbor pull-through:
   skopeo inspect docker://harbor.example.com/dockerhub/rancher/k3s:v1.34.7-k3s1
   ```

5. The new k3s minor version is supported by:
   - The **k3k controller** version we run (k3k v1.0.2 supports K8s 1.31–1.34)
   - The **Rancher** version we run (per `docs/runbooks/rancher-upgrade-v2-14.md`,
     v2.14.1 is tested against K8s 1.33.11 / 1.34.7 / 1.35.4)

   Patch-level bumps within a tested minor version are routine. **Minor**
   bumps (e.g., 1.34 → 1.35) require a separate readiness review.

6. `--force-reconcile` is **not** needed: k3k watches the Cluster CR and
   reconciles on `spec` changes within seconds.

## Procedure

All commands below use the `harvester` kubeconfig context (the host cluster
where the k3k Cluster CR lives). The k3k controller does the work.

### 1. Record the current state

```bash
CURRENT_VERSION=$(kubectl --context=harvester -n rancher-k3k \
  get cluster.k3k.io rancher \
  -o jsonpath='{.spec.version}')
echo "Current spec.version: '${CURRENT_VERSION:-<unset, tracking host>}'"

kubectl --context=harvester -n rancher-k3k get pods -l role=server \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.containers[0].image}{"\n"}{end}'
# Capture this — needed for rollback
```

### 2. Patch the Cluster CR

```bash
TARGET="v1.34.7-k3s1"

kubectl --context=harvester -n rancher-k3k \
  patch cluster.k3k.io rancher --type merge \
  -p "{\"spec\":{\"version\":\"${TARGET}\"}}"
```

### 3. Watch the rolling update

The k3k controller updates the StatefulSet's `spec.template.spec.containers[0].image`
within ~30s. The StatefulSet then rolls pods one at a time
(`partition` semantics) — each replacement must be Ready before the next one
terminates. With 3 servers and the PDB enforcing `minAvailable=2`, only one
pod ever leaves the quorum at a time.

```bash
# StatefulSet rollout
kubectl --context=harvester -n rancher-k3k \
  rollout status statefulset/k3k-rancher-server --timeout=20m

# Live image versions across all server pods
watch -n 5 'kubectl --context=harvester -n rancher-k3k get pods -l role=server \
  -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount'
```

Expected: ~5–8 minutes total for 3 pods, each etcd member rejoining cleanly.

### 4. Verify quorum and API health throughout

While the rollout is in progress, the vCluster API server should stay
reachable on at least 2 of 3 server pods:

```bash
# From inside the vCluster — all server nodes should be Ready
kubectl --context=k3k-rancher get nodes -o wide

# etcd cluster health (if exec is permitted)
kubectl --context=harvester -n rancher-k3k exec k3k-rancher-server-0 -- \
  k3s etcd-snapshot list 2>/dev/null | head -3
```

If `kubectl --context=k3k-rancher` calls fail for more than ~30 seconds in a
row, **stop**. The rollout is wedged — see Recovery below.

### 5. Post-upgrade verification

```bash
# Server version reported by the vCluster API
kubectl --context=k3k-rancher version --short
# Expect: Server v1.34.7+k3s1

# All server pods running the new image
kubectl --context=harvester -n rancher-k3k get pods -l role=server \
  -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' \
  | sort -u
# Expect: a single line, rancher/k3s:v1.34.7-k3s1

# Rancher itself unaffected
kubectl --context=k3k-rancher -n cattle-system rollout status deploy/rancher

# Downstream clusters still connected
kubectl --context=k3k-rancher get clusters.management.cattle.io
# Expect: Ready=True for all
```

### 6. Update repo state to match (one PR / commit)

The live cluster's `spec.version` is now ahead of `rancher-cluster.yaml`'s
default. Bump the repo so the next deploy / restore lands on the same value:

- `deploy.sh`: update the `K3S_VERSION` default
- `deploy.conf.example`: update the commented example

This keeps the source-of-truth aligned with what is actually running.
Out-of-band cluster mutations that aren't reflected in the repo cause
disaster recovery to silently restore the cluster to an older shape.

## Rollback

### Path A: Re-patch the CR (preferred)

```bash
kubectl --context=harvester -n rancher-k3k \
  patch cluster.k3k.io rancher --type merge \
  -p "{\"spec\":{\"version\":\"${CURRENT_VERSION}\"}}"
```

Same rolling restart, opposite direction. Works as long as no etcd schema
migration was performed during the upgrade — k3s patches within the same
minor are always safe to roll back.

**Cross-minor rollback** (e.g., 1.35 → 1.34) is not supported by k3s/etcd —
the `etcd` storage may have been migrated. In that case skip to Path B.

### Path B: Restore from backup

If the rollout wedged or pods crashloop:

```bash
./rancher-restore.sh \
  --backup-file rancher-backup-<timestamp>.tar.gz \
  --rancher-version <current-rancher-version>
```

See [`docs/backup-restore.md`](../backup-restore.md) for the full procedure.

## Recovery from a wedged rollout

Symptoms: server pod stuck in `CrashLoopBackOff`, StatefulSet rollout paused,
API timeouts on `--context=k3k-rancher`.

1. **Identify the bad pod**:

   ```bash
   kubectl --context=harvester -n rancher-k3k get pods -l role=server
   kubectl --context=harvester -n rancher-k3k logs k3k-rancher-server-N --tail=200
   ```

2. **Roll back the CR immediately** (Path A above) — the StatefulSet
   controller will start replacing pods backward.

3. If the bad pod is `0` (the etcd seed) and quorum is lost
   (`server-1`/`server-2` show `connection refused`), follow
   [`docs/etcd-quorum-recovery.md`](../etcd-quorum-recovery.md). Don't try to
   `kubectl delete pod` — that won't fix corrupted etcd state.

4. The PDB protects voluntary disruptions but does **not** stop the
   StatefulSet controller from rolling forward. If a bad image is wedging
   things, the rollback patch is the kill switch.

## Post-procedure checklist

- [ ] `kubectl --context=k3k-rancher version --short` shows the new version
- [ ] All 3 server pods on the new image, distinct Harvester nodes
- [ ] Rancher Deployment Ready, replicas=3
- [ ] Both downstream clusters show `Ready` in the Rancher UI
- [ ] Backup taken post-upgrade
- [ ] Repo defaults updated and committed
