import Foundation

struct CalendarSubscriptionAnnotation {
    let text: String
    let remoteObjectURLs: Set<String>
    let cancelledRemoteObjectURLs: Set<String>
    let cancelledOccurrences: Set<LocalProviderOccurrenceCancellation>
    let calendarIDs: Set<String>
}

@MainActor
struct CalendarSubscriptionSyncer {
    func sync(
        text: String,
        account: CalendarProviderAccount,
        store: LocalCalendarStore,
        ownedCalendarIDs: Set<String>? = nil
    ) throws -> LocalICSImportSummary {
        let annotator = CalendarSubscriptionAnnotator()
        let annotated = annotator.annotatedText(text, account: account)
        let calendarIDPrefix = annotator.calendarIDPrefix(for: account)
        let replies = LocalCalendarICSCodec.replies(from: text)
        let cancelledDeleted: Int
        if let ownedCalendarIDs {
            cancelledDeleted = store.removeProviderEvents(
                remoteObjectURLs: annotated.cancelledRemoteObjectURLs,
                calendarIDs: ownedCalendarIDs
            )
        } else {
            cancelledDeleted = store.removeProviderEvents(
                remoteObjectURLs: annotated.cancelledRemoteObjectURLs,
                calendarIDPrefix: calendarIDPrefix
            )
        }
        let summary: LocalICSImportSummary

        do {
            summary = try store.importICSText(annotated.text)
        } catch LocalICSImportError.noEvents where !annotated.cancelledRemoteObjectURLs.isEmpty
            || !annotated.cancelledOccurrences.isEmpty
            || !replies.isEmpty {
            let cancelledOccurrencesDeleted: Int
            let repliedCount: Int
            if let ownedCalendarIDs {
                cancelledOccurrencesDeleted = store.cancelProviderOccurrences(
                    calendarIDs: ownedCalendarIDs,
                    cancellations: annotated.cancelledOccurrences
                )
                repliedCount = store.applyReplies(replies, calendarIDs: ownedCalendarIDs)
            } else {
                cancelledOccurrencesDeleted = store.cancelProviderOccurrences(
                    calendarIDPrefix: calendarIDPrefix,
                    cancellations: annotated.cancelledOccurrences
                )
                repliedCount = store.applyReplies(replies, calendarIDPrefix: calendarIDPrefix)
            }
            return LocalICSImportSummary(
                calendarsImported: 0,
                eventsImported: 0,
                eventsUpdated: repliedCount,
                eventsSkipped: 0,
                eventsDeleted: cancelledDeleted + cancelledOccurrencesDeleted
            )
        }

        var mutableSummary = summary
        mutableSummary.eventsDeleted += cancelledDeleted
        if let ownedCalendarIDs {
            mutableSummary.eventsDeleted += store.cancelProviderOccurrences(
                calendarIDs: ownedCalendarIDs,
                cancellations: annotated.cancelledOccurrences
            )
            mutableSummary.eventsDeleted += store.pruneProviderEvents(
                calendarIDs: ownedCalendarIDs,
                keepingRemoteObjectURLs: annotated.remoteObjectURLs
            )
        } else {
            mutableSummary.eventsDeleted += store.cancelProviderOccurrences(
                calendarIDPrefix: calendarIDPrefix,
                cancellations: annotated.cancelledOccurrences
            )
            mutableSummary.eventsDeleted += store.pruneProviderEvents(
                calendarIDPrefix: calendarIDPrefix,
                keepingRemoteObjectURLs: annotated.remoteObjectURLs
            )
        }
        let deletedCalendars: (calendarsDeleted: Int, eventsDeleted: Int)
        if let ownedCalendarIDs {
            deletedCalendars = store.pruneProviderCalendars(
                ownedCalendarIDs: ownedCalendarIDs,
                keepingCalendarIDs: annotated.calendarIDs
            )
        } else {
            deletedCalendars = store.pruneProviderCalendars(
                calendarIDPrefix: calendarIDPrefix,
                keepingCalendarIDs: annotated.calendarIDs
            )
        }
        mutableSummary.eventsDeleted += deletedCalendars.eventsDeleted
        if let ownedCalendarIDs {
            mutableSummary.eventsUpdated += store.applyReplies(replies, calendarIDs: ownedCalendarIDs)
        } else {
            mutableSummary.eventsUpdated += store.applyReplies(replies, calendarIDPrefix: calendarIDPrefix)
        }
        return mutableSummary
    }
}

