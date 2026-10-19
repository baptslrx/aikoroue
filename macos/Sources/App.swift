import AppKit
import ServiceManagement

@main
@MainActor
struct AikoRoueMain {
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
    private var statusItem: NSStatusItem!
    private var watcher: DragWatcher!
    private var wheel: RadialPanel!
    private var toast: Toast!
    private var recorder: ShortcutRecorder!
    private let defaults = UserDefaults.standard

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled"); watcher.isEnabled = newValue }
    }

    private var reveal: Bool {
        get { defaults.bool(forKey: "reveal") }
        set { defaults.set(newValue, forKey: "reveal") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        toast = Toast()

        wheel = RadialPanel()
        wheel.onPick = { [weak self] action, urls in
            self?.perform(action, on: urls)
        }

        recorder = ShortcutRecorder()
        recorder.onSave = { [weak self] trigger in
            trigger.save()
            self?.watcher.trigger = trigger
            self?.rebuildMenu()
        }

        watcher = DragWatcher()
        watcher.isEnabled = enabled
        watcher.trigger = Trigger.load()
        watcher.onShiftDrag = { [weak self] urls, point in
            self?.openWheel(for: urls, at: point)
        }
        watcher.onMouseUp = { [weak self] in
            self?.wheel.dismiss(after: 0.4)
        }
        watcher.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = statusBarIcon()
        rebuildMenu()

        if !defaults.bool(forKey: "welcomed") {
            defaults.set(true, forKey: "welcomed")
            showWelcome()
        }
    }

    // MARK: - Roue

    private func openWheel(for urls: [URL], at point: NSPoint) {
        guard enabled else { return }
        let actions = Catalog.actions(for: urls)
        guard !actions.isEmpty else { return }
        wheel.present(actions: actions, badge: Catalog.badge(for: urls), count: urls.count, at: point)
    }

    private func perform(_ action: FileAction, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        let anchor = NSEvent.mouseLocation
        toast.show("\(action.verb)…", spinning: true, near: anchor)
        let showInFinder = reveal
        Task { @MainActor [weak self] in
            do {
                let outputs = try await action.run(urls)
                NSSound(named: "Glass")?.play()
                let message: String
                if outputs.count == 1 {
                    message = "✓ \(outputs[0].lastPathComponent)"
                } else {
                    message = "✓ \(outputs.count) fichiers créés"
                }
                self?.toast.show(message, spinning: false, near: anchor, hideAfter: 2.2)
                if showInFinder, !outputs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
            } catch {
                NSSound(named: "Basso")?.play()
                self?.toast.show("⚠︎ \(error.localizedDescription)", spinning: false, near: anchor, hideAfter: 4.5)
            }
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        let head = NSMenuItem(title: "AikoRoue", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        let hint = NSMenuItem(title: "\(watcher.trigger.label) + glisser un fichier", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(item("Changer le raccourci…", #selector(changeShortcut)))
        statusItem.button?.toolTip = "AikoRoue — \(watcher.trigger.label) + glisser un fichier"

        menu.addItem(.separator())
        menu.addItem(item("Activé", #selector(toggleEnabled), on: enabled))
        menu.addItem(item("Montrer le résultat dans le Finder", #selector(toggleReveal), on: reveal))
        menu.addItem(item("Ouvrir au démarrage du Mac", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled))
        menu.addItem(.separator())
        menu.addItem(item("Quitter AikoRoue", #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func item(_ title: String, _ selector: Selector, on: Bool? = nil, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        i.target = self
        if let on { i.state = on ? .on : .off }
        return i
    }

    @objc private func changeShortcut() {
        recorder.open(current: watcher.trigger)
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        rebuildMenu()
    }

    @objc private func toggleReveal() {
        reveal.toggle()
        rebuildMenu()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Impossible de modifier l'ouverture au démarrage"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AikoRoue est prêt"
        alert.informativeText = """
        Glisse un fichier depuis le Finder en maintenant la touche Maj (⇧) : une roue apparaît.

        • Anneau intérieur : convertir dans un autre format
        • Anneau extérieur : outils (compresser, détourer, pivoter, fusionner…)
        • Lâcher au centre : annuler

        Tu peux changer la touche Maj pour celle de ton choix dans le menu de l'icône → « Changer le raccourci… ».

        Le résultat est créé à côté du fichier d'origine. AikoRoue vit dans la barre des menus (icône en forme de roue).
        """
        alert.addButton(withTitle: "C'est parti")
        alert.runModal()
    }
}
