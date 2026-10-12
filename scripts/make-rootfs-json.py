#!/usr/bin/env python3
"""Generate a Droidspaces `rootfs.json` feed from the tarballs in out/.

The Droidspaces Android app can subscribe to any HTTPS URL that serves a
`rootfs.json` array (Containers -> Manage Repositories). Point --base-url at
wherever you upload the tarballs (a GitHub release, your own web server, ...).

    ./scripts/make-rootfs-json.py --base-url https://example.com/ds
    ./scripts/make-rootfs-json.py --base-url https://example.com/ds -o out/rootfs.json
"""
import argparse
import glob
import hashlib
import json
import os
import re
import shlex
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAME_RE = re.compile(r"^(?P<name>.+)-Droidspaces-rootfs-(?P<arch>[^-]+)-(?P<date>\d{8})-(?P<version>.+)\.tar\.xz$")


def parse_labels(path):
    text = open(path, encoding="utf-8").read().replace("\\\n", " ")
    labels = {}
    for line in text.splitlines():
        line = line.strip()
        if not line.upper().startswith("LABEL "):
            continue
        for tok in shlex.split(line[6:]):
            key, _, value = tok.partition("=")
            if key.startswith("droidspaces."):
                labels[key[len("droidspaces.") :]] = value
    return labels


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True, help="base URL the tarballs are served from")
    ap.add_argument("--dir", default=os.path.join(ROOT, "out"),
                    help="directory holding the *.tar.xz files (default: out/)")
    ap.add_argument("-o", "--output", default=os.path.join(ROOT, "rootfs.json"))
    ap.add_argument("--no-sha256", action="store_true", help="skip hashing (fast, for previews)")
    args = ap.parse_args()

    base = args.base_url.rstrip("/")
    entries = []
    for tarball in sorted(glob.glob(os.path.join(args.dir, "*.tar.xz"))):
        base_name = os.path.basename(tarball)
        m = NAME_RE.match(base_name)
        if not m:
            print(f"skip (unexpected name): {base_name}", file=sys.stderr)
            continue
        name, arch = m.group("name"), m.group("arch")
        template = os.path.join(ROOT, "templates", arch, f"{name}.Dockerfile")
        labels = parse_labels(template) if os.path.isfile(template) else {}
        entry = {
            "author": labels.get("author", "unknown"),
            "name": labels.get("name", name),
            "distro": labels.get("distro", "Debian"),
            "description": labels.get("description", ""),
            "architecture": arch,
            "file": name,
            "download_url": f"{base}/{base_name}",
            "sha256": "" if args.no_sha256 else sha256(tarball),
            "size_bytes": os.path.getsize(tarball),
            "version": m.group("version"),
            "build_date": m.group("date"),
        }
        for key, value in labels.items():
            if key not in ("name", "distro", "description", "author"):
                entry[key] = value
        entries.append(entry)

    if not entries:
        print(f"no tarballs in {args.dir} -- run ./build.sh first", file=sys.stderr)
        return 1
    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(entries, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    print(f"wrote {args.output} ({len(entries)} entries)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
