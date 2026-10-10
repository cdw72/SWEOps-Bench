# SWEOps-Bench

## Repository layout

```
cases/<slug>/            one directory per case:
  task.toml              task metadata
  instruction.md         the incident prompt
  steps/k0-baseline/     round k=0: healthy cluster, baseline inspection
  steps/k1-incident/     round k=1: fault injected, full diagnosis/repair
  environment/           docker-compose + Dockerfile + seed.py + src-snapshot
  tests/                 judge / regression / recovery tests
  solution/              reference solve script
scripts/fetch_images.sh  restore operator image tarballs from Docker Hub
images-manifest.json     tarball <-> Docker Hub image mapping + checksums
tools/                   dataset aggregation & environment preflight
```

## Images

The baked operator images (~31 GB, 101 unique images) are mirrored on Docker Hub
under `cdddddd/opsrca-*`. One command restores them where each case expects them:

```bash
docker login               # recommended (anonymous pulls are rate-limited)
scripts/fetch_images.sh    # or: scripts/fetch_images.sh cassop-696
```

## Run

```bash
uv tool install harbor     # the runner CLI (tested with v0.22.0)
scripts/fetch_images.sh    # restore images (see above)
harbor run -c job.yaml -a claude-code -m <model>
```

`-a` picks the agent backend — `claude-code` or `codex`, each pointed at your own
endpoint with the usual env vars (`oracle` runs the reference solution instead) —
and `-m` picks any model that endpoint serves; repeat it to compare models.