struct CalendarSubscriptionAnnotator {
    func annotatedText(_ text: String, account: CalendarProviderAccount) -> CalendarSubscriptionAnnotation {
        let normalizedLines = unfoldedICSLines(from: text)
        let isCancelMethod = icsPropertyValue(named: "METHOD", in: normalizedLines)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() == "CANCEL"
        let calendarID = "\(calendarIDPrefix(for: account))\(stableIdentifierComponent(for: account.endpointURLString))"
        let calendarTitle = account.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Calendar Subscription"
            : account.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let calendarColorHex = calendarColorHex(from: normalizedLines) ?? "#3B82F6"

        var output: [String] = []
        var currentEventLines: [String]?
        var currentFreeBusyLines: [String]?
        var remoteObjectURLs: Set<String> = []
        var cancelledRemoteObjectURLs: Set<String> = []
        var cancelledOccurrences: Set<LocalProviderOccurrenceCancellation> = []
        var calendarIDs: Set<String> = []
        var componentIndex = 0

        for line in normalizedLines {
            let uppercasedLine = line.uppercased()
            if uppercasedLine == "BEGIN:VEVENT" {
                currentEventLines = [line]
                continue
            }

            if uppercasedLine == "BEGIN:VFREEBUSY" {
                currentFreeBusyLines = [line]
                continue
            }

            if uppercasedLine == "END:VEVENT", var eventLines = currentEventLines {
                eventLines.append(line)
                let remoteObjectURL = remoteObjectURLString(
                    account: account,
                    componentLines: eventLines,
                    fallbackIndex: componentIndex
                )
                if isCancelledICSEvent(eventLines, isCancelMethod: isCancelMethod) {
                    cancelledRemoteObjectURLs.insert(remoteObjectURL)
                    if let cancelledOccurrence = cancelledOccurrence(from: eventLines) {
                        cancelledOccurrences.insert(cancelledOccurrence)
                    }
                    currentEventLines = nil
                    componentIndex += 1
                    continue
                }
                remoteObjectURLs.insert(remoteObjectURL)
                calendarIDs.insert(calendarID)
                output.append(contentsOf: annotatedICSComponentLines(
                    eventLines,
                    beginLine: "BEGIN:VEVENT",
                    calendarID: calendarID,
                    calendarTitle: calendarTitle,
                    calendarColorHex: calendarColorHex,
                    remoteObjectURL: remoteObjectURL
                ))
                currentEventLines = nil
                componentIndex += 1
                continue
            }

            if uppercasedLine == "END:VFREEBUSY", var freeBusyLines = currentFreeBusyLines {
                freeBusyLines.append(line)
                let remoteObjectURL = remoteObjectURLString(
                    account: account,
                    componentLines: freeBusyLines,
                    fallbackIndex: componentIndex
                )
                let freeBusyRemoteObjectURLs = freeBusyRemoteObjectURLs(
                    baseRemoteObjectURL: remoteObjectURL,
                    componentLines: freeBusyLines
                )
                remoteObjectURLs.formUnion(freeBusyRemoteObjectURLs)
                if !freeBusyRemoteObjectURLs.isEmpty {
                    calendarIDs.insert(calendarID)
                }
                output.append(contentsOf: annotatedICSComponentLines(
                    freeBusyLines,
                    beginLine: "BEGIN:VFREEBUSY",
                    calendarID: calendarID,
                    calendarTitle: calendarTitle,
                    calendarColorHex: calendarColorHex,
                    remoteObjectURL: remoteObjectURL
                ))
                currentFreeBusyLines = nil
                componentIndex += 1
                continue
            }

            if currentEventLines != nil {
                currentEventLines?.append(line)
            } else if currentFreeBusyLines != nil {
                currentFreeBusyLines?.append(line)
            } else {
                output.append(line)
            }
        }

        if let currentEventLines {
            output.append(contentsOf: currentEventLines)
        }
        if let currentFreeBusyLines {
            output.append(contentsOf: currentFreeBusyLines)
        }

        return CalendarSubscriptionAnnotation(
            text: output.joined(separator: "\r\n") + "\r\n",
            remoteObjectURLs: remoteObjectURLs,
            cancelledRemoteObjectURLs: cancelledRemoteObjectURLs,
            cancelledOccurrences: cancelledOccurrences,
            calendarIDs: calendarIDs
        )
    }

