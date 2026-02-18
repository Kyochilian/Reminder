import AppKit
import SwiftUI
import UserNotifications

private let reminderCategoryID = "EYE_REMINDER_CATEGORY"
private let confirmRestActionID = "EYE_REMINDER_CONFIRM_REST"
private let legacyReminderNotificationID = "legacy_rest_reminder"

private enum WindowDefaults {
    static var defaultSize: CGSize {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return CGSize(width: 800, height: 600)
        }

        let ratio = visibleFrame.width / visibleFrame.height
        let targetHeight = min(max(560, visibleFrame.height * 0.68), 980)
        let targetWidth = min(targetHeight * ratio, visibleFrame.width * 0.90)
        let adjustedHeight = targetWidth / ratio

        return CGSize(width: targetWidth, height: adjustedHeight)
    }
}

enum SessionPhase: String {
    case working
    case resting
}

private enum NotificationBackend {
    case userNotifications
    case legacyNSUserNotifications
    case disabledForTests
}

private enum NotificationBridge {
    static func requestAuthorization() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    static func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

private enum DefaultsKey {
    static let workIntervalMinutes = "workIntervalMinutes"
    static let breakDurationMinutes = "breakDurationMinutes"
    static let workMinMinutes = "workMinMinutes"
    static let workMaxMinutes = "workMaxMinutes"
    static let breakMinMinutes = "breakMinMinutes"
    static let breakMaxMinutes = "breakMaxMinutes"
    static let allowExitFullscreenDuringBreak = "allowExitFullscreenDuringBreak"
    static let phase = "phase"
    static let remainingWorkSeconds = "remainingWorkSeconds"
    static let waitingForRestConfirmation = "waitingForRestConfirmation"
    static let secondsUntilNextReminder = "secondsUntilNextReminder"
    static let breakEndDate = "breakEndDate"
    static let remindersSent = "remindersSent"
    static let notificationAuthorizationRequested = "notificationAuthorizationRequested"
    static let hasStartedTimer = "hasStartedTimer"
}

@MainActor
final class ReminderEngine: ObservableObject {
    static let shared = ReminderEngine(
        defaults: .standard,
        notificationBackend: nil,
        now: Date.init
    )

    @Published private(set) var workIntervalMinutes: Double = 20
    @Published private(set) var breakDurationMinutes: Double = 5
    @Published private(set) var workMinMinutes: Double = 0
    @Published private(set) var workMaxMinutes: Double = 120
    @Published private(set) var breakMinMinutes: Double = 0
    @Published private(set) var breakMaxMinutes: Double = 60
    @Published private(set) var phase: SessionPhase = .working
    @Published private(set) var remainingWorkSeconds: Int = 20 * 60
    @Published private(set) var waitingForRestConfirmation = false
    @Published private(set) var secondsUntilNextReminder = 5 * 60
    @Published private(set) var breakEndDate: Date?
    @Published private(set) var remainingBreakSeconds = 0
    @Published private(set) var remindersSent = 0
    @Published private(set) var isScreenLocked = false
    @Published private(set) var isFullscreenReminderVisible = false
    @Published private(set) var notificationStatusText = "通知权限检查中"
    @Published private(set) var hasStartedTimer = false
    @Published private(set) var isTickerRunning = false
    @Published var enableFullscreenBlur = true
    @Published var enableRestAnimation = true
    @Published private(set) var allowExitFullscreenDuringBreak = true

    private let defaults: UserDefaults
    private let now: () -> Date
    private var tickTimer: Timer?
    private var isActivated = false
    private let notificationBackend: NotificationBackend
    private let absoluteMaximumMinutes: Double = 1_440
    private var showFullscreenPrompt: (() -> Void)?
    private var showFullscreenBreakCountdown: (() -> Void)?
    private var hideFullscreenReminder: (() -> Void)?
    private var isSystemFullscreenContext: (() -> Bool)?

    private init(
        defaults: UserDefaults,
        notificationBackend: NotificationBackend?,
        now: @escaping () -> Date
    ) {
        self.defaults = defaults
        self.now = now
        self.notificationBackend = notificationBackend ?? (
            Bundle.main.bundleURL.pathExtension == "app" ? .userNotifications : .legacyNSUserNotifications
        )
        loadState()
        reconcileStateAfterLaunch()
    }

    static func makeForTesting(
        defaults: UserDefaults,
        now: @escaping () -> Date
    ) -> ReminderEngine {
        ReminderEngine(
            defaults: defaults,
            notificationBackend: .disabledForTests,
            now: now
        )
    }

    func activate() {
        activate(startTicker: shouldAutoStartOnActivation)
    }

    func activate(startTicker: Bool) {
        guard !isActivated else { return }
        isActivated = true
        if startTicker {
            hasStartedTimer = true
            startTicking()
        }

        switch notificationBackend {
        case .userNotifications:
            requestNotificationAuthorizationOnFirstLaunchIfNeeded()
            refreshNotificationStatus()
        case .legacyNSUserNotifications:
            notificationStatusText = "通知已开启（开发模式）"
        case .disabledForTests:
            notificationStatusText = "通知已开启（测试模式）"
        }
    }

    var usesUserNotifications: Bool {
        notificationBackend == .userNotifications
    }

    var shouldAutoStartOnActivation: Bool {
        hasStartedTimer
    }

    var needsManualStart: Bool {
        !hasStartedTimer && !isTickerRunning
    }

    var canConfirmRest: Bool { phase == .working }

    func startTiming() {
        guard isActivated else { return }
        guard !isTickerRunning else { return }
        hasStartedTimer = true
        startTicking()
        saveState()
    }

    var modeTitle: String {
        if needsManualStart {
            return "等待开始计时"
        }
        switch phase {
        case .resting:
            return "休息中"
        case .working:
            if waitingForRestConfirmation {
                return "等待确认休息"
            }
            return isScreenLocked ? "工作中（锁屏暂停）" : "工作中"
        }
    }

