import Foundation
import AppKit
import ImageIO

/// Shared by a view task and its blocking transfer worker.
final class PreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = stopped; lock.unlock()
        if value { throw CancellationError() }
    }
}

/// Cache decoded preview content, rather than decoding during every body evaluation.
final class PreviewContent: @unchecked Sendable {
    let image: NSImage?
    let text: String?
    init(data: Data, extension ext: String, fullResolution: Bool = false) {
        if ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "heic", "webp"].contains(ext) {
            if ext == "gif" || fullResolution { image = NSImage(data: data) }
            else if let source = CGImageSourceCreateWithData(data as CFData, nil),
                    let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2400,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary) {
                let bitmap = NSBitmapImageRep(cgImage: thumbnail)
                let preview = NSImage(size: bitmap.size)
                preview.addRepresentation(bitmap)
                image = preview
            } else { image = nil }
            text = nil
        } else {
            image = nil
            text = data.contains(0) ? nil : String(data: data, encoding: .utf8)
        }
    }
}
