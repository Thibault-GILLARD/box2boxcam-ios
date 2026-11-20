import Foundation
import Darwin
import DockKitCore

@MainActor
final class MotorControllerTests {
    func testPulseDisablesTrackingThenMovesAndStops() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .ready)
        try expectTrue(controller.pulse(MotorVelocity(yaw: 0.15), duration: .milliseconds(100)))
        await controller.waitUntilIdle()
        try expectEqual(transport.calls, [
            .tracking(false), .velocity(.zero),
            .velocity(MotorVelocity(yaw: 0.15)), .velocity(.zero)
        ])
        try expectEqual(controller.status, .ready)
    }

    func testAccessoryReenablingSystemTrackingIsTakenBack() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        try expectFalse(controller.systemTrackingReclaimed)
        // The Osmo trigger switches DockKit tracking back on behind the app's back.
        transport.isSystemTrackingEnabled = true
        try expectTrue(controller.systemTrackingReclaimed)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .ready)
        try expectFalse(controller.systemTrackingReclaimed)
        try expectEqual(transport.calls, [
            .tracking(false), .velocity(.zero), .tracking(false), .velocity(.zero)
        ])
    }

    func testYieldToAccessoryThenPrepareTakesBack() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        try expectTrue(controller.startFollowing())
        transport.isSystemTrackingEnabled = true
        let before = transport.calls.count
        controller.yieldToAccessory()
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .systemTracking)
        try expectEqual(transport.calls.count, before)
        try expectFalse(controller.updateFollowingVelocity(MotorVelocity(yaw: 0.1)))
        try expectFalse(controller.systemTrackingReclaimed)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .ready)
        try expectEqual(Array(transport.calls.suffix(2)), [.tracking(false), .velocity(.zero)])
    }

    func testKeepAliveSendsZeroOnlyWhenReadyAndIdle() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        try expectFalse(controller.keepAlive())  // not prepared
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        let before = transport.calls.count
        try expectTrue(controller.keepAlive())
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .ready)
        try expectEqual(Array(transport.calls.dropFirst(before)), [.velocity(.zero)])
        try expectTrue(controller.startFollowing())
        try expectFalse(controller.keepAlive())  // following streams its own commands
        controller.stop()
        await controller.waitUntilIdle()
        controller.close()
        try expectFalse(controller.keepAlive())
    }

    func testStopWaitsForInflightWriteThenSendsZeroWithoutAnotherMovement() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        transport.pauseNextVelocity = true
        controller.pulse(MotorVelocity(yaw: 0.15), duration: .seconds(1))
        try await waitUntil { transport.pending != nil }
        controller.stop()
        try expectEqual(controller.status, .stopping)
        try expectFalse(controller.pulse(MotorVelocity(yaw: -0.15), duration: .milliseconds(100)))
        try expectEqual(transport.calls.last, .velocity(MotorVelocity(yaw: 0.15)))
        transport.releaseWrite()
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .ready)
        try expectTrue(transport.calls.dropFirst(3).allSatisfy { $0 == .velocity(.zero) })
        try expectEqual(transport.maximumConcurrentWrites, 1)
    }

    func testStopInterruptsOneSecondPulseDelay() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        controller.pulse(MotorVelocity(pitch: -0.1), duration: .seconds(1))
        try await waitUntil { transport.calls.count == 3 }
        controller.stop()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        try await waitUntil(deadline: deadline) { controller.status == .ready }
        try expectEqual(transport.calls.last, .velocity(.zero))
    }

    func testCloseDuringInflightWriteRejectsFutureCommands() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        transport.pauseNextVelocity = true
        controller.pulse(MotorVelocity(yaw: 0.1), duration: .seconds(1))
        try await waitUntil { transport.pending != nil }
        controller.close()
        controller.enableSystemTracking()
        controller.prepareManualControl()
        try expectFalse(controller.pulse(MotorVelocity(yaw: 0.1), duration: .milliseconds(100)))
        transport.releaseWrite()
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .closed)
        try expectFalse(transport.calls.contains(.tracking(true)))
        try expectEqual(transport.calls.last, .velocity(.zero))
    }

    func testSystemTrackingStopsManualMotionBeforeEnablingAndStopTakesControlBack() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        controller.pulse(MotorVelocity(yaw: 0.1), duration: .seconds(1))
        try await waitUntil { transport.calls.count == 3 }
        controller.enableSystemTracking()
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .systemTracking)
        try expectEqual(Array(transport.calls.suffix(2)), [.velocity(.zero), .tracking(true)])
        try expectFalse(controller.pulse(MotorVelocity(yaw: 0.1), duration: .milliseconds(100)))
        controller.stop()
        await controller.waitUntilIdle()
        try expectEqual(Array(transport.calls.suffix(2)), [.tracking(false), .velocity(.zero)])
        try expectEqual(controller.status, .ready)
    }

    func testFailedMotionStillAttemptsZeroAndRequiresRecovery() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        var logs: [String] = []
        controller.onLog = { logs.append($0) }
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        transport.failNextMotion = true
        controller.pulse(MotorVelocity(yaw: 0.1), duration: .milliseconds(100))
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .failed)
        try expectEqual(transport.calls.last, .velocity(.zero))
        try expectTrue(logs.contains { $0.contains("ÉCHEC") })
        try expectFalse(controller.pulse(MotorVelocity(yaw: 0.1), duration: .milliseconds(100)))
        controller.stop()
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .ready)
    }

    func testFailedStopDoesNotReportReady() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        transport.failZeros = true
        controller.stop()
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .failed)
    }

    func testInvalidAndOverlappingPulsesNeverReachTransport() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        try expectFalse(controller.pulse(MotorVelocity(yaw: 0.1), duration: .milliseconds(100)))
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        for badVelocity in [MotorVelocity(yaw: .nan), MotorVelocity(pitch: .infinity), MotorVelocity(yaw: 0.31), .zero] {
            try expectFalse(controller.pulse(badVelocity, duration: .milliseconds(100)))
        }
        try expectFalse(controller.pulse(MotorVelocity(yaw: 0.1), duration: .seconds(2)))
        try expectFalse(controller.pulse(MotorVelocity(yaw: 0.1), duration: .milliseconds(99)))
        try expectTrue(controller.pulse(MotorVelocity(yaw: 0.1), duration: .milliseconds(100)))
        try expectFalse(controller.pulse(MotorVelocity(yaw: -0.1), duration: .milliseconds(100)))
        controller.stop()
        await controller.waitUntilIdle()
        try expectEqual(transport.calls.filter { if case .velocity(let v) = $0 { return v != .zero }; return false }.count, 0)
    }

    private func waitUntil(deadline: ContinuousClock.Instant? = nil, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let end = deadline ?? clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < end else {
                throw TestError.timeout
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func testFollowingCoalescesAndStopInvalidatesQueuedMotion() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        try expectTrue(controller.startFollowing())
        transport.pauseNextVelocity = true
        controller.updateFollowingVelocity(MotorVelocity(yaw: 0.05))
        try await waitUntil { transport.pending != nil }
        controller.updateFollowingVelocity(MotorVelocity(yaw: 0.10))
        controller.updateFollowingVelocity(MotorVelocity(yaw: 0.15))
        transport.releaseWrite()
        await controller.waitUntilIdle()
        try expectFalse(transport.calls.contains(.velocity(MotorVelocity(yaw: 0.10))))
        try expectEqual(transport.calls.last, .velocity(MotorVelocity(yaw: 0.15)))
        transport.pauseNextVelocity = true
        controller.updateFollowingVelocity(MotorVelocity(pitch: 0.1))
        try await waitUntil { transport.pending != nil }
        controller.updateFollowingVelocity(MotorVelocity(yaw: -0.15))
        controller.stop()
        transport.releaseWrite()
        await controller.waitUntilIdle()
        try expectFalse(transport.calls.contains(.velocity(MotorVelocity(yaw: -0.15))))
        try expectEqual(transport.calls.last, .velocity(.zero))
        try expectEqual(transport.maximumConcurrentWrites, 1)
    }

    func testFollowingLeaseStopsAfterLateAcknowledgement() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        controller.startFollowing()
        transport.pauseNextVelocity = true
        controller.updateFollowingVelocity(MotorVelocity(yaw: 0.1))
        try await waitUntil { transport.pending != nil }
        try await Task.sleep(for: .milliseconds(400))
        transport.releaseWrite()
        await controller.waitUntilIdle()
        try expectEqual(transport.calls.last, .velocity(.zero))
        try expectEqual(controller.status, .following)
        controller.updateFollowingVelocity(MotorVelocity(yaw: 0.1))
        await controller.waitUntilIdle()
        try await waitUntil { transport.calls.last == .velocity(.zero) }
        controller.close()
        await controller.waitUntilIdle()
    }

    func testFollowingRefreshSurvivesOldAcknowledgementButStillExpires() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        try expectTrue(controller.startFollowing())
        transport.pauseNextVelocity = true
        try expectTrue(controller.updateFollowingVelocity(MotorVelocity(yaw: 0.05)))
        try await waitUntil { transport.pending != nil }
        // The first write exceeds its original 350 ms deadline. However, the
        // incoming control stream stays fresh, and only its latest value matters.
        for velocity in [0.075, 0.10, 0.125, 0.15] {
            try await Task.sleep(for: .milliseconds(100))
            try expectTrue(controller.updateFollowingVelocity(MotorVelocity(yaw: velocity)))
        }
        transport.releaseWrite()
        await controller.waitUntilIdle()
        try expectEqual(Array(transport.calls.dropFirst(2)), [
            .velocity(MotorVelocity(yaw: 0.05)), .velocity(MotorVelocity(yaw: 0.15))
        ])
        try expectEqual(controller.status, .following)
        // Refreshing does not remove the watchdog: a genuine gap still stops.
        try await waitUntil { transport.calls.last == .velocity(.zero) }
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .following)
        try expectEqual(transport.maximumConcurrentWrites, 1)

        // Stop invalidates a refreshed value queued behind an in-flight write.
        transport.pauseNextVelocity = true
        try expectTrue(controller.updateFollowingVelocity(MotorVelocity(pitch: 0.1)))
        try await waitUntil { transport.pending != nil }
        try expectTrue(controller.updateFollowingVelocity(MotorVelocity(yaw: -0.15)))
        controller.stop()
        transport.releaseWrite()
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .ready)
        try expectFalse(transport.calls.contains(.velocity(MotorVelocity(yaw: -0.15))))
        try expectEqual(transport.calls.last, .velocity(.zero))
        try expectEqual(transport.maximumConcurrentWrites, 1)
    }

    func testFollowingErrorStopsAndRejectsFurtherVelocity() async throws {
        let transport = FakeTransport()
        let controller = MotorController(transport: transport)
        controller.prepareManualControl()
        await controller.waitUntilIdle()
        controller.startFollowing()
        transport.failNextMotion = true
        controller.updateFollowingVelocity(MotorVelocity(yaw: 0.1))
        controller.updateFollowingVelocity(MotorVelocity(yaw: 0.15))
        await controller.waitUntilIdle()
        try expectEqual(controller.status, .failed)
        try expectEqual(transport.calls.last, .velocity(.zero))
        try expectFalse(controller.updateFollowingVelocity(MotorVelocity(yaw: 0.1)))
    }
}

private enum TestError: Error { case rejected, timeout }

@MainActor
private final class FakeTransport: MotorTransport {
    enum Call: Equatable { case tracking(Bool), velocity(MotorVelocity) }
    var calls: [Call] = []
    var isSystemTrackingEnabled = true
    var pauseNextVelocity = false
    var failNextMotion = false
    var failZeros = false
    var pending: CheckedContinuation<Void, Never>?
    private var concurrentWrites = 0
    private(set) var maximumConcurrentWrites = 0

    func setSystemTrackingEnabled(_ enabled: Bool) async throws {
        calls.append(.tracking(enabled))
        isSystemTrackingEnabled = enabled
    }

    func sendVelocity(_ velocity: MotorVelocity) async throws {
        concurrentWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, concurrentWrites)
        defer { concurrentWrites -= 1 }
        calls.append(.velocity(velocity))
        if pauseNextVelocity {
            pauseNextVelocity = false
            await withCheckedContinuation { pending = $0 }
        }
        if velocity != .zero, failNextMotion {
            failNextMotion = false
            throw TestError.rejected
        }
        if velocity == .zero, failZeros { throw TestError.rejected }
    }

    func releaseWrite() {
        let continuation = pending
        pending = nil
        continuation?.resume()
    }
}
