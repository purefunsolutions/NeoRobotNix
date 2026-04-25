# SPDX-FileCopyrightText: 2026 NeoRobotNix contributors
# SPDX-License-Identifier: MIT
#
# fetchgcs — fetch a single object from a Google Cloud Storage bucket.
# Used for Chromium DEPS entries with dep_type "gcs" (AFDO profiles,
# select test data, some toolchain tarballs). The DEPS entry pins a
# sha256sum for the object, so this is a thin wrapper around fetchurl
# that composes the URL from bucket + object_name.
#
# Example DEPS entry:
#   'src/third_party/node/linux': {
#     'bucket': 'chromium-nodejs',
#     'dep_type': 'gcs',
#     'objects': [{
#       'object_name': '...',
#       'sha256sum': 'a1b2...',
#       ...
#     }],
#   }
#
# Corresponding call:
#   fetchgcs {
#     bucket = "chromium-nodejs";
#     object = "...";
#     hash = "sha256-...";
#   }

{ fetchurl, lib }:

{
  bucket,
  object,
  hash ? null,
  sha256 ? null,
  name ? builtins.baseNameOf object,
}:

assert hash != null || sha256 != null;

fetchurl (
  {
    inherit name;
    url = "https://storage.googleapis.com/${bucket}/${object}";
  }
  // lib.optionalAttrs (hash != null) { inherit hash; }
  // lib.optionalAttrs (sha256 != null) { inherit sha256; }
)
