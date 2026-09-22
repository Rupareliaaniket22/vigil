import Foundation
import OSLog
import VigilCore

/// Installs Vigil's hook into Claude Code's settings.
///
/// This edits a file the user did not ask us to touch, so it backs up first,
/// writes atomically, and never rewrites anything it cannot parse.
struct HookInstaller {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "installer")

  /// Paths are injected so the whole install/uninstall cycle can be exercised
  /// against a temporary directory. This code rewrites someone's editor
  /// settings; it should not be the one part that is never run before shipping.
  let scriptPath: String
  let settingsPath: String
  let integration: AgentIntegration

  /// One installer per agent Vigil knows about.
  static func live(for integration: AgentIntegration) -> HookInstaller {
    HookInstaller(
      scriptPath: defaultScriptPath,
      settingsPath: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(integration.settingsPath).path,
      integration: integration
    )
  }

  enum InstallError: LocalizedError {
    case scriptMissingFromBundle
    case settingsUnreadable(String)

    var errorDescription: String? {
      switch self {
      case .scriptMissingFromBundle:
        "Vigil's hook script is missing from the app bundle. Reinstall Vigil."
      case .settingsUnreadable(let path):
        "Couldn't read \(path). Vigil left it untouched — check it is valid JSON."
      }
    }
  }

  /// Where the hook script lives once installed.
  ///
  /// Copied out of the bundle rather than referenced inside it, so moving or
  /// replacing the app doesn't break a hook Claude Code has already recorded.
  static var defaultScriptPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".vigil/hooks/vigil-hook.sh")
      .path
  }

  static var defaultSettingsPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/settings.json")
      .path
  }

  var isInstalled: Bool {
    guard FileManager.default.isExecutableFile(atPath: scriptPath),
      let settings = try? Self.readSettings(at: settingsPath)
    else { return false }
    return HookConfiguration.isInstalled(
      in: settings, scriptPath: scriptPath, integration: integration)
  }

  // MARK: - Install

  func install() throws {
    try copyScript()

    var settings = try Self.readSettings(at: settingsPath)
    settings = HookConfiguration.install(
      into: settings, scriptPath: scriptPath, integration: integration)
    try Self.writeSettings(settings, to: settingsPath)

    Self.log.info("hooks installed into \(settingsPath, privacy: .public)")
  }

  func uninstall() throws {
    var settings = try Self.readSettings(at: settingsPath)
    settings = HookConfiguration.uninstall(from: settings, scriptPath: scriptPath)
    try Self.writeSettings(settings, to: settingsPath)

    try? FileManager.default.removeItem(atPath: scriptPath)
    Self.log.info("hooks removed")
  }

  // MARK: - Files

  private func copyScript() throws {
    guard
      let source = Bundle.main.url(forResource: "vigil-hook", withExtension: "sh")
    else { throw InstallError.scriptMissingFromBundle }

    let destination = URL(fileURLWithPath: scriptPath)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if FileManager.default.fileExists(atPath: scriptPath) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
  }

  /// An absent settings file is an empty one — first run is not an error.
  private static func readSettings(at path: String) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path) else { return [:] }

    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard !data.isEmpty else { return [:] }

    guard let object = try? JSONSerialization.jsonObject(with: data),
      let settings = object as? [String: Any]
    else {
      // Refuse rather than overwrite something we can't understand.
      throw InstallError.settingsUnreadable(path)
    }
    return settings
  }

  private static func writeSettings(_ settings: [String: Any], to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    // Keep one backup. If a merge ever goes wrong, the user has a way back
    // that doesn't involve reconstructing their settings from memory.
    if FileManager.default.fileExists(atPath: path) {
      let backup = path + ".vigil-backup"
      try? FileManager.default.removeItem(atPath: backup)
      try? FileManager.default.copyItem(atPath: path, toPath: backup)
    }

    // withoutEscapingSlashes matters: Foundation writes "\/Users\/..." by
    // default, which is valid JSON but makes a hand-edited settings file uglier
    // than we found it and produces noisy diffs for anyone versioning dotfiles.
    let data = try JSONSerialization.data(
      withJSONObject: settings,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    // Atomic, so an interrupted write can't truncate their settings.
    try data.write(to: url, options: .atomic)
  }
}
