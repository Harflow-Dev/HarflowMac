# Validate Apple credentials in GitHub Actions

This manually triggered preflight validates credentials using a generated local C executable and authenticated notarization history access. It does not upload or notarize a product, release artifacts, or establish production runtime trust. Publisher: Nayanda Haberty. The repositories use Apache 2.0; this bootstrap assigns no release version or date.

## Prepare the protected environment

These files are reviewed configuration payloads, not evidence that settings have been applied. Publication and account changes require the owner's authorization. Retain the bootstrap commits on main. Later merge extracted project history through an ordinary merge atop main; never force-push or replace the bootstrap history.

1. Publish the reviewed bootstrap on `Harflow-Dev/HarflowMac` main. The workflow accepts only manual `workflow_dispatch`; its job also checks repository and main ref. It has no custom inputs, dependency installs, caches, artifact uploads, or product payload downloads.
2. In [repository environments](https://github.com/Harflow-Dev/HarflowMac/settings/environments), create `apple-signing`. Configure required reviewer `hainayanda` (user ID 24823437), allow self-review for the sole maintainer, set no wait timer, and allow the `main` branch. Before product release signing, also add the selected `v*` tag policy from `ci/github-release-tag-policy.json`; do not add arbitrary branch access. The documented REST payloads are `ci/github-environment.json` and `ci/github-branch-policy.json`; they target the environment PUT endpoint and its deployment branch policies endpoint respectively.
3. In that environment's protection rules, disable the UI option allowing administrators to bypass protection. Verify the disabled setting and reviewer/main policy before adding secrets or running the workflow. Configure administrative bypass through the environment UI; the REST environment PUT schema does not expose this control. Until the UI setting is verified, administrator bypass protection remains pending.
4. Apply and verify the active main ruleset in `ci/github-main-ruleset.json`: deletion and non-fast-forward updates prohibited, no bypass actors. This preserves history without imposing a PR gate that would prevent the initial bootstrap.
5. Add only the five environment secrets listed below. Do not create repository or organization copies of these secrets: those would undermine the environment gate. HarflowMCP has no signing credentials in this phase.

The workflow requests no permissions globally and only `contents: read` for its environment-gated job. Checkout v6 is pinned to verified upstream commit `d23441a48e516b6c34aea4fa41551a30e30af803` and does not persist credentials. `macos-26` is GitHub's hosted arm64 runner. Concurrency permits at most one running and one pending preflight; a newer pending run replaces an older pending run even with `cancel-in-progress: false`.

## Provision credentials securely

Use an active Apple Developer account with a **Developer ID Application** certificate and its private key. If this identity is missing, create it through Xcode or [Apple Developer certificate management](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) first. An Apple Development identity does not satisfy this requirement. An App Store app record, installer certificate, provisioning profile, or App Store Connect API key is not required for this preflight.

In Keychain Access, locate the Developer ID Application identity under My Certificates, expand it to confirm the private key, and export it as a password-protected `.p12`. Use a compatible PKCS#12 export that Apple's `security import` can read. If chain validation fails, re-export with the Developer ID G2 intermediate available so the export carries the needed chain. Do not work around chain failures by importing trust settings or granting broad trust.

At the `apple-signing` environment, create:

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `HARFLOW_DEVELOPER_ID_P12_BASE64` | Base64 encoding of the password-protected P12, at most 48 KiB encoded |
| Secret | `HARFLOW_DEVELOPER_ID_P12_PASSWORD` | P12 export password |
| Secret | `HARFLOW_NOTARY_APPLE_ID` | Apple ID email with notarization access |
| Secret | `HARFLOW_NOTARY_APP_PASSWORD` | Apple ID app-specific password |
| Secret | `HARFLOW_APPLE_TEAM_ID` | Ten uppercase letters/digits from the developer account |

Use the [environment UI](https://github.com/Harflow-Dev/HarflowMac/settings/environments) or a separately authorized local secure channel. With GitHub CLI authenticated to the intended repository, pipe the P12 directly without displaying its encoding:

```sh
base64 -i /absolute/private/path/signing.p12 | tr -d '\n' | gh secret set HARFLOW_DEVELOPER_ID_P12_BASE64 --env apple-signing --repo Harflow-Dev/HarflowMac
gh secret set HARFLOW_DEVELOPER_ID_P12_PASSWORD --env apple-signing --repo Harflow-Dev/HarflowMac
gh secret set HARFLOW_NOTARY_APPLE_ID --env apple-signing --repo Harflow-Dev/HarflowMac
gh secret set HARFLOW_NOTARY_APP_PASSWORD --env apple-signing --repo Harflow-Dev/HarflowMac
gh secret set HARFLOW_APPLE_TEAM_ID --env apple-signing --repo Harflow-Dev/HarflowMac
```

The last four commands prompt interactively. Never put secret values in shell arguments/history, chat, repository files, logs, or uploaded artifacts. Obtain the app-specific password through [Apple Account](https://account.apple.com/). Store the Team ID as an environment secret so GitHub masks it in step environment logs. Keep the source P12 and its password in approved private storage.

## Run and interpret

Open [Apple signing credential preflight](https://github.com/Harflow-Dev/HarflowMac/actions/workflows/apple-signing-preflight.yml), choose **Run workflow**, select main, then approve the environment deployment. The script runs with `/usr/bin/python3 -I`, standard library only, Python 3.9 or newer. It refuses execution before side effects unless the explicit hosted-runner/repository/main/macOS 26/arm64 checks and input checks pass. These checks are defense in depth, not an OS sandbox.

The script uses a private temporary directory, an ephemeral keychain and random password. It snapshots the runner's user keychain search list before creating/prepending its keychain and restores the exact saved list in cleanup, including partial prepend failures. No login/default keychain contents or trust settings are changed. Import permits codesign access only; partition access is limited to `apple-tool:,apple:,codesign:`. The P12 file is deleted immediately after import and remaining temporary files are removed in cleanup.

Exactly one valid Developer ID Application identity for the configured team must be present. The generated probe uses secure timestamping and hardened runtime, strict signature verification, Developer ID authority and exact TeamIdentifier checks. Notarytool validates a temporary keychain credential profile and reads history JSON; it never submits a payload. No history details, identity names/fingerprints, Team ID, Apple ID, or captured tool errors are printed. Public output contains stage labels, success/failure and the fixed notary failure categories below only. A cleanup or search-list restoration failure fails the run with a generic stage error; the disposable runner teardown remains the final backup.

Notary checks report three separate stages: `notary-credential-validation` validates the stored credential profile, `notary-history-access` requests history and writes the private temporary `history.json`, and `notary-response-validation` checks the returned JSON and its history-list shape. The history file stays private and is removed during cleanup. Tool stdin is closed to prevent interactive prompts.

Notary subprocess failures use `preflight <stage> failed: <category>`. Categories describe the observed signal and do not establish the underlying cause:

| Category | Interpretation |
| --- | --- |
| `timed-out` | The command exceeded its local deadline; this alone does not identify an authentication or service problem. |
| `authentication-rejected` | Captured output explicitly reported HTTP status 401; check the configured credentials. |
| `authorization-rejected` | Captured output explicitly reported HTTP status 403; check account/team access. |
| `service-unavailable` | Captured output explicitly reported an HTTP 5xx status; a service or intermediary may have failed. |
| `network-failure` | Captured output contained a recognized transport failure marker; investigate connectivity. |
| `command-failed` | The notary command failed without a recognized signal. |
| `invalid-response` | JSON parsing or the expected history-list shape failed during response validation. |

Timeout takes precedence over output, followed by 401, 403, 5xx, transport markers, and the generic command category. Bare numbers are not treated as HTTP statuses. Unexpected exceptions and history-file write failures retain plain stage failure output. Raw command arguments, captured output and exception details are never printed, including workflow command text.

After pushing a diagnostic change, start a **new** workflow dispatch on main and approve its environment deployment. Rerunning an older workflow run uses its original commit SHA and will not exercise the updated script.

Passwords are passed as arguments to trusted Apple tools and can be visible to other processes on the disposable single-tenant hosted VM. This is not encryption at runtime or a promise of zero exposure. Do not run this script with real credentials on a developer machine. Local tests mock subprocesses and credentials; no local signing/keychain mutation is required.

A green run proves credential import, generated-probe signing and authenticated notary access on that runner. It does not prove product signing, notarization, downloaded-artifact Gatekeeper behavior, release publication, or clean-machine operation.

References: [GitHub environments REST API](https://docs.github.com/en/rest/deployments/environments), [environment protection](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments), [GitHub hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [repository rulesets REST API](https://docs.github.com/en/rest/repos/rules), [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [Developer ID](https://developer.apple.com/developer-id/).

## Maintainer validation

From the repository root, run `/usr/bin/python3 -I -B tests/ci/test_preflight.py -v`. These tests mock credentials and Apple tools; they do not validate real signing access.

## Product release signing

The separate [release workflow](releasing.md) consumes the exact built app artifact and performs product signing/notarization only in `apple-signing`. Before enabling it, add the selected `v*` tag deployment policy alongside main, retain the required reviewer and disabled administrative bypass, and disable HarflowMac immutable releases so assets can be attached after the published event. These payloads document owner actions and have not applied settings. The credential preflight above remains main-only and nonuploading. Manual signed validation uploads a product to Apple and requires explicit owner authorization before a later run.
