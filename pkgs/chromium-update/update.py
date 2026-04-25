#! /usr/bin/env nix-shell
#! nix-shell -i python3 -p python3 nix-prefetch-git git
# SPDX-FileCopyrightText: 2026 NeoRobotNix contributors
# SPDX-License-Identifier: MIT
#
# Update script for apks/chromium/info.json.
#
# What this does (analogous to nixpkgs' update.mjs):
# 1. Resolve the requested Chromium version tag to a git rev via gitiles.
# 2. Fetch a depot_tools checkout at a pinned rev (so gclient_eval is
#    importable). Fetched via nix-prefetch-git into a temp dir — not
#    stored in /nix/store at this stage; pinned-rev + hash go into
#    info.json so the actual build uses fetchFromGitiles on the same rev.
# 3. Invoke ./depot_tools.py which walks DEPS (with Android-aware
#    condition vars) and prints a JSON map of every dep as a fetcher
#    record with a dummy hash.
# 4. Fill every dummy hash via a per-fetcher prefetch call. GitilesRepo
#    entries go through nix-build against an expression with a fakeHash
#    — the "got" hash scraped from the stderr becomes the real hash.
#    CIPD and GCS entries go through the same mechanism.
# 5. Write info.json.
#
# Usage:
#   ./update.py --chromium-version 145.0.7632.116
#   ./update.py --chromium-version 145.0.7632.116\
#               --depot-tools-rev fb0b652edba70f5c4ac867f3beca9e535f905b4c
#
# By default, depot_tools and gn revs come from the nixpkgs stable info
# (nixpkgs tracks these per Chromium milestone via its own update.mjs).

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.request import urlopen


HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
INFO_JSON = REPO_ROOT / "apks" / "chromium" / "info.json"

# depot_tools main HEAD 2026-04-24. Newer than what nixpkgs 145 pins,
# because Chromium 148's DEPS uses the CIPD-with-version_file shape that
# older gclient_eval schemas reject.
DEFAULT_DEPOT_TOOLS_REV = "140bbee04c87350f0d797e31aaa3987bd5f40ea8"

CHROMIUM_URL = "https://chromium.googlesource.com/chromium/src.git"
DEPOT_TOOLS_URL = "https://chromium.googlesource.com/chromium/tools/depot_tools.git"

DUMMY_SHA256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="


def resolve_tag(url: str, tag: str) -> str:
    """Resolve a git tag (or branch) to a commit sha via gitiles JSON API."""
    api = f"{url}/+refs/tags/{tag}?format=JSON"
    data = urlopen(api, timeout=60).read()
    # Gitiles prefixes JSON with `)]}'\n` as an anti-XSSI measure.
    text = data.decode("utf-8").lstrip(")]}'\n")
    j = json.loads(text)
    return j[f"refs/tags/{tag}"]["value"]


def sh(cmd: list[str], **kw) -> str:
    print(f"+ {' '.join(cmd)}", file=sys.stderr)
    return subprocess.check_output(cmd, text=True, **kw)


def prefetch_git(url: str, rev: str) -> str:
    """Prefetch a gitiles-sourced tree via fetchFromGitiles and return SRI hash.

    We intentionally don't use nix-prefetch-git here: fetchFromGitiles
    fetches a tarball from the gitiles HTTP API (not a git clone), so
    the resulting store path — and therefore the hash — would differ.
    Instead we try to realize with a dummy hash and scrape the expected
    hash from the stderr.
    """
    expr = f"""
      let
        pkgs = import {REPO_ROOT}/pkgs/default.nix {{}};
      in
        pkgs.fetchFromGitiles {{
          url = "{url}";
          rev = "{rev}";
          hash = "{DUMMY_SHA256}";
        }}
    """
    return _nix_build_capture_got(expr)


def prefetch_cipd(package: str, version: str) -> str:
    expr = f"""
      let
        pkgs = import {REPO_ROOT}/pkgs/default.nix {{}};
      in
        pkgs.fetchcipd {{
          package = "{package}";
          version = "{version}";
          sha256 = "{DUMMY_SHA256}";
        }}
    """
    return _nix_build_capture_got(expr)


def prefetch_gcs(bucket: str, object_name: str) -> str:
    expr = f"""
      let
        pkgs = import {REPO_ROOT}/pkgs/default.nix {{}};
      in
        pkgs.fetchgcs {{
          bucket = "{bucket}";
          object = "{object_name}";
          hash = "{DUMMY_SHA256}";
        }}
    """
    return _nix_build_capture_got(expr)


GOT_RE = re.compile(r"^\s*got:\s*(sha256-[A-Za-z0-9+/=]+)\s*$", re.MULTILINE)


def _nix_build_capture_got(expr: str) -> str:
    try:
        subprocess.run(
            ["nix-build", "--no-out-link", "-E", expr],
            capture_output=True,
            check=True,
            text=True,
        )
    except subprocess.CalledProcessError as e:
        m = GOT_RE.search(e.stderr)
        if m:
            return m.group(1)
        print(e.stderr, file=sys.stderr)
        raise
    # Build succeeded (hash already correct — shouldn't happen for a
    # dummy hash, but still).
    raise RuntimeError("nix-build unexpectedly succeeded with dummy hash")