    func calendarIDPrefix(for account: CalendarProviderAccount) -> String {
        "local-calendar-ics-\(account.id)-"
    }

    private func annotatedICSComponentLines(
        _ componentLines: [String],
        beginLine: String,
        calendarID: String,
        calendarTitle: String,
        calendarColorHex: String,
        remoteObjectURL: String
    ) -> [String] {
        var output: [String] = []
        let normalizedBeginLine = beginLine.uppercased()
        for line in componentLines {
            output.append(line)
            if line.uppercased() == normalizedBeginLine {
                output.append("X-WORKING-CALENDAR-ID:\(escapeICSText(calendarID))")
                output.append("X-WORKING-CALENDAR-TITLE:\(escapeICSText(calendarTitle))")
                output.append("X-WORKING-CALENDAR-COLOR:\(escapeICSText(calendarColorHex))")
                output.append("X-WORKING-CALENDAR-ALLOWS-EVENT-WRITE:FALSE")
                output.append("X-WORKING-CALENDAR-ALLOWS-RESPONSES:FALSE")
                output.append("X-WORKING-REMOTE-OBJECT-URL:\(escapeICSText(remoteObjectURL))")
            }
        }
        return output
    }

    private func calendarColorHex(from lines: [String]) -> String? {
        for propertyName in ["X-WR-CALCOLOR", "COLOR", "X-APPLE-CALENDAR-COLOR"] {
            if let rawColor = icsPropertyValue(named: propertyName, in: lines),
               let color = normalizedCalendarColorHex(rawColor) {
                return color
            }
        }
        return nil
    }

    private func normalizedCalendarColorHex(_ value: String) -> String? {
        var color = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let semicolon = color.firstIndex(of: ";") {
            color = String(color[..<semicolon])
        }
        if color.hasPrefix("#") {
            color.removeFirst()
        }
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard color.count == 6,
              color.unicodeScalars.allSatisfy({ hexDigits.contains($0) })
        else {
            return nil
        }
        return "#\(color.uppercased())"
    }

    private func isCancelledICSEvent(_ eventLines: [String], isCancelMethod: Bool) -> Bool {
        let status = icsPropertyValue(named: "STATUS", in: eventLines)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        return isCancelMethod || status == "CANCELLED"
    }

    private func cancelledOccurrence(from eventLines: [String]) -> LocalProviderOccurrenceCancellation? {
        guard let uid = icsPropertyValue(named: "UID", in: eventLines)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !uid.isEmpty,
              let recurrenceID = icsProperty(named: "RECURRENCE-ID", in: eventLines),
              let occurrenceStartDate = icsDate(from: recurrenceID.value, params: recurrenceID.params)
        else {
            return nil
        }

        return LocalProviderOccurrenceCancellation(
            externalUID: uid,
            occurrenceStartDate: occurrenceStartDate,
            appliesToFutureOccurrences: recurrenceID.params["RANGE"]?.uppercased() == "THISANDFUTURE"
        )
    }

