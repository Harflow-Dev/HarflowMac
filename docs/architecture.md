# Architecture

The Swift packages preserve the coordinator → navigation view → view → view model → use case → repository chain. Shared UI and utilities are in HfFoundation; domain transport remains MonitorCore; repository implementations are in HfCore; feature composition is in HfFeatures. Harflow assembles the application.

Production repository Module wiring uses ManagedToolEnvironmentRepository and ManagedInstallRepository. The managed boundary provides no executable discovery, empty launch environment, unavailable control/setup clients, and an inaccessible task directory. Retained transport and installer implementations are test seams only until managed runtime integration. External installer controls are hidden.

The local package build packages the app icon and both menu template images, then applies an ad-hoc signature. Developer ID, notarization, distribution, and Xcode Cloud are outside this phase.
