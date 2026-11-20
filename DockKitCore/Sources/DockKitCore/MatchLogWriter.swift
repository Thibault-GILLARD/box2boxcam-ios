import Foundation

public struct MatchLogSummary: Codable, Sendable {
    public let writtenEvents: Int
    public let droppedEvents: Int
    public let error: String?
}

/// Stream to disk on a serial utility queue, with bounded queued events.
/// A slow/full disk cannot build an hour of frame objects in memory.
public final class MatchLogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pitchlens.match-log", qos: .utility)
    private let lock = NSLock()
    private var pending = 0
    private var closing = false
    private var dropped = 0
    private var handle: FileHandle?
    private var written = 0
    private var failure: String?
    private var startPTS: Double?
    private let maximumPending: Int

    public init(url: URL, maximumPending: Int = 120) throws {
        self.maximumPending = max(1, maximumPending)
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteFileExists)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    public func setVideoStartPTS(_ value: Double) {
        lock.withLock {
            guard !closing else { return }
            queue.async { self.startPTS = value.isFinite ? value : nil }
        }
    }

    public func append<Value: Encodable & Sendable>(_ type: String, at timestamp: Double, value: Value) {
        lock.lock()
        guard !closing else { lock.unlock(); return }
        guard pending < maximumPending else { dropped += 1; lock.unlock(); return }
        pending += 1
        // Enqueue while holding the lock: finish cannot overtake an accepted event.
        queue.async {
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            guard self.failure == nil, let handle = self.handle else {
                self.lock.withLock { self.dropped += 1 }; return
            }
            do {
                let time = timestamp.isFinite ? timestamp : nil
                let record = Envelope(type: type, timestamp: time,
                                      videoSeconds: time.flatMap { time in self.startPTS.map { time - $0 } }, payload: value)
                var data = try JSONEncoder().encode(record)
                data.append(0x0a)
                try handle.write(contentsOf: data)
                self.written += 1
                if self.written % 120 == 0 { try handle.synchronize() }
            } catch {
                self.failure = error.localizedDescription
                self.lock.withLock { self.dropped += 1 }
            }
        }
        lock.unlock()
    }

    public func finish() async -> MatchLogSummary {
        return await withCheckedContinuation { continuation in
            lock.withLock {
                closing = true
                queue.async {
                    do { try self.handle?.synchronize(); try self.handle?.close() }
                    catch { self.failure = self.failure ?? error.localizedDescription }
                    self.handle = nil
                    let dropped = self.lock.withLock { self.dropped }
                    continuation.resume(returning: MatchLogSummary(writtenEvents: self.written, droppedEvents: dropped, error: self.failure))
                }
            }
        }
    }

    private struct Envelope<Value: Encodable>: Encodable {
        let type: String
        let timestamp: Double?
        let videoSeconds: Double?
        let payload: Value
    }
}
