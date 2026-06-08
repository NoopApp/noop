import Foundation
import CoreImage.CIFilterBuiltins
import CoreGraphics

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Generates a crisp QR code image for a string (e.g. a crypto address) so people can scan straight
/// from their wallet — the lowest-friction way to donate. Returns the platform-native image type.
enum QRCode {
    private static let context = CIContext()

    static func image(for string: String, scale: CGFloat = 12) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
              let cg = context.createCGImage(output, from: output.extent) else { return nil }
        #if canImport(AppKit)
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
        #elseif canImport(UIKit)
        return UIImage(cgImage: cg)
        #else
        return nil
        #endif
    }
}
