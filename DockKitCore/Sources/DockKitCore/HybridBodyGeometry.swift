import Foundation
import simd

/// Torso-plane fitting and limb evidence. These are geometric hypotheses,
/// not a learned gaze model. Ambiguous directions remain explicitly ambiguous.
public enum HybridBodyGeometry {
    private static let torso = [SIMD3<Double>(0.20, 0, 0), SIMD3(-0.20, 0, 0), SIMD3(0.14, 0.50, 0), SIMD3(-0.14, 0.50, 0)]
    private static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        var a = zip(matrix, rhs).map { $0 + [$1] }
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }), abs(a[pivot][column]) > 1e-12 else { return nil }
            a.swapAt(column, pivot)
            let scale = a[column][column]
            for j in column...n { a[column][j] /= scale }
            for i in 0..<n where i != column {
                let amount = a[i][column]
                for j in column...n { a[i][j] -= amount * a[column][j] }
            }
        }
        return a.map { $0[n] }
    }
    private static func rotate(_ value: SIMD3<Double>, _ rotation: SIMD3<Double>) -> SIMD3<Double> {
        let angle = simd_length(rotation)
        if angle < 1e-9 { return value + simd_cross(rotation, value) }
        let axis = rotation / angle
        return value * cos(angle) + simd_cross(axis, value) * sin(angle) + axis * simd_dot(axis, value) * (1 - cos(angle))
    }
    private static func project(_ points: [SIMD3<Double>], _ params: [Double]) -> [Double]? {
        let r = SIMD3(params[0], params[1], params[2]), t = SIMD3(params[3], params[4], params[5])
        var values: [Double] = []
        for point in points {
            let camera = rotate(point, r) + t
            guard camera.z > 1e-6 else { return nil }
            values += [camera.x / camera.z, camera.y / camera.z]
        }
        return values
    }
    private static func parameters(_ r1: SIMD3<Double>, _ r2: SIMD3<Double>, _ translation: SIMD3<Double>) -> [Double] {
        let matrix = simd_double3x3(columns: (r1, r2, simd_cross(r1, r2)))
        let quaternion = simd_quatd(matrix)
        let length = simd_length(quaternion.imag)
        let rotation = length < 1e-9 ? SIMD3<Double>.zero : quaternion.imag / length * (2 * atan2(length, quaternion.real))
        return [rotation.x, rotation.y, rotation.z, translation.x, translation.y, translation.z]
    }
    private static func refine(_ initial: [Double], observed: [Double]) -> [Double]? {
        var p = initial, damping = 0.001
        for _ in 0..<32 {
            guard let base = project(torso, p) else { return nil }
            let residual = zip(base, observed).map(-)
            let error = residual.reduce(0) { $0 + $1 * $1 }
            var jacobian = Array(repeating: Array(repeating: 0.0, count: 6), count: 8)
            for j in 0..<6 {
                let epsilon = 1e-5 * max(1, abs(p[j]))
                var shifted = p; shifted[j] += epsilon
                guard let values = project(torso, shifted) else { return nil }
                for i in 0..<8 { jacobian[i][j] = (values[i] - base[i]) / epsilon }
            }
            var normal = Array(repeating: Array(repeating: 0.0, count: 6), count: 6), gradient = Array(repeating: 0.0, count: 6)
            for a in 0..<6 {
                for i in 0..<8 { gradient[a] += jacobian[i][a] * residual[i] }
                for b in 0..<6 { for i in 0..<8 { normal[a][b] += jacobian[i][a] * jacobian[i][b] } }
                normal[a][a] += damping * max(normal[a][a], 1e-6)
            }
            guard let delta = solve(normal, gradient) else { return nil }
            let candidate = zip(p, delta).map(-)
            guard let values = project(torso, candidate) else { damping *= 5; continue }
            let newError = zip(values, observed).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) }
            if newError < error {
                p = candidate; damping = max(1e-8, damping / 3)
                if delta.reduce(0, { $0 + $1 * $1 }) < 1e-12 { break }
            } else { damping *= 5 }
        }
        return p
    }

    public static func rays(joints: [HybridJoint], width: Double, height: Double,
            motion: HybridVector? = nil, motionStrength: Double = 0,
            previous: HybridVector? = nil, previousStrength: Double = 0,
            motionAngularStrength: Double? = nil, horizontalFOV: Double = 60) -> [HybridRay] {
        guard joints.count == 17, width > 0, height > 0 else { return [] }
        let indices = [5, 6, 11, 12], body = indices.map { joints[$0] }
        guard body.allSatisfy({ $0.confidence >= 0.55 && $0.point.finite && (0...1).contains($0.point.x) && (0...1).contains($0.point.y) }) else { return [] }
        let pixels = body.map { HybridVector($0.point.x * width, $0.point.y * height) }
        let span = hypot(pixels.map(\.x).max()! - pixels.map(\.x).min()!, pixels.map(\.y).max()! - pixels.map(\.y).min()!)
        guard span >= 12, (pixels[0] - pixels[1]).length >= 2 else { return [] }
        let focal = width / (2 * tan(max(5, min(150, horizontalFOV)) * .pi / 360))
        let observed = pixels.flatMap { [($0.x - width / 2) / focal, ($0.y - height / 2) / focal] }
        var matrix: [[Double]] = [], values: [Double] = []
        for i in 0..<4 {
            let X = torso[i].x, Y = torso[i].y, u = observed[2 * i], v = observed[2 * i + 1]
            matrix.append([X,Y,1,0,0,0,-u*X,-u*Y]); values.append(u)
            matrix.append([0,0,0,X,Y,1,-v*X,-v*Y]); values.append(v)
        }
        guard let h = solve(matrix, values) else { return [] }
        let a = SIMD3(h[0], h[3], h[6]), b = SIMD3(h[1], h[4], h[7]), t = SIMD3(h[2], h[5], 1)
        let scale = 2 / (simd_length(a) + simd_length(b))
        let r1 = simd_normalize(a), r2 = simd_normalize(b - r1 * simd_dot(r1, b)), translation = t * scale
        guard r1.x.isFinite, r2.x.isFinite, translation.z > 0 else { return [] }
        let mirrored1 = SIMD3(r1.x, r1.y, -r1.z), mirrored2 = SIMD3(r2.x, r2.y, -r2.z)
        var candidates: [HybridRay] = []
        for initial in [parameters(r1, r2, translation), parameters(mirrored1, mirrored2, translation)] {
            guard let fitted = refine(initial, observed: observed), let reprojection = project(torso, fitted) else { continue }
            let error = sqrt(zip(reprojection, observed).reduce(0) { $0 + pow(($1.0 - $1.1) * focal, 2) } / 4)
            if error > max(1, span * 0.12) { continue }
            guard let axis = project([SIMD3(0,0.25,0), SIMD3(0,0.25,-fitted[5]*0.2)], fitted) else { continue }
            let direction = HybridVector((axis[2] - axis[0]) * focal, (axis[3] - axis[1]) * focal)
            if direction.length < 0.03 * width { continue }
            let origin = HybridVector((axis[0] * focal + width / 2) / width, (axis[1] * focal + height / 2) / height)
            let weight = body.map(\.confidence).reduce(0,+) / 4 * exp(-error / span)
            candidates.append(HybridRay(origin: origin, direction: direction.unit, weight: weight, selected: false))
        }
        if candidates.count == 1 { candidates[0].selected = true; return candidates }
        guard candidates.count == 2 else { return [] }
        if candidates[0].direction.dot(candidates[1].direction) >= cos(.pi / 9) {
            var ray = candidates[0]; ray.direction = (candidates[0].direction + candidates[1].direction).unit; ray.selected = true
            return [ray]
        }
        let cues = limbCues(joints: joints, width: width, height: height)
        var scores = candidates.map { log(max(1e-6, $0.weight)) }
        for (direction, strength, weight) in cues { for i in 0..<2 { scores[i] += weight * strength * candidates[i].direction.dot(direction) } }
        if let motion { for i in 0..<2 { scores[i] += 0.65 * motionStrength * candidates[i].direction.dot(motion) } }
        if let previous { for i in 0..<2 { scores[i] += 0.7 * previousStrength * candidates[i].direction.dot(previous) } }
        let exponentials = scores.map { exp($0 - scores.max()!) }, total = exponentials.reduce(0,+)
        let winner = scores[0] >= scores[1] ? 0 : 1, probability = exponentials[winner] / total
        let realCount = cues.filter { $0.1 >= 0.15 }.count + (motionStrength >= 0.15 ? 1 : 0)
        let strongKnees = cues.contains { $0.2 == 1.8 && $0.1 >= 0.8 }
        if probability >= 0.78 && (realCount >= 2 || strongKnees || (realCount > 0 && previousStrength >= 0.15)) {
            var ray = candidates[winner]; ray.weight *= probability; ray.selected = true
            ray.direction = refinedDirection(ray.direction, motion: motion, strength: motionAngularStrength ?? motionStrength, limbEvidence: cues)
            return [ray]
        }
        return candidates
    }

    public static func refinedDirection(_ direction: HybridVector, motion: HybridVector?, strength: Double,
            limbEvidence: [(HybridVector, Double, Double)] = []) -> HybridVector {
        guard let motion, direction.finite, motion.finite, strength.isFinite, strength >= 0.55,
              direction.dot(motion) >= cos(.pi / 3) else { return direction }
        if limbEvidence.contains(where: { $0.1 >= 0.55 && $0.0.dot(motion) < cos(.pi / 3) }) { return direction }
        let angle = atan2(direction.x * motion.y - direction.y * motion.x, direction.dot(motion))
        let correction = max(-Double.pi / 9, min(.pi / 9, angle * 0.45 * min(1, strength)))
        return HybridVector(cos(correction) * direction.x - sin(correction) * direction.y,
                            sin(correction) * direction.x + cos(correction) * direction.y)
    }

    public static func motionEvidence(_ samples: [(Double, HybridVector)], width: Double, height: Double,
            bodyHeight: Double) -> (direction: HybridVector, strength: Double, angularStrength: Double)? {
        guard samples.count >= 4, let first = samples.first, let last = samples.last,
              last.0 - first.0 >= 0.5, bodyHeight > 0,
              samples.allSatisfy({ $0.0.isFinite && $0.1.finite }) else { return nil }
        let count = Double(samples.count), meanTime = samples.reduce(0) { $0 + $1.0 } / count
        let points = samples.map { HybridVector($0.1.x * width, $0.1.y * height) }
        let mean = points.reduce(.zero,+) / count
        var numerator = HybridVector.zero, denominator = 0.0
        for i in samples.indices { let t = samples[i].0 - meanTime; numerator = numerator + (points[i] - mean) * t; denominator += t*t }
        guard denominator > 1e-9 else { return nil }
        let velocity = numerator / denominator, speed = velocity.length
        guard speed > 1e-6 else { return nil }
        var error = 0.0, traveled = 0.0
        for i in samples.indices {
            let residual = points[i] - mean - velocity * (samples[i].0 - meanTime)
            error += pow(residual.length,2)
            if i > 0 { traveled += (points[i] - points[i-1]).length }
        }
        let residual = sqrt(error/count), coherence = (points.last! - points.first!).length / max(traveled,1e-6)
        let recent = points.last! - points[points.count-3]
        let alignment = max(0, recent.dot(velocity) / max(recent.length*speed,1e-6))
        guard coherence >= 0.55, alignment >= 0.5 else { return nil }
        let fit = max(0,min(1,1 - 2*residual / max(speed*(last.0-first.0),0.2*bodyHeight)))
        let reliability = coherence * pow(alignment,2) * fit
        let speedStrength = max(0,min(1,(speed/bodyHeight-0.2)/0.8))
        let strength = speedStrength * (0.5+0.5*reliability)
        return strength >= 0.15 ? (velocity.unit,strength,speedStrength*reliability) : nil
    }

    private static func limbCues(joints: [HybridJoint], width: Double, height: Double) -> [(HybridVector, Double, Double)] {
        func pixel(_ index: Int) -> HybridVector { HybridVector(joints[index].point.x * width, joints[index].point.y * height) }
        let vertical = ((pixel(11) + pixel(12)) / 2 - (pixel(5) + pixel(6)) / 2).unit
        var result: [(HybridVector, Double, Double)] = []
        for (triples, sign, evidenceWeight) in [([[11,13,15],[12,14,16]],1.0,1.8), ([[5,7,9],[6,8,10]],-1.0,1.1)] {
            var combined = HybridVector.zero, total = 0.0
            for triple in triples {
                let quality = triple.map { joints[$0].confidence }.min()!
                if quality < 0.55 { continue }
                let start = pixel(triple[0]), joint = pixel(triple[1]), end = pixel(triple[2]), chord = end - start
                let bone = ((joint - start).length + (end - joint).length) / 2
                if chord.length < 5 || bone < 5 || chord.length < 0.6 * bone { continue }
                let projection = start + chord * max(0, min(1, (joint - start).dot(chord) / pow(chord.length, 2)))
                let bow = joint - projection
                if bow.length < 2 { continue }
                let strength = (quality - 0.55) / 0.45 * max(0, min(1, (bow.length / bone - 0.12) / 0.30)) * pow(chord.unit.dot(vertical), 2)
                combined = combined + bow.unit * sign * strength; total += strength
            }
            if total > 0 && combined.length / total > 0.25 {
                result.append((combined.unit, min(1, total) * combined.length / total, evidenceWeight))
            }
        }
        return result
    }
}
