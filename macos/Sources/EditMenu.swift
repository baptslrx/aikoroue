import AppKit

/// Menu Édition : sans lui, ⌘V, ⌘C, ⌘X, ⌘A et ⌘Z ne font rien dans les champs de texte.
@MainActor
enum EditMenu {
    static func install(appName: String) {
        let main = NSApp.mainMenu ?? NSMenu()
        if main.items.isEmpty {
            let appItem = NSMenuItem()
            let appMenu = NSMenu()
            appMenu.addItem(withTitle: "Masquer \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            appMenu.addItem(withTitle: "Quitter \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appItem.submenu = appMenu
            main.addItem(appItem)
        }
        let hasEdit = main.items.contains { item in
            item.submenu?.items.contains { $0.action == #selector(NSText.paste(_:)) } == true
        }
        if !hasEdit {
            let editItem = NSMenuItem()
            let edit = NSMenu(title: "Édition")
            edit.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
            let redo = edit.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            edit.addItem(.separator())
            edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            editItem.submenu = edit
            main.addItem(editItem)
        }
        NSApp.mainMenu = main
    }
}
