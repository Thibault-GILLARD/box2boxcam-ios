import Foundation

/// DockKit coordinates: x = pitch (positive down), y = yaw (positive right).
/// Roll remains zero in this diagnostic and velocities are in radians/second.
public struct MotorVelocity: Equatable, Sendable {
    public let pitch: Double
    public let yaw: Double

    public init(pitch: Double = 0, yaw: Double = 0) {
        self.pitch = pitch
        self.yaw = yaw
    }

    public static let zero = MotorVelocity()
}

@MainActor
public protocol MotorTransport: AnyObject {
    /// System tracking as DockKit currently reports it. The accessory can turn it on
    /// by itself (the Osmo trigger toggles DockKit tracking).
    var isSystemTrackingEnabled: Bool { get }
    func setSystemTrackingEnabled(_ enabled: Bool) async throws
    func sendVelocity(_ velocity: MotorVelocity) async throws
}

/// One controller per connection. Commands are serialized even across an await.
/// Stop invalidates pending motion, interrupts the pulse delay, and follows any
/// in-flight API call with zero velocity. An API acknowledgement is not proof
/// that the physical accessory moved or stopped.
@MainActor
public final class MotorController {
    public enum Status: String, Sendable {
        case unprepared, preparing, ready, moving, following, stopping, systemTracking, failed, closed
    }

    public private(set) var status: Status = .unprepared {
        didSet { onStatus?(status) }
    }
    public var onStatus: ((Status) -> Void)?
    public var onLog: ((String) -> Void)?

    private enum Operation {
        case prepare, pulse(MotorVelocity, Duration), continuous(MotorVelocity, ContinuousClock.Instant), stop, system, close, keepAlive
    }
    private let transport: any MotorTransport
    private var queue: [(UInt64, Operation)] = []
    private var worker: Task<Void, Never>?
    private var pulseDelay: Task<Void, Error>?
    private var commandLease: Task<Void, Never>?
    private var followingDeadline: ContinuousClock.Instant?
    private var lastContinuousLog = ContinuousClock.now
    private var generation: UInt64 = 0
    private var manualEnabled = false
    private var isClosed = false

    public init(transport: any MotorTransport) {
        self.transport = transport
    }

    /// True when this controller holds manual control but DockKit reports system tracking
    /// on again: something else (the accessory trigger) switched it back.
    public var systemTrackingReclaimed: Bool { manualEnabled && transport.isSystemTrackingEnabled }
    public var systemTrackingEnabled: Bool { transport.isSystemTrackingEnabled }

    /// The accessory took control (its trigger switched DockKit tracking on): drop pending
    /// motion without sending anything, and leave the stand to it until `prepareManualControl`.
    public func yieldToAccessory() {
        guard !isClosed else { return }
        generation &+= 1
        pulseDelay?.cancel()
        commandLease?.cancel()
        commandLease = nil
        followingDeadline = nil
        queue.removeAll()
        manualEnabled = false
        status = .systemTracking
        onLog?("Contrôle laissé à l’accessoire (suivi DockKit activé par l’Osmo).")
    }

    public func prepareManualControl() {
        guard !isClosed else { return }
        replacePending(with: .prepare, status: .preparing)
    }

    /// No overlapping pulses; cap both speed and duration at the command boundary.
    @discardableResult
    public func pulse(_ velocity: MotorVelocity, duration: Duration) -> Bool {
        guard !isClosed, status == .ready,
              velocity.pitch.isFinite, velocity.yaw.isFinite,
              abs(velocity.pitch) <= 0.3, abs(velocity.yaw) <= 0.3,
              duration >= .milliseconds(100), duration <= .seconds(1),
              velocity != .zero else { return false }
        status = .moving
        enqueue(.pulse(velocity, duration))
        return true
    }

    /// Zero velocity while ready and idle, without a status change. On 18 Nov 2026 the Osmo undocked
    /// about 6 s after connecting whenever no command followed the first one (held with a stream).
    @discardableResult
    public func keepAlive() -> Bool {
        guard !isClosed, status == .ready, manualEnabled, queue.isEmpty, worker == nil else { return false }
        enqueue(.keepAlive)
        return true
    }

    public func stop() {
        guard !isClosed else { return }
        onLog?("Arrêt demandé ; attente de la réponse DockKit.")
        replacePending(with: .stop, status: .stopping)
    }

    @discardableResult
    public func startFollowing() -> Bool {
        guard !isClosed, status == .ready, manualEnabled else { return false }
        status = .following
        return true
    }

