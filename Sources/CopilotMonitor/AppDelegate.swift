import AppKit
import Combine
import CopilotMonitorCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: MonitorModel?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var preferencesWindow: NSWindow?
    private var preferencesObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        start()
    }

    func start() {
        do {
            let demo = MonitorDatabase.isDemo
            let store = try SQLiteUsageStore(url: MonitorDatabase.url(demo: demo))
            let model = try MonitorModel(store: store, demo: demo)
            self.model = model
            preferencesObserver = NotificationCenter.default.addObserver(
                forName: .openMonitorPreferences, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.openPreferences() }
            }
            configureStatusItem(model)
            configurePopover(model)
            model.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Copilot Monitor não iniciou"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    private func configureStatusItem(_ model: MonitorModel) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        guard let button = item.button else { return }
        button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Copilot Monitor")
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        button.setAccessibilityLabel("Copilot Monitor")
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        statusItem = item
        updateStatusItem()
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }.store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func configurePopover(_ model: MonitorModel) {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 380, height: 620)
        popover.contentViewController = NSHostingController(rootView: MonitorPopoverView(model: model))
    }

    private func updateStatusItem() {
        guard let model, let button = statusItem?.button else { return }
        button.title = model.statusTitle
        button.contentTintColor = model.statusColor
        var toolTip = model.isDemo ? "Copilot Monitor · modo demo" : (model.offlineDescription() ?? "Copilot Monitor")
        if let session = model.metrics?.activeSession {
            toolTip += "\nSessão ativa · \(MonitorModel.number(session.credits)) cr"
        }
        button.toolTip = toolTip
    }

    deinit {
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(for: button)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showContextMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()
        let refresh = menu.addItem(withTitle: "Atualizar", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        let preferences = menu.addItem(withTitle: "Preferências…", action: #selector(openPreferences), keyEquivalent: ",")
        preferences.target = self
        let copy = menu.addItem(withTitle: "Copiar última resposta (debug)", action: #selector(copyResponse), keyEquivalent: "")
        copy.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Sair", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button)
    }

    @objc private func refreshNow() {
        guard let model else { return }
        Task { await model.refresh() }
    }

    @objc private func openPreferences() {
        guard let model else { return }
        if preferencesWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 500),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            window.title = "Copilot Monitor — Preferências"
            window.center()
            window.contentViewController = NSHostingController(rootView: PreferencesView(model: model))
            preferencesWindow = window
        }
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func copyResponse() {
        guard let model else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.rawResponse(), forType: .string)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
