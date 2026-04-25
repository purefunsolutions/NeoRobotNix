# SPDX-FileCopyrightText: 2020 Daniel Fullmer and robotnix contributors
# SPDX-License-Identifier: MIT

{
  pkgs,
  callPackage,
  stdenv,
  stdenvNoCC,
  lib,
  fetchFromGitiles,
  fetchurl,
  fetchcipd,
  fetchgcs,
  runCommand,
  symlinkJoin,
  autoPatchelfHook,
  buildPackages,
  python3,
  ninja,
  nodejs,
  jdk17,
  bison,
  gperf,
  pkg-config,
  dbus,
  at-spi2-atk,
  atk,
  at-spi2-core,
  nspr,
  nss,
  pciutils,
  util-linux,
  libkrb5,
  gdk-pixbuf,
  glib,
  gtk3,
  alsa-lib,
  libXScrnSaver,
  libXcursor,
  libXtst,
  libXdamage,
  libdrm,
  libxkbcommon,
  zstd,
  binutils,
  perl,
  rustc,
  rust-bindgen,
  rustfmt,
  systemdLibs,
  cups,
  expat,
  libevdev,
  libgbm,
  libglvnd,
  libva,
  pipewire,
  wayland,
  mesa,
  libffi,
  libpulseaudio,
  speechd-minimal,

  name ? "chromium",
  displayName ? "Chromium",
  enableRebranding ? false,
  enableWidevine ? false,
  enableSecondaryAbi ? true,
  customGnFlags ? { },
  targetCPU ? "arm64",
  # Default to the Trichrome shared library — smaller and faster to build
  # than the full Chrome bundle; good first target to validate the toolchain.
  # Module-level chromium.nix overrides this with the full trichrome set.
  buildTargets ? [ "trichrome_library_apk" ],
  packageName ? "org.chromium.chrome",
  webviewPackageName ? "com.android.webview",
  trichromeLibraryPackageName ? "org.chromium.trichromelibrary",
  # Pinned by info.json; passed as override for Vanadium (which keeps its own
  # version alignment) — otherwise use whatever info.json says.
  version ? null,
  versionCode ? null,
  depsOverrides ? { },
  infoJson ? ./info.json,
}:

