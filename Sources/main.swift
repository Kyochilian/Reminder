import AppKit
import CoreText
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

enum AppLanguage: String, CaseIterable, Identifiable {
    case zhHans = "zh-Hans"
    case en = "en"

    var id: String { rawValue }

    static var preferredDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first ?? ""
        return preferred.hasPrefix("zh") ? .zhHans : .en
    }
}

@MainActor
private enum FontAwesomeSupport {
    private static let candidateFontNames = [
        "Font Awesome 6 Free Solid",
        "Font Awesome 6 Free-Regular-400",
        "Font Awesome 6 Free",
        "FontAwesome"
    ]
    private static var didAttemptRegister = false
    private static var cachedFontName: String?

    static func resolvedFontName() -> String? {
        if let cachedFontName {
            return cachedFontName
        }
        registerIfNeeded()
        for name in candidateFontNames where NSFont(name: name, size: 14) != nil {
            cachedFontName = name
            return name
        }
        return nil
    }

    private static func registerIfNeeded() {
        guard !didAttemptRegister else { return }
        didAttemptRegister = true

        let cwdAssetURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("assets/fa-solid-900.ttf")

        let candidateURLs: [URL] = [
            Bundle.main.url(forResource: "fa-solid-900", withExtension: "ttf"),
            Bundle.main.url(forResource: "FontAwesomeSolid", withExtension: "ttf"),
            cwdAssetURL
        ].compactMap { $0 }

        for url in candidateURLs where FileManager.default.fileExists(atPath: url.path) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

private struct FontAwesomeSymbolView: View {
    let unicode: String
    let fallbackSystemName: String
    let size: CGFloat
    let color: Color

    init(
        unicode: String,
        fallbackSystemName: String,
        size: CGFloat = 18,
        color: Color = .primary
    ) {
        self.unicode = unicode
        self.fallbackSystemName = fallbackSystemName
        self.size = size
        self.color = color
    }

    var body: some View {
        Group {
            if let fontName = FontAwesomeSupport.resolvedFontName() {
                Text(unicode)
                    .font(.custom(fontName, size: size))
            } else {
                Image(systemName: fallbackSystemName)
                    .font(.system(size: size, weight: .semibold))
            }
        }
        .foregroundStyle(color)
    }
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
    static let appLanguage = "appLanguage"
    static let allowExitFullscreenDuringBreak = "allowExitFullscreenDuringBreak"
    static let phase = "phase"
    static let remainingWorkSeconds = "remainingWorkSeconds"
    static let waitingForRestConfirmation = "waitingForRestConfirmation"
    static let secondsUntilNextReminder = "secondsUntilNextReminder"
    static let breakEndDate = "breakEndDate"
    static let remindersSent = "remindersSent"
    static let notificationAuthorizationRequested = "notificationAuthorizationRequested"
    static let notificationEnableHintShown = "notificationEnableHintShown"
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
    @Published private(set) var notificationStatusText = "Checking notification permission..."
    @Published private(set) var hasStartedTimer = false
    @Published private(set) var isTickerRunning = false
    @Published var enableFullscreenBlur = true
    @Published var enableRestAnimation = true
    @Published private(set) var allowExitFullscreenDuringBreak = true
    @Published private(set) var appLanguage: AppLanguage = .zhHans
    @Published private(set) var shouldShowNotificationEnableHint = false

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
            if !defaults.bool(forKey: DefaultsKey.notificationEnableHintShown) {
                shouldShowNotificationEnableHint = true
            }
            requestNotificationAuthorizationOnFirstLaunchIfNeeded()
            refreshNotificationStatus()
        case .legacyNSUserNotifications:
            notificationStatusText = tr("通知已开启（开发模式）", "Notifications enabled (development mode)")
        case .disabledForTests:
            notificationStatusText = tr("通知已开启（测试模式）", "Notifications enabled (test mode)")
        }
    }

    func dismissNotificationEnableHint() {
        guard shouldShowNotificationEnableHint else { return }
        shouldShowNotificationEnableHint = false
        defaults.set(true, forKey: DefaultsKey.notificationEnableHintShown)
    }

    func tr(_ zh: String, _ en: String) -> String {
        appLanguage == .zhHans ? zh : en
    }