    var statusLine: String {
        if needsManualStart {
            return "首次打开应用请点击“开始计时”。"
        }
        switch phase {
        case .resting:
            return isScreenLocked ? "锁屏时休息计时继续。" : "请看向远处，放松眼部肌肉。"
        case .working:
            if waitingForRestConfirmation {
                return "若未点击“确定休息”，将每 5 分钟再次提醒。"
            }
            return isScreenLocked ? "屏幕已锁定，工作计时暂停。" : "专注工作中。"
        }
    }

    var countdownLine: String {
        if needsManualStart {
            return "准备时长 \(Self.format(seconds: remainingWorkSeconds))"
        }
        switch phase {
        case .resting:
            return "休息剩余 \(Self.format(seconds: remainingBreakSeconds))"
        case .working:
            if waitingForRestConfirmation {
                return "下次提醒倒计时 \(Self.format(seconds: secondsUntilNextReminder))"
            }
            return "距离提醒 \(Self.format(seconds: remainingWorkSeconds))"
        }
    }

    var workIntervalDescription: String {
        Self.formatMinutes(workIntervalMinutes)
    }

    var breakDurationDescription: String {
        Self.formatMinutes(breakDurationMinutes)
    }

    var breakCountdownText: String {
        Self.format(seconds: remainingBreakSeconds)
    }

    func configureFullscreenHandlers(
        showPrompt: @escaping () -> Void,
        showBreakCountdown: @escaping () -> Void,
        hideReminder: @escaping () -> Void,
        isSystemFullscreenContext: @escaping () -> Bool
    ) {
        self.showFullscreenPrompt = showPrompt
        self.showFullscreenBreakCountdown = showBreakCountdown
        self.hideFullscreenReminder = hideReminder
        self.isSystemFullscreenContext = isSystemFullscreenContext
    }

    func setWorkInterval(minutes: Double) {
        let clamped = clamp(minutes, min: workMinMinutes, max: workMaxMinutes)
        guard clamped != workIntervalMinutes else { return }
        workIntervalMinutes = clamped

        if phase == .working && !waitingForRestConfirmation {
            remainingWorkSeconds = configuredWorkSeconds
        }
        saveState()
    }

    func nudgeWorkInterval(by delta: Double) {
        setWorkInterval(minutes: workIntervalMinutes + delta)
    }

    func setBreakDuration(minutes: Double) {
        let clamped = clamp(minutes, min: breakMinMinutes, max: breakMaxMinutes)
        guard clamped != breakDurationMinutes else { return }
        breakDurationMinutes = clamped

        if phase == .resting {
            breakEndDate = now().addingTimeInterval(TimeInterval(configuredBreakSeconds))
            remainingBreakSeconds = configuredBreakSeconds
        }
        saveState()
    }

    func nudgeBreakDuration(by delta: Double) {
        setBreakDuration(minutes: breakDurationMinutes + delta)
    }

    func setWorkRange(min: Double, max: Double) {
        let normalized = normalizeRange(min: min, max: max, fallbackMax: max)
        let didChange = workMinMinutes != normalized.min || workMaxMinutes != normalized.max
        workMinMinutes = normalized.min
        workMaxMinutes = normalized.max
        setWorkInterval(minutes: workIntervalMinutes)
        if didChange {
            saveState()
        }
    }

    func setBreakRange(min: Double, max: Double) {
        let normalized = normalizeRange(min: min, max: max, fallbackMax: max)
        let didChange = breakMinMinutes != normalized.min || breakMaxMinutes != normalized.max
        breakMinMinutes = normalized.min
        breakMaxMinutes = normalized.max
        setBreakDuration(minutes: breakDurationMinutes)
        if didChange {
            saveState()
        }
    }

    func setAllowExitFullscreenDuringBreak(_ allow: Bool) {
        guard allowExitFullscreenDuringBreak != allow else { return }
        allowExitFullscreenDuringBreak = allow
        saveState()
    }

    func setScreenLocked(_ locked: Bool) {
        guard isScreenLocked != locked else { return }
        isScreenLocked = locked
        saveState()
    }

    func confirmRest() {
        guard phase == .working else { return }
        startRestCycle(showFullscreenCountdown: false)
    }

    func confirmRestFromFullscreenReminder() {
        guard phase == .working, waitingForRestConfirmation else { return }
        isFullscreenReminderVisible = false
        startRestCycle(showFullscreenCountdown: true)
    }

    func snoozeRestReminder() {
        guard phase == .working, waitingForRestConfirmation else { return }
        isFullscreenReminderVisible = false
        hideFullscreenReminder?()
        secondsUntilNextReminder = 5 * 60
        saveState()
    }

    func dismissFullscreenBreakOverlay() {
        guard phase == .resting else { return }
        isFullscreenReminderVisible = false
        hideFullscreenReminder?()
        saveState()
    }

    func skipRest() {
        guard phase == .resting else { return }
        finishRestCycle()
    }

    func refreshNotificationStatus() {
        guard isActivated else { return }
        switch notificationBackend {
        case .userNotifications:
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = await NotificationBridge.authorizationStatus()
                self.notificationStatusText = Self.notificationStatusText(from: status)
            }
        case .legacyNSUserNotifications:
            notificationStatusText = "通知已开启（开发模式）"
        case .disabledForTests:
            notificationStatusText = "通知已开启（测试模式）"
        }
    }

    private var configuredWorkSeconds: Int {
        Int((workIntervalMinutes * 60).rounded())
    }

    private var configuredBreakSeconds: Int {
        Int((breakDurationMinutes * 60).rounded())
    }

    private var calculatedRemainingBreakSeconds: Int {
        guard let breakEndDate else { return 0 }
        return max(0, Int(breakEndDate.timeIntervalSince(now()).rounded(.down)))
    }

    private func startTicking() {
        tickTimer?.invalidate()
        isTickerRunning = true
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        if let tickTimer {
            RunLoop.main.add(tickTimer, forMode: .common)
        }
    }

    private func tick() {
        switch phase {
        case .working:
            tickWorkingCycle()
        case .resting:
            tickRestingCycle()
        }
        saveState()
    }