def fill_hashes(deps: dict) -> dict:
    """Walk deps and fill in real hashes via per-fetcher prefetch.

    Sequential, single-threaded — we tried a thread pool; in practice
    nix-daemon serializes FOD builds behind a shared lock anyway, so
    parallel workers just compete over the same queue while burning RAM
    and occasionally stepping on each other's temp state. One nix-build
    at a time is predictable and easy to resume.
    """
    # Phase 1: instant GCS sha256sum → SRI conversion, in-process.
    for path, dep in deps.items():
        if dep["fetcher"] != "fetchgcs-bundle":
            continue
        for obj in dep["objects"]:
            if obj.get("hash", DUMMY_SHA256) != DUMMY_SHA256:
                continue
            if obj.get("sha256sum"):
                obj["hash"] = sri_from_hex_sha256(obj["sha256sum"])

    # Phase 2: collect tasks for git + cipd + gcs-without-sha256sum.
    tasks = []
    for path, dep in sorted(deps.items()):
        if dep["fetcher"] == "fetchFromGitiles":
            if dep.get("hash", DUMMY_SHA256) != DUMMY_SHA256:
                continue
            tasks.append(("git", path, dep, None))
        elif dep["fetcher"] == "fetchcipd-bundle":
            for i, pkg in enumerate(dep["packages"]):
                if pkg.get("hash", DUMMY_SHA256) != DUMMY_SHA256:
                    continue
                tasks.append(("cipd", path, dep, i))
        elif dep["fetcher"] == "fetchgcs-bundle":
            for i, obj in enumerate(dep["objects"]):
                if obj.get("hash", DUMMY_SHA256) != DUMMY_SHA256:
                    continue
                tasks.append(("gcs", path, dep, i))

    if not tasks:
        return deps

    total = len(tasks)
    print(f"prefetching {total} entries sequentially…", file=sys.stderr)

    for i, task in enumerate(tasks, start=1):
        kind, path, dep, idx = task
        label = f"[{i}/{total}] {kind} {path}"
        try:
            if kind == "git":
                h = prefetch_git(dep["url"], dep["rev"])
                dep["hash"] = h
            elif kind == "cipd":
                pkg = dep["packages"][idx]
                h = prefetch_cipd(pkg["package"], pkg["version"])
                pkg["hash"] = h
            elif kind == "gcs":
                obj = dep["objects"][idx]
                h = prefetch_gcs(dep["bucket"], obj["object_name"])
                obj["hash"] = h
            print(label, file=sys.stderr)
        except Exception as e:
            print(f"{label} FAILED: {e}", file=sys.stderr)
    return deps


def sri_from_hex_sha256(hex_digest: str) -> str:
    import base64

    raw = bytes.fromhex(hex_digest)
    return "sha256-" + base64.b64encode(raw).decode("ascii")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--chromium-version", required=True, help="e.g. 145.0.7632.116")
    ap.add_argument("--depot-tools-rev", default=DEFAULT_DEPOT_TOOLS_REV)
    ap.add_argument(
        "--skip-hash-fill",
        action="store_true",
        help="emit info.json with dummy hashes (fast; useful for iteration)",
    )
    ap.add_argument("-o", "--output", default=str(INFO_JSON))
    args = ap.parse_args()

    print(f"Resolving chromium tag {args.chromium_version}…", file=sys.stderr)
    src_rev = resolve_tag(CHROMIUM_URL, args.chromium_version)
    print(f"  {args.chromium_version} = {src_rev}", file=sys.stderr)

    print(f"Fetching depot_tools @ {args.depot_tools_rev[:12]}…", file=sys.stderr)
    prefetch_json = sh(
        [
            "nix-prefetch-git",
            "--url",
            DEPOT_TOOLS_URL,
            "--rev",
            args.depot_tools_rev,
            "--quiet",
        ]
    )
    depot_tools_dir = Path(json.loads(prefetch_json)["path"])
    print(f"  depot_tools at {depot_tools_dir}", file=sys.stderr)

    print("Resolving DEPS (via gclient_eval)…", file=sys.stderr)
    resolver = HERE / "depot_tools.py"
    deps_json = sh(
        [
            "python3",
            str(resolver),
            str(depot_tools_dir),
            src_rev,
        ]
    )

    deps = json.loads(deps_json)
    print(f"Got {len(deps)} deps", file=sys.stderr)

    if not args.skip_hash_fill:
        print("Filling hashes…", file=sys.stderr)
        deps = fill_hashes(deps)

    info = {
        "chromium": {
            "version": args.chromium_version,
            "rev": src_rev,
        },
        "depot_tools": {
            "rev": args.depot_tools_rev,
        },
        "deps": deps,
    }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        json.dump(info, f, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote {out_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
