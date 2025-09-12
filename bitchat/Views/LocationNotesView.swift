import SwiftUI

struct LocationNotesView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @StateObject private var manager: LocationNotesManager
    let geohash: String

    @Environment(\.colorScheme) var colorScheme
    @State private var draft: String = ""

    init(geohash: String) {
        let gh = geohash.lowercased()
        self.geohash = gh
        _manager = StateObject(wrappedValue: LocationNotesManager(geohash: gh))
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }
    private var textColor: Color {
        colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0)
    }
    private var secondaryTextColor: Color {
        colorScheme == .dark ? Color.green.opacity(0.8) : Color(red: 0, green: 0.5, blue: 0).opacity(0.8)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                list
                Divider()
                input
            }
            if manager.isLoading {
                MatrixRainView()
                    .transition(.opacity)
            }
        }
        .background(backgroundColor)
        .foregroundColor(textColor)
        .onDisappear { manager.cancel() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("notes @ #\(geohash)")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                Text("street-level notes")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(secondaryTextColor)
            }
            Spacer()
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
        .background(backgroundColor.opacity(0.95))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(manager.notes) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(note.displayName)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(secondaryTextColor)
                            Text(note.createdAt, style: .relative)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(secondaryTextColor.opacity(0.8))
                        }
                        Text(note.content)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
        .background(backgroundColor)
    }

    private var input: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("add a note for this place", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14, design: .monospaced))
                .lineLimit(3, reservesSpace: true)
                .padding(.horizontal, 12)

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : textColor)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .padding(.trailing, 12)
        }
        .frame(minHeight: 44)
        .padding(.vertical, 8)
        .background(backgroundColor.opacity(0.95))
    }

    private func send() {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        manager.send(content: content, nickname: viewModel.nickname)
        draft = ""
    }
}

// MARK: - Matrix Rain Loader
private struct MatrixRainView: View {
    @Environment(\.colorScheme) var colorScheme
    private var fg: Color { colorScheme == .dark ? Color.green : Color(red: 0, green: 0.5, blue: 0) }
    private let charset = Array("01abcdefghijklmnopqrstuvwxyzｱｲｳｴｵｶｷｸｹｺﾊﾋﾌﾍﾎ0123456789")

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let h = max(geo.size.height, 1)
            let colWidth: CGFloat = 14
            let cols = max(Int(w / colWidth), 6)
            ZStack {
                ForEach(0..<cols, id: \.self) { i in
                    RainColumn(charset: charset,
                               columnWidth: colWidth,
                               height: h,
                               speed: Double.random(in: 2.8...4.8),
                               delay: Double.random(in: 0...1.2),
                               color: fg)
                    .frame(width: colWidth)
                    .position(x: CGFloat(i) * colWidth + colWidth/2, y: h/2)
                }
            }
            .background(Color.black.opacity(colorScheme == .dark ? 0.75 : 0.65))
            .overlay(
                VStack(spacing: 6) {
                    Text("loading notes…")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(fg)
                        .padding(.top, 12)
                    Spacer()
                }
            )
        }
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }
}

private struct RainColumn: View {
    let charset: [Character]
    let columnWidth: CGFloat
    let height: CGFloat
    let speed: Double
    let delay: Double
    let color: Color
    @State private var y: CGFloat = 0
    @State private var glyphs: [String] = []
    @State private var timer: Timer?

    var body: some View {
        let font = Font.system(size: 12, weight: .regular, design: .monospaced)
        VStack(spacing: 0) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { idx, ch in
                Text(ch)
                    .font(font)
                    .foregroundColor(color.opacity(opacity(for: idx)))
                    .frame(width: columnWidth, alignment: .center)
            }
        }
        .offset(y: y)
        .onAppear {
            let count = max(Int(height / 14) + 12, 24)
            glyphs = randomGlyphs(count)
            startGlyphTimer()
            y = -height
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.linear(duration: speed).repeatForever(autoreverses: false)) {
                    y = height * 2
                }
            }
        }
        .onDisappear { stopGlyphTimer() }
    }

    private func opacity(for idx: Int) -> Double {
        let p = Double(idx) / Double(max(glyphs.count, 1))
        return 0.15 + (1.0 - p) * 0.85
    }

    private func randomGlyphs(_ n: Int) -> [String] {
        (0..<n).map { _ in String(charset.randomElement() ?? "0") }
    }

    private func startGlyphTimer() {
        stopGlyphTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { _ in
            if glyphs.isEmpty { return }
            let changes = Int.random(in: 1...3)
            for _ in 0..<changes {
                let idx = Int.random(in: 0..<glyphs.count)
                glyphs[idx] = String(charset.randomElement() ?? "1")
            }
        }
    }

    private func stopGlyphTimer() {
        timer?.invalidate()
        timer = nil
    }
}
