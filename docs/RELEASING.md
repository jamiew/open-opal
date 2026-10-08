# Releasing

Pushing a `v*` tag builds, signs, notarizes, and publishes a DMG to GitHub
Releases (`.github/workflows/release.yml`).

The release script bundles the complete non-system dylib dependency tree into
`Contents/Frameworks` before signing. This includes indirect dependencies such
as Homebrew's libpsl: a notarized app can still fail at launch if one of its
libraries loads a dependency from the build machine's Homebrew installation.
Bundled dependencies use paths relative to their loader and are signed with
the app's identity. Library validation remains enabled.

To package or check an unsigned local build without signing or installing it:

```sh
python3 scripts/bundle-dependencies.py /path/to/OpenOpal.app
python3 scripts/bundle-dependencies.py /path/to/OpenOpal.app --validate-only
python3 -m unittest discover -s scripts/tests -v
```

Packaging copies dylibs, leaving the original build/Homebrew libraries alone.
It fails on missing dependencies or conflicting library filenames; rebuild
with a consistent dependency set to resolve those errors. Validation inspects
all Mach-O files, including the camera extension, and rejects unresolved
`@rpath` loads and non-system dependencies outside the app. `sign.sh` runs that
same read-only check before signing. Run packaging before signing, since
rewriting a Mach-O file invalidates any existing signature. The packaging tests
compile tiny Mach-O fixtures on macOS without launching the app or camera.

The release script runs `clean build` before packaging. This removes old bundled
libraries whose load paths or signatures were rewritten by a previous release.
Do the same when rebuilding a manually packaged app before packaging it again.
```sh
git tag v0.1.0
git push origin v0.1.0
```

## Camera-free control checks

These standalone checks use isolated preferences and launch-policy state. They
do not open a camera, register the helper, or activate the extension.

```sh
swiftc -swift-version 6 Sources/OpenOpal/Render/CameraFilter.swift \
  Sources/OpenOpal/Camera/CameraSettings.swift \
  Tests/CameraSettingsPersistenceTests.swift -o /tmp/opal-settings-checks
/tmp/opal-settings-checks
swiftc -swift-version 6 Sources/OpenOpalLauncher/CameraLaunchPolicy.swift \
  Tests/CameraLaunchPolicyTests.swift -o /tmp/opal-launch-checks
/tmp/opal-launch-checks
```

The integration also passed an unsigned app, extension, and helper build using
existing native libraries. Synthetic feeder checks covered sink selection,
numbered-frame delivery, conversion, queue-full drops, and failed-enqueue
ownership. These checks do not establish installed-extension or live-camera
behavior.

## One-time: repository secrets

The CI can't sign or notarize without these. Add them under
**Settings → Secrets and variables → Actions → New repository secret**. The
base64 values were generated into `~/Library/Application Support/OpenOpal/ci-secrets/`
(that directory is outside the repo and holds the private key — do not commit it).

| Secret | Where it comes from |
|---|---|
| `CERT_P12_BASE64` | contents of `ci-secrets/CERT_P12_BASE64.txt` |
| `CERT_PASSWORD` | contents of `ci-secrets/CERT_PASSWORD.txt` |
| `KEYCHAIN_PASSWORD` | any random string (ephemeral CI keychain) |
| `APP_PROFILE_BASE64` | contents of `ci-secrets/APP_PROFILE_BASE64.txt` |
| `CAMERA_PROFILE_BASE64` | contents of `ci-secrets/CAMERA_PROFILE_BASE64.txt` |
| `NOTARY_APPLE_ID` | your Apple ID email |
| `NOTARY_TEAM_ID` | `GFU82T28YT` |
| `NOTARY_PASSWORD` | an app-specific password from appleid.apple.com |

Certificates and profiles expire or become invalid when you change
capabilities. Use this team's certificate and profiles, regenerate them per
[SIGNING.md](SIGNING.md), and re-encode the secrets with `base64 -i <file>`.

## Runner

The workflow uses `runs-on: macos-26` for Xcode 26 and the Liquid Glass SDK.
This experimental branch targets macOS 26 because its editor uses Foundation
Models. `bundle-dependencies.py` rejects bundled libraries that require a newer
macOS than the app declares. Upstream's macOS 14 target does not apply here.
The first run builds depthai-core from source and caches it. Changes to
`scripts/bootstrap.sh` or `patches/` rebuild it.