    private func remoteObjectURLString(
        account: CalendarProviderAccount,
        componentLines: [String],
        fallbackIndex: Int
    ) -> String {
        let uid = icsPropertyValue(named: "UID", in: componentLines)
        let recurrenceID = icsPropertyValue(named: "RECURRENCE-ID", in: componentLines)
        let stableValue = [uid, recurrenceID]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "#")

        let rawIdentifier = stableValue.isEmpty
            ? "\(fallbackIndex)-\(stableIdentifierComponent(for: componentLines.joined(separator: "\n")))"
            : stableValue

        return "ics://\(account.id)/\(base64URLEncode(rawIdentifier))"
    }

    private func freeBusyRemoteObjectURLs(baseRemoteObjectURL: String, componentLines: [String]) -> Set<String> {
        let uid = icsPropertyValue(named: "UID", in: componentLines)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var urls: Set<String> = []
        var periodIndex = 0

        for property in icsProperties(named: "FREEBUSY", in: componentLines) {
            let fbType = property.params["FBTYPE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? "BUSY"

            for periodValue in property.value.split(separator: ",").map(String.init) {
                let trimmedPeriod = periodValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedPeriod.isEmpty,
                      trimmedPeriod.split(separator: "/", maxSplits: 1).count == 2
                else {
                    continue
                }

                let sourceKey = [
                    uid,
                    trimmedPeriod,
                    fbType,
                    String(periodIndex)
                ].joined(separator: "|")
                urls.insert("\(baseRemoteObjectURL)/freebusy-\(stableIdentifierComponent(for: sourceKey))")
                periodIndex += 1
            }
        }

        return urls
    }

    private func unfoldedICSLines(from text: String) -> [String] {
        var lines: [String] = []
        for rawLine in text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n") {
            if rawLine.hasPrefix(" ") || rawLine.hasPrefix("\t"), let previous = lines.popLast() {
                lines.append(previous + String(rawLine.dropFirst()))
            } else if !rawLine.isEmpty {
                lines.append(rawLine)
            }
        }
        return lines
    }

    private func icsPropertyValue(named propertyName: String, in lines: [String]) -> String? {
        icsProperty(named: propertyName, in: lines)?.value
    }

    private func icsProperty(
        named propertyName: String,
        in lines: [String]
    ) -> (value: String, params: [String: String])? {
        icsProperties(named: propertyName, in: lines).first
    }

    private func icsProperties(
        named propertyName: String,
        in lines: [String]
    ) -> [(value: String, params: [String: String])] {
        let target = propertyName.uppercased()
        return lines.compactMap { line in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            let left = String(line[..<separator])
            let leftParts = left.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard leftParts.first?.uppercased() == target else { return nil }

            var params: [String: String] = [:]
            for part in leftParts.dropFirst() {
                guard let equal = part.firstIndex(of: "=") else { continue }
                let key = String(part[..<equal])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                var value = String(part[part.index(after: equal)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value.removeFirst()
                    value.removeLast()
                }
                params[key] = value
            }

            return (String(line[line.index(after: separator)...]), params)
        }
    }

    private func icsDate(from rawValue: String, params: [String: String]) -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")

        if params["VALUE"]?.uppercased() == "DATE" || (!value.contains("T") && value.count == 8) {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = TimeZone.current
            return formatter.date(from: value).map { Calendar.current.startOfDay(for: $0) }
        }

        if value.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return formatter.date(from: value)
        }

        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = params["TZID"].flatMap { TimeZone(identifier: $0) } ?? TimeZone.current
        return formatter.date(from: value)
    }

    private func base64URLEncode(_ value: String) -> String {
        let data = Data(value.utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func stableIdentifierComponent(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "default" }

        var hash: UInt64 = 14695981039346656037
        for byte in trimmed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }

        return String(hash, radix: 16)
    }

    private func escapeICSText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
