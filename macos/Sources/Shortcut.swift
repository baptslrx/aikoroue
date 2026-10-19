import AppKit

/// La touche (ou combinaison) à maintenir pendant le glisser pour ouvrir la roue.
struct Trigger: Codable, Equatable {
    var modifiers: UInt          // NSEvent.ModifierFlags (⇧ ⌃ ⌥ ⌘)
    var keyCode: UInt16?         // touche « normale » éventuelle (A, Espace, F5…)
    var keyLabel: String?

    static let shift = Trigger(modifiers: NSEvent.ModifierFlags.shift.rawValue, keyCode: nil, keyLabel: nil)
    static let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(Trigger.relevant)
    }

    var label: String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃ Ctrl") }
        if flags.contains(.option) { parts.append("⌥ Option") }
        if flags.contains(.shift) { parts.append("⇧ Maj") }
        if flags.contains(.command) { parts.append("⌘ Cmd") }
        if let key = keyLabel { parts.append(key) }
        return parts.isEmpty ? "—" : parts.joined(separator: " + ")
    }

    /// Lu directement auprès du système : aucune surveillance du clavier.
    func isPressed() -> Bool {
        guard flags.isEmpty == false || keyCode != nil else { return false }
        let current = NSEvent.modifierFlags.intersection(Trigger.relevant)
        guard current.isSuperset(of: flags) else { return false }
        if let code = keyCode {
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
        }
        return true
    }

    static func load() -> Trigger {
        guard let data = UserDefaults.standard.data(forKey: "trigger"),
              let saved = try? JSONDecoder().decode(Trigger.self, from: data) else { return .shift }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "trigger")
        }
    }

    static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case 49: return "Espace"
        case 48: return "Tab"
        case 36, 76: return "Entrée"
        case 51: return "⌫"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: break
        }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return "Touche \(event.keyCode)"
        }
        if (0xF704...0xF726).contains(scalar.value) { return "F\(scalar.value - 0xF703)" }
        if scalar.value < 33 || (0xF700...0xF8FF).contains(scalar.value) { return "Touche \(event.keyCode)" }
        return String(scalar).uppercased()
    }
}

/// Petite fenêtre « Appuie sur la touche voulue ».
@MainActor
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    var onSave: ((Trigger) -> Void)?

    private var window: NSWindow?
    private var monitor: Any?
    private var pending = Trigger.shift
    private var held: NSEvent.ModifierFlags = []
    private let display = NSTextField(labelWithString: "")

    func open(current: Trigger) {
        NSApp.activate(ignoringOtherApps: true)
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            return
        }
        pending = current
        held = []

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 230),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Raccourci AikoRoue"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let intro = NSTextField(wrappingLabelWithString:
            "Appuie sur la touche ou la combinaison qui ouvrira la roue pendant que tu glisses un fichier.")
        intro.font = .systemFont(ofSize: 13)

        display.font = .systemFont(ofSize: 24, weight: .semibold)
        display.alignment = .center
        display.textColor = .labelColor
        display.stringValue = current.label

        let hint = NSTextField(wrappingLabelWithString:
            "Dans le Finder, ⌥ Option copie et ⌘ Cmd déplace le fichier si tu le lâches ailleurs que sur la roue. Maj ou une lettre n'ont pas cet effet.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        let reset = NSButton(title: "Rétablir Maj", target: self, action: #selector(resetToShift))
        let cancel = NSButton(title: "Annuler", target: self, action: #selector(cancelRecording))
        let save = NSButton(title: "Enregistrer", target: self, action: #selector(saveRecording))
        save.bezelColor = Theme.accentBlue
        for b in [reset, cancel, save] { b.refusesFirstResponder = true }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [reset, spacer, cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [intro, display, hint, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: w.contentRect(forFrameRect: w.frame))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            intro.widthAnchor.constraint(equalToConstant: 360),
            hint.widthAnchor.constraint(equalToConstant: 360),
            display.widthAnchor.constraint(equalToConstant: 360),
            buttons.widthAnchor.constraint(equalToConstant: 360),
        ])
        w.contentView = content
        w.center()
        window = w

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return nil
        }
        w.makeKeyAndOrderFront(nil)
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(Trigger.relevant)
        if event.type == .flagsChanged {
            if mods.isEmpty {
                held = []
            } else {
                held.formUnion(mods)
                pending = Trigger(modifiers: held.rawValue, keyCode: nil, keyLabel: nil)
            }
        } else if event.type == .keyDown {
            if event.keyCode == 53 {  // Échap
                cancelRecording()
                return
            }
            pending = Trigger(modifiers: mods.rawValue, keyCode: event.keyCode, keyLabel: Trigger.keyName(event))
        }
        display.stringValue = pending.label
    }

    @objc private func resetToShift() {
        pending = .shift
        display.stringValue = pending.label
    }

    @objc private func saveRecording() {
        onSave?(pending)
        window?.close()
    }

    @objc private func cancelRecording() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window = nil
    }
}
