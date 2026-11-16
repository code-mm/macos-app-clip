import Foundation
import ImageIO
import CoreGraphics

public enum ImageSupport {
    /// Limit a preview to 8 megapixels / 4096 px per edge; the original file remains untouched.
    public static func previewPixelLimit(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 1 }
        let edge = Double(max(width, height))
        let pixels = Double(width) * Double(height)
        let scale = min(1, min(4096 / edge, sqrt(8_000_000 / pixels)))
        return max(1, Int(floor(edge * scale)))
    }

    public static func preview(at url: URL, width: Int, height: Int) -> CGImage? {
        thumbnail(at: url, maxPixels: previewPixelLimit(width: width, height: height))
    }

    public static func dimensions(_ data: Data) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ClipError.invalidImage }
        guard width <= 40_000_000 / height else { throw ClipError.oversized }
        return (width, height)
    }

    public static func thumbnail(at url: URL, maxPixels: Int = 240) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as CFDictionary)
    }
}
