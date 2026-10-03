#!/usr/bin/env python3
"""Static pre-flight for a hub task's environment, run BEFORE any smoke/build.

The failure this exists to catch is the expensive kind: an env whose seed
deploys an image the sandbox cannot possibly have. `seed.py` imports whatever
tars sit in /images/ and then applies the bundle with `image_rewrites` applied;
anything still unresolved is left to the k3s node to pull. A *registry* tag can
be pulled (all seven empty-`images/` envs -- cassop-696/705, rdoptwo-1668/1863/
283/292/297 -- passed their gates that way). A *locally built* tag cannot: it
only ever existed on the build host, so the pod sits in ImagePullBackOff and the
seed burns its whole timeout before anyone sees why.

So the check is name-aware, not emptiness-aware:

    local_tag(ghcr.io/x/y:srcbuggy-11042)  and not baked  -> HARD FAIL
    local_tag(...)                         and baked       -> ok
    registry_tag(...)                      and not baked   -> WARN (egress)
    rewrite target resolves to neither                     -> WARN, named

A rewrite whose `from` appears in no manifest is also reported: it means the
bundle moved on and the rewrite is now decoration.

exit 0 = no HARD findings; 1 = at least one. WARNs never fail the run.
"""
import json
import os
import re
import sys
import tarfile
from pathlib import Path

HUB = Path(os.environ.get("SWEOPS_HUB", "hub"))
N3 = Path(os.environ.get("SWEOPS_N3", "n3-harbor-task"))

# tags that only ever existed on a build host. `candidate-<slug>-<hash>` is what
# run_resolution_batch builds; the rest are build_operator_images conventions.
LOCAL_TAG_RE = re.compile(r":(srcbuggy|srcfix|buggy|bug|fix|src|local|candidate)[-_:.]",
                          re.IGNORECASE)
IMAGE_RE = re.compile(r"^\s*(?:-\s*)?image:\s*[\"']?([^\"'\s]+)")


def repo_of(ref):
    """image ref -> repo without tag/digest (registry path included)."""
    ref = ref.split("@", 1)[0]
    head, sep, tail = ref.rpartition(":")
    # a ':' after the last '/' is a tag; before it, it's a registry port
    if sep and "/" not in tail:
        return head
    return ref


def tars_in(env):
    d = env / "images"
    if not d.is_dir():
        return []
    return sorted(p for p in d.iterdir() if p.suffix == ".tar")


def baked_tags(env):
    """{tag: tar name} for every image inside images/*.tar (manifest.json)."""
    out = {}
    for tar in tars_in(env):
        try:
            with tarfile.open(tar, "r:*") as tf:
                m = tf.extractfile("manifest.json")
                if not m:
                    continue
                for rec in json.load(m):
                    for t in rec.get("RepoTags") or []:
                        if t and t != "<none>:<none>":
                            out[t] = tar.name
        except Exception as e:            # unreadable tar is itself a finding
            out.setdefault("!UNREADABLE:%s" % tar.name, str(e))
    return out


def yaml_image_refs(env):
    """image refs the seed will apply, per file (seed-materials/*.yaml)."""
    refs = {}
    for f in sorted((env / "seed-materials").rglob("*.yaml")):
        for line in f.read_text(errors="replace").splitlines():
            m = IMAGE_RE.match(line)
            if m:
                refs.setdefault(m.group(1), []).append(f.name)
    return refs


def env_of(slug):
    """Where this case's env lives.

    hub/<slug>/task/environment is the publishable copy and the default. But
    the point of this check is to run BEFORE anything is built, and at that
    moment gen has not created hub/<slug>/task yet -- so fall back to the N3
    env n3ify_b materialized, whose shape is identical (seed.py reads the same
    seed-config.json / seed-materials/ / images/). Without the fallback a
    not-yet-generated case reports "no environment/seed-config.json", which is
    a HARD finding about the wrong thing and says nothing about images.
    """
    for env in (HUB / slug / "task" / "environment",
                N3 / slug / "environment"):
        if (env / "seed-config.json").is_file():
            return env
    return HUB / slug / "task" / "environment"


def check(slug):
    env = env_of(slug)
    cfgp = env / "seed-config.json"
    if not cfgp.is_file():
        # 2-tuple like every other finding: the 3-element one this used to
        # return made main()'s `for slug, msg in all_hard` raise ValueError,
        # so the ONE case that most needs reporting (nothing generated yet)
        # crashed the run instead of printing.
        return [(slug, "no environment/seed-config.json (neither hub/%s/task "
                       "nor n3-harbor-task/%s/environment)" % (slug, slug))], []
    cfg = json.loads(cfgp.read_text())
    hard, warn = [], []

    # ---- seed-materials the config points at must exist --------------------
    sm = env / "seed-materials"
    for step in cfg.get("cr_sequence") or []:
        if step.get("file") and not (sm / step["file"]).is_file():
            hard.append((slug, "cr_sequence file missing: %s" % step["file"]))
    if cfg.get("operator_bundle") and not (sm / cfg["operator_bundle"]).is_file():
        hard.append((slug, "operator_bundle missing: %s" % cfg["operator_bundle"]))
    ts = cfg.get("trigger_script")
    if ts and not (sm / "triggers" / ts).is_file():
        hard.append((slug, "trigger_script missing: triggers/%s" % ts))

    # ---- the image question ------------------------------------------------
    refs = yaml_image_refs(env)
    baked = baked_tags(env)
    baked_names = {t for t in baked if not t.startswith("!")}
    rewrites = [tuple(p) for p in (cfg.get("image_rewrites") or [])]
    rw = dict(rewrites)

    if not tars_in(env):
        warn.append((slug, "images/ is EMPTY -- every non-baked image is an "
                           "egress dependency"))
    if not refs:
        warn.append((slug, "no `image:` refs found in seed-materials"))

    for from_, to in rewrites:
        if from_ not in refs:
            warn.append((slug, "rewrite source unused: %s (bundle moved on?)"
                         % from_))
        if to not in baked_names and repo_of(to) not in {repo_of(b) for b in baked_names}:
            warn.append((slug, "rewrite target not baked: %s" % to))

    for ref, files in sorted(refs.items()):
        eff = rw.get(ref, ref)
        if eff in baked_names:
            continue
        if LOCAL_TAG_RE.search(eff):
            hard.append((slug, "UNPULLABLE image %s (used by %s) -- not in any "
                               "images/*.tar and not a registry tag"
                         % (eff, ", ".join(sorted(set(files))))))
        else:
            warn.append((slug, "runtime pull: %s (used by %s)"
                         % (eff, ", ".join(sorted(set(files))))))
    return hard, warn


def main():
    argv = sys.argv[1:]
    slugs = argv or sorted(p.parent.parent.parent.name
                           for p in HUB.glob("*/task/environment/seed-config.json"))
    all_hard, all_warn = [], []
    for slug in slugs:
        h, w = check(slug)
        all_hard += h
        all_warn += w

    print("scanned %d env(s)" % len(slugs))
    if all_hard:
        print("\nHARD (%d)" % len(all_hard))
        for slug, msg in all_hard:
            print("  %-18s %s" % (slug, msg))
    if all_warn:
        print("\nWARN (%d)" % len(all_warn))
        for slug, msg in all_warn:
            print("  %-18s %s" % (slug, msg))
    if not all_hard:
        print("\nPREFLIGHT OK (no unpullable images, all referenced files present)")
    return 1 if all_hard else 0


if __name__ == "__main__":
    sys.exit(main())
