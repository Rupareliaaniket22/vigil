import Foundation
import OSLog
import VigilCore

/// Installs Vigil's hook into Claude Code's settings.
///
/// This edits a file the user did not ask us to touch, so it backs up first,
/// writes atomically, and never rewrites anything it cannot parse.
enum HookInstaller {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "installer")

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
  static var scriptPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".vigil/hooks/vigil-hook.sh")
      .path
  }

  static var claudeSettingsPath: String {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".claude/settings.json")
      .path
  }

  static var isInstalled: Bool {
    guard FileManager.default.isExecutableFile(atPath: scriptPath),
      let settings = try? readSettings(at: claudeSettingsPath)
    else { return false }
    return HookConfiguration.isInstalled(in: settings, scriptPath: scriptPath)
  }

  // MARK: - Install

  static func install() throws {
    try copyScript()

    var settings = try readSettings(at: claudeSettingsPath)
    settings = HookConfiguration.install(into: settings, scriptPath: scriptPath)
    try writeSettings(settings, to: claudeSettingsPath)

    log.info("hooks installed into \(claudeSettingsPath, privacy: .public)")
  }

  static func uninstall() throws {
    var settings = try readSettings(at: claudeSettingsPath)
    settings = HookConfiguration.uninstall(from: settings, scriptPath: scriptPath)
    try writeSettings(settings, to: claudeSettingsPath)

    try? FileManager.default.removeItem(atPath: scriptPath)
    log.info("hooks removed")
  }

  // MARK: - Files

  private static func copyScript() throws {
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

    let data = try JSONSerialization.data(
      withJSONObject: settings,
      options: [.prettyPrinted, .sortedKeys]
    )
    // Atomic, so an interrupted write can't truncate their settings.
    try data.write(to: url, options: .atomic)
  }
}
