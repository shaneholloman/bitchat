import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Placeholder view to display the user's verification QR payload as text.
struct MyQRView: View {
    let qrString: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Scan to verify me")
                .font(.system(size: 16, weight: .bold, design: .monospaced))

            QRCodeImage(data: qrString, size: 240)
                .accessibilityLabel("verification QR code")

            HStack(spacing: 8) {
                Button("Copy Link") {
                    #if os(iOS)
                    UIPasteboard.general.string = qrString
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(qrString, forType: .string)
                    #endif
                }
                .buttonStyle(.bordered)
            }

            ScrollView {
                Text(qrString)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
            }
            .frame(maxHeight: 120)
        }
        .padding()
    }
}

// Render a QR code image for a given string using CoreImage
struct QRCodeImage: View {
    let data: String
    let size: CGFloat

    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        Group {
            if let image = generateImage() {
                ImageWrapper(image: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                    .frame(width: size, height: size)
                    .overlay(
                        Text("QR unavailable")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.gray)
                    )
            }
        }
    }

    private func generateImage() -> CGImage? {
        let inputData = Data(data.utf8)
        filter.message = inputData
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scale = max(1, Int(size / 32))
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        return context.createCGImage(transformed, from: transformed.extent)
    }
}

// Platform-specific wrapper to display CGImage in SwiftUI
struct ImageWrapper: View {
    let image: CGImage
    var body: some View {
        #if os(iOS)
        let ui = UIImage(cgImage: image)
        return Image(uiImage: ui)
        #else
        let ns = NSImage(cgImage: image, size: .zero)
        return Image(nsImage: ns)
        #endif
    }
}

/// Placeholder scanner UI; real camera scanning will be added later.
struct QRScanView: View {
    @State private var input = ""
    @State private var result: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste QR content to simulate scan:")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
            TextEditor(text: $input)
                .frame(height: 100)
                .border(Color.gray.opacity(0.4))
            Button("Validate") {
                if let _ = VerificationService.shared.verifyScannedQR(input) {
                    result = "Valid QR payload"
                } else {
                    result = "Invalid or expired QR payload"
                }
            }
            .buttonStyle(.bordered)
            Text(result)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(result.contains("Valid") ? .green : .orange)
            Spacer()
        }
        .padding()
    }
}
