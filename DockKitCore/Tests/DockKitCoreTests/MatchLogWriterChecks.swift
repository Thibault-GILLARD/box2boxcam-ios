import Foundation
import DockKitCore

private struct LogFixture: Codable, Sendable {
    let frame: Int
    let scores: [Double]
}

private func recordingTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pitchlens-recording-check-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func checkMatchLogTimeline() async throws {
    let directory = try recordingTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("events.jsonl")
    let writer = try MatchLogWriter(url: url, maximumPending: 4000)
    writer.setVideoStartPTS(12_345.125)
    // Two minutes at 30 Hz: beyond the previous 15-second/1,200-frame limits.
    for index in 0..<3600 {
        writer.append("analysis", at: 12_345.125 + Double(index) / 30,
                      value: LogFixture(frame: index, scores: [0.85, 0.42, 0.18]))
    }
    writer.append("stop", at: 12_345.125 + 7200, value: "Fin de match")
    let summary = await writer.finish()
    try expectEqual(summary.writtenEvents, 3601)
    try expectEqual(summary.droppedEvents, 0)
    try expectEqual(summary.error, nil)
    let lines = try Data(contentsOf: url).split(separator: 0x0a)
    try expectEqual(lines.count, 3601)
    let first = try JSONSerialization.jsonObject(with: Data(lines[0])) as! [String: Any]
    let last = try JSONSerialization.jsonObject(with: Data(lines.last!)) as! [String: Any]
    try expectEqual(first["videoSeconds"] as? Double, 0)
    try expectEqual(last["videoSeconds"] as? Double, 7200)
    let payload = first["payload"] as! [String: Any]
    try expectEqual(payload["scores"] as? [Double], [0.85, 0.42, 0.18])
    let finalData = try Data(contentsOf: url)
    writer.append("late", at: 20_000, value: "Discard after finalization")
    _ = await writer.finish()
    try expectEqual(try Data(contentsOf: url), finalData)
}

func checkMatchLogBackpressure() async throws {
    let directory = try recordingTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("events.jsonl")
    let writer = try MatchLogWriter(url: url, maximumPending: 1)
    let count = 20_000
    // Concurrent producers stress the acceptance/finalization boundary as well
    // as a slow consumer. Queued events must be bounded and losses accounted for.
    DispatchQueue.concurrentPerform(iterations: count) { index in
        writer.append("analysis", at: Double(index), value: LogFixture(frame: index, scores: [0.7]))
    }
    let summary = await writer.finish()
    try expectEqual(summary.writtenEvents + summary.droppedEvents, count)
    try expectTrue(summary.writtenEvents > 0)
    try expectTrue(summary.droppedEvents > 0)
    try expectEqual(summary.error, nil)
    let lines = try Data(contentsOf: url).split(separator: 0x0a)
    try expectEqual(lines.count, summary.writtenEvents)
    for line in lines { _ = try JSONSerialization.jsonObject(with: Data(line)) }
}

func checkMatchLogFailure() async throws {
    let directory = try recordingTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("events.jsonl")
    let writer = try MatchLogWriter(url: url)
    writer.append("valid", at: 10, value: LogFixture(frame: 0, scores: [0.8]))
    writer.append("invalid", at: 11, value: LogFixture(frame: 1, scores: [.nan]))
    writer.append("after-error", at: 12, value: LogFixture(frame: 2, scores: [0.8]))
    let summary = await writer.finish()
    try expectEqual(summary.writtenEvents, 1)
    try expectEqual(summary.droppedEvents, 2)
    try expectTrue(summary.error != nil)
    let data = try Data(contentsOf: url)
    try expectEqual(data.split(separator: 0x0a).count, 1)
    // A subsequent recording must never silently overwrite an existing journal.
    var refusedOverwrite = false
    do { _ = try MatchLogWriter(url: url) } catch { refusedOverwrite = true }
    try expectTrue(refusedOverwrite)
    try expectEqual(try Data(contentsOf: url), data)
}
