# Runbook: k3k Server Pod Wedged in safe_mode()

## Symptom

A single k3k server pod (typically the highest- or lowest-ordinal one
during a rolling update) crashloops after a pod IP change with this exact
log signature:

```text
[INFO] Starting pod k3k-rancher-server-N in HA node setup
[INFO] Starting K3s in Safe Mode (Network Policy Disabled) to patch Node IP from <old-IP> to <new-IP>
[INFO] Waiting for Node IP to update to <new-IP>.
[FATAL] timed out waiting for node to change IP from <old-IP> to <new-IP>
```

The pod restarts every ~2 minutes and either:

- FATALs at the 120-second hard cap (visible in the log above), or
- Briefly reaches Ready=true, then drops back to Ready=false on the next
  liveness/readiness blip.

The other server pods (those that already rolled successfully) are healthy
and Ready. Etcd quorum holds at `(N-1)/N`. Rancher itself is unaffected.

The Node object for the wedged server is **missing or stale** in
`kubectl --context=<vcluster> get nodes` — the pod's k3s never finishes
registering itself.

## Root cause

k3k's per-pod init wrapper (`pkg/controller/cluster/server/template.go`
upstream — function `safe_mode()`) was added by
[PR #598](https://github.com/rancher/k3k/pull/598) to fix
[issue #679](https://github.com/rancher/k3k/issues/679) ("Flannel network
policy controller crashes after pod reschedule"). The function reads the
last-known pod IP from a persisted file on the PVC:

```text
/var/lib/rancher/k3s/k3k-node-ip
```

When the current `POD_IP` differs from the persisted value, safe_mode
starts a temporary `k3s server --disable-network-policy` and polls
`kubectl get nodes -o wide | grep $POD_IP` every 2 seconds, up to 60
iterations (= 120 seconds). If the new IP doesn't appear in the Node list
in time, the script `fatal`s and the container exits.

The 120-second timeout is hardcoded and is racy under contention —
especially for ordinal-0 (etcd seed) when other servers are mid-rolling.
Once a pod misses the window, the persisted file is **never updated**
(safe_mode short-circuits the post-success write `echo $POD_IP >
/var/lib/rancher/k3s/k3k-node-ip` because it FATAL'd before reaching it).
Subsequent restarts get fresh pod IPs (the K8s pod IP is dynamic), so
each retry compares a *new* `$POD_IP` against the *same* stale persisted
value — every restart re-enters safe_mode and risks the same race.

## What `k3k-watcher` does NOT cover

This repo ships `k3k-watcher` with two scenarios:

1. **Etcd quorum deadlock** (issue [#678](https://github.com/rancher/k3k/issues/678))
   — triggered only when `crash == total` (every server pod
   CrashLoopBackOff with the timeout log). Auto-recovers via cluster-reset
   to 1 server.
2. **HA pod imbalance** (issue [#522](https://github.com/rancher/k3k/issues/522))
   — triggered when multiple server pods land on the same Harvester node.

A **single pod** wedged in safe_mode while the rest are healthy is **not
covered** — neither scenario's guard matches. The cluster looks healthy
to the watcher (quorum holds, placement is balanced) so it stays silent.

## Recovery (single-file fix, no PVC destruction)

The fix is to delete the stale `k3k-node-ip` file on the wedged pod's PVC
so that the next safe_mode invocation finds `CURRENT_IP=""` and returns
immediately, letting k3s boot normally and register a fresh Node with the
current pod IP.

The wedged pod is alive for ~2 minutes between FATAL crashes — enough
window for `kubectl exec`. No need to scale, drain, or wipe a PVC.

### Procedure

Replace `<wedged-pod>` with the affected server pod (e.g.
`k3k-rancher-server-0`) and `<context>` with the harvester host context
(`hvst-cluster` via Rancher proxy, or `hvst-local` direct to the
Harvester VIP — direct is preferred if the proxy is twitchy).

1. **Confirm the failure pattern**: read the current container's log to
   verify the safe_mode FATAL signature:

   ```bash
   kubectl --context=<context> -n rancher-k3k logs <wedged-pod> --tail=20
   ```

   Expect the four-line "Starting pod / Starting K3s in Safe Mode /
   Waiting for Node IP / FATAL timed out" pattern.

2. **Delete the stale-IP marker file** in the running container:

   ```bash
   kubectl --context=<context> -n rancher-k3k exec <wedged-pod> -- \
       rm -f /var/lib/rancher/k3s/k3k-node-ip
   ```

   You're racing the FATAL — if exec returns "container terminated", the
   container restarted between log-check and exec. Just retry — there's
   another 2-minute window before the next FATAL.

3. **Force a clean restart** so the next boot re-evaluates safe_mode with
   the missing file:

   ```bash
   kubectl --context=<context> -n rancher-k3k delete pod <wedged-pod>
   ```

   The StatefulSet recreates the pod immediately. Its safe_mode finds
   `CURRENT_IP=""` (file doesn't exist) and returns at the first guard:

   ```sh
   if [ -z "$CURRENT_IP" ] || [ "$CURRENT_IP" = "$POD_IP" ] ...; then
       return
   fi
   ```

4. **Watch for clean Ready** (no further crashloops):

   ```bash
   kubectl --context=<context> -n rancher-k3k get pods -l role=server -w
   ```

   Within ~60s the new pod transitions Pending → Running → Ready,
   restart count stays at 0, and `kubectl --context=<vcluster> get nodes`
   shows the fresh server with the new pod IP and current k3s version.

5. **Confirm etcd member rejoin** from a healthy peer:

   ```bash
   kubectl --context=<context> -n rancher-k3k exec <healthy-peer> -- \
       k3s etcd-snapshot list 2>/dev/null | head -3
   ```

   The wedged-pod hostname appears as a member when listing snapshots
   (the snapshot file names include `etcd-snapshot-<pod-name>-<epoch>`).

## Why not the destructive options

| Approach | Cost | Why we don't |
|---|---|---|
| Wipe the entire PVC (`kubectl delete pvc data-<pod>`) | 40Gi+ of replicated etcd data destroyed; etcd member must be cleanly removed first to avoid quorum issues; ~3-5 min repopulation from peers | Solves the same problem (no persisted IP file) but at huge cost |
| Roll back `spec.version` | The same safe_mode logic runs on the rollback restart; problem can recur | Doesn't fix the root cause |
| Surgical: temp-edit pod spec to `sleep` then exec in | Achieves the same `rm` outcome | More moving parts than `kubectl exec` against the live container |

The single-file `rm` is reversible (k3s rewrites the file once it boots
normally) and surgical (12 bytes vs 40Gi).

## Second failure mode: etcd member can't rejoin

If `safe_mode()` ran for several minutes before the recovery above (or the
pod was crashlooping for >5 minutes after the IP change), there is a
**second**, deeper, persisted-state issue beyond the IP marker file. The
etcd member's identity on the PVC — `db/etcd/member/`, `db/etcd/config`,
`db/etcd/name`, and the etcd-specific TLS material under `tls/etcd/` —
encodes the **old** peer URL and an old member-ID. Even after the
single-file `rm` recovery clears safe_mode, k3s on the wedged pod will
present a stale identity to the cluster, and the etcd cluster will reject
the local etcd's TLS handshake indefinitely:

```text
time="..." level=info msg="Failed to test etcd connection: ...
  authentication handshake failed: context deadline exceeded"
```

Symptoms:

- The pod is `Ready=true` (kubelet's basic check passes).
- `kubectl --context=<vcluster> get nodes` may show the wedged server as
  Ready, with role `control-plane,etcd` — but this is misleading
  (described below).
- An `etcdctl member list` from a healthy peer **does not include** the
  wedged server.
- Log lines above repeat every 5 seconds indefinitely, no progress.

The Node-listing-but-not-in-etcd-membership inconsistency is real: the
wedged pod runs its own apiserver+kubelet that reads cluster state from
one of the *other* servers' etcd over the cluster bootstrap channel, so
it **looks** like a healthy node from a Service-load-balanced query —
particularly via `k3k-rancher-service`, which load-balances across all
server pods including the wedged one. The **etcd member list is the
source of truth.**

### Recovery: empty the etcd state on the PVC, but **do not delete the directories**

This is where the procedure becomes **highly ordinal-0-sensitive**. See
the warning in the next section before doing this on `*-server-0`.

```bash
kubectl --context=<context> -n rancher-k3k exec <wedged-pod> -- sh -c '
    rm -rf /var/lib/rancher/k3s/server/db/etcd/*
    rm -rf /var/lib/rancher/k3s/server/db/etcd/.[!.]* 2>/dev/null || true
    rm -rf /var/lib/rancher/k3s/server/tls/etcd/*
    rm -f /var/lib/rancher/k3s/k3k-node-ip
'
kubectl --context=<context> -n rancher-k3k delete pod <wedged-pod>
```

Note: the `rm -rf .../etcd/*` empties the contents but **leaves the
`etcd/` directory in place** — that is critical. See next section.

On restart:

1. `safe_mode` short-circuits (no `k3k-node-ip` file).
2. k3s sees an empty `db/etcd/` and `tls/etcd/`, but the directories
   exist → init script chooses the JOIN path (not bootstrap-new — see
   warning below).
3. k3s authenticates to the bootstrap server using the persisted
   server-node-token (in `/var/lib/rancher/k3s/server/`), fetches the
   *real* cluster's etcd CAs over that channel, and runs `etcd member
   add` against the live cluster.
4. Local etcd starts with `initial-cluster-state=existing`, joins the
   cluster, and replicates state from peers (~2-3 minutes for
   ~100-200MB).
5. Verify with `etcdctl member list` from any peer — the wedged server
   appears with current peer URL.

Quorum stays at `(N-1)/N` throughout this recovery; never drops below.

## ⚠️ CRITICAL: Do **not** `rm -rf` the entire `db/etcd/` directory on `*-server-0`

The k3k init script's HA branch logic is:

```sh
if [ ${POD_NAME: -1} == 0 ] && [ ! -d "${ETCD_DIR}" ]; then
    # First-time start for ordinal 0 — BOOTSTRAP A NEW CLUSTER
    /bin/k3s server --config ${INIT_CONFIG} ...      # has --cluster-init
else
    # Other ordinals OR ordinal-0 with existing etcd dir — JOIN existing
    safe_mode ${SERVER_CONFIG}
    /bin/k3s server --config ${SERVER_CONFIG} ...    # has --server <URL>
fi
```

If you do `rm -rf /var/lib/rancher/k3s/server/db/etcd` (deleting the
**directory**, not just emptying it) on an ordinal-0 pod, the script's
`[ ! -d "${ETCD_DIR}" ]` check passes and it runs `INIT_CONFIG`. **That
bootstraps a brand new 1-node etcd cluster with a fresh cluster-id.** The
real etcd cluster (still running on the other servers) is unaffected;
your ordinal-0 pod now operates a parallel split-brain etcd cluster
visible only to itself.

This is observed cleanly in the pod logs:

```text
"Starting etcd for new cluster, cluster-reset=false"
"initial-cluster":"k3k-rancher-server-0-<hash>=https://<pod-ip>:2380"
"initial-cluster-state":"new"
"cluster-id":"<NEW-id-different-from-real-cluster>"
```

Recovery from a split-brain server-0 is the same procedure as above
(empty contents, keep directory, restart pod) — but knowing not to
trigger it in the first place is preferable.

For ordinals 1 and above, the script's first condition is false
regardless, so the bootstrap path is impossible and `rm -rf` of the
whole `etcd/` directory is technically OK — but for muscle memory,
**always preserve the directory** when wiping etcd state on any k3k
server pod. The "empty the contents" pattern is correct and safe for all
ordinals.

## Upstream follow-up

Filed upstream as
[**rancher/k3k#836**](https://github.com/rancher/k3k/issues/836) (follow-up to
closed [#679](https://github.com/rancher/k3k/issues/679)). Key points:

- **safe_mode timeout is hardcoded at 120s** (`count -gt 60`, `sleep 2`)
  and not configurable.
- **No self-recovery on timeout**: when safe_mode FATALs, the persisted
  `k3k-node-ip` file is left intact. A reasonable upstream fix would be
  to delete the file on FATAL so the next restart skips safe_mode
  entirely (self-healing).
- **No coverage in k3k-watcher upstream test suite** — issue
  [#559](https://github.com/rancher/k3k/issues/559) tracks the broader
  gap of upgrade testing.

When filing, include the FATAL log snippet, the value of
`/var/lib/rancher/k3s/k3k-node-ip` post-recovery (should be the new
POD_IP), and the rolling-update event timeline showing other servers
completed safe_mode while the wedged one didn't.

## Hardening: extending k3k-watcher

A future scenario in `k3k-watcher.yaml` could detect this pattern early:

- Trigger: any single server pod with `safe_mode FATAL` in `--previous`
  logs AND `restartCount >= 2` AND other servers Ready.
- Action: `kubectl exec <wedged-pod> -- rm -f /var/lib/rancher/k3s/k3k-node-ip`
  followed by `kubectl delete pod <wedged-pod>`.
- Cooldown: at least 600s between attempts to avoid masking a different
  underlying failure.

This would close the coverage gap between scenarios 1 and 2 and
auto-resolve the issue documented here.
