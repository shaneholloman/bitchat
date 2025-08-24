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
            .interpolation(.none)
            .resizable()
        #else
        let ns = NSImage(cgImage: image, size: .zero)
        return Image(nsImage: ns)
            .interpolation(.none)
            .resizable()
        #endif
    }
}

/// Placeholder scanner UI; real camera scanning will be added later.
struct QRScanView: View {
    @State private var input = ""
    @State private var result: String = ""
    @State private var lastValid: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(iOS)
            Text("Scan a friend's QR")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
            CameraScannerView { code in
                if let qr = VerificationService.shared.verifyScannedQR(code) {
                    result = "Valid QR: \(qr.nickname)"
                    lastValid = code
                } else {
                    result = "Invalid or expired QR"
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 1))
            #else
            Text("Paste QR content to validate:")
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
            #endif
            Text(result)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(result.contains("Valid") ? .green : .orange)
            if !lastValid.isEmpty {
                Text(lastValid)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding()
    }
}

#if os(iOS)
import AVFoundation

struct CameraScannerView: UIViewRepresentable {
    typealias UIViewType = PreviewView
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.setup(sessionOwner: view, onCode: onCode)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private var onCode: ((String) -> Void)?
        private weak var owner: PreviewView?
        private let session = AVCaptureSession()

        func setup(sessionOwner: PreviewView, onCode: @escaping (String) -> Void) {
            self.owner = sessionOwner
            self.onCode = onCode
            session.beginConfiguration()
            session.sessionPreset = .high
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            sessionOwner.videoPreviewLayer.session = session
            // Request permission and start
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.session.startRunning() }
                }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            for obj in metadataObjects {
                guard let m = obj as? AVMetadataMachineReadableCodeObject,
                      m.type == .qr,
                      let str = m.stringValue else { continue }
                onCode?(str)
            }
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override init(frame: CGRect) {
            super.init(frame: frame)
            videoPreviewLayer.videoGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
#endif
