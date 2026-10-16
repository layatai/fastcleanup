import Foundation

/// Presence checks are evidence, not proof of disposability. The caller validates the
/// physical location and metadata. No project code or package-manager script is executed.
public enum CleanupRecipe {
    public static func kind(categoryID: String, directoryName: String, manifests: Set<String>) -> CandidateKind? {
        switch categoryID {
        case "app-caches": return .cache
        case "xcode-derived": return .buildOutput
        case "node-modules": return manifests.contains("package.json") ? .dependencies : nil
        case "build-artifacts":
            if directoryName == "target" { return manifests.contains("Cargo.toml") ? .buildOutput : nil }
            if ["dist", ".next", ".turbo", ".parcel-cache", ".svelte-kit", "coverage"].contains(directoryName) {
                return manifests.contains("package.json") ? .buildOutput : nil
            }
            if ["__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"].contains(directoryName) {
                return !manifests.isDisjoint(with: ["pyproject.toml", "requirements.txt", "setup.cfg"]) ? .buildOutput : nil
            }
            return nil
        default: return nil // Unknown data, personal files, backups, models, VMs, and commands are not AI candidates.
        }
    }
}
