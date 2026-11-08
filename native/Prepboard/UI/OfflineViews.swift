import AVFoundation
import SwiftData
import SwiftUI

/// A video thumbnail from the device when it was downloaded for offline, otherwise from YouTube.
struct VideoThumbnail: View {
    let video: Video
    var body: some View {
        let file = OfflineLibrary.thumbnailFile(video.id)
        if let image = PlatformImage(contentsOfFile: file.path) {
            platformImage(image).resizable().scaledToFill()
        } else {
            AsyncImage(url: video.thumbnailURL) { img in img.resizable().scaledToFill() } placeholder: { Color.black.opacity(0.85) }
        }
    }
}

#if os(iOS)
typealias PlatformImage = UIImage
private func platformImage(_ i: UIImage) -> Image { Image(uiImage: i) }
#else
typealias PlatformImage = NSImage
private func platformImage(_ i: NSImage) -> Image { Image(nsImage: i) }
#endif

/// Reads text aloud with the system voice: no network needed, keeps playing with the screen locked (iPhone).
@MainActor
@Observable
final class SpeechReader: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var speakingID: String?
    private(set) var paused = false
    var rate: Float = UserDefaults.standard.object(forKey: "listen.rate") as? Float ?? 0.5 {
        didSet { UserDefaults.standard.set(rate, forKey: "listen.rate") }
    }
    /// Made on first use: creating a synthesizer talks to the speech service, which must not hold up launch.
    @ObservationIgnored private lazy var synth: AVSpeechSynthesizer = {
        let s = AVSpeechSynthesizer(); s.delegate = self; return s
    }()

    /// Markdown or code turned into what a listener should hear: no symbols, fences or link targets.
    static func speakable(_ markdown: String) -> String {
        var out: [String] = []
        var inCode = false
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); if inCode { out.append("Code example skipped.") }; continue }
            if inCode || line.isEmpty { continue }
            var t = line.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            t = t.replacingOccurrences(of: #"^(#+|[-*+]|\d+\.|>)\s*"#, with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: #"[*_`|]"#, with: "", options: .regularExpression)
            if !t.trimmingCharacters(in: .whitespaces).isEmpty { out.append(t.hasSuffix(".") || t.hasSuffix(":") || t.hasSuffix("?") ? t : t + ".") }
        }
        return out.joined(separator: "\n")
    }

    func toggle(id: String, text: String) {
        if speakingID == id {
            if synth.isPaused { synth.continueSpeaking(); paused = false } else { synth.pauseSpeaking(at: .word); paused = true }
            return
        }
        stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let u = AVSpeechUtterance(string: Self.speakable(text))
        u.rate = AVSpeechUtteranceMinimumSpeechRate + (AVSpeechUtteranceMaximumSpeechRate - AVSpeechUtteranceMinimumSpeechRate) * rate * 0.8
        u.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")) ?? AVSpeechSynthesisVoice(language: "en-US")
        speakingID = id; paused = false
        synth.speak(u)
    }

    func stop() {
        if speakingID != nil { synth.stopSpeaking(at: .immediate) }
        speakingID = nil; paused = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speakingID = nil; self.paused = false }
    }
}

/// "Listen" / "Pause" for any text: documents, problem statements, video key points.
struct ListenButton: View {
    let id: String
    let text: String
    var compact = false
    @Environment(SpeechReader.self) private var reader

    var body: some View {
        let on = reader.speakingID == id
        Button { reader.toggle(id: id, text: text) } label: {
            Label(on ? (reader.paused ? "Resume" : "Pause") : "Listen", systemImage: on && !reader.paused ? "pause.fill" : "headphones")
        }
        .buttonStyle(PillButtonStyle(filled: on, compact: true))
        .help("Read this aloud with the system voice. Works offline and with the screen locked.")
        .contextMenu {
            if on { Button("Stop", systemImage: "stop.fill") { reader.stop() } }
            Picker("Speed", selection: Binding(get: { reader.rate }, set: { reader.rate = $0 })) {
                Text("Slow").tag(Float(0.4)); Text("Normal").tag(Float(0.5)); Text("Fast").tag(Float(0.62)); Text("Faster").tag(Float(0.75))
            }
        }
    }
}

