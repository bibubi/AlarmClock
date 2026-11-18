import Foundation
import SwiftUI
import Combine
import UIKit
import AVFoundation
import UserNotifications

#if canImport(AlarmKit)
import AlarmKit
#endif

#if canImport(AlarmKit)
struct AlarmMetadataPayload: AlarmMetadata {}
#endif

// MARK: - Model

enum MedSlot: String, Codable, Identifiable {
    case morning, evening

    var id: String { rawValue }
    var label: String { self == .morning ? "早上" : "晚上" }
    var shortLabel: String { self == .morning ? "早" : "晚" }

    func flipped() -> MedSlot { self == .morning ? .evening : .morning }
}

struct PlannedDose: Codable, Equatable, Identifiable {
    var date: Date
    var slot: MedSlot

    var id: String { PlannedDose.doseId(for: date, slot: slot) }

    static func doseId(for date: Date, slot: MedSlot) -> String {
        "\(Int(date.timeIntervalSince1970))-\(slot.rawValue)"
    }
}

enum DoseAction: String {
    case taken, skipped

    var label: String { self == .taken ? "已服用" : "已跳过" }
}

// MARK: - Scheduler

@MainActor
final class AlarmScheduler: ObservableObject {
    static let shared = AlarmScheduler()

    static let preScheduleCount = 32          // 提前预排的剂次数量
    static let activeRingGrace: TimeInterval = 2 * 3600   // 打开 App 时补响铃的时限
    static let recordRetention: TimeInterval = 7 * 24 * 3600
    static let defaultEveningMinutes = 22 * 60 + 30

    private enum Keys {
        static let interval = "med.intervalHalfDays"
        static let morningMinutes = "med.morningMinutes"
        static let eveningMinutes = "med.eveningMinutes"
        static let lastDoseDate = "med.lastDoseDate"
        static let lastDoseSlot = "med.lastDoseSlot"
        static let isRunning = "med.isRunning"
        static let plan = "med.plan"
        static let records = "med.records"
        static let snoozeUntil = "med.snoozeUntil"
        static let snoozeDose = "med.snoozeDose"
        static let alarmIDs = "med.alarmIDs"
        static let testAlarmID = "med.testAlarmID"
        static let testFireDate = "med.testFireDate"
    }

    static let snoozeDuration: TimeInterval = 10 * 60
    static let snoozeNotificationID = "med.snooze"
    static let testNotificationID = "medtest"
    static let testDelay: TimeInterval = 10
    /// 通知提示音（三音上行循环 ~28 秒）；随包内 chime.wav 生成
    static let notificationSound = "chime.wav"

    // MARK: settings（修改后自动重建计划）

    @Published var intervalHalfDays: Int {
        didSet { persist(); scheduleRebuild() }
    }
    @Published var morningMinutes: Int {
        didSet { persist(); scheduleRebuild() }
    }
    @Published var eveningMinutes: Int {
        didSet { persist(); scheduleRebuild() }
    }
    @Published var lastDoseDate: Date {
        didSet { persist(); scheduleRebuild() }
    }
    @Published var lastDoseSlot: MedSlot {
        didSet { persist(); scheduleRebuild() }
    }
    @Published private(set) var isRunning: Bool

    // MARK: runtime state

    @Published private(set) var plan: [PlannedDose] = []
    @Published private(set) var isRinging = false
    @Published private(set) var ringingDose: PlannedDose?
    @Published private(set) var snoozedDose: PlannedDose?
    @Published private(set) var snoozeUntil: Date?
    @Published private(set) var scheduleDescription = ""
    @Published private(set) var errorMessage: String?
    /// 系统闹钟（AlarmKit）是否可用；不可用时退化为本地通知
    @Published private(set) var usesSystemAlarm = false
    /// 当前是否是手动测试触发的响铃（测试不写入服药记录）
    @Published private(set) var isTestRing = false
    /// 测试提醒实际挂在哪条通道上，直接显示给用户，便于判断锁屏会不会响
    @Published private(set) var testArmInfo = ""

