import Foundation
import SwiftUI
import Combine
import UIKit
import AVFoundation
import UserNotifications

#if canImport(AlarmKit)
import AlarmKit
#endif

/// AlarmKit only needs metadata for the Live Activity UI, so an empty payload is enough.
#if canImport(AlarmKit)
struct AlarmMetadataPayload: AlarmMetadata {}
#endif

enum ScheduleError: LocalizedError {
    case notificationsDenied

    var errorDescription: String? {
        switch self {
        case .notificationsDenied:
            return "通知权限被拒绝，请到「设置 → 秒闹钟 → 通知」中允许通知。"
        }
    }
}

@MainActor
final class AlarmScheduler: ObservableObject {
    static let shared = AlarmScheduler()

    private enum Keys {
        static let fireDate = "alarm.fireDate"
        static let usesSystemAlarm = "alarm.usesSystemAlarm"
        static let alarmKitID = "alarm.alarmKitID"
    }

    private static let notificationID = "alarmclock.local"

    @Published private(set) var fireDate: Date?
    @Published private(set) var isRinging = false
    @Published private(set) var scheduleDescription = ""
    @Published private(set) var errorMessage: String?

    private var alarmKitID: UUID?
    private var monitor: Timer?
    private var player: AVAudioPlayer?
    private var usesSystemAlarm = false

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Keys.alarmKitID) {
            alarmKitID = UUID(uuidString: raw)
        }

        if let stored = UserDefaults.standard.object(forKey: Keys.fireDate) as? Date {
            if stored > Date() {
                fireDate = stored
                usesSystemAlarm = UserDefaults.standard.bool(forKey: Keys.usesSystemAlarm)
                scheduleDescription = "已设定"
                startMonitor()
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.fireDate)
                UserDefaults.standard.removeObject(forKey: Keys.usesSystemAlarm)
            }
        }
    }

    // MARK: - Scheduling

    func schedule(at date: Date) async {
        errorMessage = nil
        guard date.timeIntervalSinceNow > 0.5 else {
            errorMessage = "请选择一个晚于当前时间的时间。"
            return
        }

        await clearScheduledAlerts()

        var usedAlarmKit = false
        var alarmKitError: Error?

        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do {
                usedAlarmKit = try await scheduleWithAlarmKit(at: date)
            } catch {
                alarmKitError = error
            }
        }
        #endif

        if usedAlarmKit {
            scheduleDescription = "系统闹钟 · 可穿透静音与专注模式"
        } else {
            do {
                try await scheduleNotification(at: date)
                if alarmKitError != nil {
                    scheduleDescription = "本地通知 · 系统闹钟不可用，已降级"
                } else {
                    scheduleDescription = "本地通知 · 静音模式下可能没有声音"
                }
            } catch {
                errorMessage = error.localizedDescription
                fireDate = nil
                return
            }
        }

        fireDate = date
        usesSystemAlarm = usedAlarmKit
        UserDefaults.standard.set(date, forKey: Keys.fireDate)
        UserDefaults.standard.set(usedAlarmKit, forKey: Keys.usesSystemAlarm)
        startMonitor()
    }

    func cancel() async {
        monitor?.invalidate()
        monitor = nil
        stopRinging()
        fireDate = nil
        usesSystemAlarm = false
        scheduleDescription = ""
        UserDefaults.standard.removeObject(forKey: Keys.fireDate)
        UserDefaults.standard.removeObject(forKey: Keys.usesSystemAlarm)
        await clearScheduledAlerts()
    }

    /// Called when the app becomes active again, so a passed deadline still rings.
    func refresh() {
        tick()
    }

    private func clearScheduledAlerts() async {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.notificationID])

        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), let id = alarmKitID {
            try? await AlarmManager.shared.cancel(id: id)
        }
        #endif

        alarmKitID = nil
        UserDefaults.standard.removeObject(forKey: Keys.alarmKitID)
    }

    // MARK: - AlarmKit (iOS 26+)

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private func scheduleWithAlarmKit(at date: Date) async throws -> Bool {
        let manager = AlarmManager.shared
        let state = try await manager.requestAuthorization()
        guard state == .authorized else { return false }

        let alert = AlarmPresentation.Alert(
            title: "闹钟时间到了",
            stopButton: .stopButton,
            secondaryButton: nil,
            secondaryButtonBehavior: nil
        )

        let attributes = AlarmAttributes<AlarmMetadataPayload>(
            presentation: AlarmPresentation(alert: alert, countdown: nil, paused: nil),
            metadata: AlarmMetadataPayload(),
            tintColor: .orange
        )

        let configuration = AlarmManager.AlarmConfiguration(
            countdownDuration: nil,
            schedule: .fixed(date),
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: nil,
            sound: .default
        )

        let id = UUID()
        _ = try await manager.schedule(id: id, configuration: configuration)
        alarmKitID = id
        UserDefaults.standard.set(id.uuidString, forKey: Keys.alarmKitID)
        return true
    }
    #endif

    // MARK: - Local notification fallback

    private func scheduleNotification(at date: Date) async throws {
        let center = UNUserNotificationCenter.current()
        let granted = try await center.requestAuthorization(options: [.alert, .sound])
        guard granted else { throw ScheduleError.notificationsDenied }

        let content = UNMutableNotificationContent()
        content.title = "闹钟时间到了"
        content.body = "现在是 \(Self.clockString(date))"
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "alarm.wav"))

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, date.timeIntervalSinceNow),
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: Self.notificationID,
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }

    // MARK: - Foreground ringing

    private func startMonitor() {
        monitor?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitor = timer
        tick()
    }

    private func tick() {
        guard let fireDate, !isRinging, Date() >= fireDate else { return }

        // AlarmKit already presents its own full-screen alert with sound,
        // so the app must not ring a second time on top of it.
        if usesSystemAlarm {
            monitor?.invalidate()
            monitor = nil
            self.fireDate = nil
            usesSystemAlarm = false
            scheduleDescription = ""
            alarmKitID = nil
            UserDefaults.standard.removeObject(forKey: Keys.fireDate)
            UserDefaults.standard.removeObject(forKey: Keys.usesSystemAlarm)
            UserDefaults.standard.removeObject(forKey: Keys.alarmKitID)
            return
        }

        startRinging()
    }

    private func startRinging() {
        guard !isRinging else { return }
        isRinging = true
        monitor?.invalidate()
        monitor = nil

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)

        if let url = Bundle.main.url(forResource: "alarm", withExtension: "wav") {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.volume = 1
            player?.play()
        }

        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    private func stopRinging() {
        player?.stop()
        player = nil
        isRinging = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Formatting

    static func clockString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
