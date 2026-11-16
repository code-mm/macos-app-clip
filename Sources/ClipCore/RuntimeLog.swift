import Foundation
import Darwin
import OSLog

public actor RuntimeLog {
    private struct Event: Encodable {
        let time: String
        let event: String
        let metrics: [String: Double]
    }
    private let directory: URL
    private let maxBytes: Int
    private let backups: Int
    private var size = 0
    private let formatter = ISO8601DateFormatter()
    private let system = Logger(subsystem: "com.codemm.cliprecord", category: "runtime")

    public init(directory: URL, maxBytes: Int = 1_024 * 1_024, backups: Int = 3) {
        self.directory = directory; self.maxBytes = maxBytes; self.backups = backups
    }

    /// Numeric diagnostics only. Clipboard text, image bytes, search terms and app names never enter logs.
    public func write(_ event: String, metrics: [String: Double] = [:]) {
        do {
            let files = FileManager.default
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            let current = directory.appendingPathComponent("runtime.jsonl")
            if size == 0 { size = (try? files.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0 }
            var line = try JSONEncoder().encode(Event(time: formatter.string(from: Date()), event: event, metrics: metrics))
            line.append(10)
            guard line.count <= maxBytes else { return }
            if size + line.count > maxBytes {
                for number in stride(from: backups, through: 1, by: -1) {
                    let destination = directory.appendingPathComponent("runtime.\(number).jsonl")
                    if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
                    let source = number == 1 ? current : directory.appendingPathComponent("runtime.\(number - 1).jsonl")
                    if files.fileExists(atPath: source.path) { try files.moveItem(at: source, to: destination) }
                }
                size = 0
            }
            if !files.fileExists(atPath: current.path) {
                files.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            size += line.count
        } catch {
            system.error("Runtime log write failed; no clipboard contents logged")
        }
    }
}

public struct ResourceSample: Sendable {
    public let residentBytes: UInt64
    public let cpuSeconds: Double
    public static func capture() -> ResourceSample {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return ResourceSample(residentBytes: status == KERN_SUCCESS ? info.resident_size : 0,
                              cpuSeconds: user + system)
    }
}