let
  info = builtins.fromJSON (builtins.readFile infoJson);
  _version = if version != null then version else info.chromium.version;

  _versionCode =
    let
      parts = builtins.splitVersion _version;
      minor = lib.fixedWidthString 4 "0" (builtins.elemAt parts 2);
      patch = lib.fixedWidthString 3 "0" (builtins.elemAt parts 3);
    in
    if (versionCode != null) then versionCode else "${minor}${patch}00";

  buildenv = import ./buildenv.nix { inherit pkgs; };

  # Unified source tree assembled from info.json. See apks/chromium/src.nix.
  src = callPackage ./src.nix {
    inherit infoJson;
  };

  # gn is prebuilt and shipped via CIPD in DEPS. src.nix lays it down at
  # src/buildtools/linux64/gn, but it needs autoPatchelf to reference
  # nixpkgs' glibc/libstdc++ rather than the Ubuntu paths the CIPD build
  # was linked against. Extract + patch once, add to PATH for gn gen.
  gn = stdenv.mkDerivation {
    name = "chromium-gn";
    src = src.fetchedDeps."src/buildtools/linux64";
    nativeBuildInputs = [ autoPatchelfHook ];
    dontBuild = true;
    installPhase = ''
      install -Dm755 gn $out/bin/gn
    '';
  };

  # Symlink-joined Rust toolchain: rustc provides the stdlib; rust-bindgen
  # and rustfmt are used by Chromium's build as required by rust_bindgen_root.
  # We stage them into one prefix so `rust_bindgen_root` has bin/bindgen,
  # bin/rustfmt, etc. under a single path (matching Chromium's expectation).
  rustTools = symlinkJoin {
    name = "chromium-rust-tools";
    paths = [
      rust-bindgen
      rustfmt
    ];
  };

  # For Android builds we use Chromium's bundled clang (fetched via GCS in
  # DEPS at src/third_party/llvm-build/Release+Asserts/), not nixpkgs' LLVM.
  # Reasons: (1) compiler-rt runtime libs for every Android ABI
  # (aarch64-android, arm-android, i686-android, x86_64-android) are only
  # shipped with the bundled distribution — building them in nixpkgs would
  # be a large undertaking. (2) Chromium encodes its clang major version
  # (currently 23) in many BUILD.gn paths, so matching that cleanly means
  # using the version it expects. Bindings/wrappers around Rust still use
  # nixpkgs rustc via rust_sysroot_absolute; only the C++/Rust linker
  # runtime dependencies are satisfied by the bundled clang tree.

  # Serialize Nix types into GN types according to
  # https://gn.googlesource.com/gn/+/refs/heads/main/docs/language.md
  gnToString =
    let
      mkGnString = value: "\"${lib.escape [ "\"" "$" "\\" ] value}\"";
      sanitize =
        value:
        if value == true then
          "true"
        else if value == false then
          "false"
        else if lib.isList value then
          "[${lib.concatMapStringsSep ", " sanitize value}]"
        else if lib.isInt value then
          toString value
        else if lib.isString value then
          mkGnString value
        else
          throw "Unsupported type for GN value `${value}'.";
      toFlag = key: value: "${key}=${sanitize value}";
    in
    attrs: lib.concatStringsSep " " (lib.attrValues (lib.mapAttrs toFlag attrs));

  gnFlags = {
    # Android target
    target_os = "android";
    target_cpu = targetCPU;
    android_channel = "stable";
    android_default_version_name = _version;
    android_default_version_code = _versionCode;
    chrome_public_manifest_package = packageName;
    system_webview_package_name = webviewPackageName;
    trichrome_library_package = trichromeLibraryPackageName;

    # Host toolchain (for build-side tools like protoc, mojo_parser, etc.)
    host_cpu =
      {
        i686-linux = "x86";
        x86_64-linux = "x64";
        armv7l-linux = "arm";
        aarch64-linux = "arm64";
      }
      .${stdenv.buildPlatform.system};

    # Host toolchain (for protoc-gen-js and other build-time tools): route
    # through the unbundle:host toolchain so Chromium uses nixpkgs' clang +
    # ld.lld with compiler-rt runtime (matches cc-wrapper env vars below).
    # `custom_toolchain` (the "target" in Chromium parlance) stays as
    # Chromium's default Android toolchain, so Android code still builds
    # with the NDK/Chromium clang for the aarch64 ABI.
    host_toolchain = "//build/toolchain/linux/unbundle:host";
    v8_snapshot_toolchain = "//build/toolchain/linux/unbundle:host";

    # Product flavor
    is_official_build = true;
    is_debug = false;
    is_component_build = false;
    is_clang = true;
    clang_use_chrome_plugins = false;
    treat_warnings_as_errors = false;
    use_sysroot = false;
    # Chromium 148 removed the enable_nacl declare_args — setting it here
    # would trigger "Build argument has no effect" warning. NaCl is gone.
    symbol_level = 1;
    blink_symbol_level = 1;
    disable_fieldtrial_testing_config = true;

    # Disable things we don't want/need on Android Trichrome
    use_gnome_keyring = false;
    enable_vr = false;
    # `enable_vr = false` alone isn't enough in M148: Android's WebXR
    # Java code still compiles unless we also turn off the feature flags
    # that route WebXR's generate_jni targets into the monochrome lib.
    # Without these three, libmonochrome_64__jni_registration fails with
    # "Excess Java files: ArCoreInstallUtils.java / CardboardUtils.java
    # / XrActivityListener.java / XrSessionCoordinator.java".
    enable_cardboard = false;
    enable_arcore = false;
    enable_openxr = false;
    enable_remoting = false;
    enable_reporting = true;
    chrome_pgo_phase = 0;
    # With chrome_pgo_phase=0 && is_android && !is_high_end_android,
    # Chromium falls back to a default AFDO sample profile at
    # chrome/android/profiles/afdo.prof, which is normally fetched via
    # a gclient hook. We don't run hooks, so disable the default profile
    # entirely — the resulting binary is a bit less optimized but builds.
    clang_use_default_sample_profile = false;

    # Widevine DRM: always enable the build path — Chromium 148's
    # Android code (components/cdm/renderer/key_system_support_update.cc)
    # unconditionally references `kWidevineKeySystem` within an
    # `#if BUILDFLAG(IS_ANDROID)` block, so `enable_widevine = false`
    # produces an undeclared-identifier build error rather than a
    # graceful no-build of the Widevine path. The user-facing
    # `apps.chromium.enableWidevine` option is documentation/future-
    # reserved — toggling it on/off doesn't change the resulting binary
    # today. Turning on the feature here doesn't pull any CDM .so into
    # the build: on Android, Widevine flows through MediaDrm which the
    # device's own vendor partition provides (or doesn't).
    enable_widevine = true;

    # Secondary ABI: pack a 32-bit (arm) sidecar library into the
    # Trichrome bundle alongside the 64-bit (arm64) primary, so devices
    # with 32-bit-only apps can keep using a Chromium-backed WebView.
    # Defaults to true via `apps.chromium.enableSecondaryAbi`. Turning
    # this off cuts compile time roughly in half and produces a
    # 64-only `TrichromeChrome.aab` instead of `TrichromeChrome6432.aab`.
    # See: chromium-148-v8-secondary-abi-torque.patch — this build path
    # is the one the per-ABI torque fix exists for.
    enable_android_secondary_abi = enableSecondaryAbi;

    # Codecs
    proprietary_codecs = true;
    ffmpeg_branding = "Chrome";

    # Use the bundled clang extracted from DEPS. We could set `clang_base_path`
    # explicitly, but leaving it to the build default (`//third_party/llvm-build/
    # Release+Asserts/`) lets postPatch place a ready-to-use tree there.
    # Keep clang modules off — safer cross-ver compat even with bundled clang.
    use_clang_modules = false;
    # Chromium's bundled libffi builds a _pic.a variant that we don't
    # ship from nixpkgs' libffi. Tell Chromium to use system libffi,
    # same workaround nixpkgs/common.nix uses.
    use_system_libffi = true;
    # Use Chromium's bundled Rust toolchain (extracted in postPatch to
    # third_party/rust-toolchain/): its stdlib is pre-built for every
    # Android ABI (aarch64-linux-android, armv7-linux-androideabi, etc.).
    # nixpkgs' rustc doesn't ship those target stdlibs. Leaving
    # rust_sysroot_absolute unset makes GN's `use_chromium_rust_toolchain`
    # evaluate true, which routes compilation through //third_party/rust-
    # toolchain. rust_bindgen_root also points there (bundled LLVM-23
    # libclang matches Chromium's compile flags).
    rust_bindgen_root = "//third_party/rust-toolchain";
    enable_rust = true;
  } // customGnFlags;

