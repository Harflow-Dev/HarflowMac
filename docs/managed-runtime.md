# Managed runtime

Harflow for Mac 0.0.1 pairs with HarflowMCP 0.0.1 on Apple Silicon/macOS 26. It never discovers or adopts an ambient Python, uv, Git checkout, Homebrew installation, or external engine.

The app reuses a locally qualified managed runtime without network calls. First preparation requests only the exact release-specific PyPI JSON endpoint and canonical `harflow_mcp-0.0.1-py3-none-any.whl`. PyPI TLS/account ownership provides engine publication trust; the observed PyPI SHA256 provides transfer integrity and is retained in the completion receipt. It is not an app-signed publisher attestation. An exact-version yanked wheel remains eligible, with its yanked metadata recorded. Missing or malformed releases fail clearly with no fallback.

The bundled specification pins self-contained non-free-threaded CPython 3.13.16, python-build-standalone release 20261020, and 29 active Darwin arm64/pure dependency wheels from the engine lock. Downloads are HTTPS-only with bounded responses and redirect checks. Every artifact's expected size and SHA256 are checked before installation. Both pip installs run offline with hashes, binary-only inputs, no dependency resolution, no cache, no version check, and no user input. A private installer HOME/TMPDIR, a scrubbed environment, and `PIP_CONFIG_FILE=/dev/null` prevent inherited pip target/prefix/user/configuration settings from changing the installation. Ordinary engine launches preserve user HOME and harness authentication, isolate Python imports with `-I`, and select the managed state root/PATH after sanitizing inherited runtime variables. Bounded login and interactive-login zsh probes discover harness directories for Finder launches; login directories remain first, unique interactive additions follow, and the managed bin directory leads the final PATH. Invalid or timed-out shell output falls back to the inherited/system PATH. The same discovered environment reaches reused runtimes and explicit setup registrations.

## Paths and lifecycle

Runtime storage is `~/Library/Application Support/Harflow/Runtime`. Task state remains `~/.harflow/tasks`. Paths derive from the selected home; computing them does not inspect history. A private permanent lock permits one writer. A busy process reports preparation in progress and requires a later retry. Only abandoned regular `.staging-<UUID>` directories are reaped under that lock; immutable generation directories are never deleted or overwritten.

Each unique generation contains a self-contained Python tree, generation-bound launchers, and a completion receipt written only after offline dependency checks, native imports, exact engine metadata, and the existing version-info contract/platform/store checks. Activation atomically replaces the active pointer. A failed attempt leaves prior generations and the active pointer available. A receipt-bearing generation that fails native or compatibility validation is preserved and treated as non-reusable, allowing one fresh acquisition in that attempt. If replacement fails, the failure remains retained until explicit retry; existing generations and the active pointer are preserved. The app binds its own qualified generation; stable external `bin/harflow-server`, `bin/harflow-ctl`, and `bin/harflow-setup` resolve the active generation once. They reference no app, checkout, uv, or Homebrew path. Running workers and external registrations survive app closure, relocation, or removal.

Settings → General shows preparation/failure/readiness and explicit retry. Sidebar, menu bar, and Harnesses share the same install-status surface; preparation is neutral and acquisition failure is not duplicated as a list incident. Concurrent startup callers join one attempt. Failure remains retained until retry; ordinary polls never download again. A successful explicit retry also starts the previously missing task-list watcher. Settings → Harnesses Install/Update/Remove are explicit MCP registration actions, separate from runtime acquisition. Registration stores the stable server launcher; the app never registers itself automatically.

## Maintaining pinned inputs

The checked-in `ManagedRuntime.json` is product data, not a runtime resolver. Generate it with the pinned standalone target Python and explicit frozen engine lock/production export inputs:

```sh
TARGET_PYTHON -I scripts/generate-managed-runtime.py \
  --lock /absolute/path/to/uv.lock \
  --requirements /absolute/path/to/production-locked.txt \
  --interpreter scripts/managed-runtime-interpreter.json \
  --engine-version 0.0.1 \
  --provenance 'HarflowMCP lock revision and production export command' \
  --output macos/HfCore/MonitorCore/Sources/MonitorCore/Resources/ManagedRuntime.json
```

Produce the export in the engine checkout with `uv export --locked --no-dev --format requirements-txt --no-emit-project`. The generator performs no network access or resolution and has no implicit sibling lookup. It evaluates active markers and compatible tags using the explicitly invoked target interpreter's bundled pip packaging library, requires exact matching lock versions, and records input hashes. Review changed pins and rerun native offline fixture qualification before changing the app resource.

Interpreter provenance: [python-build-standalone release 20261020](https://github.com/astral-sh/python-build-standalone/releases/tag/20261020). CPython retains the Python Software Foundation license and bundled component notices in its extracted tree. Wheel `.dist-info` license/notice files remain in the installed Python tree. The app neither strips notices nor removes quarantine attributes; digest verification is not a claim about Gatekeeper or signed distribution.

## Current distribution limits

Local native fixture qualification establishes offline installation, relocation, and app integration on the tested machine. It does not establish that the paired release is published on PyPI, ownership of the `harflow-mcp` account, or Developer ID/notarized distribution. Confirm account ownership before distribution. Release wiring is documented in [releasing](releasing.md). First PyPI publication, actual signed app validation, and notarization remain unverified and deferred. Endpoint/spec injection exists only in constructors for deterministic tests; no environment variable, preference, or debug/release switch changes production endpoints or TLS policy.