    func setLanguage(_ language: AppLanguage) {
        guard appLanguage != language else { return }
        appLanguage = language
        refreshNotificationStatus()
        saveState()
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
            return tr("等待开始计时", "Ready to Start")
        }
        switch phase {
        case .resting:
            return tr("休息中", "On Break")
        case .working:
            if waitingForRestConfirmation {
                return tr("等待确认休息", "Awaiting Break Confirmation")
            }
            return isScreenLocked
                ? tr("工作中（锁屏暂停）", "Working (Paused While Screen Locked)")
                : tr("工作中", "Working")
        }
    }

    var statusLine: String {
        if needsManualStart {
            return tr(
                "首次打开应用请点击“开始计时”。",
                "Please click “Start Timer” the first time you open the app."
            )
        }
        switch phase {
        case .resting:
            return isScreenLocked
                ? tr("锁屏时休息计时继续。", "Break countdown continues while screen is locked.")
                : tr("请看向远处，放松眼部肌肉。", "Look into the distance to relax your eye muscles.")
        case .working:
            if waitingForRestConfirmation {
                return tr(
                    "若未点击“确定休息”，将每 5 分钟再次提醒。",
                    "If not confirmed, a reminder repeats every 5 minutes."
                )
            }
            return isScreenLocked
                ? tr("屏幕已锁定，工作计时暂停。", "Screen is locked, work timer is paused.")
                : tr("专注工作中。", "Stay focused.")
        }
    }

    var countdownLine: String {
        if needsManualStart {
            return tr("准备时长 ", "Ready duration ") + Self.format(seconds: remainingWorkSeconds)
        }
        switch phase {
        case .resting:
            return tr("休息剩余 ", "Break remaining ") + Self.format(seconds: remainingBreakSeconds)
        case .working:
            if waitingForRestConfirmation {
                return tr("下次提醒倒计时 ", "Next reminder in ") + Self.format(seconds: secondsUntilNextReminder)
            }
            return tr("距离提醒 ", "Reminder in ") + Self.format(seconds: remainingWorkSeconds)
        }
    }

    var workIntervalDescription: String {
        formatMinutes(workIntervalMinutes)
    }

    var breakDurationDescription: String {
        formatMinutes(breakDurationMinutes)
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

    func showFullscreenBreakCountdownIfResting() {
        guard phase == .resting else { return }
        isFullscreenReminderVisible = true
        showFullscreenBreakCountdown?()
        saveState()
    }

    func skipRest() {
        guard allowExitFullscreenDuringBreak else { return }
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
                self.notificationStatusText = self.notificationStatusText(from: status)
            }
        case .legacyNSUserNotifications:
            notificationStatusText = tr("通知已开启（开发模式）", "Notifications enabled (development mode)")
        case .disabledForTests:
            notificationStatusText = tr("通知已开启（测试模式）", "Notifications enabled (test mode)")
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
                self.notificationStatusText = self.tr(
                    "通知授权失败：\(error.localizedDescription)",
                    "Notification authorization failed: \(error.localizedDescription)"
                )
            }
            self.refreshNotificationStatus()
        }
    }

    private func sendRestReminderNotification() {
        guard isActivated else { return }
        switch notificationBackend {
        case .userNotifications:
            let confirmRestAction = UNNotificationAction(
                identifier: confirmRestActionID,
                title: tr("确定休息", "Start Break"),
                options: [.foreground]
            )
            let category = UNNotificationCategory(
                identifier: reminderCategoryID,
                actions: [confirmRestAction],
                intentIdentifiers: []
            )
            UNUserNotificationCenter.current().setNotificationCategories([category])

            let content = UNMutableNotificationContent()
            content.title = tr("该休息眼睛了", "Time to Rest Your Eyes")
            content.body = tr(
                "点击“确定休息”开始休息计时。",
                "Tap “Start Break” to begin the rest countdown."
            )
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
                    self.notificationStatusText = self.tr(
                        "通知发送失败：\(error.localizedDescription)",
                        "Failed to send notification: \(error.localizedDescription)"
                    )
                }
            }
        case .legacyNSUserNotifications:
            let notification = NSUserNotification()
            notification.identifier = legacyReminderNotificationID
            notification.title = tr("该休息眼睛了", "Time to Rest Your Eyes")
            notification.informativeText = tr(
                "点击“确定休息”开始休息计时。",
                "Click “Start Break” to begin the rest countdown."
            )
            notification.hasActionButton = true
            notification.actionButtonTitle = tr("确定休息", "Start Break")
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
        if let rawLanguage = defaults.string(forKey: DefaultsKey.appLanguage),
           let parsedLanguage = AppLanguage(rawValue: rawLanguage) {
            appLanguage = parsedLanguage
        } else {
            appLanguage = AppLanguage.preferredDefault
        }
        notificationStatusText = tr("通知权限检查中", "Checking notification permission...")

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
        defaults.set(appLanguage.rawValue, forKey: DefaultsKey.appLanguage)
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

    private func formatMinutes(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.01 {
            let rounded = Int(value.rounded())
            return appLanguage == .zhHans ? "\(rounded) 分钟" : "\(rounded) min"
        }
        return appLanguage == .zhHans
            ? String(format: "%.1f 分钟", value)
            : String(format: "%.1f min", value)
    }

    private func notificationStatusText(from status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return tr("通知已开启", "Notifications enabled")
        case .denied:
            return tr("通知被关闭，请在系统设置中开启", "Notifications disabled. Enable them in System Settings.")
        case .notDetermined:
            return tr("通知权限未确认", "Notification permission not determined")
        @unknown default:
            return tr("通知状态未知", "Unknown notification status")
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
    @ObservedObject var engine: ReminderEngine
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

            VStack(spacing: 22) {
                HStack(spacing: 10) {
                    FontAwesomeSymbolView(
                        unicode: "\u{f06e}",
                        fallbackSystemName: "eye.fill",
                        size: 28,
                        color: .white
                    )
                    Text("👀")
                        .font(.system(size: 30))
                }

                Text(engine.tr("该休息眼睛了", "Time to Rest Your Eyes"))
                    .font(.system(size: 54, weight: .bold))
                    .foregroundStyle(.white)

                VStack(spacing: 8) {
                    Text("20-20-20")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(engine.tr(
                        "建议每工作 20 分钟，眺望 20 英尺（6 米）外至少 20 秒",
                        "Every 20 minutes, look 20 feet away for at least 20 seconds"
                    ))
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                HStack(spacing: 16) {
                    Button(engine.tr("稍后（5 分钟）", "Later (5 min)")) {
                        onLater()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(engine.tr("开始休息", "Start Break")) {
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
                Text(engine.tr("休息中", "On Break"))
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)
                Text(engine.breakCountdownText)
                    .font(.system(size: 96, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(engine.tr(
                    "休息结束后会自动开始下一轮工作计时",
                    "A new work cycle starts automatically after this break"
                ))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))

                HStack(spacing: 16) {
                    if engine.allowExitFullscreenDuringBreak {
                        Button(engine.tr("跳过休息", "Skip Break")) {
                            engine.skipRest()
                            onExitFullscreen()
                        }
                        .buttonStyle(.bordered)
                        .tint(.white.opacity(0.6))
                        .controlSize(.large)

                        Button(engine.tr("退出全屏", "Exit Fullscreen")) {
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
        guard let engine else { return }
        let window = ensureWindow()
        window.contentViewController = NSHostingController(
            rootView: FullscreenReminderPromptView(
                engine: engine,
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
                title: engine.tr("确定休息", "Start Break"),
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

    private func tr(_ zh: String, _ en: String) -> String {
        reminderEngine.tr(zh, en)
    }
    
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

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { reminderEngine.appLanguage },
            set: { reminderEngine.setLanguage($0) }
        )
    }
    
    var body: some View {
        Form {
            Section(header: Text(tr("时间设置", "Time Settings")).font(.headline)) {
                HStack(alignment: .top, spacing: 16) {
                    timeSettingCard(
                        title: tr("工作时长", "Work Duration"),
                        binding: workIntervalBinding,
                        range: reminderEngine.workMinMinutes...reminderEngine.workMaxMinutes,
                        color: .blue
                    )
                    timeSettingCard(
                        title: tr("休息时长", "Break Duration"),
                        binding: breakDurationBinding,
                        range: reminderEngine.breakMinMinutes...reminderEngine.breakMaxMinutes,
                        color: .green
                    )
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section(tr("键入时间", "Manual Input")) {
                LabeledContent(tr("工作时长", "Work Duration")) {
                    durationInputRow(
                        minutes: workMinutesInput,
                        seconds: workSecondsInput,
                        tint: .blue
                    )
                }
                LabeledContent(tr("休息时长", "Break Duration")) {
                    durationInputRow(
                        minutes: breakMinutesInput,
                        seconds: breakSecondsInput,
                        tint: .green
                    )
                }
            }

            Section(tr("时长范围", "Duration Range")) {
                LabeledContent(tr("工作范围", "Work Range")) {
                    rangeInputRow(minutesMin: workMinInput, minutesMax: workMaxInput, tint: .blue)
                }
                LabeledContent(tr("休息范围", "Break Range")) {
                    rangeInputRow(minutesMin: breakMinInput, minutesMax: breakMaxInput, tint: .green)
                }
                Text(
                    tr(
                        "可手动输入最短/最长分钟数；轮盘和输入会按该范围自动约束。",
                        "You can type min/max minutes manually; wheel/input values are constrained automatically."
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr("休息全屏策略", "Break Fullscreen Policy")) {
                Toggle(
                    tr("允许在倒计时中退出全屏", "Allow Exit Fullscreen During Break"),
                    isOn: allowExitFullscreenBreakBinding
                )
                Text(
                    tr(
                        "关闭后，休息倒计时期间不显示“退出全屏”和“跳过休息”按钮。",
                        "When disabled, both “Exit Fullscreen” and “Skip Break” are hidden during break countdown."
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(tr("语言", "Language")) {
                Picker("", selection: languageBinding) {
                    Text("中文").tag(AppLanguage.zhHans)
                    Text("English").tag(AppLanguage.en)
                }
                .pickerStyle(.segmented)
            }
            
            Section {
                Text("Reminder v0.1.2")
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
            TextField(tr("分钟", "Min"), value: minutes, format: .number)
                .frame(width: 70)
            Stepper("", value: minutes, in: 0...1_440)
                .labelsHidden()
            Text(":")
                .foregroundStyle(.secondary)
            TextField(tr("秒", "Sec"), value: seconds, format: .number)
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
            Text(tr("最短", "Min"))
                .foregroundStyle(.secondary)
            TextField("0", value: minutesMin, format: .number)
                .frame(width: 62)
            Stepper("", value: minutesMin, in: 0...1_440)
                .labelsHidden()
            Text(tr("最长", "Max"))
                .foregroundStyle(.secondary)
            TextField("120", value: minutesMax, format: .number)
                .frame(width: 62)
            Stepper("", value: minutesMax, in: 0...1_440)
                .labelsHidden()
            Text(tr("分钟", "min"))
                .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .tint(tint)
    }
}

struct TimerView: View {
    @ObservedObject var reminderEngine: ReminderEngine

    private func tr(_ zh: String, _ en: String) -> String {
        reminderEngine.tr(zh, en)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 20)

                    Circle()
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
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)

                        Text(reminderEngine.countdownLine)
                            .font(.system(size: 26, weight: .bold, design: .monospaced))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    }
                    .padding()
                }
                .frame(maxWidth: 260, maxHeight: 260)
                .aspectRatio(1, contentMode: .fit)
                .padding(.top, 8)

                Text(reminderEngine.statusLine)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                if reminderEngine.needsManualStart {
                    VStack(spacing: 10) {
                        Button(action: { reminderEngine.startTiming() }) {
                            Text(tr("开始计时", "Start Timer"))
                                .font(.headline)
                                .frame(maxWidth: 260)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Text(tr(
                            "首次启动需手动点击开始，之后会自动恢复计时。",
                            "Click once to start. Timer will auto-resume on next launches."
                        ))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                } else if reminderEngine.phase == .resting {
                    HStack(spacing: 12) {
                        if reminderEngine.allowExitFullscreenDuringBreak {
                            Button(action: { reminderEngine.skipRest() }) {
                                Text(tr("跳过休息", "Skip Break"))
                                    .font(.headline)
                                    .frame(maxWidth: 170)
                                    .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }

                        Button(action: { reminderEngine.showFullscreenBreakCountdownIfResting() }) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                Text(tr("进入全屏倒计时", "Open Fullscreen Countdown"))
                            }
                            .font(.headline)
                            .frame(maxWidth: 280)
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                } else {
                    Button(action: { reminderEngine.confirmRest() }) {
                        Text(tr("立即开始休息", "Start Break Now"))
                            .font(.headline)
                            .frame(maxWidth: 260)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!reminderEngine.canConfirmRest)
                    .controlSize(.large)
                }

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 880)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

struct RuleEducationView: View {
    @ObservedObject var reminderEngine: ReminderEngine
    private let referenceURL = URL(string: "https://www.aoa.org/AOA/Images/Patients/Eye%20Conditions/20-20-20-rule.pdf")!

    private func tr(_ zh: String, _ en: String) -> String {
        reminderEngine.tr(zh, en)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 10) {
                    FontAwesomeSymbolView(
                        unicode: "\u{f06e}",
                        fallbackSystemName: "eye.fill",
                        size: 24,
                        color: .accentColor
                    )
                    Text("👀")
                        .font(.system(size: 25))
                    Text(tr("您知道吗？", "Did You Know?"))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                }

                HStack(spacing: 14) {
                    statPill(iconUnicode: "\u{f017}", fallback: "clock.fill", title: "20 min")
                    statPill(iconUnicode: "\u{f06e}", fallback: "eye.fill", title: "20 sec")
                    statPill(iconUnicode: "\u{f279}", fallback: "ruler.fill", title: "20 ft / 6 m")
                }

                ruleTextCard(
                    body: "20-20-20 法则旨在减少数字眼睛疲劳（计算机视觉综合征）和长时间使用屏幕导致的疲劳。它建议每 20 分钟，您眺望大于等于 20 英尺（6m）外的物体超过 20 秒。这个动作可以让眼睛的聚焦肌肉放松[1]。"
                )

                ruleTextCard(
                    body: "The 20-20-20 rule is a guideline designed to reduce digital eye strain (Computer Vision Syndrome) and fatigue caused by prolonged screen use. It advises that every 20 minutes, you take a 20-second break to look at something 20 feet away. This action allows the eye's focusing muscles to relax[1]."
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("参考文献", "References"))
                        .font(.headline)
                    HStack(alignment: .top, spacing: 8) {
                        Text("[1]")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("American Optometric Association (AOA). 20-20-20 Rule.")
                                .font(.footnote)
                            Link(
                                "https://www.aoa.org/AOA/Images/Patients/Eye%20Conditions/20-20-20-rule.pdf",
                                destination: referenceURL
                            )
                            .font(.footnote.weight(.semibold))
                        }
                    }
                }
                .padding(.top, 6)
            }
            .padding(26)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.07), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func statPill(iconUnicode: String, fallback: String, title: String) -> some View {
        HStack(spacing: 8) {
            FontAwesomeSymbolView(
                unicode: iconUnicode,
                fallbackSystemName: fallback,
                size: 14,
                color: .accentColor
            )
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(0.12))
        )
    }

    private func ruleTextCard(body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(body)
                .font(.body)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
}

struct ContentView: View {
    @StateObject private var reminderEngine = ReminderEngine.shared
    @State private var selection: SidebarItem? = .timer

    private func tr(_ zh: String, _ en: String) -> String {
        reminderEngine.tr(zh, en)
    }

    enum SidebarItem: Hashable {
        case timer
        case settings
        case ruleEducation
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                NavigationLink(value: SidebarItem.timer) {
                    Label(tr("计时", "Timer"), systemImage: "timer")
                }
                NavigationLink(value: SidebarItem.settings) {
                    Label(tr("设置", "Settings"), systemImage: "gearshape")
                }
                NavigationLink(value: SidebarItem.ruleEducation) {
                    Label(tr("科普", "20-20-20 Guide"), systemImage: "book.closed")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .navigationTitle(tr("Reminder 护眼助手", "Reminder"))
        } detail: {
            Group {
                switch selection {
                case .timer:
                    TimerView(reminderEngine: reminderEngine)
                case .settings:
                    SettingsView(reminderEngine: reminderEngine)
                case .ruleEducation:
                    RuleEducationView(reminderEngine: reminderEngine)
                case .none:
                    Text(tr("请选择一项", "Please select an item"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.automatic)
        .alert(
            tr("开启通知提醒", "Enable Notifications"),
            isPresented: Binding(
                get: { reminderEngine.shouldShowNotificationEnableHint },
                set: { isPresented in
                    if !isPresented {
                        reminderEngine.dismissNotificationEnableHint()
                    }
                }
            )
        ) {
            Button(tr("我知道了", "Got it")) {
                reminderEngine.dismissNotificationEnableHint()
            }
        } message: {
            Text(
                tr(
                    "为确保按时护眼，请在系统弹窗中允许 Reminder 发送通知。",
                    "To receive eye-care reminders on time, please allow notifications for Reminder when prompted."
                )
            )
        }
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
