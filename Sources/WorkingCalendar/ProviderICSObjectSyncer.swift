import Foundation

@MainActor
struct ProviderICSObjectSyncer {
    func syncObject(
        text: String,
        protocolText: String? = nil,
        remoteObjectURL: String,
        calendarIDPrefix: String,
        store: LocalCalendarStore,
        ownedCalendarIDs: Set<String>? = nil,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String> = [],
        preservingLocalResponsesForRemoteObjectURLs protectedResponseRemoteObjectURLs: Set<String> = []
    ) throws -> LocalICSImportSummary {
        let protocolText = protocolText ?? text
        let replies = LocalCalendarICSCodec.replies(from: protocolText)

        do {
            var summary = try store.importICSText(
                text,
                preservingLocalResponsesForRemoteObjectURLs: protectedResponseRemoteObjectURLs
            )
            if let ownedCalendarIDs {
                summary.eventsUpdated += store.applyReplies(replies, calendarIDs: ownedCalendarIDs)
            } else {
                summary.eventsUpdated += store.applyReplies(replies, calendarIDPrefix: calendarIDPrefix)
            }
            return summary
        } catch LocalICSImportError.noEvents {
            let cancellationTargets = LocalCalendarICSCodec.cancellationTargets(from: protocolText)
            if !replies.isEmpty {
                let repliedCount: Int
                if let ownedCalendarIDs {
                    repliedCount = store.applyReplies(replies, calendarIDs: ownedCalendarIDs)
                } else {
                    repliedCount = store.applyReplies(replies, calendarIDPrefix: calendarIDPrefix)
                }
                return LocalICSImportSummary(
                    calendarsImported: 0,
                    eventsImported: 0,
                    eventsUpdated: repliedCount,
                    eventsSkipped: 0,
                    eventsDeleted: 0
                )
            }

            if !cancellationTargets.isEmpty {
                let deletedEvents: Int
                let deletedOccurrences: Int
                if let ownedCalendarIDs {
                    deletedEvents = store.removeEvents(
                        externalUIDs: cancellationTargets.eventUIDs,
                        calendarIDs: ownedCalendarIDs,
                        protectingRemoteObjectURLs: protectedRemoteObjectURLs
                    )
                    deletedOccurrences = store.cancelProviderOccurrences(
                        calendarIDs: ownedCalendarIDs,
                        cancellations: cancellationTargets.occurrences,
                        protectingRemoteObjectURLs: protectedRemoteObjectURLs
                    )
                } else {
                    deletedEvents = store.removeEvents(
                        externalUIDs: cancellationTargets.eventUIDs,
                        calendarIDPrefix: calendarIDPrefix,
                        protectingRemoteObjectURLs: protectedRemoteObjectURLs
                    )
                    deletedOccurrences = store.cancelProviderOccurrences(
                        calendarIDPrefix: calendarIDPrefix,
                        cancellations: cancellationTargets.occurrences,
                        protectingRemoteObjectURLs: protectedRemoteObjectURLs
                    )
                }
                let deletedRemoteEvents = cancellationTargets.eventUIDs.isEmpty
                    ? 0
                    : removeProviderEvents(
                        store: store,
                        remoteObjectURL: remoteObjectURL,
                        calendarIDPrefix: calendarIDPrefix,
                        ownedCalendarIDs: ownedCalendarIDs,
                        protectingRemoteObjectURLs: protectedRemoteObjectURLs
                    )
                return LocalICSImportSummary(
                    calendarsImported: 0,
                    eventsImported: 0,
                    eventsUpdated: 0,
                    eventsSkipped: 0,
                    eventsDeleted: deletedEvents + deletedRemoteEvents + deletedOccurrences
                )
            }

            return LocalICSImportSummary(
                calendarsImported: 0,
                eventsImported: 0,
                eventsUpdated: 0,
                eventsSkipped: 0,
                eventsDeleted: removeProviderEvents(
                    store: store,
                    remoteObjectURL: remoteObjectURL,
                    calendarIDPrefix: calendarIDPrefix,
                    ownedCalendarIDs: ownedCalendarIDs,
                    protectingRemoteObjectURLs: protectedRemoteObjectURLs
                )
            )
        }
    }

    private func removeProviderEvents(
        store: LocalCalendarStore,
        remoteObjectURL: String,
        calendarIDPrefix: String,
        ownedCalendarIDs: Set<String>?,
        protectingRemoteObjectURLs protectedRemoteObjectURLs: Set<String>
    ) -> Int {
        if let ownedCalendarIDs {
            return store.removeProviderEvents(
                remoteObjectURLs: [remoteObjectURL],
                calendarIDs: ownedCalendarIDs,
                protectingRemoteObjectURLs: protectedRemoteObjectURLs
            )
        }
        return store.removeProviderEvents(
            remoteObjectURLs: [remoteObjectURL],
            calendarIDPrefix: calendarIDPrefix,
            protectingRemoteObjectURLs: protectedRemoteObjectURLs
        )
    }
}
