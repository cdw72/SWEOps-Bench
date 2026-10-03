#!/usr/bin/env bash
# Push all baked operator images to Docker Hub.
#   usage: scripts/push_images.sh <hub_root>     # e.g. /path/to/hub
# Reads each cases/<slug>/task/environment/images/*.tar, docker-loads it,
# re-tags it to the cdddddd/opsrca-* name and pushes. Records the content-
# addressed image ID of every unique image back into images-manifest.json
# (field "image_id") so fetch_images.sh can verify pulls byte-exactly.
# Idempotent (re-run pushes only failures). Requires `docker login` first.
set -euo pipefail
HUB_ROOT="${1:?usage: push_images.sh <hub_root>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$REPO_ROOT" "$HUB_ROOT" <<'EOF'
import json, subprocess, sys, os, re
repo_root, hub = sys.argv[1], sys.argv[2].rstrip('/')
mp = json.load(open(os.path.join(repo_root, "images-manifest.json")))
def sh(*a):
    return subprocess.run(a, capture_output=True, text=True)
src_for = {}
for slug in sorted(os.listdir(hub)):
    d = os.path.join(hub, slug, 'task', 'environment', 'images')
    if not os.path.isdir(d): continue
    for f in sorted(os.listdir(d)):
        if f.endswith('.tar'):
            src_for[f"cases/{slug}/environment/images/{f}"] = os.path.join(d, f)
pushed, failed = set(), []
for rel in sorted(mp):
    meta = mp[rel]; dh = meta["dh"]
    if dh in pushed or dh in failed:
        continue
    src = src_for.get(rel)
    if not src:
        print(f"[skip] no tar on disk for {rel}"); continue
    print(f"[push] {meta['orig']} -> {dh}")
    if sh("docker", "load", "-i", src).returncode != 0:
        print("  load FAILED"); failed.append(dh); continue
    if sh("docker", "tag", meta["orig"], dh).returncode != 0:
        print("  tag FAILED"); failed.append(dh); continue
    iid = sh("docker", "inspect", "-f", "{{.Id}}", meta["orig"]).stdout.strip()
    p = sh("docker", "push", dh)
    if p.returncode != 0:
        print("  push FAILED:", p.stderr.strip()[-300:]); failed.append(dh); continue
    # record content address on first success
    for m in mp.values():
        if m["dh"] == dh:
            m.setdefault("image_id", iid)
    sh("docker", "rmi", meta["orig"], dh)
    pushed.add(dh)
json.dump(mp, open(os.path.join(repo_root, "images-manifest.json"), "w"), indent=1)
print(f"\npushed {len(pushed)} unique images; failed {len(failed)}")
for f in failed: print("  FAILED:", f)
sys.exit(1 if failed else 0)
EOF
