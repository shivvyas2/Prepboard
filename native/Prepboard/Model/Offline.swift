import Foundation
import Network
import Observation
import SwiftData

/// Whether the device is online right now; the shell shows an offline banner from it.
@MainActor
@Observable
final class NetworkStatus {
    private(set) var isOnline = true
    /// Wi-Fi or Ethernet, not a hotspot or cellular: where big downloads may run on their own.
    private(set) var isUnmetered = true
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isOnline = path.status == .satisfied
                self?.isUnmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            }
        }
        monitor.start(queue: DispatchQueue(label: "prepboard.network"))
    }
}

/// Keeps everything needed to prepare without signal on the device: every PDF in the account and every video thumbnail.
/// Notes, guides, problems and past quizzes already live in the local store; this fills in the files that are fetched on demand.
@MainActor
@Observable
final class OfflineLibrary {
    static let autoKey = "offline.auto"
    /// Download new files by themselves on Wi-Fi (on by default).
    var auto: Bool = UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(auto, forKey: Self.autoKey) }
    }
    private(set) var downloading = false
    private(set) var done = 0
    private(set) var total = 0
    private(set) var lastError: String?
    private(set) var lastSync: Date? = UserDefaults.standard.object(forKey: "offline.lastSync") as? Date {
        didSet { UserDefaults.standard.set(lastSync, forKey: "offline.lastSync") }
    }

    static var thumbnailDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Prepboard/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func thumbnailFile(_ id: String) -> URL { thumbnailDir.appendingPathComponent("\(id).jpg") }

    /// Every video saved anywhere (study sessions and practice problems).
    static func allVideos(_ context: ModelContext) -> [Video] {
        let tasks = (try? context.fetch(FetchDescriptor<PrepTask>())) ?? []
        let problems = (try? context.fetch(FetchDescriptor<Problem>())) ?? []
        var seen = Set<String>()
        return (tasks.flatMap(\.videos) + problems.flatMap(\.videos)).filter { seen.insert($0.id).inserted }
    }

    /// What is ready without signal, for the Offline card: (PDFs on device, all PDFs, thumbnails on device, all videos).
    func coverage(_ context: ModelContext) -> (pdfs: Int, pdfTotal: Int, thumbs: Int, videoTotal: Int) {
        let pdfs = ((try? context.fetch(FetchDescriptor<Doc>())) ?? []).filter(\.isPDF)
        let videos = Self.allVideos(context)
        return (pdfs.filter { Cloud.hasLocalPDF($0) }.count, pdfs.count,
                videos.filter { FileManager.default.fileExists(atPath: Self.thumbnailFile($0.id).path) }.count, videos.count)
    }

    /// Downloads whatever is missing. Safe to call often: files already on the device are skipped.
    func downloadAll(context: ModelContext, cloud: Cloud) async {
        guard !downloading else { return }
        let pdfs = ((try? context.fetch(FetchDescriptor<Doc>())) ?? []).filter { $0.isPDF && !Cloud.hasLocalPDF($0) }
        let videos = Self.allVideos(context).filter { !FileManager.default.fileExists(atPath: Self.thumbnailFile($0.id).path) }
        total = pdfs.count + videos.count; done = 0; lastError = nil
        guard total > 0 else { lastSync = .now; return }
        downloading = true
        defer { downloading = false }
        for doc in pdfs {
            do { _ = try await cloud.pdfData(for: doc) } catch { lastError = "Couldn't download \(doc.title): \(error.localizedDescription)" }
            done += 1
        }
        for v in videos {
            if let (data, response) = try? await URLSession.shared.data(from: v.thumbnailURL),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                try? data.write(to: Self.thumbnailFile(v.id), options: .atomic)
            }
            done += 1
        }
        lastSync = .now
    }
}
