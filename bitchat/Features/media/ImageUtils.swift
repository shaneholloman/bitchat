import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
import ImageIO
import UniformTypeIdentifiers
#endif

enum ImageUtilsError: Error {
    case invalidImage
    case encodingFailed
}

enum ImageUtils {
    private static let compressionQuality: CGFloat = 0.85

    static func processImage(at url: URL, maxDimension: CGFloat = 512) throws -> URL {
        let data = try Data(contentsOf: url)
        #if os(iOS)
        guard let image = UIImage(data: data) else { throw ImageUtilsError.invalidImage }
        return try processImage(image, maxDimension: maxDimension)
        #else
        guard let image = NSImage(data: data) else { throw ImageUtilsError.invalidImage }
        return try processImage(image, maxDimension: maxDimension)
        #endif
    }

    #if os(iOS)
    static func processImage(_ image: UIImage, maxDimension: CGFloat = 512) throws -> URL {
        let scaled = scaledImage(image, maxDimension: maxDimension)
        guard let jpegData = scaled.jpegData(compressionQuality: compressionQuality) else {
            throw ImageUtilsError.encodingFailed
        }
        let outputURL = try makeOutputURL()
        try jpegData.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private static func scaledImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let rendered = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return rendered ?? image
    }
    #else
    static func processImage(_ image: NSImage, maxDimension: CGFloat = 512) throws -> URL {
        let scaled = scaledImage(image, maxDimension: maxDimension)
        guard let tiffData = scaled.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let cgImage = bitmap.cgImage else {
            throw ImageUtilsError.encodingFailed
        }
        let outputURL = try makeOutputURL()
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageUtilsError.encodingFailed
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
            kCGImagePropertyExifDictionary: [:],
            kCGImagePropertyTIFFDictionary: [:],
            kCGImagePropertyIPTCDictionary: [:],
            kCGImagePropertyOrientation: 1
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageUtilsError.encodingFailed
        }
        return outputURL
    }

    private static func scaledImage(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }
        let scale = maxDimension / maxSide
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)
        let scaledImage = NSImage(size: newSize)
        scaledImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        scaledImage.unlockFocus()
        return scaledImage
    }
    #endif

    private static func makeOutputURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "img_\(formatter.string(from: Date())).jpg"

        let directory = try applicationFilesDirectory().appendingPathComponent("images/outgoing", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        return directory.appendingPathComponent(fileName)
    }

    private static func applicationFilesDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("files", isDirectory: true)
    }
}
