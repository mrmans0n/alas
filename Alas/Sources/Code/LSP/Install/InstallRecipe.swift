import Foundation

/// Package managers we know how to invoke for LSP installation.
/// Values are stable strings used in `mason-lsps.json` and in user config
/// (`AppConfig.code.userDefinedRecipes`), so do not rename.
enum InstallerKind: String, Codable, Equatable, CaseIterable, Sendable {
    case brew
    case npm
    case pnpm
    case bun
    case cargo
    case rustup
    case go
    case pipx
}

/// One way to install a given LSP. `package` is the argument to the
/// installer's install verb (e.g. "rust-analyzer" for `brew install`,
/// "golang.org/x/tools/gopls" for `go install`). `extraArgs` is used when
/// the installer's argv doesn't fit `<verb> <package>` — currently only
/// `rustup component add <name>`.
struct InstallRecipe: Codable, Equatable, Sendable {
    let installer: InstallerKind
    let package: String
    let extraArgs: [String]

    init(installer: InstallerKind, package: String, extraArgs: [String] = []) {
        self.installer = installer
        self.package = package
        self.extraArgs = extraArgs
    }
}
