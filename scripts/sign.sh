#!/usr/bin/env bash
# Signs the app and its embedded camera extension with the Developer ID
# identity. Signing must proceed INSIDE-OUT: nested code first, the app last,
# or the outer signature seals a bundle whose contents then change.
set -euo pipefail

APP="${1:?usage: sign.sh /path/to/OpenOpal.app}"
IDENTITY="${IDENTITY:-Developer ID Application}"
HELPER="$APP/Contents/Library/LoginItems/OpenOpalLauncher.app"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$(mktemp -d "${TMPDIR:-/tmp}/openopal-sign.XXXXXX")"
trap 'rm -rf "$ENTITLEMENTS"' EXIT

# Resolve templates from the built app, not the current checkout's local config.
# This keeps a separately built product's identifiers and entitlements together.
EXT="$(python3 - "$APP" "$ROOT" "$ENTITLEMENTS" <<'PY'
import datetime
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import sys

app, root, output = map(pathlib.Path, sys.argv[1:])

def info(bundle):
    with (bundle / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream)

host = info(app)
identifier = host["CFBundleIdentifier"]
team = host.get("OpenOpalSigningTeam", "")
group = host.get("OpenOpalAppGroup", "")
if not re.fullmatch(r"[A-Z0-9]{10}", team):
    sys.exit("error: configure DEVELOPMENT_TEAM before building a signed app")
if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", identifier):
    sys.exit("error: invalid built host bundle identifier")
if not re.fullmatch(r"group\.[A-Za-z0-9.-]+", group):
    sys.exit("error: invalid built App Group")
extensions = list((app / "Contents/Library/SystemExtensions").glob("*.systemextension"))
if len(extensions) != 1:
    sys.exit("error: expected exactly one embedded camera extension")
extension = extensions[0]
camera = info(extension)
camera_id = identifier + ".camera"
if camera["CFBundleIdentifier"] != camera_id or extension.name != camera_id + ".systemextension":
    sys.exit("error: camera extension identity or bundle filename disagrees with host")
if camera.get("CMIOExtension", {}).get("CMIOExtensionMachServiceName") != group + ".camera":
    sys.exit("error: camera Mach service must use the configured App Group prefix")
helper = info(app / "Contents/Library/LoginItems/OpenOpalLauncher.app")
if helper["CFBundleIdentifier"] != identifier + ".launcher":
    sys.exit("error: launcher identity disagrees with host")
if not host.get("CFBundleVersion") or any(
    item.get("CFBundleVersion") != host["CFBundleVersion"] for item in (camera, helper)
):
    sys.exit("error: host, extension and launcher build versions must agree")

# Decode profiles only in memory; expose no raw CMS content or certificate bytes.
certificates = []
now = datetime.datetime.now(datetime.timezone.utc)
for target, bundle_id in (("OpenOpal", identifier), ("OpenOpalCameraExtension", camera_id)):
    profile_path = root / "Provisioning" / (target + ".provisionprofile")
    decoded = subprocess.run(
        ["security", "cms", "-D", "-i", str(profile_path)],
        capture_output=True, check=True,
    )
    profile = plistlib.loads(decoded.stdout)
    created = profile.get("CreationDate")
    expires = profile.get("ExpirationDate")
    if not isinstance(created, datetime.datetime) or not isinstance(expires, datetime.datetime):
        sys.exit("error: provisioning profile is missing validity dates: " + target)
    if not (created.replace(tzinfo=datetime.timezone.utc) <= now
            < expires.replace(tzinfo=datetime.timezone.utc)):
        sys.exit("error: provisioning profile is expired or not yet valid: " + target)
    grants = profile.get("Entitlements", {})
    if team not in profile.get("TeamIdentifier", []):
        sys.exit("error: provisioning profile team disagrees with built metadata: " + target)
    if grants.get("com.apple.developer.team-identifier") != team:
        sys.exit("error: provisioning profile team entitlement disagrees: " + target)
    if grants.get("com.apple.application-identifier") != team + "." + bundle_id:
        sys.exit("error: provisioning profile must grant the exact application identifier: " + target)
    if group not in grants.get("com.apple.security.application-groups", []):
        sys.exit("error: provisioning profile does not grant the configured App Group: " + target)
    if target == "OpenOpal" and grants.get("com.apple.developer.system-extension.install") is not True:
        sys.exit("error: host provisioning profile does not grant system-extension.install")
    certificates.append([
        hashlib.sha256(certificate).hexdigest()
        for certificate in profile.get("DeveloperCertificates", [])
    ])
