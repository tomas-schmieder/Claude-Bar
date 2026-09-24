import AppKit
import ClaudeBarCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let store = UsageStore()
    private let popover = NSPopover()
    private var timerTask: Task<Void, Never>?

    private let refreshInterval: Duration = .seconds(5 * 60)

    override init() {
        // Never show interactive Keychain UI for "Claude Code-credentials".
        // Usage comes from Claude CLI / Web / silent OAuth cache instead.
        ClaudeOAuthKeychainPromptPreference.setStoredMode(.never)

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = self.statusItem.button {
            button.imagePosition = .imageOnly
            button.setAccessibilityTitle("ClaudeBar")
            button.target = self
            button.action = #selector(self.statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hosting = NSHostingController(rootView: PopoverView(
            store: self.store,
            onPreferencesChanged: { [weak self] in self?.updateIcon() }))
        hosting.sizingOptions = .preferredContentSize
        self.popover.contentViewController = hosting
        self.popover.behavior = .transient
        self.popover.animates = true

        self.store.onChange = { [weak self] in self?.updateIcon() }
        self.updateIcon()
    }

    func start() {
        self.store.refreshAll(userInitiated: true)
        self.timerTask?.cancel()
        let interval = self.refreshInterval
        self.timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                self?.store.refreshAll(userInitiated: false)
            }
        }
    }

    func stop() {
        self.timerTask?.cancel()
        self.store.cancelAll()
    }

    // MARK: Clicks

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            self.showContextMenu(from: sender)
        } else {
            self.togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if self.popover.isShown {
            self.popover.performClose(nil)
            return
        }
        self.store.refreshIfStale()
        // Activate so the popover becomes key (hover readouts and keyboard shortcuts need it).
        NSApp.activate()
        self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let refresh = NSMenuItem(title: "Refresh All", action: #selector(self.refreshAction(_:)), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())

        let showsItem = NSMenuItem(title: "Menu Bar Shows", action: nil, keyEquivalent: "")
        let showsMenu = NSMenu()
        for provider in AIProvider.allCases {
            let item = NSMenuItem(
                title: provider.displayName,
                action: #selector(self.selectMenuBarProvider(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = provider.rawValue
            item.state = provider == AppPreferences.menuBarProvider ? .on : .off
            showsMenu.addItem(item)
        }
        showsItem.submenu = showsMenu
        menu.addItem(showsItem)

        let styleItem = NSMenuItem(title: "Menu Bar Icon", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for style in MenuBarIconStyle.allCases {
            let item = NSMenuItem(
                title: style.menuTitle,
                action: #selector(self.selectMenuBarIconStyle(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = style == MenuBarIconStylePreference.current ? .on : .off
            styleMenu.addItem(item)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit ClaudeBar",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func refreshAction(_ sender: Any?) {
        self.store.refreshAll(userInitiated: true)
    }

    @objc private func selectMenuBarProvider(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let provider = AIProvider(rawValue: raw) else { return }
        AppPreferences.menuBarProvider = provider
        self.updateIcon()
    }

    @objc private func selectMenuBarIconStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = MenuBarIconStyle(rawValue: raw) else { return }
        MenuBarIconStylePreference.set(style)
        self.updateIcon()
    }

    // MARK: Icon

    private func updateIcon() {
        var provider = AppPreferences.menuBarProvider
        if !self.store.isEnabled(provider), let first = self.store.enabledProviders.first {
            provider = first
        }
        let state = self.store.state(for: provider)
        let windows = state.limits?.windows.filter(\.usageKnown) ?? []
        let stale = state.limitsAreStale || (state.limits == nil && state.limitsError != nil)

        // Claude's crab notches only make sense for Claude; other providers use plain bars.
        let preferred = MenuBarIconStylePreference.current
        let style: MenuBarIconStyle = provider == .claude || preferred == .barsOnly ? preferred : .barsOnly
        self.statusItem.button?.image = IconRenderer.makeClaudeIcon(
            sessionRemaining: windows.first?.window.remainingPercent,
            weeklyRemaining: windows.dropFirst().first?.window.remainingPercent,
            stale: stale,
            style: style)
        self.statusItem.button?.toolTip = self.tooltip()
    }

    private func tooltip() -> String {
        var lines = ["ClaudeBar"]
        for provider in self.store.enabledProviders {
            let state = self.store.state(for: provider)
            let parts = (state.limits?.windows.filter(\.usageKnown) ?? []).prefix(2).map {
                "\($0.title) \(Int($0.window.remainingPercent.rounded()))% left"
            }
            if !parts.isEmpty {
                lines.append("\(provider.displayName): \(parts.joined(separator: " · "))")
            } else if state.limitsError != nil {
                lines.append("\(provider.displayName): unavailable")
            }
        }
        return lines.joined(separator: "\n")
    }
}
