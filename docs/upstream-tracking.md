# Upstream Tracking — rancher/k3k

Tracks upstream k3k features this deployment depends on or would adopt once available. Check this list before planning a k3k version bump.

## k3k vs k3s versioning — read this first

**k3k itself does not pin a k3s/Kubernetes version.** The k3k controller's only image flags default to `rancher/k3s` and `rancher/k3k-kubelet` with **no tag** (see `main.go` in upstream). The actual k3s image tag for each vCluster is decided by the `Cluster.spec.version` field on the k3k Cluster CR. Quoting `pkg/controller/cluster/cluster.go`:

> if the Version is not specified we will try to use the same Kubernetes version of the host.

So bumping K8s inside the rancher vCluster is a **CR edit** (`spec.version: v1.34.7-k3s1`) followed by a rolling restart of the k3k server StatefulSet — it does **not** require a k3k chart upgrade and does **not** touch the Harvester host. See [`docs/runbooks/k3k-vcluster-k8s-upgrade.md`](runbooks/k3k-vcluster-k8s-upgrade.md) for the procedure, and [`docs/runbooks/k3k-stuck-k8s-upgrade.md`](runbooks/k3k-stuck-k8s-upgrade.md) for why the Rancher UI / system-upgrade-controller path fails on vClusters.

The `k8s.io/kubernetes` version pinned in upstream `go.mod` (currently `v1.35.4` on `main`) is the controller-runtime client-library version k3k builds against — not what runs inside our vClusters.

## k3k version readiness matrix

Last refreshed: 2026-05-02.

