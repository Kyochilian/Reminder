import XCTest
@testable import Reminder

final class ReminderEngineTests: XCTestCase {
    final class MutableClock {
        var now: Date

        init(now: Date) {
            self.now = now
        }
    }

    @MainActor
    func testDefaultAndClampSettings() {
        let (engine, defaults, suiteName, _) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        XCTAssertEqual(engine.workIntervalMinutes, 20)
        XCTAssertEqual(engine.breakDurationMinutes, 5)

        engine.setWorkInterval(minutes: 1)
        XCTAssertEqual(engine.workIntervalMinutes, 1)

        engine.setWorkInterval(minutes: -10)
        XCTAssertEqual(engine.workIntervalMinutes, 0)

        engine.setWorkInterval(minutes: 999)
        XCTAssertEqual(engine.workIntervalMinutes, 120)

        engine.setBreakDuration(minutes: 0)
        XCTAssertEqual(engine.breakDurationMinutes, 0)

        engine.setBreakDuration(minutes: -10)
        XCTAssertEqual(engine.breakDurationMinutes, 0)

        engine.setBreakDuration(minutes: 999)
        XCTAssertEqual(engine.breakDurationMinutes, 60)
    }

    @MainActor
    func testManualMinAndMaxRangeAppliesToWorkAndBreak() {
        let (engine, defaults, suiteName, _) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        engine.setWorkRange(min: 30, max: 45)
        engine.setWorkInterval(minutes: 10)
        XCTAssertEqual(engine.workIntervalMinutes, 30)

        engine.setWorkInterval(minutes: 50)
        XCTAssertEqual(engine.workIntervalMinutes, 45)

        engine.setBreakRange(min: 2, max: 4)
        engine.setBreakDuration(minutes: 1)
        XCTAssertEqual(engine.breakDurationMinutes, 2)

        engine.setBreakDuration(minutes: 9)
        XCTAssertEqual(engine.breakDurationMinutes, 4)
    }

    @MainActor
    func testCanStartRestImmediatelyDuringWorkPhase() {
        let (engine, defaults, suiteName, _) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        XCTAssertEqual(engine.phase, .working)
        XCTAssertFalse(engine.waitingForRestConfirmation)

        engine.confirmRest()
        XCTAssertEqual(engine.phase, .resting)
    }

    @MainActor
    func testFullscreenExitOptionDefaultsToEnabledAndPersists() {
        let (engine, defaults, suiteName, clock) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        XCTAssertTrue(engine.allowExitFullscreenDuringBreak)
        engine.setAllowExitFullscreenDuringBreak(false)
        XCTAssertFalse(engine.allowExitFullscreenDuringBreak)

        let reloaded = ReminderEngine.makeForTesting(defaults: defaults) {
            clock.now
        }
        reloaded.activate(startTicker: false)
        XCTAssertFalse(reloaded.allowExitFullscreenDuringBreak)
    }

    @MainActor
    func testRangePersistsAcrossRelaunch() {
        let (engine, defaults, suiteName, clock) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        engine.setWorkRange(min: 12, max: 88)
        engine.setBreakRange(min: 1, max: 33)

        let reloaded = ReminderEngine.makeForTesting(defaults: defaults) {
            clock.now
        }
        reloaded.activate(startTicker: false)

        XCTAssertEqual(reloaded.workMinMinutes, 12)
        XCTAssertEqual(reloaded.workMaxMinutes, 88)
        XCTAssertEqual(reloaded.breakMinMinutes, 1)
        XCTAssertEqual(reloaded.breakMaxMinutes, 33)
    }

    @MainActor
    func testInitialLaunchRequiresManualStart() {
        let (engine, defaults, suiteName, _) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        XCTAssertTrue(engine.needsManualStart)
        XCTAssertFalse(engine.shouldAutoStartOnActivation)
    }

    @MainActor
    func testStartTimingEnablesAutoStartForNextLaunch() {
        let (engine, defaults, suiteName, clock) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        XCTAssertTrue(engine.needsManualStart)
        engine.startTiming()
        XCTAssertFalse(engine.needsManualStart)

        let reloaded = ReminderEngine.makeForTesting(defaults: defaults) {
            clock.now
        }
        reloaded.activate(startTicker: false)

        XCTAssertTrue(reloaded.shouldAutoStartOnActivation)
        XCTAssertFalse(reloaded.needsManualStart)
    }

    @MainActor
    func testWorkTimerPausesWhenScreenLocked() {
        let (engine, defaults, suiteName, clock) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        engine.setWorkInterval(minutes: 5)
        XCTAssertEqual(engine.remainingWorkSeconds, 300)

        engine.setScreenLocked(true)
        advance(engine: engine, clock: clock, seconds: 120)
        XCTAssertEqual(engine.remainingWorkSeconds, 300)

        engine.setScreenLocked(false)
        advance(engine: engine, clock: clock, seconds: 30)
        XCTAssertEqual(engine.remainingWorkSeconds, 270)
    }

    @MainActor
    func testReminderRepeatsEveryFiveMinutesIfNotConfirmed() {
        let (engine, defaults, suiteName, clock) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        engine.setWorkInterval(minutes: 5)

        advance(engine: engine, clock: clock, seconds: 300)
        XCTAssertEqual(engine.phase, .working)
        XCTAssertTrue(engine.waitingForRestConfirmation)
        XCTAssertEqual(engine.remindersSent, 1)
        XCTAssertEqual(engine.secondsUntilNextReminder, 300)

        advance(engine: engine, clock: clock, seconds: 299)
        XCTAssertEqual(engine.remindersSent, 1)
        XCTAssertEqual(engine.secondsUntilNextReminder, 1)

        advance(engine: engine, clock: clock, seconds: 1)
        XCTAssertEqual(engine.remindersSent, 2)
        XCTAssertEqual(engine.secondsUntilNextReminder, 300)
    }

