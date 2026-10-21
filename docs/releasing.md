# Mac releases

The release workflow builds one arm64 Harflow.app for macOS 26 and checks its bundle identifier `dev.harflow.mac`, version, build, resources, managed-runtime specification and ad-hoc signature before packaging. The release tag must be strict `vX.Y.Z` and equal the app plist version; checkout, event SHA and tag commit must agree. The engine version is independently validated against the bundled supported runtime specification. App and engine versions need not remain equal. No engine, interpreter or sibling checkout is embedded or consulted.

Local unsigned validation (macOS 26 arm64, Python 3.9+):

```sh
macos/build-app.sh
/usr/bin/python3 -I scripts/ci/release.py source
/usr/bin/python3 -I scripts/ci/release.py unsigned
```

Use a fresh output directory (the default is `release-dist`); existing assets are preserved and require an explicit new output path or owner cleanup. The directory contains an unsigned ZIP/checksum; extraction is verified again. No credentials, keychain mutation, registration, state migration or user installation occurs. PyPI availability and Gatekeeper checks are explicitly skipped. Reuse smoke against a preseeded scratch runtime can be checked through the managed-runtime fixtures; no preseeded runtime is supplied by hosted release builds. Unsigned checks cannot certify Gatekeeper behavior.

Before later signed runs, the owner must configure and verify the [apple-signing protection and secrets](ci-signing.md). Allow selected `v*` tags as well as main, retain required reviewer `hainayanda`, disable administrative bypass, and allow no arbitrary branches. The existing credential preflight remains main-only and never uploads a product. Disable GitHub immutable releases for HarflowMac: this workflow reacts after a release is published and must subsequently attach assets. These account settings have not been applied or verified by local checks.

Manual dispatch defaults to unsigned validation. Selecting `signed` follows the same product signing and notarization path and necessarily uploads the app to Apple; that future run requires explicit owner authorization. It uploads only the final distributable ZIP/checksum as workflow artifacts and never creates or edits a GitHub Release. Published-release events additionally check the exact paired engine's release-specific PyPI metadata before signing, with bounded retries and no fallback. Manual validation reports that availability was skipped. Engine publication must precede production first installation.

Signing consumes the exact validated app artifact. A disposable protected macOS runner imports the five existing environment secrets into a private temporary keychain. The exact original search list is restored in cleanup even after partial failures, and cleanup failure prevents asset publication. The known bundle is inspected for executable code and signed inside-out with Developer ID Application, hardened runtime and timestamp. Unexpected embedded executable code fails for explicit review; no `codesign --deep` signing strategy, library-validation/JIT exceptions or quarantine removal is used. The independently downloaded interpreter is outside the app signature scope.

Notarytool must return accepted JSON. The app is stapled and assessed, then a final ZIP and checksum are generated from the stapled app. Extraction, strict signatures, authority/team/arm64/runtime and ticket/assessment are verified again. Logs expose stage/category labels only. Private Apple responses, identity information, P12 files and credential diagnostics are never workflow artifacts. The signing job has no publication permission.

A separate published-event-only job uploads the fixed ZIP/checksum pair without clobbering preexisting assets, verifies remote size and digest for both, clears temporary ownership labels and verifies the final public labels, and attempts to remove only newly uploaded pair assets on failure. GitHub uploads are separate HTTP requests, not an atomic transaction. A published release may temporarily have no assets during signing. If API/network failure prevents rollback, the workflow fails and reports partial assets requiring owner recovery: inspect the release and remove the incomplete pair before a new authorized publication attempt. Local mocked/unsigned checks establish neither successful notarization nor clean-machine first-install/Gatekeeper behavior.
