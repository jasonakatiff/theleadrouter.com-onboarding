#!/bin/bash
#
# Build the double-click distributable from ../install.sh into installer/dist/:
#
#   dist/Install Lead Router Assistant.command   double-clickable copy of install.sh
#   dist/Lead Router Installer/                  folder with the .command + the maintainer README
#   dist/lead-router-installer.zip               zip of that folder (ditto keeps the executable bit)
#
# The one-liner on theleadrouter.com/install does not need this; it fetches
# install.sh straight from this repository. The zip is the fallback for people
# who cannot use Terminal, and macOS Gatekeeper will make them click through
# "Open Anyway" because it is not code-signed.

set -euo pipefail
cd "$(dirname "$0")"

bash -n ../install.sh
if command -v shellcheck >/dev/null 2>&1; then shellcheck -x ../install.sh build.sh; fi

STAGE="dist/Lead Router Installer"
mkdir -p "$STAGE"
cp ../install.sh "$STAGE/Install Lead Router Assistant.command"
chmod +x "$STAGE/Install Lead Router Assistant.command"
cp README.md "$STAGE/README.md"
cp "$STAGE/Install Lead Router Assistant.command" "dist/Install Lead Router Assistant.command"

TMP_ZIP="dist/.lead-router-installer.zip.tmp"
ditto -c -k --keepParent "$STAGE" "$TMP_ZIP"
mv -f "$TMP_ZIP" dist/lead-router-installer.zip

echo "Built:"
ls -l "dist/Install Lead Router Assistant.command" dist/lead-router-installer.zip
