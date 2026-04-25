# SPDX-FileCopyrightText: 2020 Daniel Fullmer and robotnix contributors
# SPDX-License-Identifier: MIT

{ pkgs }:
with pkgs;
# FHS env for Chromium/Trichrome Android build. Modern Chromium (M141+)
# needs Rust on the host, and its Python scripts expect a standard
# FHS-shaped filesystem. We wrap everything in buildFHSEnv so the
# prebuilt CIPD toolchain (GN, Android NDK, etc.) can execute without
# patchelf massaging.
buildFHSEnv {
  name = "chromium-fhs";
  targetPkgs =
    pkgs: with pkgs; [
      # JDK: Chromium M141+ needs JDK 17 for Android build tools
      jdk17

      # Python: required by Chromium and depot_tools hooks.
      # httplib2 is referenced by download_from_google_storage; ply/jinja2/setuptools
      # are used by mojo/protobuf codegen and the resource compiler.
      (python3.withPackages (
        p: with p; [
          httplib2
          ply
          jinja2
          setuptools
          six
          pyyaml
        ]
      ))

      # Node.js: used by devtools-frontend, build tooling. Pinned via CIPD in
      # DEPS, but we still need a host node somewhere for environment setup.
      nodejs

      # Rust: Chromium M141+ requires Rust; M144+ uses rustfmt.
      # We use the nixpkgs Rust toolchain instead of the bundled one.
      rustc
      cargo
      rust-bindgen
      rustfmt

      # LLVM: Chromium's build needs a matching LLVM for cross-compile +
      # host-tool compilation. rustc.llvmPackages pulls the one matched
      # with nixpkgs' Rust.
      rustc.llvmPackages.llvm
      rustc.llvmPackages.clang
      rustc.llvmPackages.bintools

      # Build tools
      ninja # invoked inside the FHS env by the buildPhase
      glibc_multi.dev # Needs unistd.h
      glibc.dev
      libkrb5.dev
      libkrb5
      ncurses5
      libxml2
      zstd
      pkg-config
      bison
      gperf
      perl
      which
      binutils
      # gcc + its runtime so Chromium's bundled clang can find -lgcc,
      # crtbeginS.o, crtendS.o at the standard /usr/lib/gcc/<triple>/...
      # paths when linking host-side build tools like protoc-gen-js.
      gcc
      stdenv.cc.cc.lib # libgcc_s.so.1 and friends

      # Android SDK tools (minimal host interaction; most come from CIPD in DEPS)
      # No explicit androidPkgs here — the build derivation passes them in as
      # inputs where actually needed (aapt2, bundletool, zipalign).
    ];
  multiPkgs =
    pkgs: with pkgs; [
      zlib
      ncurses5
      gcc
      libgcc # Needed by their clang toolchain
    ];
}
