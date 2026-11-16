import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
enum OrbitBarMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PanelController?
    private let hotKeys = HotKeys()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        #if DEBUG
        if let directory = ProcessInfo.processInfo.environment["ORBITBAR_SNAPSHOT"] { Snapshots.run(to: directory) }
        #endif
        let model = AppModel()
        let panel = PanelController(model: model)
        self.panel = panel
        model.launch()

        hotKeys.register(keyCode: kVK_ANSI_O, modifiers: cmdKey | optionKey) { [weak panel] in panel?.toggle() }
        if ProcessInfo.processInfo.environment["ORBITBAR_OPEN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { panel.show() }
        }
        hotKeys.register(keyCode: kVK_ANSI_N, modifiers: cmdKey | optionKey) { [weak panel] in panel?.quickAdd() }
    }
}

extension AppDelegate {
    /// A menu bar app shows no menu bar, but text fields still get ⌘C, ⌘V, ⌘A, ⌘X and ⌘Z only
    /// through the key equivalents of an Edit menu. This one is never visible.
    func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
            .keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "OrbitBar", action: nil, keyEquivalent: ""))
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

/// The status item and its popover. Owns the key-down monitor that drives `AppModel.handleKey`.
@MainActor
final class PanelController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        super.init()

        if let button = statusItem.button {
            button.image = OrbitLogo.templateImage()
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: RootView().environment(model))
        popover.contentSize = NSSize(width: RootView.width, height: RootView.height)

        model.closePanel = { [weak self] in self?.close() }
        model.refocusPanel = { [weak self] in self?.popover.contentViewController?.view.window?.makeKey() }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open OrbitBar", action: #selector(openFromMenu), keyEquivalent: "").target = self
        if model.phase == .signedIn {
            menu.addItem(withTitle: "Open Orbit in Browser", action: #selector(openOrbitFromMenu), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit OrbitBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openFromMenu() { show() }
    @objc private func openOrbitFromMenu() { model.openOrbit() }

    func toggle() {
        popover.isShown ? close() : show()
    }

    func quickAdd() {
        show()
        if model.phase == .signedIn, model.screen != .editor { model.newTask() }
    }

    func show() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        NSApp.activate(ignoringOtherApps: true)
        let window = popover.contentViewController?.view.window
        window?.makeKey()
        // The list opens without a focused text field, so single-key shortcuts work at once.
        if model.phase == .signedIn, model.screen == .list || model.screen == .editor && model.draft?.isNew == false && !model.editingDescription {
            DispatchQueue.main.async { window?.makeFirstResponder(nil) }
        }
        model.panelDidOpen()
        installKeyMonitor()
    }

    func close() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.confirmTrash = nil
        model.statusPicker = nil
        // Give focus back to the app that had it. Staying active would keep the menu bar shown
        // over a full-screen app.
        // Not while signed out: a provider sign-in window may be open.
        if NSApp.isActive, model.phase == .signedIn { NSApp.hide(nil) }
        if model.screen == .help { model.screen = .list }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.popover.contentViewController?.view.window else { return event }
            // The status picker is a popover of its own: its keys come from its window.
            guard event.window === window || self.model.statusPicker != nil else { return event }
            let responder = window.firstResponder
            let editingText = responder is NSText
            // While a field is edited, its field editor (an NSTextView) is the first responder and
            // the field is its delegate.
            let field = (responder as? NSTextView)?.delegate as? NSTextField
            let inSearchField = editingText && (self.model.searchFocused || field?.placeholderString == SearchField.placeholder)
            return self.model.handleKey(event, editingText: editingText, inSearchField: inSearchField) ? nil : event
        }
    }
}
