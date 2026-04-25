# SPDX-FileCopyrightText: 2020 Daniel Fullmer and robotnix contributors
# SPDX-License-Identifier: MIT

{
  config,
  pkgs,
  apks,
  lib,
  ...
}:

let
  inherit (lib)
    mkIf
    mkMerge
    mkEnableOption
    mkOption
    mkOverride
    types
    ;

  mkWeakDefault = mkOverride 1200; # Priority betrween mkDefault and mkOptionDefault

  # aapt2 from android build-tools doesn't work here:
  # error: failed to deserialize resources.pb: duplicate configuration in resource table.
  # The version from chromium works, however:  https://bugs.chromium.org/p/chromium/issues/detail?id=1106115
  aapt2 =
    pkgs.stdenv.mkDerivation {
      # TODO: Move this into the chromium derivation. Use their own aapt2/bundletool.
      name = "aapt2";
      src = pkgs.fetchcipd {
        package = "chromium/third_party/android_build_tools/aapt2";
        version = "O9eXFyC5ZkcYvDfHRLKPO1g1Xwf7M33wT3cuJtyfc0sC";
        sha256 = "0bv8qx7snyyndk5879xjbj3ncsb5yxcgp8w0wwfrif3m22d1fn84";
      };
      nativeBuildInputs = [ pkgs.autoPatchelfHook ];
      installPhase = "mkdir -p $out/bin && cp aapt2 $out/bin/";
    }
    + "/bin/aapt2";

  # Create a universal apk from an "android app bundle"
  aab2apk =
    aab:
    pkgs.runCommand "aab-universal.apk"
      {
        nativeBuildInputs = with pkgs; [
          bundletool
          unzip
        ];
      }
      ''
        bundletool build-apks build-apks --bundle ${aab}  --output result.apks --mode universal --aapt2 ${aapt2}
        unzip result.apks universal.apk
        mv universal.apk $out
      '';

  # This is the default cert used in chrome/android/trichrome.gni of chromium source
  defaultTrichromeCertDigest = "32a2fc74d731105859e5a85df16d95f102d85b22099b8064c5d8915c61dad1e0";

  # Override the trichrome_certdigest in an already-built apk
  patchTrichromeApk =
    name: src: newCertDigest:
    pkgs.runCommand "${name}-trichrome-patched.apk"
      {
        nativeBuildInputs = with pkgs; [ python3 ];
      }
      ''
        python3 ${./chromium-trichrome-patcher.py} ${src} patched.apk ${lib.toLower defaultTrichromeCertDigest} ${lib.toLower newCertDigest}
        ${pkgs.robotnix.build-tools}/zipalign -p -f 4 patched.apk $out
      '';
