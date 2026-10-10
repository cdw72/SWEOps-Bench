#!/usr/bin/env bash
# Push all baked operator images to Docker Hub.
#   usage: scripts/push_images.sh <hub_root>     # e.g. /path/to/hub
# Reads each cases/<slug>/task/environment/images/*.tar, docker-loads it,
# re-tags it to the cdddddd/opsrca-* name and pushes. Records the content-
# addressed image ID of every unique image back into images-manifest.json
# (field "image_id") so fetch_images.sh can verify pulls byte-exactly.
# Idempotent (re-run pushes only failures). Requires `docker login` first.
# Optional 2nd arg pushes only mirrors whose name contains that substring.
set -euo pipefail
HUB_ROOT="${1:?usage: push_images.sh <hub_root> [dh_substring]}"
ONLY="${2:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$REPO_ROOT" "$HUB_ROOT" "$ONLY" <<'EOF'
import json, subprocess, sys, os, re
repo_root, hub, only = sys.argv[1], sys.argv[2].rstrip('/'), sys.argv[3]
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
# a few tars on disk still carry the pre-release brand in their filename
# (…-opsrca-NN.tar vs the manifest key …-sweops-NN.tar); index those too.
norm = lambda k: k.replace("sweops", "@").replace("opsrca", "@")
src_norm = {norm(k): v for k, v in src_for.items()}
pushed, failed = set(), []
for rel in sorted(mp):
    meta = mp[rel]; dh = meta["dh"]
    if only and only not in dh:
        continue
    if dh in pushed or dh in failed:
        continue
    src = src_for.get(rel) or src_norm.get(norm(rel))
    if not src:
        print(f"[skip] no tar on disk for {rel}"); continue
    print(f"[push] {meta['orig']} -> {dh}")
    load = sh("docker", "load", "-i", src)
    if load.returncode != 0:
        print("  load FAILED"); failed.append(dh); continue
    ref = meta["orig"]
    if sh("docker", "tag", ref, dh).returncode != 0:
        # tar carries a different name than the manifest records — use the
        # name docker actually loaded instead of hard-failing.
        m = re.search(r"Loaded image: (\S+)", load.stdout)
        if not m:
            print("  tag FAILED (and no name in load output)"); failed.append(dh); continue
        ref = m.group(1)
        if sh("docker", "tag", ref, dh).returncode != 0:
            print(f"  tag FAILED ({ref})"); failed.append(dh); continue
    iid = sh("docker", "inspect", "-f", "{{.Id}}", ref).stdout.strip()
    p = sh("docker", "push", dh)
    if p.returncode != 0:
        print("  push FAILED:", p.stderr.strip()[-300:]); failed.append(dh); continue
    # record content address on first success
    for m in mp.values():
        if m["dh"] == dh:
            m.setdefault("image_id", iid)
    sh("docker", "rmi", ref, dh)
    pushed.add(dh)
json.dump(mp, open(os.path.join(repo_root, "images-manifest.json"), "w"), indent=1)
print(f"\npushed {len(pushed)} unique images; failed {len(failed)}")
for f in failed: print("  FAILED:", f)
sys.exit(1 if failed else 0)
EOF
