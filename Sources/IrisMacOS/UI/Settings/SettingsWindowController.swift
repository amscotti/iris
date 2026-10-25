import AppKit
import SwiftUI

/// One explicitly owned window, shared by every Settings entry point.
/// SwiftUI renders the panes; AppKit owns their lifetime and activation.
/// No SettingsLink/private selector, hidden bootstrap window, or Dock-policy
/// transition is needed to create the first window in a menu-bar app.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("iris.settings")
    private weak var environment: AppEnvironment?
    /// Token box so deinit can remove observers without touching
    /// MainActor-isolated stored properties from a nonisolated context.
    private let observers = SettingsObserverTokens()
    private var presentationPending = false
    private var foregroundRequested = false

    init(environment: AppEnvironment) {
        self.environment = environment
        let window = Self.makeWindow()
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: SettingsView().environment(environment))
        let toolbar = NSToolbar(identifier: "iris.settings.panes")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        window.toolbarStyle = .preference
        window.toolbar = toolbar
        select(environment.selectedSettingsTab)
        window.setFrameAutosaveName("IrisSettings")
        if !window.setFrameUsingName("IrisSettings") { window.center() }
        observers.activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishActivation() }
        }
        observers.launch = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.presentationPending == true || self?.foregroundRequested == true {
                    self?.enqueuePresentation()
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        // The box removes both observers; NotificationCenter removal is
        // thread-safe.
        observers.removeAll()
    }

    /// Configure only the window we own, before it is ordered. Assigning a
    /// compatible behavior set here avoids unioning moveToActiveSpace with
    /// SwiftUI's canJoinAllSpaces/fullScreenPrimary flags (an AppKit trap).
    static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsPage.width, height: SettingsPage.height),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.contentMinSize = NSSize(width: SettingsPage.width, height: SettingsPage.height)
        window.identifier = windowIdentifier
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // Ordinary ordering lets another active window cover Settings,
        // including the system permission panes opened from this window.
        window.level = .normal
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // `.resizable` enables the zoom button; Settings is a fixed-content
        // window, so zoom stays disabled as documented.
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        return window
    }

    func present() {
        guard !presentationPending else { return }
        presentationPending = true
        // NSRunningApplication.isFinishedLaunching is an asynchronously
        // updated workspace value: testing it can miss didFinishLaunching
        // and strand the first request. Always enqueue; the launch observer
        // repeats an outstanding activation if startup is still in flight.
        enqueuePresentation()
    }

    private func enqueuePresentation() {
        // NSMenu restores focus as it stops tracking. Present in the default
        // run-loop mode after that handoff, including on the very first click.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.bringForward() }
        }
    }

    private func bringForward() {
        presentationPending = false
        guard let window else { return }
        foregroundRequested = true
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        if NSApplication.shared.isActive { finishActivation() }
    }

    private func finishActivation() {
        guard foregroundRequested, let window, window.isVisible else { return }
        foregroundRequested = false
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        foregroundRequested = false
    }

    /// Releases the hosted SwiftUI tree and the window. The hosting
    /// controller's view environment captures AppEnvironment strongly, so
    /// the environment → controller → window → content view reference cycle
    /// never deallocates on its own; AppEnvironment.stop() calls this.
    /// Reopening builds a fresh window; the autosaved frame survives.
    func teardown() {
        observers.removeAll()
        window?.delegate = nil
        window?.close()
        window?.contentViewController = nil
        window = nil
    }

    func select(_ pane: SettingsTab) {
        let appName = environment?.isSettingsPreview == true ? "Iris Preview" : "Iris"
        window?.title = "\(pane.title) — \(appName)"
        window?.toolbar?.selectedItemIdentifier = NSToolbarItem.Identifier(pane.rawValue)
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let pane = SettingsTab(rawValue: sender.itemIdentifier.rawValue) else { return }
        environment?.selectedSettingsTab = pane
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace] + toolbarSelectableItemIdentifiers(toolbar) + [.flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsTab(rawValue: identifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }
}

/// Deinit-safe observer storage (same pattern as SystemEvents.ObserverTokens):
/// a plain class whose own deinit runs on any thread and removes what it
/// holds, so the @MainActor controller never touches isolated state in deinit.
final class SettingsObserverTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var activationToken: NSObjectProtocol?
    private var launchToken: NSObjectProtocol?

    var activation: NSObjectProtocol? {
        get { lock.withLock { activationToken } }
        set { lock.withLock { activationToken = newValue } }
    }

    var launch: NSObjectProtocol? {
        get { lock.withLock { launchToken } }
        set { lock.withLock { launchToken = newValue } }
    }

    func removeAll() {
        let (activation, launch) = lock.withLock {
            let current = (activationToken, launchToken)
            activationToken = nil
            launchToken = nil
            return current
        }
        if let activation { NotificationCenter.default.removeObserver(activation) }
        if let launch { NotificationCenter.default.removeObserver(launch) }
    }

    deinit { removeAll() }
}
