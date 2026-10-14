import PDFKit
import SwiftUI
import UniformTypeIdentifiers
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
        if context.coordinator.loaded != data.count { context.coordinator.loaded = data.count; v.document = PDFDocument(data: data) }
    }
    func makeCoordinator() -> Loaded { Loaded() }
    final class Loaded { var loaded = -1 }
}
#else
struct PDFKitView: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.pageShadowsEnabled = true
        v.backgroundColor = UIColor(PB.surface)
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        if context.coordinator.loaded != data.count {
            context.coordinator.loaded = data.count
            v.document = PDFDocument(data: data)
            // Fit the page width to the screen, then allow pinch-zoom from there.
            DispatchQueue.main.async { v.minScaleFactor = v.scaleFactorForSizeToFit; v.maxScaleFactor = 5; v.scaleFactor = v.scaleFactorForSizeToFit }
        }
    }
    func makeCoordinator() -> Loaded { Loaded() }
    final class Loaded { var loaded = -1 }
}
#endif

/// Loads a PDF document's file (local cache first, then the account's private storage) and renders it.
struct PDFDocView: View {
    let doc: Doc
    @Environment(Cloud.self) private var cloud
    @State private var data: Data?
    @State private var error: String?
    @State private var fullScreen = false

    var body: some View {
        Group {
            if let data {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        ShareLink(item: PDFFile(data: data, name: doc.title), preview: SharePreview(doc.title)) {
                            Label("Share", systemImage: "square.and.arrow.up").font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true))
                        Button { fullScreen = true } label: {
                            Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true))
                    }
                    PDFKitView(data: data)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(PB.line))
                }
                #if os(iOS)
                .fullScreenCover(isPresented: $fullScreen) {
                    NavigationStack {
                        PDFKitView(data: data).ignoresSafeArea(edges: .bottom)
                            .navigationTitle(doc.title).navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { fullScreen = false } } }
                    }
                }
                #else
                .sheet(isPresented: $fullScreen) {
                    VStack(spacing: 0) {
                        HStack { Text(doc.title).font(.headline); Spacer(); Button("Done") { fullScreen = false }.keyboardShortcut(.cancelAction) }.padding(16)
                        PDFKitView(data: data)
                    }
                    .pbSheetFrame(minWidth: 600, idealWidth: 960, minHeight: 440, idealHeight: 720)
                }
                #endif
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
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(video.channel).font(.system(size: 12)).foregroundStyle(PB.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                CircleIconButton(systemImage: "arrow.up.left.and.arrow.down.right", size: 32, label: "Full size") {
                    app.sideVideo = nil; app.playingVideo = video
                }
                CircleIconButton(systemImage: "arrow.up.right.square", size: 32, label: "Open on YouTube") { openURL(video.watchURL) }
                #if os(macOS)
                if !compact && !WorkspaceManager.shared.isDetached(.video) {
                    CircleIconButton(systemImage: "macwindow.on.rectangle", size: 32, label: "Own window") { WorkspaceManager.shared.open(.video) }
                }
                #endif
                CircleIconButton(systemImage: "xmark", size: 32, label: "Close video") { app.sideVideo = nil }
            }
            .padding(compact ? 10 : 14)
            if !compact && !video.why.isEmpty {
                Text(video.why).font(.system(size: 12)).foregroundStyle(PB.ink2).padding(.horizontal, 16).padding(.bottom, 16)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(PB.card)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 16 : PB.rXL, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: compact ? 16 : PB.rXL, style: .continuous).strokeBorder(PB.line))
        .shadow(color: PB.shadow.opacity(0.06), radius: 14, y: 6)
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
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
            .padding(16)
        }
        .background(PB.card)
        #if os(macOS)
        .frame(minWidth: 760, idealWidth: 900)
        #endif
    }
}

/// A PDF for the share sheet (Save to Files, AirDrop, Mail…), named after the document.
struct PDFFile: Transferable {
    let data: Data
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { $0.data }
            .suggestedFileName { $0.name + ".pdf" }
    }
}
