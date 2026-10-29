# Signing and the virtual camera

The app runs fine unsigned. The **virtual camera** does not: a CoreMediaIO system
extension only loads if macOS can validate it, and outside the App Store that
means Developer ID signing *and* notarization. (`systemextensionsctl developer
on` used to be a shortcut; recent macOS refuses it while SIP is enabled.)

To build and sign your own extension, use an Apple Developer account. Using an
already-signed upstream release does not require your own signing credentials.
The instructions below apply to rebuilding this app and its extension.

## What Apple needs

1. **Developer ID Application certificate** — create at
   [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates).
   Pick the **G2 Sub-CA** intermediate. You'll also need Apple's
   [DeveloperIDG2CA.cer](https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer)
   in your keychain, or the cert shows as untrusted and `security find-identity`
   lists nothing.

2. **An App Group** — for example, `group.com.example.open-opal`. This is not optional:
   CMIO rejects any extension whose Mach service name isn't prefixed by one of
   its App Groups.

3. **Two App IDs**, both with **App Groups** enabled, and the app's with
   **System Extension** enabled:
   - Your configured host bundle ID (for example, `com.example.open-opal`)
   - The host bundle ID plus `.camera` (the extension)

4. **Two Developer ID provisioning profiles**, one per App ID. Changing
   capabilities invalidates existing profiles — regenerate them.
   Drop them in `Provisioning/` as `OpenOpal.provisionprofile` and
   `OpenOpalCameraExtension.provisionprofile`.

5. **Notarization credentials**, stored once:
   ```sh
   xcrun notarytool store-credentials openopal \
     --apple-id you@example.com --team-id YOUR_TEAM_ID
   ```
   (Needs an app-specific password from appleid.apple.com.)

Use the same Apple team for the certificate and both profiles. An existing Apple
Development identity or another app's profile does not satisfy this Developer ID
release workflow. `scripts/sign.sh` selects `Developer ID Application`; set
`IDENTITY` to the full certificate name or fingerprint if multiple identities match.

## Build identity configuration

`Config/BuildIdentity.xcconfig` is the single tracked identity configuration.
It has unsigned placeholders, not a registered team or upstream signing identity.
For your existing profiles, create the ignored, nonsecret
`Config/BuildIdentity.local.xcconfig`:

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
OPENOPAL_BUNDLE_IDENTIFIER = com.example.open-opal
OPENOPAL_APP_GROUP = group.com.example.open-opal
```

Replace every value with the exact identity registered in your Apple account.
Keep the current local override when replacing an installed app; changing the
bundle ID creates a different app/extension and no longer matches its profiles.
Do not put certificates, keys, or passwords in this file.

The camera extension ID and product name derive from the host ID plus `.camera`;
the launcher uses `.launcher`. The Mach service is the App Group plus `.camera`.
Both entitlement templates use build variables. Build-time signing stays disabled;
`sign.sh` resolves the templates from the **built host's metadata**, discovers the
embedded extension by its Info.plist, and rejects disagreement with the host,
launcher, Mach service, or synchronized build versions. It does not depend on a
hardcoded extension path or the checkout's current local override.

Before restricted signing, the script decodes profile metadata in memory and
requires current profile validity dates, the configured team, exact host/camera
application identifiers, the required App Group, and the host's system-extension
capability. App Group
validation is membership-based: Apple profiles may also grant a team wildcard.
It signs the unrestricted helper first, then checks that its actual certificate
is Apple-anchored Developer ID Application, belongs to the configured team, and
is listed by both profiles. Raw profiles and certificate bytes are not logged.

The extension retains fail-closed producer authorization: an Apple-anchored,
exact host-ID and team requirement validates the live process dynamically.
Before signing, the script copies the built host Info.plist into the extension's
sealed Resources so validation does not require sandbox access to the host files.
Do not remove this copy or replace authorization with CMIO's possibly `unknown`
signing ID.

Regenerate with `xcodegen generate` after project/template changes. The host,
extension, and helper currently all use build version **7**; bump all three for
future replacements so macOS does not keep an older same-version extension.

The release script builds, embeds profiles, and signs the app. Run:

```sh
./scripts/release.sh     # build -> sign -> notarize -> staple -> /Applications
```

To build and sign without installing, launching, or submitting to Apple:

```sh
xcodegen generate
xcodebuild -project OpenOpal.xcodeproj -scheme OpenOpal \
  -configuration Release -derivedDataPath build/DerivedData clean build
python3 scripts/bundle-dependencies.py build/DerivedData/Build/Products/Release/OpenOpal.app
./scripts/sign.sh build/DerivedData/Build/Products/Release/OpenOpal.app
```

This produces a signed artifact, not an installed/notarized one. The release
script above additionally submits to Apple, staples, and installs locally.

## Automatic startup helper

The optional auto-start helper is built into
`Contents/Library/LoginItems/OpenOpalLauncher.app` and signed before the host.
It needs no restricted entitlements or separate provisioning profile. It is
registered with `SMAppService` only when the user enables automatic startup.

The launcher's bundle ID automatically follows the configured host ID plus
`.launcher`; no separate identity edit is needed.

## Things that will waste your day

macOS reports most of these as **"Extension not found in App bundle"**,
regardless of the actual cause. It is almost never what it says.

| Symptom | Real cause |
|---|---|
| `extensionNotFound` (4) | The extension bundle must be **named after its bundle identifier** (`your.bundle.id.camera.systemextension`). Xcode's template does this via `PRODUCT_NAME = $(PRODUCT_BUNDLE_IDENTIFIER)`; other build systems don't. |
| `extensionNotFound` (4) | The app is missing `com.apple.application-identifier` / `com.apple.developer.team-identifier` entitlements. Xcode injects these from the provisioning profile; if you sign post-build, you must add them yourself. |
| `extensionNotFound` (4) | Extension `Info.plist` missing `CFBundlePackageType = SYSX`. |
| `validationFailed` (9), "extension category returned error" | `CMIOExtensionMachServiceName` must be prefixed by an **App Group**, not the team ID. |
| Launch fails, `launchd job spawn failed` (163) | The app carries the restricted `system-extension.install` entitlement without a provisioning profile that grants it. AMFI kills it. |
| "cannot allow apps outside /Applications" | The app must be in `/Applications`. Also delete stale copies elsewhere (DerivedData!) — LaunchServices may resolve your bundle ID to one of those. |
| Gatekeeper: "a sealed resource is missing or invalid" | You stapled the notarization ticket to the *extension*. Staple the app only; stapling writes into the bundle and breaks the app's seal. |
| Camera-off card, `-4` | Validate running code with [dynamic checks](https://developer.apple.com/documentation/security/ksecguestattributedynamiccode) and `sign.sh`'s host metadata, not CMIO's `unknown` signing ID. |
| Old extension after updating | Bump `CFBundleVersion`; macOS keeps same-version extensions. |

The system log is the only honest source:

```sh
log show --last 5m --predicate 'process == "sysextd"' --style compact
```
