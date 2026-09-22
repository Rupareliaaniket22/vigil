import AppKit
import Carbon.HIToolbox
import OSLog

/// A single system-wide hotkey, via Carbon's `RegisterEventHotKey`.
///
/// Carbon rather than an `NSEvent` global monitor because the Carbon route
/// needs no Accessibility permission. A utility whose whole pitch is "I only
/// watch power state" should not be asking to observe every keystroke on the
/// machine, and people are right to refuse apps that do.
@MainActor
final class GlobalShortcut {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "shortcut")

  /// Carbon hands the callback a plain C context, so the handler is reached
  /// through a file-scoped box rather than a captured closure.
  private static var handler: (@MainActor () -> Void)?
  private static var eventHandler: EventHandlerRef?
  private static var hotKey: EventHotKeyRef?

  private static let signature: OSType = 0x5647_4C00  // 'VGL\0'

  /// Register ⌥⌘L to run `action`.
  ///
  /// Returns false if the combination is already taken by another app — worth
  /// surfacing rather than failing silently, since the user will otherwise
  /// press it and wonder why nothing happens.
  @discardableResult
  static func register(_ action: @escaping @MainActor () -> Void) -> Bool {
    unregister()
    handler = action

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )

    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, _ in
        // Hop to the main actor; Carbon calls us on the main thread but the
        // compiler cannot know that.
        Task { @MainActor in GlobalShortcut.handler?() }
        return noErr
      },
      1,
      &eventType,
      nil,
      &eventHandler
    )

    guard status == noErr else {
      log.error("could not install hotkey handler: \(status, privacy: .public)")
      return false
    }

    let id = EventHotKeyID(signature: signature, id: 1)
    let registered = RegisterEventHotKey(
      UInt32(kVK_ANSI_L),
      UInt32(optionKey | cmdKey),
      id,
      GetApplicationEventTarget(),
      0,
      &hotKey
    )

    guard registered == noErr else {
      log.notice("⌥⌘L is already taken by another app")
      unregister()
      return false
    }
    return true
  }

  static func unregister() {
    if let hotKey {
      UnregisterEventHotKey(hotKey)
      Self.hotKey = nil
    }
    if let eventHandler {
      RemoveEventHandler(eventHandler)
      Self.eventHandler = nil
    }
    handler = nil
  }
}
