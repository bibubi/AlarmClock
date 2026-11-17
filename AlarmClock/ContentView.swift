import SwiftUI

struct ContentView: View {
    @StateObject private var scheduler = AlarmScheduler.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var hour: Int = Calendar.current.component(.hour, from: Date())
    @State private var minute: Int = 0
    @State private var second: Int = 0

    var body: some View {
        ZStack {
            background

            if scheduler.isRinging {
                RingingView()
                    .transition(.opacity)
            } else {
                setupView
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.35), value: scheduler.isRinging)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { scheduler.refresh() }
        }
    }

    // MARK: - Setup screen

    private var setupView: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 12)

            Spacer(minLength: 16)

            preview

            pickerRow
                .padding(.top, 8)

            statusLine
                .padding(.top, 12)
                .frame(height: 46)

            Spacer(minLength: 16)

            actionButton

            footer
                .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
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
                        colors: [Color.orange.opacity(0.22), .clear],
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("秒闹钟")
                .font(.system(size: 13, weight: .semibold))
                .tracking(3)
                .foregroundStyle(.white.opacity(0.55))

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(scheduler.fireDate == nil ? Color.white.opacity(0.25) : Color.orange)
                    .frame(width: 6, height: 6)
                Text(scheduler.fireDate == nil ? "未启动" : "已启动")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var preview: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 2) {
                Text(String(format: "%02d", hour))
                Text(":")
                    .foregroundStyle(Color.orange.opacity(scheduler.fireDate == nil ? 1 : 0.5))
                Text(String(format: "%02d", minute))
                Text(":")
                    .foregroundStyle(Color.orange.opacity(scheduler.fireDate == nil ? 1 : 0.5))
                Text(String(format: "%02d", second))
            }
            .font(.system(size: 62, weight: .light, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)

            Text(scheduler.fireDate == nil ? "精确到秒" : "到点自动响铃")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private var pickerRow: some View {
        HStack(spacing: 2) {
            wheel(values: Array(0..<24), selection: $hour)
            colon
            wheel(values: Array(0..<60), selection: $minute)
            colon
            wheel(values: Array(0..<60), selection: $second)
        }
        .frame(height: 170)
        .opacity(scheduler.fireDate == nil ? 1 : 0.35)
        .allowsHitTesting(scheduler.fireDate == nil)
    }

    private var colon: some View {
        Text(":")
            .font(.system(size: 22, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.25))
            .padding(.bottom, 4)
    }

    private func wheel(values: [Int], selection: Binding<Int>) -> some View {
        Picker("", selection: selection) {
            ForEach(values, id: \.self) { value in
                Text(String(format: "%02d", value))
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .tag(value)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var statusLine: some View {
        if let error = scheduler.errorMessage {
            Text(error)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                .multilineTextAlignment(.center)
        } else if let fireDate = scheduler.fireDate {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                HStack(spacing: 8) {
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                    Text("还有 \(countdown(to: fireDate, from: context.date)) · \(AlarmScheduler.clockString(fireDate)) 响铃")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        } else if !scheduler.scheduleDescription.isEmpty {
            Text(scheduler.scheduleDescription)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var actionButton: some View {
        Button {
            if scheduler.fireDate != nil {
                Task { await scheduler.cancel() }
            } else {
                Task { await scheduler.schedule(at: targetDate()) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: scheduler.fireDate == nil ? "alarm.fill" : "xmark")
                    .font(.system(size: 15, weight: .bold))
                Text(scheduler.fireDate == nil ? "启动闹钟" : "取消闹钟")
                    .font(.system(size: 17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        scheduler.fireDate == nil
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.48, blue: 0.16),
                                    Color(red: 0.94, green: 0.24, blue: 0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        : AnyShapeStyle(Color.white.opacity(0.1))
                    )
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        Text(scheduler.scheduleDescription.isEmpty
             ? "使用 iOS 26 系统闹钟能力，App 被杀后台也能准时响铃。"
             : scheduler.scheduleDescription)
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(.white.opacity(0.3))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func targetDate() -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        components.second = second

        var date = calendar.date(from: components) ?? Date()
        if date <= Date() {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return date
    }

    private func countdown(to date: Date, from now: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

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
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 230, height: 230)
                        .scaleEffect(pulse ? 1.18 : 0.92)
                        .opacity(pulse ? 0.15 : 0.5)

                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 170, height: 170)

                    Image(systemName: "alarm.fill")
                        .font(.system(size: 74, weight: .bold))
                        .foregroundStyle(.white)
                        .rotationEffect(.degrees(pulse ? 8 : -8))
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }

                VStack(spacing: 10) {
                    Text("闹钟时间到了")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(AlarmScheduler.clockString(context.date))
                            .font(.system(size: 17, weight: .medium, design: .monospaced))
                            .opacity(0.75)
                    }
                }
                .foregroundStyle(.white)
                .padding(.top, 32)

                Spacer()

                Button {
                    Task { await scheduler.cancel() }
                } label: {
                    Text("停止")
                        .font(.system(size: 20, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(.white, in: Capsule())
                        .foregroundStyle(Color(red: 0.58, green: 0.1, blue: 0.06))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)
                .padding(.bottom, 70)
            }
        }
    }
}

#Preview {
    ContentView()
}
