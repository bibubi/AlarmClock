import SwiftUI

struct ContentView: View {
    @StateObject private var scheduler = AlarmScheduler.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var showCalibration = false
    @State private var showPlan = false

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

            Spacer(minLength: 12)

            countdown

            actionButton
        }
        .padding(.horizontal, 22)
        .padding(.top, 50)
        .padding(.bottom, 26)
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.06, blue: 0.09),
                    Color(red: 0.02, green: 0.02, blue: 0.04)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.orange.opacity(0.2), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 260
                    )
                )
                .frame(width: 520, height: 520)
                .offset(y: -180)
                .blur(radius: 10)
                .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    private var topbar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("吃药提醒")
                .font(.system(size: 13, weight: .semibold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.55))

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(scheduler.isRunning ? Color.orange : Color.white.opacity(0.25))
                    .frame(width: 6, height: 6)
                Text(scheduler.isRunning ? "已启动" : "未启动")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
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
                ForEach([1, 2, 3, 4, 5, 6, 10], id: \.self) { halfDays in
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
                binding: morningBinding
            )
            timeRow(
                icon: "moon.fill", tint: Color(red: 0.56, green: 0.64, blue: 1),
                title: "晚上",
                usage: anchorUsage(.evening),
                binding: eveningBinding
            )
        }
        .cardStyle()
    }

    private func timeRow(icon: String, tint: Color, title: String, usage: String, binding: Binding<Date>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Text(usage)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .padding(.trailing, 8)
            DatePicker("", selection: binding, displayedComponents: .hourAndMinute)
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(.white)
        }
        .padding(.vertical, 8)
    }

    private func anchorUsage(_ slot: MedSlot) -> String {
        if scheduler.isTwiceDaily || scheduler.isAlternating { return "使用中" }
        return scheduler.lastDoseSlot == slot ? "使用中" : "不使用"
    }

    private var morningBinding: Binding<Date> {
        Binding(
            get: { scheduler.anchorDate(for: .morning) },
            set: { scheduler.morningMinutes = minutes(of: $0) }
        )
    }

    private var eveningBinding: Binding<Date> {
        Binding(
            get: { scheduler.anchorDate(for: .evening) },
            set: { scheduler.eveningMinutes = minutes(of: $0) }
        )
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
                DatePicker(
                    "",
                    selection: Binding(
                        get: { scheduler.lastDoseDate },
                        set: { scheduler.lastDoseDate = $0 }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .labelsHidden()
                .tint(.white)

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
                    .padding(.vertical, 12)
            }
        }
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
        if let next = scheduler.nextActionable {
            Text("下次提醒：\(AlarmScheduler.dateText(next.date)) \(AlarmScheduler.weekdayText(next.date)) \(AlarmScheduler.timeText(next.date))")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
                .padding(.bottom, 12)
        }
    }

    private var actionButton: some View {
        Button {
            Task {
                if scheduler.isRunning {
                    await scheduler.stop()
                } else {
                    await scheduler.start()
                }
            }
        } label: {
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
        .buttonStyle(.plain)
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
                    Text("该吃药了")
                        .font(.system(size: 30, weight: .bold, design: .rounded))

                    if let dose = scheduler.ringingDose {
                        Text("\(AlarmScheduler.dateText(dose.date)) \(AlarmScheduler.timeText(dose.date)) · \(dose.slot.label)剂")
                            .font(.system(size: 16, weight: .medium))
                            .monospacedDigit()
                            .opacity(0.75)
                    }
                }
                .foregroundStyle(.white)
                .padding(.top, 32)

                Spacer()

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
                        Task { await scheduler.record(dose, action: .skipped) }
                    }
                } label: {
                    Text("跳过这次")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.14), in: Capsule())
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
        }
    }
}

#Preview {
    ContentView()
}
