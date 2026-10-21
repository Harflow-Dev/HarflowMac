# Architecture

The Swift packages preserve the coordinator → navigation view → view → view model → use case → repository chain. Shared UI and utilities are in HfFoundation; domain transport remains MonitorCore; repository implementations are in HfCore; feature composition is in HfFeatures. Harflow assembles the application.

Production Module constructs one ManagedRuntimeCoordinator and injects it into ManagedToolEnvironmentRepository and ManagedInstallRepository. Startup consumers join the same attempt; retained failures require explicit retry. MonitorCore owns acquisition, private installation locking, hash verification, offline binary installation, qualification, immutable generations, and external launchers. App ctl/setup access binds the qualified generation; external launchers resolve the active pointer once. External runtime selection and legacy installer controls remain hidden. See [managed runtime](managed-runtime.md).

The local package build packages the app icon and both menu template images, then applies an ad-hoc signature. Developer ID, notarization, distribution, and Xcode Cloud are outside this phase.

Ctl/setup commands and asynchronous store readers validate the selected runtime and lexical state root before operations. See [MonitorCore compatibility](../macos/HfCore/MonitorCore/README.md). Managed readiness precedes those gates; no task history is scanned while preparation or qualification is unavailable.
