import SwiftUI
import AVFoundation

struct VoiceMessageRow: View {
    let fileURL: URL
    var sendProgress: Double? = nil // 0..1 filling during send
    @State private var bins: [Float] = []
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var duration: TimeInterval = 0
    @State private var player: AVAudioPlayer?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22))
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Base waveform
                    HStack(spacing: 2) {
                        ForEach(Array(bins.enumerated()), id: \.offset) { _, v in
                            // Apply logarithmic normalization for better visibility of quiet recordings
                            let normalizedV = v <= 0 ? 0 : min(1.0, log(1.0 + v * 9.0) / log(10.0))
                            let h = max(2, CGFloat(normalizedV) * geo.size.height)
                            Capsule().fill(Color.gray.opacity(0.4)).frame(width: 2, height: h)
                        }
                    }
                    // Filled progress (with normalized amplitude)
                    let activeProgress = sendProgress ?? progress
                    let filled = Int(Double(bins.count) * activeProgress)
                    HStack(spacing: 2) {
                        ForEach(0..<max(0, min(bins.count, filled)), id: \.self) { i in
                            let v = bins[i]
                            // Apply logarithmic normalization for better visibility of quiet recordings
                            let normalizedV = v <= 0 ? 0 : min(1.0, log(1.0 + v * 9.0) / log(10.0))
                            let h = max(2, CGFloat(normalizedV) * geo.size.height)
                            Capsule().fill(Color.blue).frame(width: 2, height: h)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(height: 26)

            Text(formattedDuration)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .onAppear(perform: load)
        .onDisappear { player?.stop(); isPlaying = false }
    }

    private var formattedDuration: String {
        let total = duration
        let mins = Int(total) / 60
        let secs = Int(total) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func load() {
        bins = WaveformExtractor.extractBins(url: fileURL, binCount: 120)
        do {
            player = try AVAudioPlayer(contentsOf: fileURL)
            duration = player?.duration ?? 0
            player?.prepareToPlay()
            startProgressTimer()
        } catch {
            // Ignore
        }
    }

    private func togglePlay() {
        guard let p = player else { return }
        if isPlaying { p.pause(); isPlaying = false }
        else { p.play(); isPlaying = true; startProgressTimer() }
    }

    private func startProgressTimer() {
        guard let p = player else { return }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            if !isPlaying || p.duration == 0 { t.invalidate(); return }
            progress = min(1.0, p.currentTime / p.duration)
            if progress >= 1.0 { isPlaying = false; t.invalidate() }
        }
    }
}
