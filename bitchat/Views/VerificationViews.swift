import SwiftUI

/// Placeholder view to display the user's verification QR payload as text.
struct MyQRView: View {
    let qrString: String
    var body: some View {
        VStack(spacing: 12) {
            Text("Scan to verify me")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
            // Placeholder box where a future QR image will go
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.5), lineWidth: 1)
                .frame(width: 220, height: 220)
                .overlay(Text("QR PREVIEW\ncoming soon").font(.system(size: 12, design: .monospaced)).multilineTextAlignment(.center).foregroundColor(.gray))
            ScrollView {
                Text(qrString)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
            }.frame(maxHeight: 120)
        }
        .padding()
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

