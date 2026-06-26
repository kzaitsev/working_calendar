import Foundation

@main
struct VerifyAppIntegration {
    static func main() throws {
        try verifyInfoPlist(at: "Resources/Info.plist", expectedBundleID: "dev.codex.WorkingCalendar")
        try verifyInfoPlist(at: "build/WorkingCalendar.app/Contents/Info.plist", expectedBundleID: "dev.codex.WorkingCalendar")
        try verifyRuntimeOpenRouting()
        try verifyFantasticalStyleWorkspaceShell()
        try verifyExternalOpenDeduper()
        try verifyDockIconUsesInlineUpcomingCounter()
        print("App integration invariant passed.")
    }

    private static func verifyInfoPlist(at path: String, expectedBundleID: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AppIntegrationInvariantError("Missing Info.plist at \(path)")
        }

        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw AppIntegrationInvariantError("Could not parse Info.plist at \(path)")
        }

        try expect(plist["CFBundleIdentifier"] as? String == expectedBundleID,
                   "\(path) should use the Working Calendar bundle identifier")
        try expect(plist["CFBundlePackageType"] as? String == "APPL",
                   "\(path) should describe a macOS app bundle")
        try expect(plist["LSApplicationCategoryType"] as? String == "public.app-category.productivity",
                   "\(path) should register as a productivity app")

        let documentTypes = plist["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let calendarDocument = documentTypes.first { document in
            let extensions = stringSet(document["CFBundleTypeExtensions"])
            let mimeTypes = stringSet(document["CFBundleTypeMIMETypes"])
            return extensions.isSuperset(of: ["ics", "ifb"])
                && mimeTypes.contains("text/calendar")
        }
        guard let calendarDocument else {
            throw AppIntegrationInvariantError("\(path) should register .ics/.ifb text/calendar documents")
        }
        try expect(calendarDocument["CFBundleTypeRole"] as? String == "Viewer",
                   "\(path) should open calendar files as a viewer/import target")
        try expect(calendarDocument["LSHandlerRank"] as? String == "Alternate",
                   "\(path) should not aggressively hijack the system default calendar handler")

        let urlTypes = plist["CFBundleURLTypes"] as? [[String: Any]] ?? []
        let schemes = Set(urlTypes.flatMap { stringArray($0["CFBundleURLSchemes"]) })
        try expect(schemes.isSuperset(of: ["webcal", "webcals"]),
                   "\(path) should register webcal and webcals URL schemes")

        let notificationUsage = (plist["NSUserNotificationUsageDescription"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try expect(notificationUsage.localizedCaseInsensitiveContains("meeting alerts"),
                   "\(path) should explain notification usage for meeting alerts")
    }

    private static func verifyRuntimeOpenRouting() throws {
        let appSource = try readSource("Sources/WorkingCalendar/WorkingCalendarApp.swift")
        let contentSource = try readSource("Sources/WorkingCalendar/ContentView.swift")

        try expect(appSource.contains("@NSApplicationDelegateAdaptor"),
                   "WorkingCalendarApp should install an NSApplicationDelegate bridge for macOS open events")
        try expect(appSource.contains("WorkingCalendarAppDelegate"),
                   "WorkingCalendarApp should define an app delegate for file and URL opens")
        try expect(appSource.contains("installOpenURLHandler"),
                   "WorkingCalendarApp should attach AppModel external URL handling to the app delegate")
        try expect(appSource.contains("handleExternalCalendarURL"),
                   "WorkingCalendarApp should route delegated open events into AppModel")
        try expect(appSource.contains("application(_ application: NSApplication, open urls: [URL])"),
                   "WorkingCalendarAppDelegate should handle URL-scheme open events")
        try expect(appSource.contains("application(_ sender: NSApplication, openFile filename: String)"),
                   "WorkingCalendarAppDelegate should handle single file-open events")
        try expect(appSource.contains("application(_ sender: NSApplication, openFiles filenames: [String])"),
                   "WorkingCalendarAppDelegate should handle multi-file open events")
        try expect(appSource.contains("pendingURLs"),
                   "WorkingCalendarAppDelegate should queue external URLs until the model is ready")
        try expect(contentSource.contains(".onOpenURL"),
                   "ContentView should keep SwiftUI onOpenURL routing for scene-delivered calendar links")
    }

    private static func verifyFantasticalStyleWorkspaceShell() throws {
        let contentSource = try readSource("Sources/WorkingCalendar/ContentView.swift")
        let gridSource = try readSource("Sources/WorkingCalendar/CalendarGridView.swift")

        try expect(contentSource.contains("CalendarGridView("),
                   "Main workspace should render the calendar grid as the primary surface")
        try expect(contentSource.contains("WorkspaceAgendaRail()"),
                   "Main workspace should render agenda as a side rail")
        try expect(contentSource.contains(".frame(width: 360)"),
                   "Agenda rail should have a stable side-rail width")
        try expect(contentSource.contains("WorkspaceSplitDivider()"),
                   "Main workspace should draw an explicit vertical separator between agenda and calendar")
        try expect(contentSource.contains("Color(nsColor: .separatorColor)"),
                   "Agenda/calendar separator should use the native macOS separator color")
        guard let agendaRange = contentSource.range(of: "WorkspaceAgendaRail()"),
              let calendarRange = contentSource.range(of: "CalendarGridView(") else {
            throw AppIntegrationInvariantError("Main workspace should contain both agenda rail and calendar grid")
        }
        try expect(agendaRange.lowerBound < calendarRange.lowerBound,
                   "Agenda rail should appear to the left of the calendar grid in the main workspace")
        try expect(!contentSource.contains("WorkspaceTopBar"),
                   "Main workspace should not render a separate app chrome above the split view")
        try expect(!contentSource.contains("BrandLockup"),
                   "Main workspace should not show a redundant app icon or Working Calendar lockup")
        try expect(gridSource.contains("Menu {"),
                   "Calendar toolbar should expose secondary management from the right side")
        try expect(contentSource.contains("WorkspaceSettingsPanel"),
                   "Main workspace should route Calendars, Rules, and Settings through settings panels")
        try expect(contentSource.contains("CalendarsView(pendingProviderSourceSetupIntent:"),
                   "Calendar source management should remain available from the settings panel")
        try expect(contentSource.contains("RulesView()"),
                   "Rules management should remain available from the settings panel")
        try expect(contentSource.contains("SettingsView"),
                   "Settings should remain available from the top-right menu")
        try expect(!contentSource.contains("SidebarView(selection:"),
                   "Main workspace should not regress to the old left navigation sidebar")
        try expect(!contentSource.contains("AppSection.allCases"),
                   "Rules and calendar management should not appear as top-level sidebar sections")
        try expect(gridSource.contains("openCalendars") && gridSource.contains("openRules") && gridSource.contains("openSettings"),
                   "Calendar toolbar should keep actions for calendar sources, rules, and settings")
        try expect(gridSource.contains(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"),
                   "Calendar grid root should pin its content to the top of the main workspace")
        try expect(gridSource.contains("ScrollView(.vertical)") && !gridSource.contains("ScrollView([.vertical, .horizontal])"),
                   "Week/day time grid should not scroll horizontally independently from its all-day header")
        try expect(gridSource.contains("let availableWidth = max(gutterWidth + CGFloat(dayCount), geometry.size.width)") &&
                   gridSource.contains("let dayWidth = max(1, (availableWidth - gutterWidth) / CGFloat(dayCount))"),
                   "Week/day time grid should derive header and body columns from the same available width")
        try expect(gridSource.contains("Picker(\"\", selection: $mode)") && gridSource.contains("Button(\"Today\", action: today)"),
                   "Calendar period navigation should stay visible at the top of the main calendar surface")
    }

    private static func verifyExternalOpenDeduper() throws {
        let now = try date("2026-07-01T09:00:00Z")
        var deduper = ExternalCalendarOpenDeduper(coalescingWindow: 5)
        let fileURL = URL(fileURLWithPath: "/tmp/working-calendar/team.ics")
        let secondFileURL = URL(fileURLWithPath: "/tmp/working-calendar/other.ics")

        try expect(deduper.shouldProcess(fileURL, now: now),
                   "First external file open should be processed")
        try expect(!deduper.shouldProcess(fileURL, now: now.addingTimeInterval(1)),
                   "Duplicate external file opens inside the coalescing window should be ignored")
        try expect(deduper.shouldProcess(secondFileURL, now: now.addingTimeInterval(2)),
                   "Different external calendar files should not be coalesced")
        try expect(deduper.shouldProcess(fileURL, now: now.addingTimeInterval(5)),
                   "The same external file should be processable again after the coalescing window")

        let webcalURL = try requireURL("webcal://Calendar.Example.com/team.ics#scene")
        let canonicalWebcalURL = try requireURL("https://calendar.example.com/team.ics")
        let canonicalWebcalURLWithDefaultPort = try requireURL("https://calendar.example.com:443/team.ics")
        let webcalsURL = try requireURL("webcals://Calendar.Example.com/team.ics#scene")
        try expect(ExternalCalendarOpenDeduper.dedupeKey(for: webcalURL) == ExternalCalendarOpenDeduper.dedupeKey(for: canonicalWebcalURL),
                   "External webcal dedupe keys should match normalized HTTPS subscription URLs")
        try expect(ExternalCalendarOpenDeduper.dedupeKey(for: webcalsURL) == ExternalCalendarOpenDeduper.dedupeKey(for: canonicalWebcalURL),
                   "External webcals dedupe keys should match normalized HTTPS subscription URLs")
        try expect(ExternalCalendarOpenDeduper.dedupeKey(for: canonicalWebcalURLWithDefaultPort) == ExternalCalendarOpenDeduper.dedupeKey(for: canonicalWebcalURL),
                   "External subscription dedupe keys should ignore default HTTPS ports")

        var linkDeduper = ExternalCalendarOpenDeduper(coalescingWindow: 5)
        try expect(linkDeduper.shouldProcess(webcalURL, now: now),
                   "First external webcal open should be processed")
        try expect(!linkDeduper.shouldProcess(canonicalWebcalURL, now: now.addingTimeInterval(1)),
                   "Duplicate webcal and normalized HTTPS opens from delegate and SwiftUI routing should be coalesced")
    }

    private static func verifyDockIconUsesInlineUpcomingCounter() throws {
        let dockIconSource = try readSource("Sources/WorkingCalendar/DockIconService.swift")
        let iconGeneratorSource = try readSource("Tools/GenerateIcon.swift")

        try expect(dockIconSource.contains("app.dockTile.badgeLabel = nil"),
                   "Dock icon should avoid the default red macOS badge and draw its own inline counter")
        try expect(dockIconSource.contains("drawUpcomingPill"),
                   "Dock icon should draw the upcoming meeting count inside the icon artwork")
        try expect(iconGeneratorSource.contains("drawUpcomingPill"),
                   "Static app icon should visually match the runtime dock icon counter style")
        try expect(!iconGeneratorSource.contains("alertCenter"),
                   "Static app icon should not regress to the old red alert badge artwork")
    }

    private static func readSource(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func requireURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw AppIntegrationInvariantError("Invalid fixture URL: \(value)")
        }
        return url
    }

    private static func date(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw AppIntegrationInvariantError("Invalid fixture date: \(value)")
        }
        return date
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [String]) ?? []
    }

    private static func stringSet(_ value: Any?) -> Set<String> {
        Set(stringArray(value).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw AppIntegrationInvariantError(message)
        }
    }
}

private struct AppIntegrationInvariantError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
