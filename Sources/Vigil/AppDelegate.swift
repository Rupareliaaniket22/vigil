import AppKit
import OSLog
import SwiftUI
import VigilCore

/// `NSStatusItem` rather than SwiftUI's `MenuBarExtra`: the dropdown needs a
/// battery readout, per-session rows and programmatic dismissal, none of which
/// MenuBarExtra supports. DESIGN.md records this deviation.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private static let log = Logger(subsystem: Vigil.subsystem, category: "app")

  private let model = AppModel()
  private var statusItem: NSStatusItem!
  private var panel: FloatingPanel?

  func applicationDidFinishLaunching(_: Notification) {
    NSApp.setActivationPolicy(.accessory)
    installStatusItem()
    model.start()

    // Redraw the status item whenever the model changes, without polling.
    observeModel()
    Self.log.info("\(Vigil.displayName, privacy: .public) launched")

    if ProcessInfo.processInfo.environment["VIGIL_SMOKE"] != nil {
      runSmokeTest()
    }
  }

  func applicationWillTerminate(_: Notification) {
    model.stop()
  }

  // MARK: - Status item

  private func installStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.target = self
    statusItem.button?.action = #selector(togglePanel)
    refreshStatusItem()
  }

  private func refreshStatusItem() {
    guard let button = statusItem.button else { return }

    // Fill versus outline carries the state, never colour — which keeps it
    // legible with Differentiate Without Color enabled.
    let symbol = model.decision.holdIdleAssertion ? "eye.fill" : "eye"
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.statusLine)
    image?.isTemplate = true
    button.image = image
    button.appearsDisabled = model.isPaused

    // A count cannot be encoded in a 16pt silhouette, so it goes beside it.
    let working = model.workingCount
    button.title = working > 1 ? " \(working)" : ""
    button.setAccessibilityLabel("\(Vigil.displayName), \(model.statusLine)")
  }

  /// Observation re-registers after every change, which is how `@Observable`
  /// tracking works — one shot per observed read.
  private func observeModel() {
    withObservationTracking {
      _ = model.decision
      _ = model.sessions
      _ = model.pausedUntil
    } onChange: {
      Task { @MainActor [weak self] in
        self?.refreshStatusItem()
        self?.observeModel()
      }
    }
  }

  // MARK: - Panel

  @objc private func togglePanel() {
    if let panel, panel.isVisible {
      panel.orderOut(nil)
      return
    }
    guard let button = statusItem.button else { return }

    model.reevaluate()

    let panel = panel ?? makePanel()
    self.panel = panel
    panel.show(relativeTo: button)
  }

  private func makePanel() -> FloatingPanel {
    FloatingPanel(
      contentView: MenuPanelView(
        model: model,
        onQuit: { NSApp.terminate(nil) },
        onSettings: { [weak self] in self?.openSettings() }
      )
    )
  }

  /// Build the panel for real and report its measured size, then exit.
  ///
  /// Exists because a SwiftUI layout crash only shows up when the view is
  /// actually instantiated, and CI has no one to click the menu bar.
  private func runSmokeTest() {
    let panel = makePanel()
    panel.contentView?.layoutSubtreeIfNeeded()
    let size = panel.contentView?.fittingSize ?? .zero
    print("smoke: panel built, fitting size \(Int(size.width))x\(Int(size.height))")
    guard size.width > 0, size.height > 0 else {
      print("smoke: FAILED - panel has zero size")
      exit(1)
    }
    print("smoke: ok")
    exit(0)
  }

  private func openSettings() {
    panel?.orderOut(nil)
    // TODO: settings window. Until it exists, say so rather than doing nothing.
    Self.log.notice("settings window not implemented yet")
  }
}
