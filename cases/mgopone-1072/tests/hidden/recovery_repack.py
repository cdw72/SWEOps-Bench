#!/usr/bin/env python3
"""Repack an operator image docker-archive with a freshly built binary.

The in-sandbox recovery judge cannot use `docker build` (no daemon inside the
environment container), but it CAN: `go build` the agent's tree, then append a
layer carrying the new binary (+ any extra files the family Dockerfile COPYs
from its builder stage) on top of the seed's buggy-operator image tar, and
`ctr images import` the result into the k3s containerd -- the same socket the
seed used. The operator Deployment is then rolled onto the new tag.

Archive shape (docker 26 `docker save`, OCI-layout style) -- all digest-chained:
  index.json -> OCI manifest blob -> config blob + layer blobs
  manifest.json (docker style)    -> config path + layer paths + RepoTags
  repositories                    -> top layer id
Appending one layer therefore means rewriting four small JSON entries and
adding three blobs; every original blob is copied through untouched.

Determinism: layer/config/manifest blobs are written with zeroed mtimes and
uid/gid 0 so a repack of identical inputs yields identical digests.

Usage:
  recovery_repack.py <in.tar> <out.tar> <new-tag> <src>=<dest> [<src>=<dest> ...]

<src> is a path inside the environment container (the built binary / kodata
tree), <dest> is its absolute path inside the image. Binaries land 0755;
everything else keeps its on-disk mode. Stdlib only. Exit 0 on success.
"""
import hashlib
import io
import json
import os
import sys
import tarfile


def _digest(blob: bytes) -> str:
    return "sha256:" + hashlib.sha256(blob).hexdigest()


def _blob_path(digest: str) -> str:
    return "blobs/sha256/" + digest.split(":", 1)[1]


def _read_json(tar, name):
    return json.load(tar.extractfile(name))


def _layer_for(files):
    """files: [(abs_src, abs_dest)] -> (layer_bytes, member_map)"""
    buf = io.BytesIO()
    members = []
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        for src, dest in files:
            dest = dest.lstrip("/")
            if os.path.isdir(src):
                for root, dirs, fnames in os.walk(src):
                    dirs.sort()
                    for fn in sorted(fnames):
                        s = os.path.join(root, fn)
                        d = os.path.join(dest, os.path.relpath(s, src))
                        members.append((s, d))
                        _add(tf, s, d)
            else:
                members.append((src, dest))
                _add(tf, src, dest)
    return buf.getvalue(), members


def _add(tf, src, dest):
    with open(src, "rb") as fh:
        tf.addfile(_member(src, dest), fh)


def _member(src, dest):
    st = os.lstat(src)
    mode = 0o755 if (st.st_mode & 0o111) else 0o644
    ti = tarfile.TarInfo(dest)
    ti.size = st.st_size
    ti.mtime = 0
    ti.mode = mode
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = ""
    ti.type = tarfile.REGTYPE
    return ti


