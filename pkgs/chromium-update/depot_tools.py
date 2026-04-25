#! /usr/bin/env nix-shell
#! nix-shell -i python3 -p python3
# SPDX-FileCopyrightText: 2026 NeoRobotNix contributors
# SPDX-License-Identifier: MIT
#
# Chromium DEPS resolver for Android builds. Based on nixpkgs'
# depot_tools.py (~120 lines, git-only, Linux desktop) but extended to
# also emit CIPD and GCS entries — needed for Trichrome/WebView builds
# which pull in the Android NDK, Android SDK build-tools, and AFDO
# profiles through those dep types.
#
# Called by update.py. Not intended to be invoked manually.
#
# Usage:
#   depot_tools.py <depot_tools_checkout> <chromium_src_rev>
#
# Writes a JSON map { "src/path/foo": {fetcher, url, rev, hash, ...} }
# to stdout. Hashes are all dummies (sha256-AAAA…); update.py fills
# them in via nix-build FOD rounds.

from __future__ import annotations

import base64
import json
import sys
from typing import Optional
from urllib.request import urlopen


DUMMY_SHA256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="


if len(sys.argv) != 3:
    print(
        "usage: depot_tools.py <depot_tools_checkout> <chromium_src_rev>",
        file=sys.stderr,
    )
    sys.exit(1)

depot_tools_checkout, chromium_src_rev = sys.argv[1:]

sys.path.append(depot_tools_checkout)
import gclient_eval  # type: ignore  # noqa: E402
import gclient_utils  # type: ignore  # noqa: E402


# Condition vars used to evaluate DEPS `condition` expressions.
# We want the Android + Linux-host union so that:
#   - Android-only deps (NDK, Android SDK build-tools) are included
#   - Linux-host-only deps (gn, clang, build helpers) are included
#   - iOS/Mac/Win/ChromeOS/Fuchsia/Cast3P deps are excluded
#   - All 4 Android ABIs are covered (arm, arm64, x86, x64)
ANDROID_CONDITION_VARS = {
    "checkout_android": True,
    "checkout_android_prebuilts_build_tools": True,
    "checkout_android_native_support": True,
    "checkout_linux": True,  # host
    "checkout_chromeos": False,
    "checkout_fuchsia": False,
    "checkout_ios": False,
    "checkout_ios_webkit": False,
    "checkout_mac": False,
    "checkout_win": False,
    "checkout_src_internal": False,
    "checkout_copybara": False,
    "checkout_nacl": False,
    "checkout_openxr": False,
    "checkout_google_benchmark": False,
    "checkout_cast3p": False,
    "checkout_fuchsia_internal": False,
    "checkout_fuchsia_internal_images": "",
    "checkout_fuchsia_no_hooks": False,
    "checkout_chromium_autofill_test_dependencies": False,
    "checkout_chromium_password_manager_test_dependencies": False,
    "checkout_clang_coverage_tools": False,
    "checkout_clang_tidy": False,
    "checkout_clangd": False,
    "checkout_rust_toolchain_deps": True,
    "checkout_traffic_annotation_tools": False,
    "checkout_mobile_internal": False,
    "checkout_instrumented_libraries": False,
    "checkout_wpr_archives": False,
    "checkout_js_coverage_tools": False,
    # Architectures — enable all so we don't drop deps needed by any
    # target_cpu the downstream build might pick.
    "checkout_arm": True,
    "checkout_arm64": True,
    "checkout_x86": True,
    "checkout_x64": True,
    "checkout_mips": False,
    "checkout_mips64": False,
    "checkout_ppc": False,
    "checkout_riscv64": False,
    "checkout_s390": False,
    # Platform identification vars depot_tools sets from the host.
    "host_os": "linux",
    "host_cpu": "x64",
    # Misc.
    "checkout_configuration": "default",
    "build_with_chromium": True,
    "generate_location_tags": False,
    "cros_boards": "",
    "cros_boards_with_qemu_images": "",
}


