# Releasing

Pushing a `v*` tag builds, signs, notarizes, and publishes a DMG to GitHub
Releases (`.github/workflows/release.yml`).

`develop` is production-only: camera, rendering, packaging, and docking fixes.
Filters/effects and Generate & Edit remain on the local `experiments` branch.
Shared Mirror output defaults to off and flips the final composite once for
both preview and virtual camera. The extension advertises 1920×1080 BGRA at 30 fps;
sensor capture settings do not change the extension's advertised format.

Before signing, configure the ignored `Config/BuildIdentity.local.xcconfig` as
described in [SIGNING.md](SIGNING.md). Tracked defaults are unsigned placeholders.
The local override must retain the installed app's identity and match both
provisioning profiles. Host, extension, and helper build versions are all **7**.

For a local build, sign, notarize, staple, and install:

```sh
./scripts/release.sh
```

This submits the app to Apple and replaces `/Applications/OpenOpal.app`; it is
not a camera-free test command. Warn camera users before replacement or launch.

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

## Model downloads

`fetch-models.sh` downloads each package member to its own sibling temporary
file. Only a successful, nonempty download replaces the cached member, so a
failed or interrupted download is fetched again on the next run. Exit, interrupt,
and termination traps remove only the temporary file owned by that run.

## Compiled model publication

Compilation writes into a unique staging directory beside the published model.
On macOS, a small native helper uses `renamex_np(RENAME_SWAP)` to exchange the
complete old and new directories in one operation. The published path never
disappears during replacement, and compile or exchange failures keep the old
model. A first install renames the complete staged model into place.

Normal exits and catchable interruptions remove this run's staging directory.
`SIGKILL` cannot run cleanup, so it may leave a `.compile.*` directory behind,
but the published path still contains the complete old or new model. Later runs
use their own staging directories and do not remove another run's files.
## Camera-free control checks

Use the integrated runner against the built or installed app:

```sh
bash scripts/check-camera.sh /Applications/OpenOpal.app
```

This runs seven isolated Swift fixtures for settings persistence, subject
metering, launch policy, docking geometry, sink session/timing, and sink
authorization, followed by the synthetic renderer and the app's isolated
settings persistence/cold-revision checks. It does not open a camera or activate
the extension, and does not establish installed-extension or live-camera behavior.

After warning camera users, the explicit live path is:

```sh
bash scripts/check-camera.sh /Applications/OpenOpal.app --live-takeover
```

It uses the RAM-only pipeline to exercise capture modes/frame rates, orientation,
hot-control churn, software reconnect/restart, and authorized virtual-camera
readback. A bundled, loadable depth model enables additional synchronous and
asynchronous depth-blur/subject-focus cases; missing assets remain unverified,
with no download. JSON-lines evidence contains numeric diagnostics, not recorded
pixels; saved user controls are unchanged. Exit 1 is failure; the live path
intentionally exits 2 while optical acceptance remains incomplete. Physical
unplug/replug, optical/chart-based control effects, optical depth correctness, GUI/advanced
controls, freeze, docking, automatic startup, installation, independent-client
acceptance, and missing prior camera permission need separate observation.
Do not equate software restart with physical reconnect or claim replacement
build acceptance from an earlier build's results.

## One-time: repository secrets

CI needs certificates, profiles, and notarization credentials. Add them under
**Settings → Secrets and variables → Actions → New repository secret**.
Keep private-key exports and encoded credentials outside the repository.

| Secret | Where it comes from |
|---|---|
| `CERT_P12_BASE64` | base64-encoded Developer ID certificate and private-key export |
| `CERT_PASSWORD` | password protecting that export |
| `KEYCHAIN_PASSWORD` | any random string (ephemeral CI keychain) |
| `APP_PROFILE_BASE64` | base64-encoded host Developer ID provisioning profile |
| `CAMERA_PROFILE_BASE64` | base64-encoded camera Developer ID provisioning profile |
| `NOTARY_APPLE_ID` | your Apple ID email |
| `NOTARY_TEAM_ID` | your Apple developer team ID |
| `NOTARY_PASSWORD` | an app-specific password from appleid.apple.com |

Set two nonsecret repository **Actions variables**:

| Variable | Value |
|---|---|
| `OPENOPAL_BUNDLE_IDENTIFIER` | host App ID matching the signing profiles |
| `OPENOPAL_APP_GROUP` | exact shared App Group granted by both profiles |

CI passes these and `NOTARY_TEAM_ID` as Xcode build settings. It does not need a
local override file. The extension and launcher identities derive automatically.

Certificates and profiles expire or become invalid when you change
capabilities. Use this team's certificate and profiles, regenerate them per
[SIGNING.md](SIGNING.md), and re-encode the secrets with `base64 -i <file>`.

## Runner

The workflow uses `runs-on: macos-26` for Xcode 26 and the Liquid Glass SDK.
The production integration keeps a macOS 26 deployment target.
`bundle-dependencies.py` rejects bundled libraries that require a newer
macOS than the app declares. Upstream's deployment target does not override it.
The first run builds depthai-core from source and caches it. Changes to
`scripts/bootstrap.sh` or `patches/` rebuild it.

## Release names

Packaging and notarization receive the tag through the `RELEASE_TAG` environment
variable and quote it as filename data. Tags are never inserted into shell
source: a valid Git tag can contain shell command substitution. The release
action's `files` input remains data, not shell code.

The offline release-name tests run with
`python3 -m unittest discover -s scripts/tests -p test_release_names.py -v`.
They execute the workflow's shell steps using local DMG and notary fixtures,
including tags containing shell syntax. They do not sign or notarize artifacts.