def repack(src_tar, dst_tar, new_tag, files):
    with tarfile.open(src_tar, "r") as t:
        idx = _read_json(t, "index.json")
        man_docker = _read_json(t, "manifest.json")
        if not isinstance(man_docker, list) or len(man_docker) != 1:
            sys.exit("[repack] unexpected manifest.json shape")
        entry = dict(man_docker[0])
        old_cfg_path = entry["Config"]
        config = _read_json(t, old_cfg_path)

        oci_digest = idx["manifests"][0]["digest"]
        oci_path = _blob_path(oci_digest)
        oci = _read_json(t, oci_path)
        # Multi-arch export (<case>, quay.io/opstree/redis-operator:
        # CRI pulled the manifest LIST, so index.json's first entry points at
        # an image INDEX -- a blob with manifests[] and no "layers", and the
        # repack died on KeyError 'layers' before ever rolling the operator).
        # The right child is the arch manifest whose config digest equals the
        # docker entry's Config blob -- that config is what the cluster runs.
        if "layers" not in oci:
            want = "sha256:" + old_cfg_path.rsplit("/", 1)[-1]
            hit = None
            for m in oci.get("manifests") or []:
                cand_path = _blob_path(m["digest"])
                try:
                    cand = _read_json(t, cand_path)
                except KeyError:
                    continue
                if cand.get("config", {}).get("digest") == want:
                    hit = (m["digest"], cand)
                    break
            if not hit:
                sys.exit("[repack] index has no arch manifest whose config "
                         "matches the docker entry -- cannot repack")
            oci_digest, oci = hit

        # every original entry, byte-for-byte
        originals = {}
        for m in t.getmembers():
            if m.isfile():
                originals[m.name] = t.extractfile(m).read()

    # 1. new layer
    layer_bytes, members = _layer_for(files)
    layer_d = _digest(layer_bytes)
    # 2. new config (rootfs/history only; entrypoint/user/workdir stay)
    diff_ids = list(config["rootfs"]["diff_ids"]) + [layer_d]
    config = dict(config)
    config["rootfs"] = dict(config["rootfs"], diff_ids=diff_ids)
    config.setdefault("history", []).append(
        {"created": "2026-01-01T00:00:00Z",
         "created_by": "sweops recovery repack: " + ", ".join(
             d for _, d in members)})
    cfg_bytes = json.dumps(config, separators=(",", ":")).encode()
    cfg_d = _digest(cfg_bytes)
    # 3. new OCI manifest
    oci = dict(oci)
    oci["layers"] = list(oci["layers"]) + [{
        "mediaType": "application/vnd.oci.image.layer.v1.tar",
        "digest": layer_d, "size": len(layer_bytes)}]
    oci["config"] = dict(oci["config"], digest=cfg_d, size=len(cfg_bytes))
    oci_bytes = json.dumps(oci, separators=(",", ":")).encode()
    oci_d = _digest(oci_bytes)
    # 4. index / docker manifest / repositories
    idx = dict(idx)
    # After a multi-arch descend, manifests[0] was an INDEX entry; pointing it
    # at the new arch manifest while keeping the index mediaType would make
    # containerd parse a manifest as an index. Force the child's mediaType.
    idx["manifests"] = [dict(idx["manifests"][0], digest=oci_d,
                             size=len(oci_bytes),
                             mediaType=oci.get(
                                 "mediaType",
                                 "application/vnd.oci.image.manifest.v1+json"),
                             annotations=dict(
                                 idx["manifests"][0].get("annotations", {}),
                                 **{"io.containerd.image.name": new_tag}))]
    entry["Config"] = _blob_path(cfg_d)
    entry["RepoTags"] = [new_tag]
    entry["Layers"] = list(entry["Layers"]) + [_blob_path(layer_d)]

    out = dict(originals)
    out[_blob_path(layer_d)] = layer_bytes
    out[_blob_path(cfg_d)] = cfg_bytes
    out[_blob_path(oci_d)] = oci_bytes
    out["index.json"] = json.dumps(idx, separators=(",", ":")).encode()
    out["manifest.json"] = json.dumps([entry], separators=(",", ":")).encode()
    if "repositories" in out:
        repo, tag = new_tag.rsplit(":", 1)
        out["repositories"] = json.dumps(
            {repo: {tag: layer_d.split(":")[1]}}).encode()

    with tarfile.open(dst_tar, "w", format=tarfile.USTAR_FORMAT) as tf:
        for name in sorted(out):
            b = out[name]
            ti = tarfile.TarInfo(name)
            ti.size = len(b)
            ti.mtime = 0
            ti.mode = 0o644
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = ""
            tf.addfile(ti, io.BytesIO(b))
    print(f"[repack] +1 layer {layer_d[:19]} ({len(layer_bytes)} bytes, "
          f"{len(members)} file(s)): " + ", ".join(d for _, d in members))


if __name__ == "__main__":
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    _in, _out, _tag = sys.argv[1:4]
    _files = []
    for pair in sys.argv[4:]:
        s, d = pair.split("=", 1)
        _files.append((s, d))
    repack(_in, _out, _tag, _files)