    private var records: [String: String] = [:]
    private var alarmIDs: [String: String] = [:]   // doseId -> AlarmKit UUID
    private var snoozeAlarmID: String?
    private var testAlarmID: String?
    /// 测试提醒的预定触发时刻；用于回到前台时判断是否已过点需要补响
    private var testFireDate: Date?
    private var monitor: Timer?
    private var player: AVAudioPlayer?
    private var rebuildTask: Task<Void, Never>?
    private var rebuildGeneration = 0

    private let defaults = UserDefaults.standard

    // MARK: init

    private init() {
        let interval = defaults.object(forKey: Keys.interval) as? Int ?? 2
        intervalHalfDays = min(14, max(1, interval))
        morningMinutes = defaults.object(forKey: Keys.morningMinutes) as? Int ?? 7 * 60 + 30
        eveningMinutes = defaults.object(forKey: Keys.eveningMinutes) as? Int ?? Self.defaultEveningMinutes
        lastDoseSlot = MedSlot(rawValue: defaults.string(forKey: Keys.lastDoseSlot) ?? "") ?? .evening

        if let stored = defaults.object(forKey: Keys.lastDoseDate) as? Date {
            lastDoseDate = stored
        } else {
            // 默认校准：昨天晚上（常见场景）
            var day = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
            day = Calendar.current.startOfDay(for: day)
            let m = Self.defaultEveningMinutes
            lastDoseDate = Calendar.current.date(
                byAdding: DateComponents(minute: m),
                to: day
            ) ?? day
        }

        isRunning = defaults.bool(forKey: Keys.isRunning)

        if let data = defaults.data(forKey: Keys.records),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            records = decoded
        }
        if let data = defaults.data(forKey: Keys.plan),
           let decoded = try? JSONDecoder().decode([PlannedDose].self, from: data) {
            plan = decoded
        }
        if let until = defaults.object(forKey: Keys.snoozeUntil) as? Date,
           let data = defaults.data(forKey: Keys.snoozeDose),
           let dose = try? JSONDecoder().decode(PlannedDose.self, from: data) {
            snoozedDose = dose
            snoozeUntil = until
        }
        pruneRecords()
    }

    // MARK: derived

    var isAlternating: Bool { intervalHalfDays % 2 == 1 }
    var isTwiceDaily: Bool { intervalHalfDays == 1 }

    var intervalText: String {
        let days = Double(intervalHalfDays) / 2
        return days.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(days))
            : String(format: "%.1f", days)
    }

    var intervalHint: String {
        if isTwiceDaily { return "每天 2 次 · 早晚各一次" }
        if isAlternating { return "每 \(intervalText) 天 1 次 · 早晚自动交替" }
        return "每 \(intervalText) 天 1 次 · 固定在\(lastDoseSlot.label)"
    }

    func anchor(for slot: MedSlot) -> (hour: Int, minute: Int) {
        let m = slot == .morning ? morningMinutes : eveningMinutes
        return (m / 60, m % 60)
    }

    func anchorDate(for slot: MedSlot, on day: Date = Date()) -> Date {
        let (h, m) = anchor(for: slot)
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: day)
        comps.hour = h
        comps.minute = m
        return Calendar.current.date(from: comps) ?? day
    }

    var missedDoses: [PlannedDose] {
        let now = Date()
        return plan.filter { $0.date <= now && records[$0.id] == nil }
    }

    var upcomingDoses: [PlannedDose] {
        let now = Date()
        return plan.filter { $0.date > now }
    }

    /// 下一个等待用户操作（已服用/跳过）的剂次，可能是刚过点的未记录剂次
    var nextActionable: PlannedDose? {
        plan.first { records[$0.id] == nil }
    }

    func action(for dose: PlannedDose) -> DoseAction? {
        records[dose.id].flatMap(DoseAction.init(rawValue:))
    }

    /// 下一次实际会响铃的剂次与时刻：稍后提醒生效时取稍后时间，否则取下一剂计划时间
    var nextReminder: (dose: PlannedDose, date: Date)? {
        if let dose = snoozedDose, let until = snoozeUntil,
           records[dose.id] == nil, until > Date() {
            return (dose, until)
        }
        guard let dose = nextActionable else { return nil }
        return (dose, dose.date)
    }

    // MARK: start / stop

    func start() async {
        errorMessage = nil
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            if !granted {
                errorMessage = "通知权限被拒绝，请到系统设置里允许「通知」"
            }
        } catch {
            errorMessage = "通知授权失败：\(error.localizedDescription)"
        }
        isRunning = true
        defaults.set(true, forKey: Keys.isRunning)
        scheduleRebuild()
    }

    func stop() async {
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuildGeneration += 1
        await cancelAllScheduled()
        await cancelSnoozeReminder()
        monitor?.invalidate()
        monitor = nil
        stopRinging()
        clearSnooze()
        isRunning = false
        defaults.set(false, forKey: Keys.isRunning)
        plan = []
        scheduleDescription = ""
    }

    func refreshOnActive() async {
        await resumeTestIfNeeded()
        guard isRunning else { return }
        startMonitor()
        let futureUnrecorded = upcomingDoses.filter { records[$0.id] == nil }.count
        if futureUnrecorded < 16 {
            scheduleRebuild()
        }
        if let until = snoozeUntil, until > Date() {
            await scheduleSnoozeReminder()
        }
        evaluateRinging()
    }

    // MARK: scheduling core

    /// 由上一剂推导下一剂：非整天间隔时早晚交替，钟点取对应锚点时间
    private func nextDose(after prev: PlannedDose) -> PlannedDose {
        let slot: MedSlot = isAlternating ? prev.slot.flipped() : prev.slot
        let nominal = prev.date.addingTimeInterval(Double(intervalHalfDays) * 12 * 3600)
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: nominal)
        let (h, m) = anchor(for: slot)
        comps.hour = h
        comps.minute = m
        let date = Calendar.current.date(from: comps) ?? nominal
        return PlannedDose(date: date, slot: slot)
    }

    func buildUpcoming(count: Int) -> [PlannedDose] {
        var result: [PlannedDose] = []
        var current = PlannedDose(date: lastDoseDate, slot: lastDoseSlot)
        var steps = 0
        let now = Date()
        while result.count < count && steps < 500 {
            steps += 1
            let next = nextDose(after: current)
            current = next
            if next.date > now { result.append(next) }
        }
        return result
    }

    private func scheduleRebuild() {
        guard isRunning else { return }
        rebuildGeneration += 1
        let generation = rebuildGeneration
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            await self?.rebuild(generation: generation)
        }
    }

    private func rebuild(generation: Int) async {
        let upcoming = buildUpcoming(count: Self.preScheduleCount)
        plan = upcoming
        defaults.set(encode(upcoming), forKey: Keys.plan)

        var usedSystem = false
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do {
                let state = try await AlarmManager.shared.requestAuthorization()
                usedSystem = (state == .authorized)
            } catch {
                usedSystem = false
            }
        }
        #endif
        guard generation == rebuildGeneration, !Task.isCancelled else { return }

        usesSystemAlarm = usedSystem
        scheduleDescription = usedSystem
            ? "系统闹钟 · 可穿透静音与专注模式"
            : "本地通知 · 静音模式下可能没有声音"

        await scheduleAll(upcoming)
        guard generation == rebuildGeneration, !Task.isCancelled else { return }

        // 重建会清空全部已排定提醒，稍后提醒需要重新挂回
        await scheduleSnoozeReminder()
        guard generation == rebuildGeneration, !Task.isCancelled else { return }

        startMonitor()
        evaluateRinging()
    }

    /// 先清空全部已排定提醒，再逐剂重新排定，保证与当前计划严格一致
    private func scheduleAll(_ doses: [PlannedDose]) async {
        await cancelAllScheduled()

        if usesSystemAlarm {
            #if canImport(AlarmKit)
            if #available(iOS 26.0, *) {
                let manager = AlarmManager.shared
                for dose in doses {
                    do {
                        let uuid = try await scheduleAlarmKit(dose, at: dose.date, manager: manager)
                        alarmIDs[dose.id] = uuid.uuidString
                    } catch {
                        // 单剂排定失败 → 该剂退化为本地通知，绝不静默丢弃
                        await addNotification(for: dose)
                    }
                }
            }
            #endif
        } else {
            for dose in doses {
                await addNotification(for: dose)
            }
        }

        defaults.set(encode(alarmIDs), forKey: Keys.alarmIDs)
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private func scheduleAlarmKit(_ dose: PlannedDose, at date: Date, manager: AlarmManager) async throws -> UUID {
        let alert = AlarmPresentation.Alert(
            title: "该吃药了",
            stopButton: AlarmButton(
                text: "知道了",
                textColor: .white,
                systemImageName: "pills.fill"
            )
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
        return id
    }

    /// App 已在前台自行响铃时，撤掉这一剂的系统闹钟，避免两路声音叠加
    @available(iOS 26.0, *)
    private func cancelSystemAlarm(for dose: PlannedDose) async {
        guard let uuidStr = alarmIDs[dose.id], let uuid = UUID(uuidString: uuidStr) else { return }
        try? await AlarmManager.shared.cancel(id: uuid)
        alarmIDs[dose.id] = nil
        defaults.set(encode(alarmIDs), forKey: Keys.alarmIDs)
    }

    /// 测试提醒的系统闹钟：10 秒后触发，锁屏也全屏弹出
    @available(iOS 26.0, *)
    private func scheduleTestAlarmKit(at date: Date) async throws -> UUID {
        let alert = AlarmPresentation.Alert(
            title: "测试提醒",
            stopButton: AlarmButton(
                text: "知道了",
                textColor: .white,
                systemImageName: "pills.fill"
            )
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
        _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
        return id
    }
    #endif

    private func addNotification(for dose: PlannedDose) async {
        let interval = dose.date.timeIntervalSinceNow
        guard interval > 0.5 else { return }
        let content = UNMutableNotificationContent()
        content.title = "该吃药了"
        content.body = "\(Self.dateText(dose.date)) \(Self.timeText(dose.date)) · \(dose.slot.label)剂"
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: Self.notificationSound))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: "med.\(dose.id)", content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: snooze（稍后提醒）

    /// 稍后提醒：不记录本剂，10 分钟后再次响铃
    func snooze(_ dose: PlannedDose) async {
        snoozedDose = dose
        snoozeUntil = Date().addingTimeInterval(Self.snoozeDuration)
        persistSnooze()
        stopRinging()
        await scheduleSnoozeReminder()
    }

    private func scheduleSnoozeReminder() async {
        await cancelSnoozeReminder()
        guard isRunning,
              let dose = snoozedDose,
              let until = snoozeUntil,
              until.timeIntervalSinceNow > 0.5,
              records[dose.id] == nil else { return }

        if usesSystemAlarm {
            #if canImport(AlarmKit)
            if #available(iOS 26.0, *) {
                do {
                    let uuid = try await scheduleAlarmKit(dose, at: until, manager: AlarmManager.shared)
                    snoozeAlarmID = uuid.uuidString
                    return
                } catch {
                    // 系统闹钟排定失败 → 退化为本地通知
                }
            }
            #endif
        }

        let content = UNMutableNotificationContent()
        content.title = "该吃药了"
        content.body = "\(Self.dateText(dose.date)) \(Self.timeText(dose.date)) · \(dose.slot.label)剂 尚未记录"
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: Self.notificationSound))
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, until.timeIntervalSinceNow),
            repeats: false
        )
        let request = UNNotificationRequest(
            identifier: Self.snoozeNotificationID,
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func cancelSnoozeReminder() async {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.snoozeNotificationID])
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            if let id = snoozeAlarmID, let uuid = UUID(uuidString: id) {
                try? await AlarmManager.shared.cancel(id: uuid)
            }
        }
        #endif
        snoozeAlarmID = nil
        persistSnooze()
    }

    private func clearSnooze() {
        snoozedDose = nil
        snoozeUntil = nil
        snoozeAlarmID = nil
        persistSnooze()
    }

    private func persistSnooze() {
        defaults.set(snoozeUntil, forKey: Keys.snoozeUntil)
        if let dose = snoozedDose, let data = encode(dose) {
            defaults.set(data, forKey: Keys.snoozeDose)
        } else {
            defaults.removeObject(forKey: Keys.snoozeDose)
        }
    }

    private func cancelAllScheduled() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let medIds = pending.map(\.identifier).filter { $0.hasPrefix("med.") }
        if !medIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: medIds)
        }
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            for uuidStr in alarmIDs.values {
                if let uuid = UUID(uuidString: uuidStr) {
                    try? await AlarmManager.shared.cancel(id: uuid)
                }
            }
        }
        #endif
        alarmIDs = [:]
    }

    // MARK: record

    func record(_ dose: PlannedDose, action: DoseAction) async {
        records[dose.id] = action.rawValue
        pruneRecords()
        persistRecords()
        stopRinging()
        if snoozedDose?.id == dose.id {
            await cancelSnoozeReminder()
            clearSnooze()
        }
        lastDoseDate = dose.date
        lastDoseSlot = dose.slot
    }

    // MARK: in-app ringing

    func startMonitorIfNeeded() {
        guard isRunning else { return }
        startMonitor()
        evaluateRinging()
    }

    private func startMonitor() {
        monitor?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateRinging()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitor = timer
    }

    /// 到点响铃判定：App 在前台跨过剂次时间，或刚打开 App 且剂次在 2 小时内过点且未记录。
    /// 前台一律由 App 自己全屏响铃并播放声音（系统闹钟只在 App 不在前台时接管），
    /// 避免「系统闹钟没弹出来就彻底没提醒」这种致命空档。
    func evaluateRinging() {
        guard isRunning, !isRinging else { return }
        let now = Date()

        // 稍后提醒：等待期内不响铃；到点后再次响铃（同一剂次，仍未记录）
        if let dose = snoozedDose, let until = snoozeUntil, records[dose.id] == nil {
            if now < until { return }
            if now.timeIntervalSince(until) <= Self.activeRingGrace {
                startRinging(dose)
                return
            }
            clearSnooze()
        }

        guard let dose = plan.first(where: {
            records[$0.id] == nil
                && now >= $0.date
                && now.timeIntervalSince($0.date) <= Self.activeRingGrace
        }) else { return }

        startRinging(dose)
    }

    private func startRinging(_ dose: PlannedDose) {
        guard !isRinging else { return }
        isRinging = true
        ringingDose = dose

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)

        if let url = Bundle.main.url(forResource: "alarm", withExtension: "wav") {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.volume = 1
            player?.play()
        }

        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), usesSystemAlarm, !isTestRing {
            Task { await cancelSystemAlarm(for: dose) }
        }
        #endif
    }

    private func stopRinging() {
        player?.stop()
        player = nil
        isRinging = false
        ringingDose = nil
        isTestRing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: 测试提醒（不写入服药记录）

    /// 手动测试：立即进入全屏响铃，用于验证提醒页面与声音
    func startTestRinging() {
        guard !isRinging else { return }
        isTestRing = true
        startRinging(PlannedDose(date: Date(), slot: .morning))
    }

    func endTestRinging() {
        stopRinging()
    }

    // MARK: 测试提醒（锁屏 / 后台同样生效）

    /// 排定 10 秒后的测试提醒。
    /// App 在前台时由界面倒数计时器接管全屏响铃；锁屏或退到后台时由系统闹钟接管，
    /// 系统闹钟不可用则退化为本地通知（带 28 秒提示音），确保任何状态下都真的会响。
    func armTestReminder() async {
        await cancelTestReminder()
        let fire = Date().addingTimeInterval(Self.testDelay)
        testFireDate = fire
        defaults.set(fire, forKey: Keys.testFireDate)
        testArmInfo = ""

        var scheduledBySystem = false
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            do {
                // 关键：测试必须自己申请闹钟权限，不再依赖「是否已启动提醒」，
                // 否则权限没拿到时锁屏不会有任何动静
                let state = try await AlarmManager.shared.requestAuthorization()
                if state == .authorized {
                    let uuid = try await scheduleTestAlarmKit(at: fire)
                    testAlarmID = uuid.uuidString
                    defaults.set(uuid.uuidString, forKey: Keys.testAlarmID)
                    usesSystemAlarm = true
                    scheduledBySystem = true
                    testArmInfo = "已排定系统闹钟 · 锁屏也会全屏响铃"
                } else {
                    testArmInfo = "未获得闹钟权限 · 只能用本地通知"
                }
            } catch {
                testArmInfo = "系统闹钟排定失败 · 改用本地通知"
            }
        } else {
            testArmInfo = "系统低于 iOS 26 · 只能用本地通知"
        }
        #else
        testArmInfo = "此构建不含闹钟能力 · 只能用本地通知"
        #endif

        guard !scheduledBySystem else { return }

        // 退化为本地通知：同样要确保通知权限已拿到，否则锁屏也不会响
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            testArmInfo += " · 通知权限未开启"
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "测试提醒"
        content.body = "这是一次测试，不会写入服药记录"
        content.sound = UNNotificationSound(
            named: UNNotificationSoundName(rawValue: Self.notificationSound)
        )
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.testDelay, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.testNotificationID,
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)
        testArmInfo = "已排定本地通知 · 静音模式下可能没有声音"
    }

    func cancelTestReminder() async {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.testNotificationID])
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            if let stored = testAlarmID ?? defaults.string(forKey: Keys.testAlarmID),
               let uuid = UUID(uuidString: stored) {
                try? await AlarmManager.shared.cancel(id: uuid)
            }
        }
        #endif
        testAlarmID = nil
        testFireDate = nil
        defaults.removeObject(forKey: Keys.testAlarmID)
        defaults.removeObject(forKey: Keys.testFireDate)
    }

    /// 测试提醒已在锁屏/后台触发 → 用户点通知或回到 App 时进入全屏测试响铃
    func fireTestReminder() async {
        await cancelTestReminder()
        startTestRinging()
    }

    /// 回到前台补响：测试提醒已在后台过点且未处理
    private func resumeTestIfNeeded() async {
        let fire = testFireDate ?? (defaults.object(forKey: Keys.testFireDate) as? Date)
        guard let fire else { return }
        let elapsed = Date().timeIntervalSince(fire)
        guard elapsed >= 0 else { return }
        guard elapsed <= 300 else {
            await cancelTestReminder()
            return
        }
        // 系统闹钟已经负责过锁屏响铃，回到前台不再重放，避免重复打扰
        if testAlarmID != nil || defaults.string(forKey: Keys.testAlarmID) != nil {
            await cancelTestReminder()
            return
        }
        await fireTestReminder()
    }

    // MARK: persistence helpers

    private func persist() {
        defaults.set(intervalHalfDays, forKey: Keys.interval)
        defaults.set(morningMinutes, forKey: Keys.morningMinutes)
        defaults.set(eveningMinutes, forKey: Keys.eveningMinutes)
        defaults.set(lastDoseDate, forKey: Keys.lastDoseDate)
        defaults.set(lastDoseSlot.rawValue, forKey: Keys.lastDoseSlot)
    }

    private func persistRecords() {
        defaults.set(encode(records), forKey: Keys.records)
    }

    private func pruneRecords() {
        let cutoff = Date().addingTimeInterval(-Self.recordRetention)
        records = records.filter { key, _ in
            guard let epoch = key.split(separator: "-").first, let t = Double(epoch) else { return false }
            return Date(timeIntervalSince1970: t) > cutoff
        }
    }

    private func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    // MARK: formatting

    static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f.string(from: date)
    }

    static func timeText(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    static func weekdayText(_ date: Date) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let index = Calendar.current.component(.weekday, from: date) - 1
        return names[index]
    }
}
