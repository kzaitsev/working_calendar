import Foundation

enum CalendarSubscriptionDecoder {
    static func text(from data: Data, contentType: String?) -> String? {
        for encoding in encodings(contentType: contentType) {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    static func encodings(contentType: String?) -> [String.Encoding] {
        var encodings: [String.Encoding] = []

        if let charset = contentType.flatMap(charset),
           let encoding = stringEncoding(forCharset: charset) {
            encodings.append(encoding)
        }

        encodings.append(contentsOf: [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .isoLatin1,
            .windowsCP1252,
            windowsCyrillicEncoding,
            isoLatinCyrillicEncoding,
            .macOSRoman
        ])

        var seen: Set<UInt> = []
        return encodings.filter { seen.insert($0.rawValue).inserted }
    }

    static func charset(from contentType: String) -> String? {
        for part in contentType.split(separator: ";").dropFirst() {
            let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2,
                  pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "charset"
            else {
                continue
            }

            let charset = pieces[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return charset.isEmpty ? nil : charset
        }

        return nil
    }

    static func stringEncoding(forCharset charset: String) -> String.Encoding? {
        let normalized = charset.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        let compact = normalized.replacingOccurrences(of: "-", with: "")

        switch normalized {
        case "utf-8", "utf8":
            return .utf8
        case "utf-16", "utf16", "unicode":
            return .utf16
        case "utf-16le", "utf16le":
            return .utf16LittleEndian
        case "utf-16be", "utf16be":
            return .utf16BigEndian
        case "iso-8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "iso-8859-5", "iso-ir-144", "cyrillic":
            return isoLatinCyrillicEncoding
        case "windows-1251", "cp1251", "cp-1251", "x-cp1251", "x-cp-1251", "x-windows-1251", "windows-cyrillic":
            return windowsCyrillicEncoding
        case "windows-1252", "cp1252", "cp-1252", "x-cp1252", "x-cp-1252", "x-windows-1252":
            return .windowsCP1252
        case "us-ascii", "ascii", "ansi-x3.4-1968":
            return .ascii
        case "macintosh", "mac-roman", "macos-roman":
            return .macOSRoman
        default:
            if compact == "iso88591" {
                return .isoLatin1
            }
            if compact == "iso88595" {
                return isoLatinCyrillicEncoding
            }
            return ianaStringEncoding(forCharset: normalized)
        }
    }

    private static func ianaStringEncoding(forCharset charset: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        guard nsEncoding != UInt(kCFStringEncodingInvalidId) else { return nil }
        return String.Encoding(rawValue: nsEncoding)
    }

    private static let windowsCyrillicEncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)
        )
    )

    private static let isoLatinCyrillicEncoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.isoLatinCyrillic.rawValue)
        )
    )
}
