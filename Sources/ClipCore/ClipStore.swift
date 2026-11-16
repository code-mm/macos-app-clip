import Foundation

/// Only metadata stays in memory. All payload and index I/O is serialized off the UI actor.
public actor ClipStore {
    private struct Index: Codable { let version: Int; let records: [ClipRecord] }
    public struct Snapshot: Sendable {
        public let count: Int
        public let bytes: Int
    }
    public let directory: URL
    private let limits: StorageLimits
    private var records: [ClipRecord] = []
    private var loaded = false
    private let files = FileManager.default
    private var payloadDirectory: URL { directory.appendingPathComponent("items", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL, limits: StorageLimits = StorageLimits()) {
        self.directory = directory
        self.limits = limits
    }

    public func load() throws -> [ClipRecord] {
        if loaded { return records }
        try files.createDirectory(at: payloadDirectory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        if files.fileExists(atPath: indexURL.path) {
            let size = try files.attributesOfItem(atPath: indexURL.path)[.size] as? Int ?? 0
            guard size <= 4 * 1_024 * 1_024 else { throw ClipError.invalidIndex }
            do {
                let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL))
                guard index.version == 1, index.records.count <= 10_000 else { throw ClipError.invalidIndex }
                var seen = Set<UUID>()
                records = index.records.filter { record in
                    guard valid(record), seen.insert(record.id).inserted else { return false }
                    let url = payloadDirectory.appendingPathComponent(record.filename)
                    guard let info = try? files.attributesOfItem(atPath: url.path),
                          info[.type] as? FileAttributeType == .typeRegular,
                          info[.size] as? Int == record.byteCount else { return false }
                    return true
                }
            } catch { throw ClipError.invalidIndex }
        }
        let removed = trim(&records)
        try persist(records)
        loaded = true
        removePayloads(removed)
        removeOrphans()
        return records
    }

    public func save(_ payload: ClipPayload) throws -> [ClipRecord] {
        guard loaded else { throw ClipError.invalidIndex }
        guard !payload.data.isEmpty else { throw ClipError.empty }
        guard payload.data.count <= limits.itemBytes, payload.data.count <= limits.totalBytes else {
            throw ClipError.oversized
        }
        let allowed = payload.kind == .text ? ["txt"] : ["png", "tiff"]
        guard allowed.contains(payload.fileExtension) else { throw ClipError.invalidPayload }
        let fingerprint = payload.fingerprint
        var next = records
        if let position = next.firstIndex(where: { $0.fingerprint == fingerprint }) {
            var existing = next.remove(at: position)
            existing.createdAt = Date()
            next.insert(existing, at: 0)
            try persist(next)
            records = next
            return records
        }
        let id = UUID()
        let filename = "\(id.uuidString).\(payload.fileExtension)"
        let url = payloadDirectory.appendingPathComponent(filename)
        try payload.data.write(to: url, options: .atomic)
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let item = ClipRecord(id: id, createdAt: Date(), kind: payload.kind,
                              preview: payload.preview, filename: filename,
                              byteCount: payload.data.count, fingerprint: fingerprint,
                              pixelWidth: payload.pixelWidth, pixelHeight: payload.pixelHeight)
        next.insert(item, at: 0)
        let removed = trim(&next)
        do { try persist(next) }
        catch {
            try? files.removeItem(at: url)
            throw error
        }
        records = next
        removePayloads(removed)
        return records
    }

    public func payload(for id: UUID) throws -> (ClipRecord, Data) {
        guard let record = records.first(where: { $0.id == id }) else { throw ClipError.missingRecord }
        let data = try Data(contentsOf: payloadDirectory.appendingPathComponent(record.filename), options: .mappedIfSafe)
        guard data.count == record.byteCount else { throw ClipError.missingRecord }
        return (record, data)
    }

    public func delete(_ id: UUID) throws -> [ClipRecord] {
        let removed = records.filter { $0.id == id }
        let next = records.filter { $0.id != id }
        try persist(next)
        records = next
        removePayloads(removed)
        return records
    }

    public func snapshot() -> Snapshot {
        Snapshot(count: records.count, bytes: records.reduce(0) { $0 + $1.byteCount })
    }

    public func fileURL(for record: ClipRecord) -> URL { payloadDirectory.appendingPathComponent(record.filename) }

    private func valid(_ record: ClipRecord) -> Bool {
        let ext = record.kind == .text ? ["txt"] : ["png", "tiff"]
        return ext.contains(URL(fileURLWithPath: record.filename).pathExtension)
            && record.filename == "\(record.id.uuidString).\(URL(fileURLWithPath: record.filename).pathExtension)"
            && record.byteCount > 0 && record.byteCount <= limits.itemBytes
            && record.preview.count <= 240 && record.fingerprint.count == 64
    }

    private func trim(_ items: inout [ClipRecord]) -> [ClipRecord] {
        var bytes = items.reduce(0) { $0 + $1.byteCount }
        var removed: [ClipRecord] = []
        while items.count > limits.count || bytes > limits.totalBytes {
            guard let last = items.popLast() else { break }
            bytes -= last.byteCount
            removed.append(last)
        }
        return removed
    }

    private func persist(_ items: [ClipRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Index(version: 1, records: items))
        try data.write(to: indexURL, options: .atomic)
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private func removePayloads(_ removed: [ClipRecord]) {
        for item in removed { try? files.removeItem(at: payloadDirectory.appendingPathComponent(item.filename)) }
    }

    private func removeOrphans() {
        let live = Set(records.map(\.filename))
        let urls = (try? files.contentsOfDirectory(at: payloadDirectory,
                                                  includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for url in urls where !live.contains(url.lastPathComponent) {
            // Only remove files matching our own UUID payload format.
            if UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
               ["txt", "png", "tiff"].contains(url.pathExtension) {
                try? files.removeItem(at: url)
            }
        }
    }
}
