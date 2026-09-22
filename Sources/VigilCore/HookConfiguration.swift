import Foundation

/// Merging Vigil's hooks into an agent's settings file.
///
/// Pure JSON transformation, kept here rather than in the app layer because
/// editing someone's editor configuration is exactly the kind of thing that
/// must be tested before it ever runs. The rules: never drop a setting we
/// don't understand, never install twice, and always be removable.
public enum HookConfiguration {

  /// The Claude Code lifecycle events Vigil listens for.
  ///
  /// `Notification` means the agent is blocked on the user, which maps to
  /// `waiting` — deliberately not a reason to hold the Mac awake.
  public static let claudeCodeEvents = [
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "SubagentStart",
    "SubagentStop",
    "Notification",
    "SessionEnd",
  ]

  /// A hook entry is ours if its command invokes our script.
  ///
  /// Matched on the script's *filename*, not its full path: the app can move
  /// between builds and installs, and matching the whole path would leave the
  /// old entry behind so every event fired twice. The filename is distinctive
  /// enough to be safe.
  public static func isVigilHook(_ command: String, scriptPath: String) -> Bool {
    let name = (scriptPath as NSString).lastPathComponent
    guard !name.isEmpty else { return false }
    return command.contains(name)
  }

  /// Add Vigil's hooks to a settings dictionary, leaving everything else alone.
  ///
  /// Idempotent: installing twice produces the same result as installing once.
  public static func install(
    into settings: [String: Any],
    scriptPath: String,
    events: [String] = claudeCodeEvents
  ) -> [String: Any] {
    var settings = settings
    var hooks = settings["hooks"] as? [String: Any] ?? [:]

    for event in events {
      var matchers = hooks[event] as? [[String: Any]] ?? []

      // Drop any previous entry of ours before adding, so a changed script path
      // replaces the old one instead of accumulating beside it.
      matchers = matchers.filter { matcher in
        guard let inner = matcher["hooks"] as? [[String: Any]] else { return true }
        return !inner.contains { entry in
          (entry["command"] as? String).map { isVigilHook($0, scriptPath: scriptPath) } ?? false
        }
      }

      matchers.append([
        "hooks": [["type": "command", "command": "\(scriptPath) \(event)"]]
      ])
      hooks[event] = matchers
    }

    settings["hooks"] = hooks
    return settings
  }

  /// Remove Vigil's hooks, leaving every other hook intact.
  ///
  /// Prunes empty containers so uninstalling returns the file to its original
  /// shape rather than leaving `"hooks": {}` behind.
  public static func uninstall(
    from settings: [String: Any],
    scriptPath: String
  ) -> [String: Any] {
    var settings = settings
    guard var hooks = settings["hooks"] as? [String: Any] else { return settings }

    for (event, value) in hooks {
      guard var matchers = value as? [[String: Any]] else { continue }

      matchers = matchers.filter { matcher in
        guard let inner = matcher["hooks"] as? [[String: Any]] else { return true }
        return !inner.contains { entry in
          (entry["command"] as? String).map { isVigilHook($0, scriptPath: scriptPath) } ?? false
        }
      }

      if matchers.isEmpty {
        hooks.removeValue(forKey: event)
      } else {
        hooks[event] = matchers
      }
    }

    if hooks.isEmpty {
      settings.removeValue(forKey: "hooks")
    } else {
      settings["hooks"] = hooks
    }
    return settings
  }

  /// Whether our hooks are already present for every event we want.
  public static func isInstalled(in settings: [String: Any], scriptPath: String) -> Bool {
    guard let hooks = settings["hooks"] as? [String: Any] else { return false }
    return claudeCodeEvents.allSatisfy { event in
      guard let matchers = hooks[event] as? [[String: Any]] else { return false }
      return matchers.contains { matcher in
        guard let inner = matcher["hooks"] as? [[String: Any]] else { return false }
        return inner.contains { entry in
          (entry["command"] as? String).map { isVigilHook($0, scriptPath: scriptPath) } ?? false
        }
      }
    }
  }
}
