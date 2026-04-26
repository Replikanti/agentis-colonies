# Kubernetes deployment recipes

Sample manifests for running the `dev-apprenticeship` federation as a single-replica Deployment on any cluster (GKE, EKS, AKS, k3s, kind). Multi-arch images at `ghcr.io/replikanti/agentis-colonies` cover both `linux/amd64` and `linux/arm64` nodes ([#324](https://github.com/Replikanti/agentis-colonies/issues/324)).

These manifests are operator references. They are not opinionated production templates — there is no Ingress, no NetworkPolicy, no Service (the federation does not expose a port; the optional `federation-dashboard` does, and is shipped as a separate component). Layer your own overlays on top.

## Prerequisites

- `kubectl >= 1.27`
- A cluster with a default `StorageClass` that supports `ReadWriteOnce` PVCs.
- A namespace (the manifests are namespace-agnostic; default is whatever your `kubectl config current-context` resolves to).

## Setup

```bash
# 1. Fill in real credentials and apply the Secret.
cp secret.yaml.example secret.yaml
$EDITOR secret.yaml      # paste your glpat-... or ghp_... token
kubectl apply -f secret.yaml

# 2. Set forge type + project / repo paths.
cp configmap.yaml.example configmap.yaml
$EDITOR configmap.yaml
kubectl apply -f configmap.yaml

# 3. Apply the Deployment + PVC.
kubectl apply -f deployment.yaml

# 4. Watch the federation come up. The first start does an `agentis init`
#    + writes the federation-wide config keys; subsequent starts skip both.
kubectl logs -f -l app.kubernetes.io/name=agentis-colonies
```

The Deployment uses a `Recreate` strategy so a rollout never has two pods racing the same agentis registry.

## Image tags

| Tag                                      | Meaning                                                  |
|------------------------------------------|----------------------------------------------------------|
| `dev-apprenticeship-X.Y.Z`               | Pinned federation release. Use this in production.       |
| `dev-apprenticeship-latest`              | Latest dev-apprenticeship release. Dev / staging only.   |

Tags are produced by `.github/workflows/release-docker.yml` on every `dev-apprenticeship-v*` git tag push. The image bundles the `agentis` runtime binary at the version listed in `dev-apprenticeship/.agentis-version`.

## Persistent state

| Path inside container | Backing                  | Purpose                                                    |
|-----------------------|--------------------------|------------------------------------------------------------|
| `/data/.agentis/`     | `agentis-data` PVC (5Gi) | experience JSONL, memo store, daemon registry, config      |

Lose the PVC and the federation forgets every confidence value, every learned classification, every memo, and every experience row. Back up the PVC contents on a schedule that matches your data-retention requirements.

## Resource sizing

The defaults (`requests: 200m / 256Mi`, `limits: 2 / 2Gi`) match a small-to-medium project (~50 issues, ~100 MRs in flight). Bump the limits if you observe OOM kills under heavier load — the agentis runtime grows roughly linearly with experience JSONL size.

## Switching forge backends

Edit `forge_type` in the ConfigMap and re-apply. The next pod start will rewrite each colony's `colony.toml` `[forge].type` key. You will also need the corresponding `*_token` secret populated.

## Out of scope (for now)

- Helm chart — deferred to a follow-up issue.
- Multi-tenant deployments — one federation per cluster namespace is the recommended boundary.
- Operator (CRD-based) lifecycle — out of scope. The Deployment manages the federation supervisor; the supervisor manages 21 daemon processes inside one pod.

## See also

- `examples/docker/` — equivalent recipe via `docker run` / `docker compose`.
- `dev-apprenticeship/install.sh` — the host-install path. Shares the same forge-config logic with `entrypoint.sh`.
- [Issue #324](https://github.com/Replikanti/agentis-colonies/issues/324) — implementation tracking.