    private func tickWorkingCycle() {
        if waitingForRestConfirmation {
            guard !isFullscreenReminderVisible else { return }
            guard !isScreenLocked else { return }

            if secondsUntilNextReminder > 0 {
                secondsUntilNextReminder -= 1
            }

            if secondsUntilNextReminder <= 0 {
                triggerReminderPresentation()
                secondsUntilNextReminder = 5 * 60
            }
            return
        }

        guard !isScreenLocked else { return }

        if remainingWorkSeconds > 0 {
            remainingWorkSeconds -= 1
        }

        if remainingWorkSeconds <= 0 {
            remainingWorkSeconds = 0
            waitingForRestConfirmation = true
            secondsUntilNextReminder = 5 * 60
            triggerReminderPresentation()
        }
    }

    private func tickRestingCycle() {
        guard let breakEndDate else {
            finishRestCycle()
            return
        }

        remainingBreakSeconds = calculatedRemainingBreakSeconds
        if now() >= breakEndDate {
            finishRestCycle()
        }
    }

    private func startRestCycle(showFullscreenCountdown: Bool) {
        waitingForRestConfirmation = false
        secondsUntilNextReminder = 5 * 60
        phase = .resting
        breakEndDate = now().addingTimeInterval(TimeInterval(configuredBreakSeconds))
        remainingBreakSeconds = configuredBreakSeconds
        isFullscreenReminderVisible = showFullscreenCountdown
        if showFullscreenCountdown {
            showFullscreenBreakCountdown?()
        } else {
            hideFullscreenReminder?()
        }
        clearReminderNotifications()
        saveState()
    }

    private func finishRestCycle() {
        phase = .working
        breakEndDate = nil
        remainingBreakSeconds = 0
        waitingForRestConfirmation = false
        secondsUntilNextReminder = 5 * 60
        remainingWorkSeconds = configuredWorkSeconds
        isFullscreenReminderVisible = false
        hideFullscreenReminder?()
        saveState()
    }

    private func triggerReminderPresentation() {
        let shouldShowFullscreenReminder = shouldShowFullscreenReminder()
        if shouldShowFullscreenReminder, let showFullscreenPrompt {
            isFullscreenReminderVisible = true
            showFullscreenPrompt()
            return
        }
        sendRestReminderNotification()
    }

    private func shouldShowFullscreenReminder() -> Bool {
        guard notificationBackend != .disabledForTests else { return false }
        guard let isSystemFullscreenContext else { return false }
        return !isSystemFullscreenContext()
    }

    private func requestNotificationAuthorizationOnFirstLaunchIfNeeded() {
        guard notificationBackend == .userNotifications else { return }
        guard !defaults.bool(forKey: DefaultsKey.notificationAuthorizationRequested) else { return }

        defaults.set(true, forKey: DefaultsKey.notificationAuthorizationRequested)
        requestNotificationAuthorization()
    }