/// The video's saved key points, readable and listenable without signal, plus the ways to get the video itself offline.
struct VideoKeyPoints: View {
    let video: Video
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: PB.s2) {
            if !video.keyPoints.isEmpty {
                HStack {
                    Text("What it covers").pbLabelStyle()
                    Spacer(minLength: 0)
                    ListenButton(id: "video-" + video.id, text: video.title + ". " + video.keyPoints, compact: true)
                }
                Text(video.keyPoints).font(.system(size: 13)).foregroundStyle(PB.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                openURL(video.youtubeAppURL) { ok in if !ok { openURL(video.watchURL) } }
            } label: { Label("Open in YouTube to download", systemImage: "arrow.down.circle") }
                .buttonStyle(PillButtonStyle(filled: false, compact: true))
                .help("YouTube only allows downloads in its own app, with Premium: tap Download under the video.")
        }
    }
}

/// Settings card: what is ready offline, the Wi-Fi auto-download switch, and the YouTube playlist of every prep video.
struct OfflineCard: View {
    @Environment(OfflineLibrary.self) private var library
    @Environment(NetworkStatus.self) private var network
    @Environment(Cloud.self) private var cloud
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var tick = 0

    var body: some View {
        @Bindable var library = library
        let c = library.coverage(context)
        let videos = OfflineLibrary.allVideos(context)
        VStack(alignment: .leading, spacing: PB.s3) {
            Label("Offline prep", systemImage: "tram.fill").font(.system(size: 15, weight: .semibold))
            Text("Notes, guides, practice problems, past quizzes and video key points always work without signal. PDFs and video thumbnails download here so they do too.")
                .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: PB.s4) {
                stat("PDFs", c.pdfs, c.pdfTotal)
                stat("Thumbnails", c.thumbs, c.videoTotal)
            }
            if library.downloading {
                ProgressBar(value: library.total == 0 ? 0 : Double(library.done) / Double(library.total))
                Text("Downloading \(library.done) of \(library.total)…").font(.system(size: 12)).foregroundStyle(PB.muted)
            } else if let e = library.lastError {
                Text(e).font(.system(size: 12)).foregroundStyle(PB.sunInk).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Download new files on Wi-Fi by themselves", isOn: $library.auto).tint(PB.cobalt)
            FlowLayout(spacing: PB.s2) {
                Button { Task { await library.downloadAll(context: context, cloud: cloud); tick += 1 } } label: {
                    Label("Download everything now", systemImage: "arrow.down.circle")
                }
                .buttonStyle(PillButtonStyle(compact: true))
                .disabled(library.downloading || !network.isOnline)
                if let url = Video.playlistURL(videos) {
                    Button { openURL(url) } label: { Label("Make a YouTube playlist (\(min(50, videos.count)))", systemImage: "play.rectangle.on.rectangle") }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
            }
            if !videos.isEmpty {
                Text("The playlist opens in the YouTube app. Save it to your library, then tap Download to keep every video for the subway (YouTube Premium). YouTube doesn't let other apps download its videos.")
                    .font(.system(size: 12)).foregroundStyle(PB.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let last = library.lastSync {
                Text("Last checked \(last.formatted(.relative(presentation: .named)))").font(.system(size: 11)).foregroundStyle(PB.muted)
            }
        }
        .id(tick)
    }

    private func stat(_ label: String, _ have: Int, _ all: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(have) / \(all)").font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(all > 0 && have == all ? PB.green : PB.ink)
            Text(label + " saved").font(.system(size: 11, weight: .semibold)).foregroundStyle(PB.ink2).lineLimit(1)
        }
        .padding(.horizontal, PB.s3).padding(.vertical, PB.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: PB.rMD).fill(PB.surface))
    }
}

/// The thin banner the shell shows while there is no signal.
struct OfflineBanner: View {
    var body: some View {
        Label("Offline: everything you downloaded still works, and your changes sync when you're back.", systemImage: "wifi.slash")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PB.ink2)
            .padding(.horizontal, PB.s4).padding(.vertical, PB.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PB.sunSoft)
    }
}