in
{
  options = {
    apps.chromium.enable = mkEnableOption "chromium browser";
    apps.chromium.enableWidevine = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Build Chromium/Trichrome with Widevine DRM support
        (`enable_widevine = true` passed to GN).

        On Android this does NOT bundle a proprietary CDM: the browser
        talks to the device's `android.media.MediaDrm` HAL, which routes
        to the Widevine TA running in the TEE. No unfree blob is pulled
        into the Nix build.

        Whether playback lands at L1 (hardware-backed) or L3 (software)
        depends entirely on the LineageOS vendor partition carrying the
        OEM's Widevine keybox — a per-device/ROM concern, not something
        this option controls.

        Off by default so anyone who doesn't explicitly opt in ships a
        fully-DRM-free browser. Opt in when you want Netflix / Spotify
        Premium / other EME-protected content to play in Chromium or
        in apps that embed the Chromium-provided WebView.

        See: https://github.com/purefunsolutions/NeoRobotNix (issue
        documenting this option).
      '';
    };
    apps.vanadium.enable = mkEnableOption "vanadium browser";
  };

  config = mkMerge (
    (lib.flatten (
      map
        (
          {
            name,
            displayName,
            buildSeparately ? false,
            chromeModernIsBundled ? true,
            isTriChrome ? (config.androidVersion >= 10),
            enableWidevine ? false,
          }:
          let
            # There is a lot of shared code between chrome app and chrome webview. So we
            # default to building them in a single derivation. This is not optimal if
            # the user is enabling/disabling the apps/webview independently, but the
            # benefits outweigh the costs.
            packageName = "org.robotnix.${name}"; # Override package names here so we don't have to worry about conflicts
            webviewPackageName = "org.robotnix.${name}.webview";
            trichromeLibraryPackageName = "org.robotnix.${name}.trichromelibrary";

            patchedTrichromeApk = componentName: apk: apk; # patchTrichromeApk "${name}-${componentName}" apk config.apps.prebuilt.${name}.fingerprint;

            _browser =
              buildTargets:
              apks.${name}.override (
                {
                  customGnFlags ? { },
                  ...
                }:
                {
                  inherit
                    packageName
                    webviewPackageName
                    trichromeLibraryPackageName
                    displayName
                    buildTargets
                    enableWidevine
                    ;
                  targetCPU =
                    {
                      arm64 = "arm64";
                      arm = "arm";
                      x86_64 = "x64";
                      x86 = "x86";
                    }
                    .${config.arch};
                }
              );
            chromiumTargets =
              if isTriChrome then
                [
                  "trichrome_chrome_bundle"
                  "trichrome_library_apk"
                ]
              else if chromeModernIsBundled then
                # Was `chrome_modern_public_bundle` in <=M147 — renamed to
                # `chrome_public_bundle` in M148.
                [ "chrome_public_bundle" ]
              else
                [ "chrome_public_apk" ];
            webviewTargets =
              if isTriChrome then
                [
                  "trichrome_webview_apk"
                  "trichrome_library_apk"
                ]
              else
                [ "system_webview_apk" ];

            browser =
              if buildSeparately then
                pkgs.symlinkJoin {
                  inherit name;
                  paths =
                    lib.optional config.apps.${name}.enable (_browser chromiumTargets)
                    ++ lib.optional config.webview.${name}.enable (_browser webviewTargets);
                }
              else
                _browser (
                  lib.unique (
                    lib.optionals config.apps.${name}.enable chromiumTargets
                    ++ lib.optionals config.webview.${name}.enable webviewTargets
                  )
                );

          in
          [
            {
              apps.prebuilt.${name} = {
                apk =
                  if isTriChrome then
                    patchedTrichromeApk "browser" (aab2apk "${browser}/TrichromeChrome.aab")
                  else if chromeModernIsBundled then
                    aab2apk "${browser}/ChromeModernPublic.aab"
                  else
                    "${browser}/ChromeModernPublic.apk";
                enable = mkWeakDefault config.apps.${name}.enable;
              };

              # Unconditionally fill out the apk/description here, but it will not be included unless webview.<name>.enable = true;
              webview.${name} = {
                packageName = webviewPackageName;
                description = "${displayName} WebView";
                apk =
                  if isTriChrome then
                    patchedTrichromeApk "webview" "${browser}/TrichromeWebView.apk"
                  else
                    "${browser}/SystemWebView.apk";
              };

              build.${name} = browser; # Put here for convenience

              apps.prebuilt."${name}TrichromeLibrary" = {
                apk = "${browser}/TrichromeLibrary.apk";
                enable = mkWeakDefault (
                  isTriChrome && (config.apps.${name}.enable || config.webview.${name}.enable)
                );
                certificate = config.apps.prebuilt.${name}.certificate; # Share certificate with application
              };
            }
          ]
        )
        [
          {
            name = "chromium";
            displayName = "Chromium";
            enableWidevine = config.apps.chromium.enableWidevine;
          }
          {
            name = "vanadium";
            displayName = "Vanadium";
          }
        ]
    ))
  );
}
