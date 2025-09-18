// ImageMessageRow.swift
// bitchat
//
// Renders an image message bubble with rounded corners and optional delivery status.
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ImageMessageRow: View {
    let path: String
    let message: BitchatMessage
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var viewModel: ChatViewModel

    var body: some View {
        #if os(iOS)
        if let uiImage = UIImage(contentsOfFile: path) {
            VStack(alignment: .leading, spacing: 4) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 200, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 2)
                if message.isPrivate && message.sender == viewModel.nickname,
                   let status = message.deliveryStatus {
                    DeliveryStatusView(status: status, colorScheme: colorScheme)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("⚠️ Image unavailable")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        Text("📷 Image: \(path)")
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(colorScheme == .dark ? .green : Color(red: 0, green: 0.5, blue: 0))
            .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }
}
