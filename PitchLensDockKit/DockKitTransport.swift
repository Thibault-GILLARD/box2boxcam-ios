import DockKit
import Spatial

@MainActor
final class DockKitTransport: MotorTransport {
    let accessory: DockAccessory

    init(accessory: DockAccessory) {
        self.accessory = accessory
    }

    // Not read from DockKit (as in build 39): builds 40–41 polled it and the Osmo kept undocking.
    var isSystemTrackingEnabled: Bool { false }

    func setSystemTrackingEnabled(_ enabled: Bool) async throws {
        try await DockAccessoryManager.shared.setSystemTrackingEnabled(enabled)
    }

    func sendVelocity(_ velocity: MotorVelocity) async throws {
        try await accessory.setAngularVelocity(Vector3D(x: velocity.pitch, y: velocity.yaw, z: 0))
    }
}