| Feature                               | Needed for                         | v1.0.2 (current) | v1.0.3-rc1 | v1.1.0-rc6 | Status                    |
|---------------------------------------|------------------------------------|------------------|------------|------------|---------------------------|
| `serverAffinity` on Cluster CR        | Anti-affinity across Harvester nodes for k3k server pods | No | No (preferred-affinity backport only, #736) | Yes (#696) | Adopt when v1.1.0 **stable** |
| PVC race-condition fix (#789)         | Prevents PVC bind flap during server pod restart | No | Yes (backport)              | Yes        | v1.0.3 worth tracking      |
| `WorkerLimit` for shared-mode clusters (#804) | Caps shared-cluster worker count | No | Yes (backport)         | Yes        | We use `mode: virtual` — not relevant |
| Distribution algorithm refactor (#695) | Fairer pod placement across host capacity | No | Yes (backport) | Yes | Quality of life |
| `bci-base` v16 controller image       | Base image refresh (security)      | No               | No         | Yes (#819) | Comes with v1.1.0          |
| cgroup-dirs fix for virtual mode (#792) | Affects systemd-cgroup pod startup | No             | No         | Yes        | Watch for our setup        |
| Controller leader election            | Scaling k3k controller to ≥2 replicas | No            | No         | No         | Blocked upstream           |

## Open / recently closed upstream tickets

| Ticket                                              | Summary                                   | State   | Impact                                                                                                              |
|-----------------------------------------------------|-------------------------------------------|---------|---------------------------------------------------------------------------------------------------------------------|
| [k3k#522](https://github.com/rancher/k3k/issues/522) | Affinity / scheduling for server and agent pods | Closed (PR #696 merged 2026-03-23) | Fix shipped in v1.1.0-rc3 onward (latest: v1.1.0-rc6 from 2026-04-28). Watch for v1.1.0 stable; then add `spec.serverAffinity` to `rancher-cluster.yaml`. |
| [k3k#678](https://github.com/rancher/k3k/issues/678) | etcd deadlock on server pod restart       | Open    | Mitigated by `k3k-watcher` etcd recovery.                                                                           |
| [k3k#679](https://github.com/rancher/k3k/issues/679) | Flannel network-policy-controller crash on reschedule | Open | Mitigated by `--disable-network-policy` in Cluster spec and `ingress-watcher` scenario 2.                           |
| [k3k#680](https://github.com/rancher/k3k/issues/680) | Ingress deletion during reconcile         | Open    | Mitigated by `ingress-reconciler` CronJob.                                                                          |
| k3k controller leader election (no issue yet)        | `ctrl.NewManager()` called without `LeaderElection: true` — no `--leader-elect` flag | Upstream gap | Controller stays at 1 replica. File an upstream issue if we want HA controller. |

## Recent upstream releases

- **v1.1.0-rc6** (2026-04-28) — current pre-release tip. Includes PR #792 (cgroup dirs), #819 (bci-base v16), #811 (Kubernetes deps → 1.35.4), chart `1.1.0-rc6`. Still RC — do not adopt.
- **v1.1.0-rc5** (2026-04-28) — superseded by rc6 the same day.
- **v1.1.0-rc4** (2026-04-15)
- **v1.1.0-rc3** (2026-04-09) — first RC carrying PR #696 (`serverAffinity`).
- **v1.0.3-rc1** (2026-04-24) — first pre-release on `release/v1.0`. Backports affinity-preferred (#736), PVC race fix (#789), distribution refactor (#695), WorkerLimit (#804). Not stable yet.

## Readiness criteria for k3k v1.1.0 adoption

Do **not** bump until all of the following are true:

1. v1.1.0 is released as stable (not `-rc*`).
2. Release notes confirm no breaking change to the Cluster CRD schema used in `rancher-cluster.yaml` (check `serverArgs`, `expose.ingress`, `persistence`, `mode: virtual`, `sync`, `tlsSANs`).
3. Harbor pull-through has cached the new `rancher/k3k` and `rancher/k3k-kubelet` images.
4. A snapshot/backup of the current rancher vCluster exists (Step 7 backup run succeeded within last 24h).
5. Dry-run: `helm upgrade k3k k3k/k3k --version <new> --dry-run --reuse-values` passes.
6. Plan rollback: previous chart version + k3k image tag recorded; `helm rollback k3k <rev>` tested in a non-prod vCluster if one is available.

Once bumped, add `serverAffinity` to `rancher-cluster.yaml` (after the `tlsSANs:` block):

```yaml
  serverAffinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              role: server
              cluster: __CLUSTER_NAME__
          topologyKey: kubernetes.io/hostname
```

This combined with the existing PDB (`k3k-pdb.yaml`) gives full protection: one server pod per Harvester node (hard constraint) and at most one voluntarily evicted at a time (PDB).

## Controller restart safety

The k3k controller is stateless. If its single pod is evicted, crashes, or its node is drained:

- Running vCluster server pods (e.g. `k3k-rancher-server-0/1/2`) keep running. They are a plain Kubernetes StatefulSet once created; the controller does not gate their liveness.
- Rancher (inside the vCluster), cattle-cluster-agent, and downstream cluster connectivity are **unaffected**.
- Only net-new k3k Cluster CR reconciles pause — typically for the 30–60 seconds the controller takes to reschedule.
- No data-plane impact. No LB flap. No quorum loss.

This is why a 1-replica k3k controller is acceptable despite not being HA. The controller reschedule was **not** the cause of the Rancher LB outage observed during Harvester v1.7.1 upgrade; that was eviction of the vCluster server pods themselves (now addressed by the PDB).

## Pre-Harvester-upgrade checklist

Add to the Harvester upgrade runbook:

1. `kubectl get addons.harvesterhci.io kubeovn-operator -n kube-system -o jsonpath='{.spec.enabled}'` must return `false`. Harvester 1.7.1 ships KubeOVN CRDs and an Addon; if enabled during/after upgrade it replaces canal/flannel and breaks every flannel-specific mitigation in this repo.
2. `kubectl get pdb -n rancher-k3k k3k-rancher-server` must show `ALLOWED DISRUPTIONS: 1` and `MIN AVAILABLE: 2`.
3. All 3 `k3k-rancher-server-*` pods Ready, one per distinct Harvester node.
4. Most recent Rancher backup (Step 7) is <24h old and verified restorable (see `docs/backup-restore.md`).
