#!/usr/bin/env bash
# Fetch the baked operator images for all (or selected) cases from Docker Hub
# and write them back as cases/<slug>/environment/images/*.tar — exactly where
# each case's Dockerfile expects them (`COPY images/ /images/`).
#
#   usage: scripts/fetch_images.sh [slug ...]        # no args = all 55 cases
#
# Pulls the cdddddd/opsrca-* mirrors listed in images-manifest.json.
# Tip: `docker login` first — anonymous Docker Hub pulls are rate-limited
# (100/6h); the full set is 106 unique images.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
exec python3 - "$@" <<'EOF'
import json, subprocess, sys, os, hashlib
mp = json.load(open("images-manifest.json"))
want_slugs = set(sys.argv[1:])
def sha256(p, chunk=1 << 20):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        while True:
            b = f.read(chunk)
            if not b: break
            h.update(b)
    return h.hexdigest()
done, skipped, failed = 0, 0, []
for rel, meta in sorted(mp.items()):
    slug = rel.split("/")[1]
    if want_slugs and slug not in want_slugs:
        continue
    dest = rel
    if os.path.exists(dest) and sha256(dest) == meta["sha256"]:
        skipped += 1; continue
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    print(f"[fetch] {meta['dh']} -> {dest}")
    r = subprocess.run(["docker", "pull", meta["dh"]])
    if r.returncode != 0:
        print("  pull FAILED"); failed.append(meta["dh"]); continue
    # Save under the upstream (orig) name, not the mirror name: the cases'
    # manifests and CRs reference the upstream ref, and the recorded sha256
    # was taken from a save of that ref. Without this the tar imports into
    # containerd under cdddddd/opsrca-* and every pod goes ImagePullBackOff.
    t = subprocess.run(["docker", "tag", meta["dh"], meta["orig"]])
    if t.returncode != 0:
        print("  tag FAILED"); failed.append(rel); continue
    s = subprocess.run(["docker", "save", "-o", dest, meta["orig"]])
    iid = subprocess.run(["docker", "inspect", "-f", "{{.Id}}", meta["orig"]],
                         capture_output=True, text=True).stdout.strip()
    subprocess.run(["docker", "rmi", meta["dh"], meta["orig"]], capture_output=True)
    if s.returncode != 0:
        print("  save FAILED"); failed.append(rel); continue
    # content-address verification: image ID is stable across save/load/pull
    if meta.get("image_id"):
        status = "ok" if iid == meta["image_id"] else f"CONTENT MISMATCH exp={meta['image_id'][:19]} got={iid[:19]}"
    else:
        status = "saved (no image_id on record)"
    print("  ", status, f"({os.path.getsize(dest)//1048576} MiB)")
    done += 1
print(f"\nfetched {done}, verified-skip {skipped}, failed {len(failed)}")
for f in failed: print("  FAILED:", f)
sys.exit(1 if failed else 0)
EOF
