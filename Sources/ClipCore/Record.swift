import Foundation
import CryptoKit

public struct ClipRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case text, image }
    public var id: UUID
    public var createdAt: Date
    public let kind: Kind
    public let preview: String
    public let filename: String
    public let byteCount: Int
    public let fingerprint: String
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public var title: String {
        if kind == .image { return "图片" }
        let firstLine = preview.split(whereSeparator: \.isNewline).first.map(String.init) ?? "文字"
        return String(firstLine.prefix(36))
    }

    public var requiresPreview: Bool {
        if kind == .image { return true }
        // 多行、较长或列表摘要已截断的文字，先查看再决定是否复制。
        return preview.contains(where: \.isNewline) || preview.count > 80 || byteCount > preview.utf8.count
    }
}

public struct ClipPayload: Sendable {
    public let kind: ClipRecord.Kind
    public let data: Data
    public let preview: String
    public let fileExtension: String
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(kind: ClipRecord.Kind, data: Data, preview: String, fileExtension: String,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.kind = kind
        self.data = data
        self.preview = String(preview.prefix(240))
        self.fileExtension = fileExtension
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public static func text(_ value: String) -> ClipPayload {
        ClipPayload(kind: .text, data: Data(value.utf8), preview: value, fileExtension: "txt")
    }

    public var fingerprint: String {
        var digest = SHA256()
        digest.update(data: Data(kind.rawValue.utf8))
        digest.update(data: data)
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct StorageLimits: Sendable {
    public var count: Int
    public var totalBytes: Int
    public var itemBytes: Int
    public init(count: Int = 500, totalBytes: Int = 250 * 1_024 * 1_024,
                itemBytes: Int = 20 * 1_024 * 1_024) {
        self.count = count
        self.totalBytes = totalBytes
        self.itemBytes = itemBytes
    }
}

public enum ClipError: LocalizedError {
    case empty, oversized, invalidImage, invalidIndex, missingRecord, invalidPayload
    public var errorDescription: String? {
        switch self {
        case .empty: return "当前剪贴板中没有可记录的文字或图片。"
        case .oversized: return "内容超过容量限制：文字最多 2 MB，图片最多 20 MB、4000 万像素。"
        case .invalidImage: return "图片格式无法读取，请重新复制后再试。"
        case .invalidIndex: return "记录索引无法读取。已保留原始文件，请从设置打开数据目录检查。"
        case .missingRecord: return "这条记录的文件已不存在。"
        case .invalidPayload: return "记录内容或文件格式无效。"
        }
    }
}
