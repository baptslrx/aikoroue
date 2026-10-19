import AppKit

/// Détecte, sans aucune permission spéciale, qu'un fichier est en train d'être glissé
/// (n'importe où dans macOS) pendant que la touche choisie (Maj par défaut) est enfoncée.
///
/// Principe : quand un glisser-déposer commence, le système écrit les fichiers dans le
/// presse-papiers de glisser (`NSPasteboard(name: .drag)`), ce qui incrémente son
/// `changeCount`. On surveille ce compteur pendant que le bouton de la souris est enfoncé.
@MainActor
final class DragWatcher: NSObject {
    var onShiftDrag: (([URL], NSPoint) -> Void)?
    var onMouseUp: (() -> Void)?
    var isEnabled = true
    var trigger = Trigger.shift

    private var timer: Timer?
    private var wasDown = false
    private var lastCount = NSPasteboard(name: .drag).changeCount
    private var baseline = 0
    private var firedForThisDrag = false

    func start() {
        let t = Timer(timeInterval: 0.03, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        let pasteboard = NSPasteboard(name: .drag)
        let count = pasteboard.changeCount
        let down = (NSEvent.pressedMouseButtons & 1) == 1

        if down && !wasDown {
            // Nouveau clic : on mémorise l'état du presse-papiers d'avant le clic.
            baseline = lastCount
            firedForThisDrag = false
        }
        if !down && wasDown {
            onMouseUp?()
        }
        wasDown = down
        lastCount = count

        guard isEnabled, down, !firedForThisDrag, count != baseline,
              trigger.isPressed() else { return }

        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }

        firedForThisDrag = true
        onShiftDrag?(urls, NSEvent.mouseLocation)
    }
}
