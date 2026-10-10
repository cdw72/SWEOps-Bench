#!/usr/bin/env python3
"""Convert the Claude Code role cards (agents/*.md: YAML frontmatter + body)
into Codex custom-agent roles.

Codex reads custom agent roles as TOML from $CODEX_HOME/agents/*.toml, with the
required fields `name`, `description` and `developer_instructions`. The .md
cards are the single source of truth; this script derives the .toml twins.

    usage: md2codex.py <src_agents_dir> <out_dir>
"""
import json
import os
import sys


def parse_card(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if not text.startswith("---"):
        raise SystemExit("%s: missing YAML frontmatter" % path)
    end = text.index("\n---", 3)
    front = {}
    for line in text[3:end].strip().splitlines():
        key, _, value = line.partition(":")
        front[key.strip()] = value.strip()
    for field in ("name", "description"):
        if not front.get(field):
            raise SystemExit("%s: frontmatter is missing `%s`" % (path, field))
    body = text[end + 4:].lstrip("\n")
    return front["name"], front["description"], body


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__.strip().splitlines()[-1])
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    written = []
    for name in sorted(os.listdir(src)):
        if not name.endswith(".md"):
            continue
        role, description, body = parse_card(os.path.join(src, name))
        dest = os.path.join(out, name[:-3] + ".toml")
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write("# Generated from agents/%s by agents/md2codex.py.\n" % name)
            fh.write("# Edit the .md card, not this file.\n")
            fh.write("name = %s\n" % json.dumps(role, ensure_ascii=False))
            fh.write("description = %s\n" % json.dumps(description, ensure_ascii=False))
            fh.write("developer_instructions = %s\n" % json.dumps(body, ensure_ascii=False))
        written.append(dest)
    print("[md2codex] wrote %d codex agent role(s) into %s" % (len(written), out))


if __name__ == "__main__":
    main()