    private func requestNotificationAuthorization() {
        guard notificationBackend == .userNotifications else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await NotificationBridge.requestAuthorization()
            } catch {
                self.notificationStatusText = "通知授权失败：\(error.localizedDescription)"
            }
            self.refreshNotificationStatus()
        }
    }

    private func sendRestReminderNotification() {
        guard isActivated else { return }
        switch notificationBackend {
        case .userNotifications:
            let content = UNMutableNotificationContent()
            content.title = "该休息眼睛了"
            content.body = "点击“确定休息”开始休息计时。"
            content.sound = .default
            content.categoryIdentifier = reminderCategoryID

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            )

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await NotificationBridge.add(request)
                } catch {
                    self.notificationStatusText = "通知发送失败：\(error.localizedDescription)"
                }
            }
        case .legacyNSUserNotifications:
            let notification = NSUserNotification()
            notification.identifier = legacyReminderNotificationID
            notification.title = "该休息眼睛了"
            notification.informativeText = "点击“确定休息”开始休息计时。"
            notification.hasActionButton = true
            notification.actionButtonTitle = "确定休息"
            NSUserNotificationCenter.default.deliver(notification)
        case .disabledForTests:
            break
        }
        remindersSent += 1
    }

    private func clearReminderNotifications() {
        guard isActivated else { return }
        switch notificationBackend {
        case .userNotifications:
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        case .legacyNSUserNotifications:
            NSUserNotificationCenter.default.removeAllDeliveredNotifications()
        case .disabledForTests:
            break
        }
    }

    private func normalizeRange(min: Double, max: Double, fallbackMax: Double) -> (min: Double, max: Double) {
        let safeMin = clamp(min, min: 0, max: absoluteMaximumMinutes)
        let proposedMax = max >= 0 ? max : fallbackMax
        let safeMax = clamp(proposedMax, min: 0, max: absoluteMaximumMinutes)
        let normalizedMax = Swift.max(safeMin, safeMax)
        return (safeMin, normalizedMax)
    }

    private func loadState() {
        if defaults.object(forKey: DefaultsKey.workMinMinutes) != nil ||
            defaults.object(forKey: DefaultsKey.workMaxMinutes) != nil {
            let loadedMin = defaults.object(forKey: DefaultsKey.workMinMinutes) != nil
                ? defaults.double(forKey: DefaultsKey.workMinMinutes)
                : workMinMinutes
            let loadedMax = defaults.object(forKey: DefaultsKey.workMaxMinutes) != nil
                ? defaults.double(forKey: DefaultsKey.workMaxMinutes)
                : workMaxMinutes
            let normalized = normalizeRange(min: loadedMin, max: loadedMax, fallbackMax: 120)
            workMinMinutes = normalized.min
            workMaxMinutes = normalized.max
        }

        if defaults.object(forKey: DefaultsKey.breakMinMinutes) != nil ||
            defaults.object(forKey: DefaultsKey.breakMaxMinutes) != nil {
            let loadedMin = defaults.object(forKey: DefaultsKey.breakMinMinutes) != nil
                ? defaults.double(forKey: DefaultsKey.breakMinMinutes)
                : breakMinMinutes
            let loadedMax = defaults.object(forKey: DefaultsKey.breakMaxMinutes) != nil
                ? defaults.double(forKey: DefaultsKey.breakMaxMinutes)
                : breakMaxMinutes
            let normalized = normalizeRange(min: loadedMin, max: loadedMax, fallbackMax: 60)
            breakMinMinutes = normalized.min
            breakMaxMinutes = normalized.max
        }

        if defaults.object(forKey: DefaultsKey.allowExitFullscreenDuringBreak) != nil {
            allowExitFullscreenDuringBreak = defaults.bool(forKey: DefaultsKey.allowExitFullscreenDuringBreak)
        } else {
            allowExitFullscreenDuringBreak = true
        }

        if defaults.object(forKey: DefaultsKey.workIntervalMinutes) != nil {
            workIntervalMinutes = clamp(
                defaults.double(forKey: DefaultsKey.workIntervalMinutes),
                min: workMinMinutes,
                max: workMaxMinutes
            )
        }
        if defaults.object(forKey: DefaultsKey.breakDurationMinutes) != nil {
            breakDurationMinutes = clamp(
                defaults.double(forKey: DefaultsKey.breakDurationMinutes),
                min: breakMinMinutes,
                max: breakMaxMinutes
            )
        }
        if let rawPhase = defaults.string(forKey: DefaultsKey.phase),
           let parsedPhase = SessionPhase(rawValue: rawPhase) {
            phase = parsedPhase
        }
        if defaults.object(forKey: DefaultsKey.remainingWorkSeconds) != nil {
            remainingWorkSeconds = max(0, defaults.integer(forKey: DefaultsKey.remainingWorkSeconds))
        }
        waitingForRestConfirmation = defaults.bool(forKey: DefaultsKey.waitingForRestConfirmation)
        if defaults.object(forKey: DefaultsKey.secondsUntilNextReminder) != nil {
            secondsUntilNextReminder = defaults.integer(forKey: DefaultsKey.secondsUntilNextReminder)
        }
        breakEndDate = defaults.object(forKey: DefaultsKey.breakEndDate) as? Date
        remindersSent = max(0, defaults.integer(forKey: DefaultsKey.remindersSent))
        if defaults.object(forKey: DefaultsKey.hasStartedTimer) != nil {
            hasStartedTimer = defaults.bool(forKey: DefaultsKey.hasStartedTimer)
        } else {
            // Migrate old installs: if legacy state exists, treat as already started.
            hasStartedTimer = defaults.object(forKey: DefaultsKey.notificationAuthorizationRequested) != nil ||
                defaults.object(forKey: DefaultsKey.workIntervalMinutes) != nil ||
                defaults.object(forKey: DefaultsKey.breakDurationMinutes) != nil ||
                defaults.object(forKey: DefaultsKey.remainingWorkSeconds) != nil
        }
        
        // Visual effects are always enabled by default and no longer user configurable.
        enableFullscreenBlur = true
        enableRestAnimation = true
    }

    private func reconcileStateAfterLaunch() {
        if phase == .resting {
            guard let breakEndDate else {
                finishRestCycle()
                return
            }

            remainingBreakSeconds = calculatedRemainingBreakSeconds
            if now() >= breakEndDate {
                finishRestCycle()
            }
        } else {
            breakEndDate = nil
            remainingBreakSeconds = 0
            if waitingForRestConfirmation {
                remainingWorkSeconds = 0
            } else {
                let maxSeconds = configuredWorkSeconds
                if remainingWorkSeconds <= 0 || remainingWorkSeconds > maxSeconds {
                    remainingWorkSeconds = maxSeconds
                }
            }

            if secondsUntilNextReminder <= 0 || secondsUntilNextReminder > 5 * 60 {
                secondsUntilNextReminder = 5 * 60
            }
        }
        saveState()
    }

    private func saveState() {
        defaults.set(workIntervalMinutes, forKey: DefaultsKey.workIntervalMinutes)
        defaults.set(breakDurationMinutes, forKey: DefaultsKey.breakDurationMinutes)
        defaults.set(workMinMinutes, forKey: DefaultsKey.workMinMinutes)
        defaults.set(workMaxMinutes, forKey: DefaultsKey.workMaxMinutes)
        defaults.set(breakMinMinutes, forKey: DefaultsKey.breakMinMinutes)
        defaults.set(breakMaxMinutes, forKey: DefaultsKey.breakMaxMinutes)
        defaults.set(allowExitFullscreenDuringBreak, forKey: DefaultsKey.allowExitFullscreenDuringBreak)
        defaults.set(phase.rawValue, forKey: DefaultsKey.phase)
        defaults.set(remainingWorkSeconds, forKey: DefaultsKey.remainingWorkSeconds)
        defaults.set(waitingForRestConfirmation, forKey: DefaultsKey.waitingForRestConfirmation)
        defaults.set(secondsUntilNextReminder, forKey: DefaultsKey.secondsUntilNextReminder)
        defaults.set(remindersSent, forKey: DefaultsKey.remindersSent)
        defaults.set(hasStartedTimer, forKey: DefaultsKey.hasStartedTimer)

        if let breakEndDate {
            defaults.set(breakEndDate, forKey: DefaultsKey.breakEndDate)
        } else {
            defaults.removeObject(forKey: DefaultsKey.breakEndDate)
        }
    }

    private func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        Swift.max(minValue, Swift.min(maxValue, value))
    }

    func testAdvance(seconds: Int) {
        guard seconds > 0 else { return }
        for _ in 0..<seconds {
            tick()
        }
    }

    static func format(seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        let minutes = safeSeconds / 60
        let second = safeSeconds % 60
        return String(format: "%02d:%02d", minutes, second)
    }

    private static func formatMinutes(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.01 {
            return "\(Int(value.rounded())) 分钟"
        }
        return String(format: "%.1f 分钟", value)
    }

    private static func notificationStatusText(from status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return "通知已开启"
        case .denied:
            return "通知被关闭，请在系统设置中开启"
        case .notDetermined:
            return "通知权限未确认"
        @unknown default:
            return "通知状态未知"
        }
    }
}

