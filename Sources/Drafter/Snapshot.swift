import AppKit

/// For looking at the app without screen-recording permission: with
/// DRAFTER_SNAPSHOT=<dir> set, the app draws its windows into PNGs there a
/// moment after launch, then again with ⌘K open, and quits.
@MainActor
enum Snapshot {
    static func scheduleIfRequested(_ controller: MainWindowController) {
        guard let dir = ProcessInfo.processInfo.environment["DRAFTER_SNAPSHOT"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        let env = ProcessInfo.processInfo.environment
        if let location = env["DRAFTER_SNAPSHOT_CURSOR"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                controller.editor.reveal(NSRange(location: location, length: 5), atTop: true, flash: false)
                controller.editor.textView.setSelectedRange(NSRange(location: location, length: 5))
            }
        }
        if env["DRAFTER_SNAPSHOT_NOTES"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { controller.toggleNotes(nil) }
        }
        if let text = env["DRAFTER_SNAPSHOT_TYPE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                (controller.window?.firstResponder as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        if let heading = env["DRAFTER_SNAPSHOT_HEADING"].flatMap(Int.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { controller.editor.goToHeading(heading) }
        }
        if env["DRAFTER_SNAPSHOT_TIMELINE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { controller.showTimeline(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { controller.nextDraftOrEntry() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if let query = ProcessInfo.processInfo.environment["DRAFTER_SNAPSHOT_QUERY"] {
                controller.goToAnything(query: query)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                    write(window, to: url.appendingPathComponent("window-\(index).png"))
                }
                NSApp.terminate(nil)
            }
        }
    }

    private static func write(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