    @MainActor
    func testRestCountdownContinuesWhileScreenLockedThenResetsWorkCycle() {
        let (engine, defaults, suiteName, clock) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        engine.setWorkInterval(minutes: 5)
        engine.setBreakDuration(minutes: 1)

        advance(engine: engine, clock: clock, seconds: 300)
        XCTAssertTrue(engine.waitingForRestConfirmation)

        engine.confirmRest()
        XCTAssertEqual(engine.phase, .resting)

        engine.setScreenLocked(true)
        advance(engine: engine, clock: clock, seconds: 60)

        XCTAssertEqual(engine.phase, .working)
        XCTAssertEqual(engine.remainingWorkSeconds, 300)
        XCTAssertFalse(engine.waitingForRestConfirmation)
    }

    @MainActor
    func testBreakCountdownTicksEverySecond() {
        let (engine, defaults, suiteName, clock) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        engine.setWorkInterval(minutes: 5)
        engine.setBreakDuration(minutes: 1)
        advance(engine: engine, clock: clock, seconds: 300)

        engine.confirmRest()
        XCTAssertEqual(engine.remainingBreakSeconds, 60)

        advance(engine: engine, clock: clock, seconds: 1)
        XCTAssertEqual(engine.remainingBreakSeconds, 59)
    }

    @MainActor
    func testSnoozeRestReminderResetsToFiveMinutes() {
        let (engine, defaults, suiteName, clock) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        engine.setWorkInterval(minutes: 5)
        advance(engine: engine, clock: clock, seconds: 300)
        XCTAssertTrue(engine.waitingForRestConfirmation)

        advance(engine: engine, clock: clock, seconds: 120)
        XCTAssertEqual(engine.secondsUntilNextReminder, 180)

        engine.snoozeRestReminder()
        XCTAssertEqual(engine.secondsUntilNextReminder, 300)
    }

    @MainActor
    func testConfirmRestFromFullscreenReminderShowsBreakOverlayAndCountsDown() {
        let (engine, defaults, suiteName, clock) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        engine.setWorkInterval(minutes: 5)
        engine.setBreakDuration(minutes: 1)
        advance(engine: engine, clock: clock, seconds: 300)
        XCTAssertTrue(engine.waitingForRestConfirmation)

        engine.confirmRestFromFullscreenReminder()
        XCTAssertEqual(engine.phase, .resting)
        XCTAssertTrue(engine.isFullscreenReminderVisible)
        XCTAssertEqual(engine.remainingBreakSeconds, 60)

        advance(engine: engine, clock: clock, seconds: 1)
        XCTAssertEqual(engine.remainingBreakSeconds, 59)
    }

    @MainActor
    func testDismissFullscreenBreakOverlayKeepsRestCycleRunning() {
        let (engine, defaults, suiteName, clock) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        engine.setWorkInterval(minutes: 5)
        engine.setBreakDuration(minutes: 1)
        advance(engine: engine, clock: clock, seconds: 300)

        engine.confirmRestFromFullscreenReminder()
        XCTAssertEqual(engine.phase, .resting)
        XCTAssertTrue(engine.isFullscreenReminderVisible)

        engine.dismissFullscreenBreakOverlay()
        XCTAssertEqual(engine.phase, .resting)
        XCTAssertFalse(engine.isFullscreenReminderVisible)

        advance(engine: engine, clock: clock, seconds: 60)
        XCTAssertEqual(engine.phase, .working)
    }

    @MainActor
    func testStatePersistsAcrossRelaunch() {
        let (engine, defaults, suiteName, clock) = makeEngine()
        defer { cleanup(defaults: defaults, suiteName: suiteName) }

        engine.setWorkInterval(minutes: 5)
        engine.setBreakDuration(minutes: 7)
        advance(engine: engine, clock: clock, seconds: 300)

        XCTAssertTrue(engine.waitingForRestConfirmation)
        XCTAssertEqual(engine.remindersSent, 1)

        let reloaded = ReminderEngine.makeForTesting(defaults: defaults) {
            clock.now
        }
        reloaded.activate(startTicker: false)

        XCTAssertEqual(reloaded.workIntervalMinutes, 5)
        XCTAssertEqual(reloaded.breakDurationMinutes, 7)
        XCTAssertTrue(reloaded.waitingForRestConfirmation)
        XCTAssertEqual(reloaded.phase, .working)
        XCTAssertEqual(reloaded.remainingWorkSeconds, 0)
        XCTAssertEqual(reloaded.remindersSent, 1)
    }

    @MainActor
    private func makeEngine() -> (ReminderEngine, UserDefaults, String, MutableClock) {
        let suiteName = "EyeReminderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let clock = MutableClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let engine = ReminderEngine.makeForTesting(defaults: defaults) {
            clock.now
        }
        engine.activate(startTicker: false)
        return (engine, defaults, suiteName, clock)
    }

    private func cleanup(defaults: UserDefaults, suiteName: String) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    private func advance(engine: ReminderEngine, clock: MutableClock, seconds: Int) {
        guard seconds > 0 else { return }
        for _ in 0..<seconds {
            clock.now = clock.now.addingTimeInterval(1)
            engine.testAdvance(seconds: 1)
        }
    }
}
