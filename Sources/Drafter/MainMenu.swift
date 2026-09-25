import AppKit

/// The menu bar, built in code. Every command the app has is here, with its
/// shortcut, because the menu bar is where a Mac user looks for them.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        let name = "Drafter"

        main.addItem(submenu(name, [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Choose Drafts Folder…", #selector(AppDelegate.chooseDraftsFolder(_:)), ","),
            .separator(),
            servicesItem(),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("File", [
            item("New Draft", #selector(MainWindowController.newDraft(_:)), "n"),
            item("Open Notes", #selector(MainWindowController.openNotes(_:)), "n", [.command, .option]),
            .separator(),
            item("Save", #selector(MainWindowController.saveDraft(_:)), "s"),
            item("Rename to Match Title", #selector(MainWindowController.renameToTitle(_:))),
            .separator(),
            item("Show in Finder", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .shift]),
            item("Copy Path", #selector(MainWindowController.copyPath(_:)), "c", [.command, .option]),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]))

        let find = submenu("Find", [
            findItem("Find…", .showFindInterface, "f"),
            findItem("Find and Replace…", .showReplaceInterface, "f", [.command, .option]),
            findItem("Find Next", .nextMatch, "g"),
            findItem("Find Previous", .previousMatch, "g", [.command, .shift]),
            findItem("Use Selection for Find", .setSearchString, "e"),
            item("Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j"),
        ])
        let spelling = submenu("Spelling and Grammar", [
            item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
            item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
            .separator(),
            item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
            item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))),
        ])
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            find,
            spelling,
        ]))

        main.addItem(submenu("View", [
            item("Inbox", #selector(MainWindowController.showInbox(_:)), "1"),
            item("Archive", #selector(MainWindowController.showArchive(_:)), "2"),
            .separator(),
            item("Bigger", #selector(MainWindowController.makeTextBigger(_:)), "+"),
            item("Smaller", #selector(MainWindowController.makeTextSmaller(_:)), "-"),
            item("Actual Size", #selector(MainWindowController.makeTextStandardSize(_:)), "0"),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        main.addItem(submenu("Go", [
            item("Go to Anything…", #selector(MainWindowController.goToAnything(_:)), "k"),
            item("Run Command…", #selector(MainWindowController.runCommand(_:)), "k", [.command, .shift]),
            .separator(),
            item("Next Draft", #selector(MainWindowController.nextDraft(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            item("Previous Draft", #selector(MainWindowController.previousDraft(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            .separator(),
            item("Draft List", #selector(MainWindowController.focusList(_:)), "l", [.command, .option]),
            item("Editor", #selector(MainWindowController.focusEditor(_:)), "e", [.command, .option]),
        ]))

        main.addItem(submenu("Draft", [
            item("Archive", #selector(MainWindowController.toggleArchive(_:)), "a", [.command, .control]),
            item("Sync Now", #selector(MainWindowController.syncNow(_:)), "r"),
        ]))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        let help = submenu("Help", [])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func findItem(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                                 _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = self.item(title, #selector(NSResponder.performTextFinderAction(_:)), key, modifiers)
        item.tag = action.rawValue
        return item
    }

    private static func servicesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Services")
        item.submenu = menu
        NSApp.servicesMenu = menu
        return item
    }
}
