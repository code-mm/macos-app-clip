import AppKit
import ClipCore
import ImageIO
import UniformTypeIdentifiers

enum ClipboardInput: Sendable {
    case text(String)
    case image(Data)
    case imageFile(URL)
}

enum ClipboardImportError: LocalizedError {
    case unsupportedFile, multipleFiles
    var errorDescription: String? {
        switch self {
        case .unsupportedFile: return "目前支持文字和图片，请选择图片文件。"
        case .multipleFiles: return "请每次放入一张图片。"
        }
    }
}

enum ClipboardImport {
    static let imageTypes: [UTType] = [.png, .jpeg, .tiff, .heic, .gif, .bmp]
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .fileURL, .string]

    @MainActor
    static func read(from board: NSPasteboard) throws -> ClipboardInput {
        if let type = board.availableType(from: [.png, .tiff]), let data = board.data(forType: type) {
            return .image(data)
        }
        if board.availableType(from: [.fileURL]) != nil {
            let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            guard urls.count == 1, let url = urls.first else { throw ClipboardImportError.multipleFiles }
            return .imageFile(url)
        }
        if let text = board.string(forType: .string), !text.isEmpty { return .text(text) }
        throw ClipError.empty
    }

    static func prepare(_ input: ClipboardInput) throws -> ClipPayload {
        switch input {
        case .text(let text):
            guard !text.isEmpty else { throw ClipError.empty }
            guard text.utf8.count <= 2 * 1_024 * 1_024 else { throw ClipError.oversized }
            return .text(text)
        case .image(let data):
            return try prepareImage(data)
        case .imageFile(let url):
            guard url.isFileURL,
                  let type = UTType(filenameExtension: url.pathExtension),
                  imageTypes.contains(where: { type.conforms(to: $0) }) else { throw ClipboardImportError.unsupportedFile }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw ClipboardImportError.unsupportedFile }
            guard let size = values.fileSize, size <= 20 * 1_024 * 1_024 else { throw ClipError.oversized }
            return try prepareImage(Data(contentsOf: url, options: .mappedIfSafe))
        }
    }

    private static func prepareImage(_ data: Data) throws -> ClipPayload {
        guard data.count <= 20 * 1_024 * 1_024 else { throw ClipError.oversized }
        let (width, height) = try ImageSupport.dimensions(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) else { throw ClipError.invalidImage }
        let type = identifier as String
        if type == UTType.png.identifier || type == UTType.tiff.identifier {
            return ClipPayload(kind: .image, data: data, preview: "图片", fileExtension: type == UTType.png.identifier ? "png" : "tiff",
                               pixelWidth: width, pixelHeight: height)
        }
        guard imageTypes.contains(where: { $0.identifier == type }),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ClipError.invalidImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw ClipError.invalidImage
        }
        // Non-PNG/TIFF input is normalized once. Keep orientation so the preview remains upright.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var options: [CFString: Any] = [:]
        options[kCGImagePropertyOrientation] = properties?[kCGImagePropertyOrientation]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ClipError.invalidImage }
        guard output.length <= 20 * 1_024 * 1_024 else { throw ClipError.oversized }
        return ClipPayload(kind: .image, data: output as Data, preview: "图片", fileExtension: "png",
                           pixelWidth: width, pixelHeight: height)
    }
}
