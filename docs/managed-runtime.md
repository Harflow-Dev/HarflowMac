# Managed runtime

The current Harflow for Mac source pairs with HarflowMCP 0.0.2 on Apple Silicon/macOS 26. It never discovers or adopts an ambient Python, uv, Git checkout, Homebrew installation, or external engine.

Startup only checks and qualifies existing managed software under the installation lock. It never downloads components. A missing, outdated, or damaged runtime presents explicit installation or update controls in the sidebar and Settings → General. Installation requests only the exact release-specific PyPI JSON endpoint and canonical `harflow_mcp-0.0.2-py3-none-any.whl`. PyPI TLS/account ownership provides engine publication trust; the observed PyPI SHA256 provides transfer integrity and is retained in the completion receipt. It is not an app-signed publisher attestation. An exact-version yanked wheel remains eligible, with its yanked metadata recorded. Missing or malformed releases fail clearly with no fallback.

The bundled specification pins self-contained non-free-threaded CPython 3.13.16, python-build-standalone release 20261020, and 29 active Darwin arm64/pure dependency wheels from the engine lock. Downloads are HTTPS-only with bounded responses and redirect checks. Every artifact's expected size and SHA256 are checked before installation. Both pip installs run offline with hashes, binary-only inputs, no dependency resolution, no cache, no version check, and no user input. A private installer HOME/TMPDIR, a scrubbed environment, and `PIP_CONFIG_FILE=/dev/null` prevent inherited pip target/prefix/user/configuration settings from changing the installation. Ordinary engine launches preserve user HOME and harness authentication, isolate Python imports with `-I`, and select the managed state root/PATH after sanitizing inherited runtime variables. Bounded login and interactive-login zsh probes discover harness directories for Finder launches; login directories remain first, unique interactive additions follow, and the managed bin directory leads the final PATH. Invalid or timed-out shell output falls back to the inherited/system PATH. The same discovered environment reaches reused runtimes and explicit setup registrations.

## Paths and lifecycle

Runtime storage is `~/Library/Application Support/Harflow/Runtime`. Task state remains `~/.harflow/tasks`. Paths derive from the selected home; computing them does not inspect history. A private permanent lock permits one writer. A busy process reports preparation in progress and requires a later retry. Only abandoned regular `.staging-<UUID>` directories are reaped under that lock; immutable generation directories are never deleted or overwritten.

Each unique generation contains a self-contained Python tree, generation-bound launchers, and a completion receipt written only after offline dependency checks, native imports, exact engine metadata, and the existing version-info contract, platform, and selected-root checks. Activation atomically replaces the active pointer. A failed attempt leaves prior generations and the active pointer available. A receipt-bearing generation that fails native or compatibility validation is preserved and treated as non-reusable. Only an explicit installation or update attempts fresh acquisition. If replacement fails, the failure remains retained until explicit retry; existing generations and the active pointer are preserved. The app binds its own qualified generation; stable external `bin/harflow-server`, `bin/harflow-ctl`, and `bin/harflow-setup` resolve the active generation once. They reference no app, checkout, uv, or Homebrew path. Running workers and external registrations survive app closure, relocation, or removal.

Settings → General and the sidebar show shared checking, installation-required, update-required, progress, retained failure, and readiness states. Update progress and failure retain the validated installed and required engine versions. Unknown or corrupt managed receipts never invent an installed version. While unavailable, the sidebar replaces creation/search/history with a compact setup card, keeps settings and appearance controls, and the main detail asks the user to finish setup. Session and workflow menu, keyboard, and coordinator launch routes are gated until ready; repository command gates remain authoritative. Concurrent startup callers share one reuse-only check, and explicit concurrent actions share one acquisition. Failure remains retained until explicit retry; ordinary polls never download. A successful explicit action also restarts the previously missing task-list watcher. Readiness does not imply connection: the connection indicator waits for a successful task listing. Settings → Harnesses Install/Update/Remove are explicit MCP registration actions, separate from runtime acquisition. Registration stores the stable server launcher; the app never registers itself automatically.