    /// Latest command wins. A command expires after 350 ms without a refresh.
    @discardableResult
    public func updateFollowingVelocity(_ velocity: MotorVelocity) -> Bool {
        guard !isClosed, status == .following,
              velocity.pitch.isFinite, velocity.yaw.isFinite,
              abs(velocity.pitch) <= 0.3, abs(velocity.yaw) <= 0.3 else { return false }
        commandLease?.cancel()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(350))
        followingDeadline = deadline
        enqueueLatestVelocity(velocity, deadline: deadline)
        let token = generation
        commandLease = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self, self.generation == token, self.status == .following else { return }
            self.onLog?("Flux de suivi interrompu ; vitesse nulle demandée.")
            self.enqueueLatestVelocity(.zero, deadline: .now)
        }
        return true
    }

    private func enqueueLatestVelocity(_ velocity: MotorVelocity, deadline: ContinuousClock.Instant) {
        queue.removeAll { if case .continuous = $0.1 { return true }; return false }
        enqueue(.continuous(velocity, deadline))
    }

    public func enableSystemTracking() {
        guard !isClosed else { return }
        replacePending(with: .system, status: .stopping)
    }

    /// Used on undocking or leaving the foreground; it never restores tracking.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        replacePending(with: .close, status: .stopping)
    }

    public func waitUntilIdle() async {
        if let worker { await worker.value }
    }

    private func replacePending(with operation: Operation, status: Status) {
        generation &+= 1
        pulseDelay?.cancel()
        commandLease?.cancel()
        commandLease = nil
        followingDeadline = nil
        queue.removeAll()
        self.status = status
        enqueue(operation)
    }

    private func enqueue(_ operation: Operation) {
        queue.append((generation, operation))
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let (token, operation) = queue.removeFirst()
            guard token == generation else { continue }
            do {
                switch operation {
                case .prepare:
                    // An explicit request always re-sends the switch-off: the accessory may
                    // have turned DockKit tracking on without the reported state following.
                    try await takeManualControl(force: true)
                    try await send(.zero)
                    if token == generation { status = .ready }
                case let .pulse(velocity, duration):
                    guard manualEnabled else { continue }
                    try await send(velocity)
                    if token == generation {
                        let delay = Task<Void, Error> { try await Task.sleep(for: duration) }
                        pulseDelay = delay
                        // Cancel only the delay, never an in-flight motor write.
                        do { try await delay.value } catch is CancellationError {} catch { throw error }
                        pulseDelay = nil
                    }
                    try await send(.zero)
                    if token == generation { status = .ready }
                case let .continuous(velocity, deadline):
                    guard manualEnabled, status == .following else { continue }
                    let fresh = velocity == .zero || ContinuousClock.now < deadline
                    let log = ContinuousClock.now - lastContinuousLog >= .seconds(1)
                    if log { lastContinuousLog = .now }
                    try await send(fresh ? velocity : .zero, log: log)
                    // Refreshes received during the write renew the control stream.
                    // An old write's deadline must not insert zero ahead of a fresh
                    // queued command. A real gap, stop, or mode change still stops.
                    let acknowledgedAt = ContinuousClock.now
                    let flowIsFresh = token == generation && status == .following
                        && followingDeadline.map { acknowledgedAt < $0 } == true
                    if velocity != .zero, acknowledgedAt >= deadline, !flowIsFresh {
                        try await send(.zero)
                    }
                case .keepAlive:
                    guard manualEnabled, status == .ready else { continue }
                    try await send(.zero, log: false)
                case .stop, .close:
                    try await takeManualControl()
                    try await send(.zero)
                    if token == generation { status = isClosed ? .closed : .ready }
                case .system:
                    try await takeManualControl()
                    try await send(.zero)
                    guard token == generation else { continue }
                    try await transport.setSystemTrackingEnabled(true)
                    manualEnabled = false
                    onLog?("Suivi système activé : réponse DockKit reçue.")
                    if token == generation { status = .systemTracking }
                }
            } catch {
                let nsError = error as NSError
                onLog?("ÉCHEC \(nsError.domain) [\(nsError.code)] : \(error)")
                // A failed motion call can still have reached the hardware.
                let wasMotion: Bool
                switch operation {
                case .pulse, .continuous: wasMotion = true
                default: wasMotion = false
                }
                if wasMotion {
                    do { try await send(.zero) }
                    catch { onLog?("ÉCHEC de l'arrêt après erreur : \(error)") }
                }
                if token == generation {
                    commandLease?.cancel()
                    followingDeadline = nil
                    queue.removeAll()
                    status = isClosed ? .closed : .failed
                }
            }
        }
        worker = nil
    }

    private func takeManualControl(force: Bool = false) async throws {
        guard force || !manualEnabled || transport.isSystemTrackingEnabled else { return }
        try await transport.setSystemTrackingEnabled(false)
        manualEnabled = true
        onLog?("Suivi système désactivé : réponse DockKit reçue.")
    }

    private func send(_ velocity: MotorVelocity, log: Bool = true) async throws {
        if log { onLog?(String(format: "Commande pitch %.3f / yaw %.3f rad/s", velocity.pitch, velocity.yaw)) }
        try await transport.sendVelocity(velocity)
        if log { onLog?("Réponse DockKit reçue pour la commande de vitesse.") }
    }
}