struct GradientBackgroundView: View {
    let colors: [Color]
    let animate: Bool
    
    @State private var startPoint = UnitPoint(x: 0, y: 0)
    @State private var endPoint = UnitPoint(x: 1, y: 1)
    
    var body: some View {
        LinearGradient(colors: colors, startPoint: startPoint, endPoint: endPoint)
            .ignoresSafeArea()
            .onAppear {
                if animate {
                    withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
                        startPoint = UnitPoint(x: 1, y: 0)
                        endPoint = UnitPoint(x: 0, y: 1)
                    }
                }
            }
    }
}

struct CircularClockView: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let color: Color
    
    // For countdown
    var isCountdown: Bool = false
    var totalSeconds: Double = 1
    var remainingSeconds: Double = 0
    
    var progress: Double {
        if isCountdown {
            return remainingSeconds / totalSeconds
        } else {
            return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = size / 2
            
            ZStack {
                // Background Circle
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 10)
                
                // Progress Circle
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [color.opacity(0.6), color]),
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(-90 + 360 * progress)
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(isCountdown ? .linear(duration: 1) : .interactiveSpring(), value: progress)
                
                if !isCountdown {
                    // Drag Knob
                    Circle()
                        .fill(Color.white)
                        .shadow(radius: 2)
                        .frame(width: 20, height: 20)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(progress * 360))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    updateValue(location: value.location, center: center, size: size)
                                }
                        )
                }

                // Center Text
                VStack {
                    if isCountdown {
                         Text(ReminderEngine.format(seconds: Int(remainingSeconds)))
                            .font(.system(size: size * 0.25, weight: .bold, design: .monospaced))
                    } else {
                        Text("\(String(format: step < 1 ? "%.1f" : "%.0f", value))")
                             .font(.system(size: size * 0.3, weight: .bold, design: .rounded))
                        Text(label)
                            .font(.system(size: size * 0.1, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
    
    private func updateValue(location: CGPoint, center: CGPoint, size: CGFloat) {
        let vector = CGVector(dx: location.x - center.x, dy: location.y - center.y)
        let angle = atan2(vector.dy, vector.dx) + .pi / 2
        let fixedAngle = angle < 0 ? angle + 2 * .pi : angle
        let progress = fixedAngle / (2 * .pi)
        
        // Calculate new value
        let rawValue = range.lowerBound + progress * (range.upperBound - range.lowerBound)
        
        // Snap to step
        let steppedValue = (rawValue / step).rounded() * step
        let clampedValue = min(max(steppedValue, range.lowerBound), range.upperBound)
        
        self.value = clampedValue
    }
}


private struct FullscreenReminderPromptView: View {
    let onStartBreak: () -> Void
    let onLater: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.12, green: 0.12, blue: 0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("该休息眼睛了")
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(.white)

                VStack(spacing: 8) {
                    Text("20-20-20 法则")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text("建议每工作 20 分钟，眺望 20 英尺（6 米）外至少 20 秒")
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                HStack(spacing: 16) {
                    Button("稍后（5 分钟）") {
                        onLater()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button("开始休息") {
                        onStartBreak()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(36)
        }
    }
}

private struct FullscreenBreakCountdownView: View {
    @ObservedObject var engine: ReminderEngine
    let onExitFullscreen: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.04, blue: 0.08), Color.black],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Text("休息中")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)
                Text(engine.breakCountdownText)
                    .font(.system(size: 96, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("休息结束后会自动开始下一轮工作计时")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))

                HStack(spacing: 16) {
                    Button("跳过休息") {
                        engine.skipRest()
                        onExitFullscreen()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white.opacity(0.6))
                    .controlSize(.large)

                    if engine.allowExitFullscreenDuringBreak {
                        Button("退出全屏") {
                            onExitFullscreen()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                    }
                }
            }
            .padding(36)
        }
    }
}

@MainActor
final class FullscreenReminderManager {
    private weak var engine: ReminderEngine?
    private var window: NSWindow?

    init(engine: ReminderEngine) {
        self.engine = engine
    }

    func showPrompt(onStartBreak: @escaping () -> Void, onLater: @escaping () -> Void) {
        let window = ensureWindow()
        window.contentViewController = NSHostingController(
            rootView: FullscreenReminderPromptView(
                onStartBreak: onStartBreak,
                onLater: onLater
            )
        )
        present(window)
    }