## Store readiness and recovery

Executable qualification uses only the pure `version-info` handshake. A `state_incompatible` command refusal does not invalidate the qualified generation, restart acquisition, or change the selected root. Task and workflow repositories retain the engine’s structured refusal in a shared recovery repository.

Capability `state-recovery.v1` gates the public `state-inspect` and `state-recover` commands. Inspection does not create a root or initialize history. Recovery requires the exact inspected operation and confirmation token; the client never supplies a backup destination or changes private store files. The engine returns the archival backup path and retains interrupted-operation evidence in structured failures. Active or ambiguous owners prevent recovery. Backup and reset does not import historical data into the fresh store or guarantee an automatic restore.

Settings → General exposes inspection, exact-operation confirmation, cancellation, progress, completion and failure independently of runtime setup. The panel shows the actual selected state root, reason, backup proposal and operation identity. Ready or missing inspections offer no reset action. Unsupported, active-owner, ambiguous-owner, stale-confirmation and partial-backup failures retain the engine message and available backup evidence; retry requires a fresh inspection and confirmation. Interrupted recovery likewise requires inspecting and confirming the same resumable operation. Confirmation is inline and is cancelled when the settings view disappears. Concurrent recovery commands are single-flight; selected-context changes invalidate suspended results. Older engines without the capability return an unsupported-command outcome.

A completed receipt exposes Show backup in Finder for the engine-returned path. Later inspection or incompatibility does not discard that receipt; the prior completed backup remains distinguished from a new proposal or partial-backup path. Recovery refreshes listing and watchers through the normal readiness gate without changing the root or starting acquisition. It does not promise automatic restore or import archived history.

Native implementation references: HarflowDesign commit `9e6a9a3`, `scripts/sidebar-setup.js`, `setup-*` states; commit `4dfc64c`, `scripts/state-recovery.js`, `recovery-*` and `tasks/store-incompatible` states. Visual verification and refinement remain outstanding.

## Maintaining pinned inputs

The checked-in `ManagedRuntime.json` is product data, not a runtime resolver. Generate it with the pinned standalone target Python and explicit frozen engine lock/production export inputs:

```sh
TARGET_PYTHON -I scripts/generate-managed-runtime.py \
  --lock /absolute/path/to/uv.lock \
  --requirements /absolute/path/to/production-locked.txt \
  --interpreter scripts/managed-runtime-interpreter.json \
  --engine-version 0.0.2 \
  --provenance 'HarflowMCP lock revision and production export command' \
  --output macos/HfCore/MonitorCore/Sources/MonitorCore/Resources/ManagedRuntime.json
```

Produce the export in the engine checkout with `uv export --locked --no-dev --format requirements-txt --no-emit-project`. The generator performs no network access or resolution and has no implicit sibling lookup. It evaluates active markers and compatible tags using the explicitly invoked target interpreter's bundled pip packaging library, requires exact matching lock versions, and records input hashes. Review changed pins and rerun native offline fixture qualification before changing the app resource.

Interpreter provenance: [python-build-standalone release 20261020](https://github.com/astral-sh/python-build-standalone/releases/tag/20261020). CPython retains the Python Software Foundation license and bundled component notices in its extracted tree. Wheel `.dist-info` license/notice files remain in the installed Python tree. The app neither strips notices nor removes quarantine attributes; digest verification is not a claim about Gatekeeper or signed distribution.

## Current distribution limits

Local native fixture qualification establishes offline installation, relocation, and app integration on the tested machine. It does not establish that the paired release is published on PyPI, ownership of the `harflow-mcp` account, or Developer ID/notarized distribution. Confirm account ownership before distribution. Release wiring is documented in [releasing](releasing.md). First PyPI publication, actual signed app validation, and notarization remain unverified and deferred. Endpoint/spec injection exists only in constructors for deterministic tests; no environment variable, preference, or debug/release switch changes production endpoints or TLS policy.
