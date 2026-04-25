# SPDX-FileCopyrightText: 2020 Daniel Fullmer and robotnix contributors
# SPDX-License-Identifier: MIT

{
  chromium,
  fetchFromGitHub,
  git,
  fetchcipd,
  linkFarmFromDrvs,
  fetchurl,
}:

let
  # GrapheneOS Vanadium tag 148.0.7778.60.0 — their fork of Chromium 148
  # with hardening and rebranding patches. Must match the Chromium version
  # pinned in apks/chromium/info.json.
  vanadium_src = fetchFromGitHub {
    owner = "GrapheneOS";
    repo = "Vanadium";
    rev = "148.0.7778.60.0";
    hash = "sha256-JXqC5ctE2AjbZWEhaCow6rotAPMZGFIPzq+OaTzUIx8=";
  };
in
(chromium.override {
  name = "vanadium";
  displayName = "Vanadium";
  version = "148.0.7778.60";
  enableRebranding = false; # Patches already include rebranding
  customGnFlags = {
    # enable patented codecs
    ffmpeg_branding = "Chrome";
    proprietary_codecs = true;

    # Hardening: Vanadium enables CFI
    is_cfi = true;

    enable_gvr_services = false;
    enable_remoting = false;
    enable_reporting = true;
  };
}).overrideAttrs
  (attrs: {
    # Use `git apply` so patches can include "git binary diff" format
    # chunks; plain `patch -p1` chokes on those.
    postPatch =
      ''
        ( cd src
          for patchfile in ${vanadium_src}/patches/*.patch; do
            ${git}/bin/git apply --unsafe-paths $patchfile
          done
        )
      ''
      + attrs.postPatch;
  })
