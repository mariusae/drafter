import AppKit
import DrafterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let directoryKey = "DraftsDirectory"

    private var store: DraftStore!
    private var windowController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = UserDefaults.standard.string(forKey: Self.directoryKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? DraftsDirectory.defaultRoot
        store = DraftStore(root: root)
        NSApp.mainMenu = MainMenu.build()
        windowController = MainWindowController(store: store)
        windowController.showWindow(nil)
        NSApp.activate()
        Snapshot.scheduleIfRequested(windowController)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController.showWindow(nil) }
        return true
    }

    // Activation can come before launch has finished — when macOS asks
    // about reopening windows after a crash — so neither assumes a window.

    func applicationDidResignActive(_ notification: Notification) {
        windowController?.editor.saveNow()
        windowController?.recordState()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store?.reload()
    }

    /// Saves, and gives git a moment to commit and push what was saved, so a
    /// draft written just before quitting is not left only on this disk.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowController.editor.saveNow()
        windowController.recordState()
        guard let git = store.git else { return .terminateNow }
        // Off the main actor, and answered through the run loop: while
        // terminate: waits, the main queue may be blocked beneath it, but its
        // modal run loop still runs.
        Task.detached {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await git.commitAndPush() }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    @objc func chooseDraftsFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder your drafts are kept in."
        panel.directoryURL = store.directory.root
        guard let window = windowController.window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            self.windowController.editor.saveNow()
            UserDefaults.standard.set(url.path, forKey: Self.directoryKey)
            SessionState.shared.openDraft = nil
            self.windowController.editor.show(nil)
            self.store.open(url)
        }
    }
}
