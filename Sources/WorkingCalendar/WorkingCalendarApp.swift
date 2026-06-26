import AppKit
import SwiftUI

@main
struct WorkingCalendarApp: App {
    @NSApplicationDelegateAdaptor(WorkingCalendarAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Working Calendar") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.providerStore)
                .environmentObject(model.ruleStore)
                .task {
                    appDelegate.installOpenURLHandler { url in
                        Task { await model.handleExternalCalendarURL(url) }
                    }
                    model.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        MenuBarExtra("Working Calendar", systemImage: "calendar.badge.clock") {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.providerStore)
        }
    }
}

final class WorkingCalendarAppDelegate: NSObject, NSApplicationDelegate {
    private var openURLHandler: ((URL) -> Void)?
    private var pendingURLs: [URL] = []

    func installOpenURLHandler(_ handler: @escaping (URL) -> Void) {
        openURLHandler = handler
        let urls = pendingURLs
        pendingURLs.removeAll()
        urls.forEach(dispatch)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(dispatch)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        dispatch(URL(fileURLWithPath: filename))
        return true
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        filenames
            .map(URL.init(fileURLWithPath:))
            .forEach(dispatch)
        sender.reply(toOpenOrPrint: .success)
    }

    private func dispatch(_ url: URL) {
        if let openURLHandler {
            openURLHandler(url)
            return
        }

        if !pendingURLs.contains(url) {
            pendingURLs.append(url)
        }
    }
}
