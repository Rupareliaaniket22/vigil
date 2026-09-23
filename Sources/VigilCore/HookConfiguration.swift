import Foundation

/// Merging Vigil's hooks into an agent's settings file.
///
/// Pure JSON transformation, kept here rather than in the app layer because
/// editing someone's editor configuration is exactly the kind of thing that
/// must be tested before it ever runs. The rules: never drop a setting we
/// don't understand, never install twice, and always be removable.
public enum HookConfiguration {

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

  /// Whether a hook entry is one of ours, in either shape a host might use.
  static func isOurs(_ matcher: [String: Any], scriptPath: String) -> Bool {
    if let command = matcher["command"] as? String {
      return isVigilHook(command, scriptPath: scriptPath)
    }
    guard let inner = matcher["hooks"] as? [[String: Any]] else { return false }
    return inner.contains { entry in
      (entry["command"] as? String).map { isVigilHook($0, scriptPath: scriptPath) } ?? false
    }
  }

  /// Add an agent's hooks to its settings, leaving everything else alone.
  ///
  /// The event-to-state mapping is baked into the command at install time
  /// (`vigil-hook.sh <agent> <event> <state>`) rather than branching inside the
  /// shell script. That keeps one script for every agent and keeps the mapping
  /// here, where it is typed and tested.
  ///
  /// Idempotent: installing twice produces the same result as installing once.
  public static func install(
    into settings: [String: Any],
    scriptPath: String,
    integration: AgentIntegration
  ) -> [String: Any] {
    var settings = settings
    var hooks = settings["hooks"] as? [String: Any] ?? [:]

    for event in integration.allEvents {
      let state = integration.state(for: event)
      var matchers = hooks[event] as? [[String: Any]] ?? []

      // Drop any previous entry of ours before adding, so a changed script path
      // replaces the old one instead of accumulating beside it. Uses the same
      // shape-aware check as uninstall — the nested-only version silently
      // failed for Cursor's flat entries, duplicating them on every install.
      matchers = matchers.filter { !isOurs($0, scriptPath: scriptPath) }

      // Quoted: an unquoted path containing a space made the shell try to run
      // its first word, so every hook failed silently.
      let command = "'\(scriptPath)' \(integration.id.rawValue) \(event) \(state.rawValue)"

      switch integration.entryFormat {
      case .nested:
        var entry: [String: Any] = ["type": "command", "command": command]
        if let timeout = integration.timeoutMilliseconds { entry["timeout"] = timeout }
        matchers.append(["hooks": [entry]])
      case .flat:
        var entry: [String: Any] = ["command": command]
        if let timeout = integration.timeoutMilliseconds { entry["timeout"] = timeout }
        matchers.append(entry)
      }
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

      matchers = matchers.filter { !isOurs($0, scriptPath: scriptPath) }

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
  public static func isInstalled(
    in settings: [String: Any],
    scriptPath: String,
    integration: AgentIntegration
  ) -> Bool {
    missingEvents(in: settings, scriptPath: scriptPath, integration: integration).isEmpty
  }

  /// The events we expect a hook for and did not find one.
  ///
  /// `isInstalled` is the same question asked as a yes or no, but the list is
  /// what makes a half-installed agent explicable: when Vigil's expected event
  /// set grows between versions, an older install fails the yes/no check with
  /// nothing to say about *why*, and the panel quietly under-reports.
  public static func missingEvents(
    in settings: [String: Any],
    scriptPath: String,
    integration: AgentIntegration
  ) -> [String] {
    let hooks = settings["hooks"] as? [String: Any] ?? [:]
    return integration.allEvents.filter { event in
      guard let matchers = hooks[event] as? [[String: Any]] else { return true }
      return !matchers.contains { isOurs($0, scriptPath: scriptPath) }
    }
  }
}

/// What an agent's hook setup looks like from the user's side.
public enum HookSetupState: Sendable, Equatable {
  /// Wired up for everything we listen for.
  case ready
  /// Events are arriving, but not every hook we now expect is registered —
  /// an install from an older version of Vigil. This is the case that used to
  /// be invisible: the agent is plainly working, so it never appeared in the
  /// "needs setting up" list, and the panel silently reported less than the
  /// truth.
  case outOfDate
  /// Never wired up, and not reporting.
  case notSetUp
}

extension HookConfiguration {
  /// Classify an agent from what its settings file actually contains.
  ///
  /// The distinction that matters is between "never set up" and "set up by a
  /// version of Vigil that listened for a different set of events", and it is
  /// readable straight off the file: some of our hooks present and some absent
  /// can only be an older install.
  ///
  /// Deliberately not a function of whether the agent is currently reporting.
  /// Tying it to live sessions meant an agent kept its out-of-date badge for
  /// the whole staleness window after the user had just removed it — pressing
  /// them to reinstall what they had deliberately taken out.
  public static func setupState(missingEvents: [String], expectedEvents: [String])
    -> HookSetupState
  {
    if missingEvents.isEmpty { return .ready }
    if missingEvents.count < expectedEvents.count { return .outOfDate }
    return .notSetUp
  }
}