class Repo:
    fetcher: str
    args: dict

    def __init__(self) -> None:
        self.deps: dict = {}
        self.hash = DUMMY_SHA256

    def get_deps(self, repo_vars: dict, path: str) -> None:
        print(
            f"resolving DEPS at {path} ({self.args.get('rev', '?')[:12]})",
            file=sys.stderr,
        )

        try:
            deps_file = self.get_file("DEPS")
        except Exception as e:
            print(f"  no DEPS at {path} ({e}); stopping recursion", file=sys.stderr)
            return

        # newer DEPS files set 'non_git_source' via a var some CIPD entries
        # condition on. It's not exposed via builtin_vars, so inject it.
        eval_vars = dict(repo_vars)
        eval_vars.setdefault("non_git_source", True)

        evaluated = gclient_eval.Parse(
            deps_file, vars_override=eval_vars, filename="DEPS"
        )

        # The DEPS file's own `vars` block provides defaults; caller-supplied
        # vars (eval_vars) override them.
        merged_vars = dict(evaluated.get("vars", {}))
        merged_vars.update(eval_vars)

        prefix = f"{path}/" if evaluated.get("use_relative_paths", False) else ""

        for dep_name, dep in evaluated.get("deps", {}).items():
            full_path = prefix + dep_name
            if "condition" in dep:
                if not gclient_eval.EvaluateCondition(dep["condition"], merged_vars):
                    continue
            # version_file: post-M147ish, CIPD packages can have their
            # version pinned via a text file under src/ instead of inline.
            # Resolve it via gitiles right now so CipdRepo sees a concrete
            # version string. Feels like the right layer: the DEPS author
            # wanted us to read a sibling file in the same tree, which is
            # exactly what `self.get_file` is for.
            if dep.get("dep_type") == "cipd":
                for pkg in dep.get("packages", []):
                    if "version_file" in pkg and "version" not in pkg:
                        try:
                            pkg["version"] = self.get_file(pkg["version_file"]).strip()
                        except Exception as e:
                            print(
                                f"  WARN: cannot resolve version_file {pkg['version_file']} "
                                f"for {full_path}: {e}",
                                file=sys.stderr,
                            )
                            # Keep the original; repo_from_dep will skip it below.
                    # Substitute gclient CIPD template vars (${platform},
                    # ${arch}, ${os}) which gclient normally renders as
                    # part of `gclient flatten` but gclient_eval.Parse
                    # leaves verbatim. Values are for the HOST running
                    # the build (Linux x86_64); Android per-ABI packages
                    # have their ABI baked into the package path already.
                    if "package" in pkg:
                        pkg["package"] = (
                            pkg["package"]
                            .replace("${platform}", "linux-amd64")
                            .replace("${arch}", "amd64")
                            .replace("${os}", "linux")
                        )
            repo = repo_from_dep(dep)
            if repo is not None:
                self.deps[full_path] = repo

        for key in evaluated.get("recursedeps", []):
            dep_path = prefix + key
            if dep_path in self.deps and isinstance(self.deps[dep_path], GitilesRepo):
                self.deps[dep_path].get_deps(merged_vars, dep_path)

    def flatten_repr(self) -> dict:
        return {"fetcher": self.fetcher, **self.args}

    def flatten(self, path: str) -> dict:
        out = {path: self.flatten_repr()}
        for dep_path, dep in self.deps.items():
            out.update(dep.flatten(dep_path))
        return out

    def get_file(self, filepath: str) -> str:
        raise NotImplementedError


class GitilesRepo(Repo):
    def __init__(self, url: str, rev: str) -> None:
        super().__init__()
        self.fetcher = "fetchFromGitiles"
        self.args = {
            "url": url,
            "rev": rev,
            "hash": DUMMY_SHA256,
        }

    def get_file(self, filepath: str) -> str:
        url = f"{self.args['url']}/+/{self.args['rev']}/{filepath}?format=TEXT"
        try:
            data = urlopen(url, timeout=60).read()
        except Exception as e:
            raise RuntimeError(f"failed to fetch {url}: {e}") from e
        return base64.b64decode(data).decode("utf-8")


class CipdRepo(Repo):
    """A CIPD multi-package entry flattened into one-per-package records.

    Chromium DEPS allows multiple cipd packages under a single path (a
    bundle). We emit one JSON record per (path, package) pair with the
    subpath appended, and downstream the Nix side symlinks them into
    a single directory per path.
    """

    def __init__(self, packages: list[dict]) -> None:
        super().__init__()
        self.fetcher = "fetchcipd-bundle"
        # Skip any packages that still have no concrete version — could
        # not resolve a version_file, or malformed DEPS. They'll simply
        # not appear in the output; downstream layout handles that.
        self.args = {
            "packages": [
                {"package": p["package"], "version": p["version"], "hash": DUMMY_SHA256}
                for p in packages
                if "version" in p
            ],
        }


class GcsRepo(Repo):
    def __init__(self, bucket: str, objects: list[dict]) -> None:
        super().__init__()
        self.fetcher = "fetchgcs-bundle"
        self.args = {
            "bucket": bucket,
            "objects": [
                {
                    "object_name": o["object_name"],
                    # DEPS lists sha256 as a hex digest; keep it as-is
                    # and convert to SRI-style on the Nix side.
                    "sha256sum": o.get("sha256sum", ""),
                    "size_bytes": o.get("size_bytes", 0),
                    "generation": o.get("generation", 0),
                }
                for o in objects
            ],
        }


def repo_from_dep(dep: dict) -> Optional[Repo]:
    dep_type = dep.get("dep_type", "git")
    if dep_type == "git" or "url" in dep:
        url, rev = gclient_utils.SplitUrlRevision(dep["url"])
        return GitilesRepo(url, rev)
    elif dep_type == "cipd":
        repo = CipdRepo(dep["packages"])
        if not repo.args["packages"]:
            return None  # All packages lacked a concrete version.
        return repo
    elif dep_type == "gcs":
        return GcsRepo(dep["bucket"], dep.get("objects", []))
    else:
        print(f"warning: unknown dep_type {dep_type!r}, skipping", file=sys.stderr)
        return None


chromium = GitilesRepo(
    "https://chromium.googlesource.com/chromium/src.git",
    chromium_src_rev,
)
chromium.get_deps(ANDROID_CONDITION_VARS, "src")
print(json.dumps(chromium.flatten("src"), indent=2, sort_keys=True))
