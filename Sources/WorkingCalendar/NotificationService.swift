import AppKit
import AVFoundation
import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    private let speechSynthesizer = AVSpeechSynthesizer()

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func deliver(_ alert: MeetingAlert) {
        if alert.rule.systemNotification {
            sendUserNotification(alert)
        }

        if alert.rule.playSound {
            playSound(for: alert.rule.priority)
        }

        if alert.rule.speak {
            let utterance = AVSpeechUtterance(string: "\(alert.event.title). \(alert.startsText).")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
            speechSynthesizer.speak(utterance)
        }

        if alert.rule.bounceDock {
            NSApp.requestUserAttention(alert.rule.priority == .critical ? .criticalRequest : .informationalRequest)
        }
    }

    private func sendUserNotification(_ alert: MeetingAlert) {
        let content = UNMutableNotificationContent()
        content.title = alert.event.title
        content.subtitle = "\(alert.startsText) · \(alert.event.calendarTitle)"
        content.body = [Formatters.eventRange(alert.event), alert.event.meetingMethod.title, alert.displayLocation]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "meeting-\(alert.event.id)-\(alert.rule.id)-\(alert.fireIndex)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private func playSound(for priority: AlertPriority) {
        let soundName: NSSound.Name

        switch priority {
        case .normal:
            soundName = NSSound.Name("Glass")
        case .important:
            soundName = NSSound.Name("Ping")
        case .critical:
            soundName = NSSound.Name("Basso")
        }

        NSSound(named: soundName)?.play()
    }
}
