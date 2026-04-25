# SPDX-FileCopyrightText: 2020 Daniel Fullmer and robotnix contributors
# SPDX-License-Identifier: MIT

{
  lib,
  buildGoModule,
  fetchgit,
}:

let
  # luci-go main HEAD on 2026-04-24. luci-go has no release tags for CIPD
  # specifically — pinning to a recent commit off main keeps the client able
  # to speak the current CIPD registry (chrome-infra-packages.appspot.com)
  # protocol. The previous 2019-12-13 client 404s on modern instance IDs.
  version = "2026-04-24";
  rev = "2bed93b709fc55662eedfb3f933ed29d0d625dbe";
in
buildGoModule {
  inherit version;
  pname = "cipd";

  subPackages = [ "cipd/client/cmd/cipd" ];

  src = fetchgit {
    inherit rev;
    url = "https://chromium.googlesource.com/infra/luci/luci-go";
    hash = "sha256-xKoofMa5ckN6LOt4cG7jf54S9g8gME2O0F5n95eFsrw=";
  };

  vendorHash = "sha256-Bj254DEhk28BBtQtkZ5ngtYMCLnfHKc1e/BJpboARno=";

  meta = with lib; {
    description = "Chrome Infrastructure Package Deployment";
    longDescription = ''
      CIPD is package deployment infrastructure. It consists of a package
      registry and a CLI client to create, upload, download, and install
      packages.
    '';
    homepage = "https://chromium.googlesource.com/infra/luci/luci-go/+/refs/heads/main/cipd/";
    license = licenses.asl20;
    maintainers = with maintainers; [ danielfullmer ];
    platforms = with platforms; linux;
  };
}
