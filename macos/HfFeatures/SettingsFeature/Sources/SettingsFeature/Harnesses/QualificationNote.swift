//
//  QualificationNote.swift
//  SettingsFeature
//

import HfUI

// MARK: - QualificationBackend

/// One harness of the engine catalog, in catalog order. `installed` is nil when the catalog does not say.
struct QualificationBackend: Equatable, Sendable {
    let backend: String
    let installed: Bool?
}

// MARK: - NativeQualification

/// The harnesses with native qualification (HarflowDesign `8ec4d38`, harness settings, "Qualification and G-HARNESS").
/// Every other harness makes no qualification claim and is never discovered or checked.
enum NativeQualification {
    static let backends: Set<String> = ["claude", "codex", "vibe"]

    static func isNative(_ backend: String) -> Bool { backends.contains(backend) }
}

// MARK: - QualificationNote

/// A one-line row of the qualification section for a harness that has no qualification card.
struct QualificationNote: Identifiable, Equatable, Sendable {
    let id: String
    let identity: String
    let text: String
    let glyph: RowGlyph?

    /// "No native qualification for this harness", or the not-found row when the catalog says it is not installed.
    static func make(for entry: QualificationBackend) -> QualificationNote {
        let name = BackendStyle.displayName(entry.backend)
        if entry.installed == false {
            return QualificationNote(id: entry.backend, identity: name,
                                     text: "\(name) was not found on PATH. Install it, then refresh.", glyph: .unavailable)
        }
        return QualificationNote(id: entry.backend, identity: name, text: "No native qualification for this harness", glyph: nil)
    }
}

// MARK: - QualificationGlyph

/// The glyph a Settings qualification card draws before its title. Qualifying and Not checked draw none; the title
/// text carries them.
enum QualificationGlyph {
    static func `for`(_ state: HarnessQualificationModel.State) -> RowGlyph? {
        switch state {
        case .ready: .done
        case .failed, .failedAtRuntime: .failed
        case .cancelled: .cancelled
        case .binaryChanged, .unsupported: .attention
        case .notChecked, .checking, .unavailable: nil
        }
    }
}