    func showBreakCountdown(onExitFullscreen: @escaping () -> Void) {
        guard let engine else { return }
        let window = ensureWindow()
        window.contentViewController = NSHostingController(
            rootView: FullscreenBreakCountdownView(
                engine: engine,
                onExitFullscreen: onExitFullscreen
            )
        )
        present(window)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func present(_ window: NSWindow) {
        let screen = targetScreen()
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureWindow() -> NSWindow {
        if let window {
            return window
        }

        let screen = targetScreen()
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .black
        window.level = .screenSaver
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false
        window.ignoresMouseEvents = false

        self.window = window
        return window
    }

    private func targetScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        if let hoverScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return hoverScreen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSUserNotificationCenterDelegate {
    private let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    private let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")
    private var fullscreenReminderManager: FullscreenReminderManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let engine = ReminderEngine.shared
        fullscreenReminderManager = FullscreenReminderManager(engine: engine)
        engine.configureFullscreenHandlers(
            showPrompt: { [weak self] in
                self?.fullscreenReminderManager?.showPrompt(
                    onStartBreak: {
                        ReminderEngine.shared.confirmRestFromFullscreenReminder()
                    },
                    onLater: {
                        ReminderEngine.shared.snoozeRestReminder()
                    }
                )
            },
            showBreakCountdown: { [weak self] in
                self?.fullscreenReminderManager?.showBreakCountdown(
                    onExitFullscreen: {
                        ReminderEngine.shared.dismissFullscreenBreakOverlay()
                    }
                )
            },
            hideReminder: { [weak self] in
                self?.fullscreenReminderManager?.hide()
            },
            isSystemFullscreenContext: { [weak self] in
                self?.isSystemFullscreenContext() ?? true
            }
        )

        if ReminderEngine.shared.usesUserNotifications {
            let center = UNUserNotificationCenter.current()
            center.delegate = self

            let confirmRestAction = UNNotificationAction(
                identifier: confirmRestActionID,
                title: "确定休息",
                options: [.foreground]
            )

            let category = UNNotificationCategory(
                identifier: reminderCategoryID,
                actions: [confirmRestAction],
                intentIdentifiers: []
            )
            center.setNotificationCategories([category])
        } else {
            NSUserNotificationCenter.default.delegate = self
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenLocked),
            name: screenLockedNotification,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleScreenUnlocked),
            name: screenUnlockedNotification,
            object: nil
        )

        Task { @MainActor in
            let engine = ReminderEngine.shared
            engine.activate(startTicker: engine.shouldAutoStartOnActivation)
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc
    private func handleScreenLocked() {
        Task { @MainActor in
            ReminderEngine.shared.setScreenLocked(true)
        }
    }

    @objc
    private func handleScreenUnlocked() {
        Task { @MainActor in
            ReminderEngine.shared.setScreenLocked(false)
        }
    }

    private func isSystemFullscreenContext() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        if frontmostApp.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return false
        }

        guard let windowInfos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        let pid = frontmostApp.processIdentifier
        let visibleScreens = NSScreen.screens
        guard !visibleScreens.isEmpty else { return false }

        for windowInfo in windowInfos {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid else {
                continue
            }
            guard let layer = windowInfo[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds) else {
                continue
            }

            for screen in visibleScreens {
                let screenFrame = screen.frame
                let widthMatch = abs(bounds.width - screenFrame.width) < 4
                let heightMatch = abs(bounds.height - screenFrame.height) < 4
                let originMatch = abs(bounds.minX - screenFrame.minX) < 4 && abs(bounds.minY - screenFrame.minY) < 4
                if widthMatch && heightMatch && originMatch {
                    return true
                }
            }
        }

        return false
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == confirmRestActionID {
            Task { @MainActor in
                ReminderEngine.shared.confirmRest()
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        true
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        guard notification.identifier == legacyReminderNotificationID else { return }
        guard notification.activationType == .actionButtonClicked else { return }

        Task { @MainActor in
            ReminderEngine.shared.confirmRest()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Custom Scroll Wheel Picker (macOS compatible)

struct ScrollWheelColumn: View {
    @Binding var selection: Int
    let range: ClosedRange<Int>
    let suffix: String
    
    private let itemHeight: CGFloat = 40
    private let visibleItems = 5 // show 2 above + selected + 2 below
    
    @State private var dragOffset: CGFloat = 0
    @State private var isHovering = false
    @State private var scrollAccumulator: CGFloat = 0
    @State private var localWheelMonitor: Any?

    private var valueCount: Int {
        range.upperBound - range.lowerBound + 1
    }
    
    var body: some View {
        let values = Array(range)
        
        GeometryReader { geo in
            let totalHeight = geo.size.height
            let centerY = totalHeight / 2
            
            ZStack {
                // Selection highlight
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(height: itemHeight)
                    .position(x: geo.size.width / 2, y: centerY)
                
                // Values
                ForEach(values, id: \.self) { val in
                    let idx = val - range.lowerBound
                    let selIdx = selection - range.lowerBound
                    let rawDiff = idx - selIdx
                    let half = valueCount / 2
                    let diff = abs(rawDiff) > half
                        ? rawDiff + (rawDiff > 0 ? -valueCount : valueCount)
                        : rawDiff
                    let offset = CGFloat(diff) * itemHeight + dragOffset
                    let distFromCenter = abs(offset)
                    let opacity = max(0, 1.0 - distFromCenter / (itemHeight * 2.5))
                    let scale = max(0.6, 1.0 - distFromCenter / (itemHeight * 5))
                    
                    if abs(offset) < totalHeight / 2 + itemHeight {
                        Text(String(format: "%02d", val))
                            .font(.system(size: distFromCenter < itemHeight * 0.5 ? 28 : 20,
                                          weight: distFromCenter < itemHeight * 0.5 ? .bold : .regular,
                                          design: .rounded))
                            .foregroundColor(distFromCenter < itemHeight * 0.5 ? .primary : .secondary)
                            .opacity(opacity)
                            .scaleEffect(scale)
                            .frame(height: itemHeight)
                            .position(x: geo.size.width / 2, y: centerY + offset)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        dragOffset = value.translation.height
                    }
                    .onEnded { value in
                        let steps = Int((-dragOffset / itemHeight).rounded())
                        let newVal = wrappedValue(selection + steps)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            selection = newVal
                            dragOffset = 0
                        }
                    }
            )
            .onContinuousHover { _ in } // enable scroll area
        }
        .frame(width: 70, height: itemHeight * CGFloat(visibleItems))
        .clipped()
        .onHover { hovering in
            isHovering = hovering
        }
        .onAppear {
            localWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard isHovering else { return event }
                handleScrollWheel(event)
                return nil
            }
        }
        .onDisappear {
            if let localWheelMonitor {
                NSEvent.removeMonitor(localWheelMonitor)
                self.localWheelMonitor = nil
            }
        }
    }

    private func wrappedValue(_ rawValue: Int) -> Int {
        guard valueCount > 0 else { return range.lowerBound }
        var offset = (rawValue - range.lowerBound) % valueCount
        if offset < 0 {
            offset += valueCount
        }
        return range.lowerBound + offset
    }

    private func handleScrollWheel(_ event: NSEvent) {
        let rawDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
        scrollAccumulator += rawDelta

        let threshold: CGFloat = 12
        let steps = Int((scrollAccumulator / threshold).rounded(.towardZero))
        guard steps != 0 else { return }

        scrollAccumulator -= CGFloat(steps) * threshold
        withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
            selection = wrappedValue(selection - steps)
        }
    }
}

struct WheelTimePicker: View {
    let label: String
    @Binding var totalMinutes: Double
    let range: ClosedRange<Double>
    let themeColor: Color
    
    var minutes: Int {
        Int(totalMinutes)
    }
    
    var seconds: Int {
        Int(((totalMinutes - Double(Int(totalMinutes))) * 60).rounded())
    }
    
    private var minutesBinding: Binding<Int> {
        Binding(
            get: { minutes },
            set: { newMinutes in
                let clamped = min(max(newMinutes, Int(range.lowerBound)), Int(range.upperBound))
                totalMinutes = Double(clamped) + Double(seconds) / 60.0
            }
        )
    }
    
    private var secondsBinding: Binding<Int> {
        Binding(
            get: { seconds },
            set: { newSeconds in
                let clamped = min(max(newSeconds, 0), 59)
                totalMinutes = Double(minutes) + Double(clamped) / 60.0
            }
        )
    }
    
    var body: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.headline)
                .foregroundStyle(themeColor)
            
            HStack(spacing: 4) {
                ScrollWheelColumn(
                    selection: minutesBinding,
                    range: Int(range.lowerBound)...Int(range.upperBound),
                    suffix: ""
                )
                
                Text(":")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(themeColor)
                
                ScrollWheelColumn(selection: secondsBinding, range: 0...59, suffix: "")
            }
            .tint(themeColor)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var reminderEngine: ReminderEngine
    
    private var workIntervalBinding: Binding<Double> {
        Binding(
            get: { reminderEngine.workIntervalMinutes },
            set: { reminderEngine.setWorkInterval(minutes: $0) }
        )
    }

    private var breakDurationBinding: Binding<Double> {
        Binding(
            get: { reminderEngine.breakDurationMinutes },
            set: { reminderEngine.setBreakDuration(minutes: $0) }
        )
    }

    private var workMinutesInput: Binding<Int> {
        Binding(
            get: { Int(reminderEngine.workIntervalMinutes.rounded(.down)) },
            set: { newMinutes in
                let seconds = secondsPart(from: reminderEngine.workIntervalMinutes)
                reminderEngine.setWorkInterval(minutes: Double(max(0, newMinutes)) + Double(seconds) / 60.0)
            }
        )
    }

    private var workSecondsInput: Binding<Int> {
        Binding(
            get: { secondsPart(from: reminderEngine.workIntervalMinutes) },
            set: { newSeconds in
                let minutes = Int(reminderEngine.workIntervalMinutes.rounded(.down))
                let clampedSeconds = min(max(newSeconds, 0), 59)
                reminderEngine.setWorkInterval(minutes: Double(minutes) + Double(clampedSeconds) / 60.0)
            }
        )
    }

    private var breakMinutesInput: Binding<Int> {
        Binding(
            get: { Int(reminderEngine.breakDurationMinutes.rounded(.down)) },
            set: { newMinutes in
                let seconds = secondsPart(from: reminderEngine.breakDurationMinutes)
                reminderEngine.setBreakDuration(minutes: Double(max(0, newMinutes)) + Double(seconds) / 60.0)
            }
        )
    }

    private var breakSecondsInput: Binding<Int> {
        Binding(
            get: { secondsPart(from: reminderEngine.breakDurationMinutes) },
            set: { newSeconds in
                let minutes = Int(reminderEngine.breakDurationMinutes.rounded(.down))
                let clampedSeconds = min(max(newSeconds, 0), 59)
                reminderEngine.setBreakDuration(minutes: Double(minutes) + Double(clampedSeconds) / 60.0)
            }
        )
    }

    private var workMinInput: Binding<Int> {
        Binding(
            get: { Int(reminderEngine.workMinMinutes.rounded()) },
            set: { newMin in
                reminderEngine.setWorkRange(
                    min: Double(max(0, newMin)),
                    max: reminderEngine.workMaxMinutes
                )
            }
        )
    }

    private var workMaxInput: Binding<Int> {
        Binding(
            get: { Int(reminderEngine.workMaxMinutes.rounded()) },
            set: { newMax in
                reminderEngine.setWorkRange(
                    min: reminderEngine.workMinMinutes,
                    max: Double(max(0, newMax))
                )
            }
        )
    }

    private var breakMinInput: Binding<Int> {
        Binding(
            get: { Int(reminderEngine.breakMinMinutes.rounded()) },
            set: { newMin in
                reminderEngine.setBreakRange(
                    min: Double(max(0, newMin)),
                    max: reminderEngine.breakMaxMinutes
                )
            }
        )
    }

    private var breakMaxInput: Binding<Int> {
        Binding(
            get: { Int(reminderEngine.breakMaxMinutes.rounded()) },
            set: { newMax in
                reminderEngine.setBreakRange(
                    min: reminderEngine.breakMinMinutes,
                    max: Double(max(0, newMax))
                )
            }
        )
    }

    private var allowExitFullscreenBreakBinding: Binding<Bool> {
        Binding(
            get: { reminderEngine.allowExitFullscreenDuringBreak },
            set: { reminderEngine.setAllowExitFullscreenDuringBreak($0) }
        )
    }
    
    var body: some View {
        Form {
            Section(header: Text("时间设置").font(.headline)) {
                HStack(alignment: .top, spacing: 16) {
                    timeSettingCard(
                        title: "工作时长",
                        binding: workIntervalBinding,
                        range: reminderEngine.workMinMinutes...reminderEngine.workMaxMinutes,
                        color: .blue
                    )
                    timeSettingCard(
                        title: "休息时长",
                        binding: breakDurationBinding,
                        range: reminderEngine.breakMinMinutes...reminderEngine.breakMaxMinutes,
                        color: .green
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("键入时间") {
                LabeledContent("工作时长") {
                    durationInputRow(
                        minutes: workMinutesInput,
                        seconds: workSecondsInput,
                        tint: .blue
                    )
                }
                LabeledContent("休息时长") {
                    durationInputRow(
                        minutes: breakMinutesInput,
                        seconds: breakSecondsInput,
                        tint: .green
                    )
                }
            }

            Section("时长范围") {
                LabeledContent("工作范围") {
                    rangeInputRow(minutesMin: workMinInput, minutesMax: workMaxInput, tint: .blue)
                }
                LabeledContent("休息范围") {
                    rangeInputRow(minutesMin: breakMinInput, minutesMax: breakMaxInput, tint: .green)
                }
                Text("可手动输入最短/最长分钟数；轮盘和输入会按该范围自动约束。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("全屏休息倒计时") {
                Toggle("允许在倒计时中退出全屏", isOn: allowExitFullscreenBreakBinding)
                Text("关闭后，休息倒计时期间不显示“退出全屏”按钮。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section(header: Text("通知状态")) {
                HStack {
                    Text(reminderEngine.notificationStatusText)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            
            Section {
                 Text("Reminder v0.1.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                 Text("Designed by KyochiLian with ❤️")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
    }

    private func secondsPart(from minutesValue: Double) -> Int {
        let wholeMinutes = minutesValue.rounded(.down)
        return min(max(Int(((minutesValue - wholeMinutes) * 60).rounded()), 0), 59)
    }

    private func timeSettingCard(
        title: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        color: Color
    ) -> some View {
        WheelTimePicker(
            label: title,
            totalMinutes: binding,
            range: range,
            themeColor: color
        )
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
    }

    private func durationInputRow(
        minutes: Binding<Int>,
        seconds: Binding<Int>,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            TextField("分钟", value: minutes, format: .number)
                .frame(width: 70)
            Stepper("", value: minutes, in: 0...1_440)
                .labelsHidden()
            Text(":")
                .foregroundStyle(.secondary)
            TextField("秒", value: seconds, format: .number)
                .frame(width: 56)
            Stepper("", value: seconds, in: 0...59)
                .labelsHidden()
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .tint(tint)
    }

    private func rangeInputRow(
        minutesMin: Binding<Int>,
        minutesMax: Binding<Int>,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Text("最短")
                .foregroundStyle(.secondary)
            TextField("0", value: minutesMin, format: .number)
                .frame(width: 62)
            Stepper("", value: minutesMin, in: 0...1_440)
                .labelsHidden()
            Text("最长")
                .foregroundStyle(.secondary)
            TextField("120", value: minutesMax, format: .number)
                .frame(width: 62)
            Stepper("", value: minutesMax, in: 0...1_440)
                .labelsHidden()
            Text("分钟")
                .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .tint(tint)
    }
}

struct TimerView: View {
    @ObservedObject var reminderEngine: ReminderEngine
    
    var body: some View {
        VStack(spacing: 30) {
            Spacer()
            
            // Status Circle/Ring
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.1), lineWidth: 20)
                
                Circle() // Animated ring
                    .trim(from: 0, to: statusProgress)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [statusColor.opacity(0.6), statusColor]),
                            center: .center,
                            startAngle: .degrees(-90),
                            endAngle: .degrees(-90 + 360 * statusProgress)
                        ),
                        style: StrokeStyle(lineWidth: 20, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: statusProgress)
                
                VStack(spacing: 10) {
                    Text(reminderEngine.modeTitle)
                        .font(.title)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.center)
                    
                    Text(reminderEngine.countdownLine)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
                .padding()
            }
            .frame(maxWidth: 300, maxHeight: 300)
            .aspectRatio(1, contentMode: .fit)
            .padding()
            
            Text(reminderEngine.statusLine)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            if reminderEngine.needsManualStart {
                VStack(spacing: 10) {
                    Button(action: { reminderEngine.startTiming() }) {
                        Text("开始计时")
                            .font(.headline)
                            .frame(maxWidth: 240)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("首次启动需手动点击开始，之后会自动恢复计时。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                HStack(spacing: 12) {
                    if reminderEngine.phase == .resting {
                        Button(action: { reminderEngine.skipRest() }) {
                            Text("跳过休息")
                                .font(.headline)
                                .frame(maxWidth: 150)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    Button(action: { reminderEngine.confirmRest() }) {
                        Text("立即开始休息")
                            .font(.headline)
                            .frame(maxWidth: 200)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!reminderEngine.canConfirmRest)
                    .controlSize(.large)
                }
            }
            
            Spacer()
        }
        .padding()
    }
    
    var statusProgress: Double {
        switch reminderEngine.phase {
        case .working:
             if reminderEngine.waitingForRestConfirmation {
                 return Double(reminderEngine.secondsUntilNextReminder) / 300.0 // 5 mins
             }
             let total = reminderEngine.workIntervalMinutes * 60
             return total > 0 ? Double(reminderEngine.remainingWorkSeconds) / total : 0
        case .resting:
             let total = reminderEngine.breakDurationMinutes * 60
             return total > 0 ? Double(reminderEngine.remainingBreakSeconds) / total : 0
        }
    }
    
    var statusColor: Color {
        switch reminderEngine.phase {
        case .working:
            return reminderEngine.waitingForRestConfirmation ? .orange : .blue
        case .resting:
            return .green
        }
    }
}

struct ContentView: View {
    @StateObject private var reminderEngine = ReminderEngine.shared
    @State private var selection: SidebarItem? = .timer

    enum SidebarItem: Hashable {
        case timer
        case settings
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                NavigationLink(value: SidebarItem.timer) {
                    Label("计时", systemImage: "timer")
                }
                NavigationLink(value: SidebarItem.settings) {
                    Label("设置", systemImage: "gearshape")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .navigationTitle("Reminder")
        } detail: {
            Group {
                switch selection {
                case .timer:
                    TimerView(reminderEngine: reminderEngine)
                case .settings:
                    SettingsView(reminderEngine: reminderEngine)
                case .none:
                    Text("请选择一项")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.automatic)
    }
}

@main
struct ReminderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(
            width: WindowDefaults.defaultSize.width,
            height: WindowDefaults.defaultSize.height
        )
        .windowResizability(.automatic)
    }
}
