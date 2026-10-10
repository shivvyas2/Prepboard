import PDFKit
import SwiftUI
import WebKit

// MARK: - PDF (PDFKit)

#if os(macOS)
struct PDFKitView: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = NSColor(PB.surface)
        return v
    }
    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.dataRepresentation() != data { v.document = PDFDocument(data: data) }
    }
}
#else
struct PDFKitView: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = UIColor(PB.surface)
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        if v.document?.dataRepresentation() != data { v.document = PDFDocument(data: data) }
    }
}
#endif

/// Loads a PDF document's file (local cache first, then the account's private storage) and renders it.
struct PDFDocView: View {
    let doc: Doc
    @Environment(Cloud.self) private var cloud
    @State private var data: Data?
    @State private var error: String?

    var body: some View {
        Group {
            if let data {
                PDFKitView(data: data)
                    .frame(minHeight: 600)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
            } else if let error {
                Text(error).foregroundStyle(PB.muted).frame(maxWidth: .infinity).padding(40)
            } else {
                ProgressView("Loading PDF…").frame(maxWidth: .infinity).padding(40)
            }
        }
        .task(id: doc.id) {
            do { data = try await cloud.pdfData(for: doc) }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - YouTube player (in-app)

/// Plays a YouTube video in-app through the embeddable player.
/// The page gets an https base URL so YouTube receives a referrer (without one the embed fails with error 153).
struct YouTubePlayer: View {
    let video: Video
    var body: some View {
        WebPlayer(html: """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{position:fixed;inset:0;width:100%;height:100%;border:0}</style></head>
        <body><iframe src="https://www.youtube-nocookie.com/embed/\(video.id)?playsinline=1&rel=0&autoplay=1&origin=https://prepboard.app"
          referrerpolicy="strict-origin-when-cross-origin"
          allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen></iframe></body></html>
        """)
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(Color.black)
    }
}

#if os(macOS)
private struct WebPlayer: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.loadHTMLString(html, baseURL: URL(string: "https://prepboard.app/"))
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {}
}
#else
private struct WebPlayer: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.scrollView.isScrollEnabled = false
        v.isOpaque = false
        v.backgroundColor = .black
        v.loadHTMLString(html, baseURL: URL(string: "https://prepboard.app/"))
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
#endif

/// Docked player beside the current section (documents, PDFs, timeline…). One instance, so it keeps playing.
struct SideVideoPanel: View {
    let video: Video
    var compact = false
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            YouTubePlayer(video: video).id(video.id)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(video.channel).font(.system(size: 12)).foregroundStyle(PB.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                CircleIconButton(systemImage: "arrow.up.left.and.arrow.down.right", size: 30, label: "Full size") {
                    app.sideVideo = nil; app.playingVideo = video
                }
                CircleIconButton(systemImage: "arrow.up.right.square", size: 30, label: "Open on YouTube") { openURL(video.watchURL) }
                CircleIconButton(systemImage: "xmark", size: 30, label: "Close video") { app.sideVideo = nil }
            }
            .padding(compact ? 10 : 14)
            if !compact && !video.why.isEmpty {
                Text(video.why).font(.system(size: 12)).foregroundStyle(PB.ink2).padding(.horizontal, 14).padding(.bottom, 14)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(PB.card)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 16 : PB.rXL, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 16 : PB.rXL, style: .continuous).strokeBorder(PB.line))
        .shadow(color: Color(hex: 0x3C2D14).opacity(0.07), radius: 14, y: 8)
    }
}

struct VideoPlayerSheet: View {
    let video: Video
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            YouTubePlayer(video: video)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.title).font(.system(size: 15, weight: .semibold))
                        Text(video.channel).font(.system(size: 13)).foregroundStyle(PB.muted)
                    }
                    Spacer()
                    Button("Play beside docs") {
                        app.sideVideo = video
                        app.section = .documents
                        dismiss()
                    }
                    .buttonStyle(PillButtonStyle(compact: true))
                    .help("Keep the video playing on the side while you read your documents and PDFs")
                    Button("YouTube ↗") { openURL(video.watchURL) }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                    CircleIconButton(systemImage: "xmark", size: 32, label: "Close") { dismiss() }
                }
                if !video.why.isEmpty { Text(video.why).font(.system(size: 14)).foregroundStyle(PB.ink2) }
                Text("If the video says it can't play here (some channels block embedding), use “YouTube ↗”.")
                    .font(.system(size: 12)).foregroundStyle(PB.muted)
            }
            .padding(18)
        }
        .background(PB.card)
        #if os(macOS)
        .frame(minWidth: 760, idealWidth: 900)
        #endif
    }
}
