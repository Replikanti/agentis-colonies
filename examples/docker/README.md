# Docker recipes

Sample setup for running the `dev-apprenticeship` federation via `docker run` or `docker compose`. The image is published to GHCR by `.github/workflows/release-docker.yml` on every `dev-apprenticeship-v*` git tag push, with multi-arch support for `linux/amd64` and `linux/arm64` ([#324](https://github.com/Replikanti/agentis-colonies/issues/324)).

## Quick start (docker run)

```bash
docker run --rm -d \
  --name agentis-colonies \
  -e GITLAB_URL=https://gitlab.com \
  -e GITLAB_PROJECT=my-org/my-project \
  -e GITLAB_TOKEN=glpat-REPLACE_ME \
  -v $PWD/data:/data \
  ghcr.io/replikanti/agentis-colonies:dev-apprenticeship-1.2.0
```

## Quick start (compose)

```bash
cp .env.example .env
$EDITOR .env                  # paste your token + project path
docker compose up -d
docker compose logs -f
```

## Persistent state

`/data` inside the container holds the agentis registry, the experience JSONL store, and the memo database. Mount a volume there (the compose file uses a named volume `agentis-data`; the `docker run` snippet uses a bind mount). Lose it and the federation forgets every learned confidence and every classification.

## Image tags

| Tag                                      | Meaning                                              |
|------------------------------------------|------------------------------------------------------|
| `dev-apprenticeship-X.Y.Z`               | Pinned federation release. Use in production.        |
| `dev-apprenticeship-latest`              | Latest dev-apprenticeship release. Dev / staging.    |

The image labels record the agentis runtime version baked in:

```bash
docker inspect ghcr.io/replikanti/agentis-colonies:dev-apprenticeship-1.2.0 \
  --format '{{ index .Config.Labels "agentis.version" }}'
```

## Switching forge backends

Set `FORGE_TYPE=github` in the env file and provide `GITHUB_TOKEN` / `GITHUB_OWNER` / `GITHUB_REPO`. The first start materialises each colony's `colony.toml` from `colony.example.toml` and writes the `[forge].type` key for you.

## See also

- `examples/k8s/` — equivalent recipe for Kubernetes.
- `dev-apprenticeship/install.sh` — host-install path.
- [Issue #324](https://github.com/Replikanti/agentis-colonies/issues/324) — implementation tracking.
