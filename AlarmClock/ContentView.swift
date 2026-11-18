import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var scheduler = AlarmScheduler.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var showCalibration = false
    @State private var showPlan = false
    @State private var editingSlot: MedSlot?
    @State private var draftTime = Date()
    @State private var showDateSheet = false
    @State private var draftDate = Date()

    /// 长按标题「吃药提醒」可显示/隐藏测试按钮
    @AppStorage("med.showTestButton") private var showTestButton = false
    @State private var testCountdown: Int?
    @State private var testTask: Task<Void, Never>?
    /// 测试提醒的到点时刻；用绝对时间而不是递减计数，锁屏挂起后回来才不会算错
    @State private var testDeadline: Date?

    private static let cnDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    var body: some View {
        ZStack {
            background

            if scheduler.isRinging {
                RingingView()
                    .transition(.opacity)
            } else {
                mainView
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: scheduler.isRinging)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await scheduler.refreshOnActive() }
            }
        }
    }

    // MARK: - Main

    private var mainView: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    topbar
                        .padding(.bottom, 14)

                    intervalCard

                    timeCard
                        .padding(.top, 12)

                    foldRow(
                        icon: "target", title: "服药校准",
                        summary: calibrationSummary, isOpen: showCalibration
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) { showCalibration.toggle() }
                    }
                    .padding(.top, 10)

                    if showCalibration {
                        calibrationBody
                    }

                    foldRow(
                        icon: "list.clipboard", title: "未来计划",
                        summary: planSummary, isOpen: showPlan
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) { showPlan.toggle() }
                    }
                    .padding(.top, 10)

                    if showPlan {
                        planBody
                    }

                    Color.clear
                        .frame(height: 150)
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
            }

            bottomBar
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            countdown
            if showTestButton {
                testRow
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            actionButton
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 26)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.02, blue: 0.04).opacity(0),
                    Color(red: 0.02, green: 0.02, blue: 0.04)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.06, green: 0.06, blue: 0.09),
                Color(red: 0.02, green: 0.02, blue: 0.04)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.orange.opacity(0.2), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 180
                    )
                )
                .frame(width: 380, height: 380)
                .offset(y: -150)
                .blur(radius: 10)
        }
        .clipped()
        .ignoresSafeArea()
    }

    private var topbar: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("吃药提醒")
                .font(.system(size: 13, weight: .semibold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.55))

            if showTestButton {
                testButton
                    .transition(.scale.combined(with: .opacity))
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Circle()
                    .fill(scheduler.isRunning ? Color.orange : Color.white.opacity(0.25))
                    .frame(width: 6, height: 6)
                Text(scheduler.isRunning ? "已启动" : "未启动")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showTestButton)
    }

    private func toggleTestButton() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showTestButton.toggle()
        }
        if !showTestButton { cancelTestCountdown() }
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// 长按「启动提醒 / 停止提醒」后，在其上方显示或隐藏
    private var testRow: some View {
        VStack(spacing: 6) {
            testButton
            if !scheduler.testArmInfo.isEmpty {
                Text(scheduler.testArmInfo)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.85))
                    .multilineTextAlignment(.center)
            } else {
                Text("测试提醒 · 锁屏也会响 · 不写入服药记录")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.bottom, 10)
    }

    /// 测试按钮：点一下开始 10 秒倒数，倒数结束立即进入全屏响铃
    private var testButton: some View {
        Button {
            if testCountdown != nil {
                cancelTestCountdown()
            } else {
                startTestCountdown()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: testCountdown == nil ? "alarm.waves.left.and.right.fill" : "timer")
                    .font(.system(size: 12, weight: .bold))
                Text(testCountdown.map { "\($0) 秒后响铃" } ?? "测试提醒")
                    .font(.system(size: 12, weight: .heavy))
                    .monospacedDigit()
            }
            .foregroundStyle(testCountdown == nil ? Color.orange : Color.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(testCountdown == nil ? Color.orange.opacity(0.18) : Color.orange)
            )
            .overlay(
                Capsule().stroke(Color.orange.opacity(testCountdown == nil ? 0.6 : 0), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func startTestCountdown() {
        testTask?.cancel()
        testTask = nil
        testCountdown = 10
        let deadline = Date().addingTimeInterval(10)
        testDeadline = deadline
        // 同时把系统闹钟/通知挂到 10 秒后：期间锁屏或切到后台，仍会照常响
        Task { await scheduler.armTestReminder() }
        testTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    // 前台接管响铃，先撤掉系统闹钟与通知，避免两路声音叠加
                    await scheduler.fireTestReminder()
                    await MainActor.run {
                        testCountdown = nil
                        testDeadline = nil
                    }
                    return
                }
                let shown = Int(remaining.rounded(.up))
                await MainActor.run { testCountdown = shown }
            }
        }
    }

    private func cancelTestCountdown() {
        testTask?.cancel()
        testTask = nil
        testCountdown = nil
        testDeadline = nil
        Task { await scheduler.cancelTestReminder() }
    }

    // MARK: interval card

    private var intervalCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("服药间隔")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
            .padding(.bottom, 10)

            HStack(spacing: 10) {
                roundButton(icon: "minus") {
                    if scheduler.intervalHalfDays > 1 { scheduler.intervalHalfDays -= 1 }
                }

                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(scheduler.intervalText)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("天")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(scheduler.intervalHint)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity)

                roundButton(icon: "plus") {
                    if scheduler.intervalHalfDays < 14 { scheduler.intervalHalfDays += 1 }
                }
            }

            HStack(spacing: 7) {
                ForEach([1, 2, 3, 4, 5, 6, 14], id: \.self) { halfDays in
                    chip(halfDays: halfDays)
                }
            }
            .padding(.top, 12)
        }
        .cardStyle()
    }

    private func roundButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func chip(halfDays: Int) -> some View {
        let days = Double(halfDays) / 2
        let label = days.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(days))天" : String(format: "%.1f天", days)
        return Button {
            scheduler.intervalHalfDays = halfDays
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    Group {
                        if scheduler.intervalHalfDays == halfDays {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.orange.opacity(0.18))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.white.opacity(0.07))
                        }
                    }
                )
                .foregroundStyle(scheduler.intervalHalfDays == halfDays ? Color.orange : Color.white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    // MARK: time card

    private var timeCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("提醒时间")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
            .padding(.bottom, 4)

            timeRow(
                icon: "sun.max.fill", tint: .orange,
                title: "早上",
                usage: anchorUsage(.morning),
                slot: .morning
            )
            timeRow(
                icon: "moon.fill", tint: Color(red: 0.56, green: 0.64, blue: 1),
                title: "晚上",
                usage: anchorUsage(.evening),
                slot: .evening
            )
        }
        .cardStyle()
        .sheet(item: $editingSlot) { slot in
            timeSheet(for: slot)
        }
    }

    private func timeRow(icon: String, tint: Color, title: String, usage: String, slot: MedSlot) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Text(usage)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 8)
            Button {
                draftTime = scheduler.anchorDate(for: slot)
                editingSlot = slot
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(tint)
                    Text(timeText(scheduler.anchorDate(for: slot)))
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                .frame(width: 108, alignment: .center)
                .padding(.vertical, 9)
                .background(
                    Color.white.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }

    private func timeText(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    private func timeSheet(for slot: MedSlot) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { editingSlot = nil }
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(slot == .morning ? "早上提醒时间" : "晚上提醒时间")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("确定") {
                    if slot == .morning {
                        scheduler.morningMinutes = minutes(of: draftTime)
                    } else {
                        scheduler.eveningMinutes = minutes(of: draftTime)
                    }
                    editingSlot = nil
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            DatePicker(
                "",
                selection: $draftTime,
                displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "en_GB"))
            .frame(height: 190)
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.09, green: 0.09, blue: 0.13))
        .presentationDetents([.height(276)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var dateSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") { showDateSheet = false }
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text("最近一次服用日期")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("确定") {
                    scheduler.lastDoseDate = draftDate
                    showDateSheet = false
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            DatePicker(
                "",
                selection: $draftDate,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .frame(height: 190)
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.09, green: 0.09, blue: 0.13))
        .presentationDetents([.height(276)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func anchorUsage(_ slot: MedSlot) -> String {
        if scheduler.isTwiceDaily || scheduler.isAlternating { return "使用中" }
        return scheduler.lastDoseSlot == slot ? "使用中" : "不使用"
    }

    private func minutes(of date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    // MARK: fold rows

    private func foldRow(icon: String, title: String, summary: String, isOpen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var calibrationSummary: String {
        "上次：\(AlarmScheduler.dateText(scheduler.lastDoseDate)) \(scheduler.lastDoseSlot.label)"
    }

    private var planSummary: String {
        if let next = scheduler.nextActionable {
            return "已排定 · 下次 \(AlarmScheduler.dateText(next.date)) \(AlarmScheduler.timeText(next.date))"
        }
        return "未排定"
    }

    private var calibrationBody: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("最近一次已服用")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Text("计划从此刻之后推算")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    draftDate = scheduler.lastDoseDate
                    showDateSheet = true
                } label: {
                    Text(Self.cnDate.string(from: scheduler.lastDoseDate))
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Color.white.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showDateSheet) { dateSheet }

                HStack(spacing: 3) {
                    slotButton(.morning)
                    slotButton(.evening)
                }
            }
        }
        .cardStyle()
    }

    private func slotButton(_ slot: MedSlot) -> some View {
        let selected = scheduler.lastDoseSlot == slot
        return Button {
            scheduler.lastDoseSlot = slot
        } label: {
            Text(slot.label)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 62)
                .padding(.vertical, 7)
                .background(
                    selected ? Color.orange : Color.white.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .foregroundStyle(selected ? .white : .white.opacity(0.55))
        }
        .buttonStyle(.plain)
    }

    private var planBody: some View {
        VStack(spacing: 0) {
            ForEach(displayPlan) { dose in
                planRow(dose)
            }
            if displayPlan.isEmpty {
                Text("暂无计划 · 先启动提醒")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var displayPlan: [PlannedDose] {
        let missed = Array(scheduler.missedDoses.prefix(2))
        let upcoming = Array(scheduler.upcomingDoses.prefix(5))
        return missed + upcoming
    }

    private func planRow(_ dose: PlannedDose) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(AlarmScheduler.dateText(dose.date)) \(AlarmScheduler.weekdayText(dose.date)) \(AlarmScheduler.timeText(dose.date))")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(subtitle(for: dose))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            slotTag(dose.slot)
            statusTag(dose)
        }
        .padding(.vertical, 8)
    }

    private func subtitle(for dose: PlannedDose) -> String {
        if dose.date <= Date() { return "过点未记录" }
        if let next = scheduler.nextActionable, next.id == dose.id { return "下次提醒" }
        return "已预排"
    }

    private func slotTag(_ slot: MedSlot) -> some View {
        Text(slot.shortLabel)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(
                slot == .morning ? Color.yellow.opacity(0.15) : Color(red: 0.47, green: 0.55, blue: 1).opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(slot == .morning ? Color.yellow : Color(red: 0.56, green: 0.64, blue: 1))
    }

    @ViewBuilder
    private func statusTag(_ dose: PlannedDose) -> some View {
        if let action = scheduler.action(for: dose) {
            Text(action.label)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    action == .taken ? Color.green.opacity(0.15) : Color.white.opacity(0.1),
                    in: Capsule()
                )
                .foregroundStyle(action == .taken ? Color.green : Color.white.opacity(0.5))
        } else if scheduler.nextActionable?.id == dose.id {
            Text("下次")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        }
    }

    // MARK: countdown & action

    @ViewBuilder
    private var countdown: some View {
        if let next = scheduler.nextReminder {
            Text("下次提醒：\(AlarmScheduler.dateText(next.date)) \(AlarmScheduler.weekdayText(next.date)) \(AlarmScheduler.timeText(next.date))")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 12)
        }
    }

    private var actionButton: some View {
        Group {
            HStack(spacing: 8) {
                Image(systemName: scheduler.isRunning ? "xmark" : "pill.fill")
                    .font(.system(size: 15, weight: .bold))
                Text(scheduler.isRunning ? "停止提醒" : "启动提醒")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        scheduler.isRunning
                        ? AnyShapeStyle(Color.white.opacity(0.1))
                        : AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.48, blue: 0.16),
                                    Color(red: 0.94, green: 0.24, blue: 0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    )
            }
            .foregroundStyle(.white)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        // 轻点：启动/停止提醒；长按 0.6 秒：显示/隐藏上方测试按钮
        // exclusively 保证两者只会触发一个，长按绝不会误启动提醒
        .gesture(
            LongPressGesture(minimumDuration: 0.6)
                .onEnded { _ in toggleTestButton() }
                .exclusively(
                    before: TapGesture().onEnded { toggleRunning() }
                )
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(scheduler.isRunning ? "停止提醒" : "启动提醒")
    }

    private func toggleRunning() {
        Task {
            if scheduler.isRunning {
                await scheduler.stop()
            } else {
                await scheduler.start()
            }
        }
    }
}

// MARK: - Shared styles

extension View {
    func cardStyle() -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Ringing screen

struct RingingView: View {
    @StateObject private var scheduler = AlarmScheduler.shared
    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.55, green: 0.1, blue: 0.06),
                    Color(red: 0.26, green: 0.04, blue: 0.03),
                    Color(red: 0.06, green: 0.02, blue: 0.02)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 230, height: 230)
                        .scaleEffect(pulse ? 1.18 : 0.92)
                        .opacity(pulse ? 0.15 : 0.5)

                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 170, height: 170)

                    Image(systemName: "pills.fill")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(pulse ? 6 : -6))
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }

                VStack(spacing: 10) {
                    Text(scheduler.isTestRing ? "测试提醒" : "该吃药了")
                        .font(.system(size: 30, weight: .bold, design: .rounded))

                    if scheduler.isTestRing {
                        Text("倒数结束已触发 · 本次为测试，不写入服药记录")
                            .font(.system(size: 14, weight: .medium))
                            .multilineTextAlignment(.center)
                            .opacity(0.75)
                    } else if let dose = scheduler.ringingDose {
                        Text("\(AlarmScheduler.dateText(dose.date)) \(AlarmScheduler.timeText(dose.date)) · \(dose.slot.label)剂")
                            .font(.system(size: 16, weight: .medium))
                            .monospacedDigit()
                            .opacity(0.75)
                    }
                }
                .foregroundStyle(.white)
                .padding(.top, 32)

                Spacer()

                if scheduler.isTestRing {
                    Button {
                        scheduler.endTestRinging()
                    } label: {
                        Text("知道了")
                            .font(.system(size: 20, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(.white, in: Capsule())
                            .foregroundStyle(Color(red: 0.58, green: 0.1, blue: 0.06))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        if let dose = scheduler.ringingDose {
                            Task { await scheduler.record(dose, action: .taken) }
                        }
                    } label: {
                        Text("已服用")
                            .font(.system(size: 20, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .background(.white, in: Capsule())
                            .foregroundStyle(Color(red: 0.58, green: 0.1, blue: 0.06))
                    }
                    .buttonStyle(.plain)

                    Button {
                        if let dose = scheduler.ringingDose {
                            Task { await scheduler.snooze(dose) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 15, weight: .semibold))
                            Text("稍后提醒（10 分钟后）")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.14), in: Capsule())
                        .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
        }
    }
}

#Preview {
    ContentView()
}