in
# Use rustc's matched LLVM stdenv so cc-wrapper provides CC/CXX/AR/NM/READELF
# env vars. Chromium's unbundle:host toolchain reads these for host-side
# build tools (protoc-gen-js, etc.), and Chromium's "no-lgcc" linking
# behavior needs a proper clang wrapper, not just a bundled clang binary.
rustc.llvmPackages.stdenv.mkDerivation {
  pname = name;
  version = _version;
  inherit src;

  nativeBuildInputs = [
    gn
    ninja
    pkg-config
    jdk17
    gperf
    bison
    nodejs
    (python3.withPackages (
      p: with p; [
        ply
        jinja2
        setuptools
        httplib2
        six
        pyyaml
      ]
    ))
    binutils # Needs readelf
    perl # Used by //third_party/libvpx
    zstd
    buildenv
    # Rust toolchain on PATH. cargo is not needed — Chromium uses rustc
    # directly against vendored crates, no Cargo workspace.
    rustc
    rust-bindgen
    rustfmt
  ];

  # Even though we target Android, GN still complains if host-side libs
  # aren't visible during config/build.
  buildInputs = [
    dbus
    at-spi2-atk
    atk
    at-spi2-core
    nspr
    nss
    pciutils
    util-linux
    libkrb5
    libxkbcommon
    gdk-pixbuf
    glib
    gtk3
    alsa-lib
    libXScrnSaver
    libXcursor
    libXtst
    libXdamage
    libdrm
    systemdLibs # provides libudev via pkg-config; chromium's device-service needs it
    cups # libcups for print-preview (referenced by //printing)
    expat # pkg-config expat
    libevdev # input device APIs
    libgbm # pkg-config gbm (mesa graphics buffer manager) — host-side GPU stack
    libglvnd # EGL/GL
    libva # video acceleration
    pipewire # screen capture, WebRTC audio
    wayland # wayland client headers referenced by ui/
    mesa # EGL headers
    libffi # use_system_libffi = true picks this up
    libpulseaudio # pulse_stubs.cc includes <pulse/pulseaudio.h>
    speechd-minimal # speech-dispatcher for tts stubs
  ];

  requiredSystemFeatures = [ "big-parallel" ];

  # Chromium expects nightly/bleeding edge rustc features to be
  # available. Nixpkgs' rustc follows stable; RUSTC_BOOTSTRAP=1 is the
  # canonical way to enable nightly features on stable toolchains.
  env.RUSTC_BOOTSTRAP = 1;
  # Chromium's Clang is always newer than ours; these options mute
  # warnings that would otherwise generate log-bloat / build failures.
  env.NIX_CFLAGS_COMPILE = "-Wno-unknown-warning-option -Wno-unused-command-line-argument -Wno-shadow";
  # Host-side build-tools (protoc-gen-js, bindgen callees, etc.) compile
  # with the nixpkgs cc-wrapper clang from rustc.llvmPackages.stdenv
  # ($CC/$CXX). cc-wrapper handles sysroot and lib paths, solving
  # crtbeginS.o / -lgcc / -lm automatically. LLVM-23-only compile flags
  # Chromium emits are stripped in postPatch so clang 21 accepts them.
  # cross-compile.patch from nixpkgs wires BUILD_* into unbundle:host.
  env.BUILD_CC = "$CC";
  env.BUILD_CXX = "$CXX";
  env.BUILD_AR = "$AR";
  env.BUILD_NM = "$NM";
  env.BUILD_READELF = "$READELF";

  patchFlags = [
    "-p1"
    "-d src"
  ];

  patches = [
    # Allow Node.js versions >= required instead of exact match.
    ./patches/chromium-136-nodejs-assert-minimal-version-instead-of-exact-match.patch
    # Use SOURCE_DATE_EPOCH for reproducibility.
    ./patches/no-build-timestamps.patch
    # Cross-compile fixes (READELF env var, etc.)
    ./patches/cross-compile.patch
    # Fix arm32 secondary ABI V8 torque mismatch: route arm32 run_torque
    # to a second torque binary built with v8_current_cpu="arm" so the
    # emitted torque-generated/ tree matches arm32 V8's compile-time
    # V8_ENABLE_SANDBOX=0 / pointer-compression=0 configuration.
    ./patches/chromium-148-v8-secondary-abi-torque.patch
  ];
  # Other Rust-related nixpkgs patches are intentionally omitted for M148:
  # - chromium-144-rustc_nightly_capability: 148's
  #   `rustc_nightly_capability = use_chromium_rust_toolchain || build_with_chromium`
  #   already evaluates `true` for us, so the patch's force-to-true edit is a
  #   no-op.
  # - chromium-141-rust: removes a compiler_builtins config line that moved
  #   from ~1911 to ~2039 between M141 and M148, causing the patch to reject.
  #   Revisit if link errors show up.
  # - chromium-134-rust-1.86-mismatched_lifetime_syntaxes: the anchor line it
  #   targets (`rustenv = _rustenv` at 285) moved to ~316 in M148 inside a
  #   different nesting. We inject the `-Amismatched_lifetime_syntaxes`
  #   rustflag in postPatch via sed instead — more robust to line-number
  #   drift than a context-sensitive diff.

  postPatch = ''
        ( cd src

          # Extract the Linux_x64 Rust toolchain tarball fetched via GCS into
          # the layout Chromium's build expects (bin/rustc etc.). gclient's
          # fetch_and_extract_rust_toolchain.py would do this; since we skip
          # hooks, we do it ourselves. rust_sysroot_absolute still points at
          # nixpkgs' rustc; Chromium's phony "rust_bin_inputs" dep group just
          # needs these files to exist on disk.
          for xz in third_party/rust-toolchain/Linux_x64/rust-toolchain-*.tar.xz; do
            [ -f "$xz" ] || continue
            tar -xf "$xz" -C third_party/rust-toolchain/
          done

          # Extract Chromium's bundled clang (which ships compiler-rt for every
          # Android ABI) into third_party/llvm-build/Release+Asserts/. Without
          # this, ninja fails on missing libclang_rt.builtins-<abi>-android.a.
          # The tarball comes from the GCS bundle landed at
          # third_party/llvm-build/Release+Asserts/Linux_x64/clang-*.tar.xz.
          for xz in third_party/llvm-build/Release+Asserts/Linux_x64/clang-*.tar.xz; do
            [ -f "$xz" ] || continue
            tar -xf "$xz" -C third_party/llvm-build/Release+Asserts/
          done

          # Patch out LLVM-23-only flags from Chromium's BUILD.gn so our
          # nixpkgs Clang 21 can compile the host toolchain. Chromium's
          # compile-time flags aren't recognized by our older Clang major
          # (they're only in Chromium's llvmorg-23-init fork).
          #
          # We also drop the `-fsanitize=array-bounds/return` checks entirely
          # for the host toolchain. Their `-fsanitize-ignore-for-ubsan-feature=*`
          # companion flags (which tell Clang not to treat these as
          # "undefined_behavior_sanitizer" from __has_feature's perspective)
          # are 23-only, so we can't keep them. Without the ignore flags,
          # V8 sees `__has_feature(undefined_behavior_sanitizer)` as true and
          # pulls in the ubsan runtime (`__sanitizer_set_death_callback`),
          # which isn't present in our host-side link. Dropping the sanitizer
          # options entirely avoids both mismatches.
          substituteInPlace build/config/compiler/BUILD.gn \
            --replace '"-fno-lifetime-dse"' '""' \
            --replace '"-fsanitize=array-bounds",' ' ' \
            --replace '"-fsanitize-trap=array-bounds",' ' ' \
            --replace '"-fsanitize-ignore-for-ubsan-feature=array-bounds",' ' ' \
            --replace '"-fsanitize=return",' ' ' \
            --replace '"-fsanitize-trap=return",' ' ' \
            --replace '"-fsanitize-ignore-for-ubsan-feature=return",' ' ' \
            --replace '"-Wa,--crel,--allow-experimental-crel"' '""'

          # Android NDK 28+ no longer ships libatomic.a — atomics are folded
          # into libclang_rt.builtins. Drop the `libs += [ "atomic" ]` that
          # base/BUILD.gn adds for is_android + !use_sysroot (which is our
          # config). Without this, ld.lld fails on `-latomic` when linking
          # libcrashpad_handler_trampoline.so and other target Android .so.
          substituteInPlace base/BUILD.gn \
            --replace 'libs += [ "atomic" ]' '# libs += [ "atomic" ] # (NDK 28+)'

          # Extract the node_modules tarball (named by its sha1) into place.
          # Chromium's update_node_modules.py hook would normally do this; since
          # we skip hooks, extract manually. Same pattern for the Linux node
          # binary tarball.
          for nm in third_party/node/node_modules/*; do
            case "$nm" in *.tar.gz|*.tar.xz|*.tar|*.tar.bz2) continue ;; esac
            if [ -f "$nm" ] && head -c 2 "$nm" | od -An -tx1 | grep -q '1f 8b'; then
              tar -xzf "$nm" -C third_party/node/node_modules/ && rm "$nm"
            fi
          done
          for nm in third_party/node/linux/*; do
            if [ -f "$nm" ] && head -c 2 "$nm" | od -An -tx1 | grep -q '1f 8b'; then
              tar -xzf "$nm" -C third_party/node/linux/ && rm "$nm"
            fi
          done

          # devtools-frontend ships its own node_modules/rollup which insists on
          # the @rollup/rollup-linux-x64-gnu native binding; the optional dep
          # isn't in the tarball, so rollup fails at runtime with
          # "Cannot find module @rollup/rollup-linux-x64-gnu". Chromium ships
          # @rollup/wasm-node (a WASM-based drop-in) in third_party/node's
          # node_modules — copy (not symlink) it in place of devtools-frontend's
          # rollup so Node's node_modules parent-walk for plugin resolution
          # (terser, etc.) still lands in devtools-frontend/src/node_modules
          # where the plugins actually live.
          if [ -d third_party/node/node_modules/@rollup/wasm-node ] && \
             [ -d third_party/devtools-frontend/src/node_modules/rollup ]; then
            rm -rf third_party/devtools-frontend/src/node_modules/rollup
            cp -r third_party/node/node_modules/@rollup/wasm-node \
              third_party/devtools-frontend/src/node_modules/rollup
          fi

          # patchShebangs --build . would fail on unsupported shebangs inside
          # third-party scripts; restrict to executables we know about.
          for f in $(find . -type f -executable ! -regex '.+\.make$'); do
            patchShebangs --build "$f" || true
          done

          # Chromium expects a node binary at this path for devtools-frontend
          # build steps. CIPD provides node as part of DEPS; we also expose
          # the nixpkgs node as a fallback.
          mkdir -p third_party/node/linux/node-linux-x64/bin
          if [ ! -e third_party/node/linux/node-linux-x64/bin/node ]; then
            ln -s --force ${nodejs}/bin/node third_party/node/linux/node-linux-x64/bin/node
          fi

          # gclient_args.gni is normally written by gclient sync. Since we're
          # doing pure-Nix fetches and not running gclient, synthesize it here.
          # Must list every var Chromium's `gclient_gn_args` in //DEPS names,
          # or else //BUILD.gn's first reference to a missing one will abort
          # `gn gen` with "Undefined identifier". Tracks Chromium 148's
          # gclient_gn_args list — if a future milestone adds a new var, gn
          # will tell us exactly which one to add here.
          mkdir -p build/config
          cat > build/config/gclient_args.gni <<GCLIENT_ARGS
    build_with_chromium = true
    checkout_android = true
    checkout_android_prebuilts_build_tools = true
    checkout_clang_coverage_tools = false
    checkout_clusterfuzz_data = false
    checkout_copybara = false
    checkout_glic_e2e_tests = false
    checkout_ios_webkit = false
    checkout_mutter = false
    checkout_openxr = false
    checkout_src_internal = false
    checkout_src_internal_infra = false
    cros_boards = ""
    cros_boards_with_qemu_images = ""
    generate_location_tags = false
    GCLIENT_ARGS
        )
  '';

  configurePhase = ''
    runHook preConfigure

    ( cd src
      # gn can SIGSEGV when it tries to read /proc/self/cgroup in a
      # sandbox; set HOME to a writable path to avoid stray writes.
      export HOME=$TMPDIR
      gn gen ${lib.escapeShellArg "--args=${gnToString gnFlags}"} out/Release
    )

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # RUSTC_BOOTSTRAP is also set in env.* above but buildFHSEnv spawns
    # a clean shell, so re-export into the chroot.
    chromium-fhs <<'EOF'
    set -euo pipefail
    cd src
    export RUSTC_BOOTSTRAP=1
    export TERM=dumb
    ninja -C out/Release -j $NIX_BUILD_CORES ${builtins.toString buildTargets}
    EOF

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    ( cd src
      mkdir -p $out
      cp -r out/Release/apks/. $out/ 2>/dev/null || true
      # AABs (trichrome_chrome_bundle, chrome_modern_public_bundle) land
      # as .aab under out/Release/apks (bundletool build step); they're
      # copied above. If the build emitted .aab into out/Release/ we grab
      # those too.
      for f in out/Release/*.aab; do
        [ -e "$f" ] && cp "$f" $out/
      done
    )

    runHook postInstall
  '';

  passthru = {
    inherit info;
    chromiumSrc = src;
  };
}