with (output / "identity.json").open("w") as stream:
    json.dump({"team": team, "certificates": certificates}, stream)

for target, bundle_id in (("OpenOpal", identifier), ("OpenOpalCameraExtension", camera_id)):
    path = root / "Sources" / target / (target + ".entitlements")
    with path.open("rb") as stream:
        entitlements = plistlib.load(stream)
    entitlements["com.apple.application-identifier"] = team + "." + bundle_id
    entitlements["com.apple.developer.team-identifier"] = team
    entitlements["com.apple.security.application-groups"] = [group]
    with (output / (target + ".entitlements")).open("wb") as stream:
        plistlib.dump(entitlements, stream)
print(extension)
PY
)"

echo "==> validating bundled dependencies"
# No Homebrew/build-machine paths may survive into hardened-runtime signing.
python3 "$ROOT/scripts/bundle-dependencies.py" "$APP" --validate-only

echo "==> login helper and signing identity"
# The unrestricted helper is signed first so the selected certificate can be
# checked before applying restricted entitlements to the host or extension.
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$HELPER"
python3 - "$HELPER" "$ENTITLEMENTS" <<'PY'
import hashlib
import json
import pathlib
import subprocess
import sys

helper, output = map(pathlib.Path, sys.argv[1:])
with (output / "identity.json").open() as stream:
    identity = json.load(stream)
requirement = (
    'anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists '
    'and certificate leaf[subject.OU] = "' + identity["team"] + '"'
)
subprocess.run([
    "codesign", "--verify", "--strict", "--test-requirement", "=" + requirement, str(helper),
], check=True)
subprocess.run([
    "codesign", "-d", "--extract-certificates=" + str(output / "signer-"), str(helper),
], capture_output=True, check=True)
certificate = hashlib.sha256((output / "signer-0").read_bytes()).hexdigest()
if any(certificate not in allowed for allowed in identity["certificates"]):
    sys.exit("error: selected Developer ID signing certificate is not granted by both profiles")
PY

echo "==> embedding provisioning profiles"
# Restricted entitlements (system-extension.install) are only honored when a
# provisioning profile in the bundle grants them. Developer ID signing alone
# isn't enough: AMFI rejects the launch outright (spawn error 163).
cp "$ROOT/Provisioning/OpenOpal.provisionprofile" "$APP/Contents/embedded.provisionprofile"
cp "$ROOT/Provisioning/OpenOpalCameraExtension.provisionprofile" "$EXT/Contents/embedded.provisionprofile"

# The camera sandbox can check running code, but cannot read the host's files.
mkdir -p "$EXT/Contents/Resources"
cp "$APP/Contents/Info.plist" "$EXT/Contents/Resources/OpenOpalHostInfo.plist"

echo "==> dylibs"
for LIB in "$APP"/Contents/Frameworks/*.dylib; do
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$LIB"
done

echo "==> camera extension"
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS/OpenOpalCameraExtension.entitlements" \
  --sign "$IDENTITY" "$EXT"


echo "==> app"
codesign --force --timestamp --options runtime \
  --entitlements "$ENTITLEMENTS/OpenOpal.entitlements" \
  --sign "$IDENTITY" "$APP"

echo "==> verify"
codesign --verify --deep --strict --verbose=1 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -o "system-extension.install" || true
