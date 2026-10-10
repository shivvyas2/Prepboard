import Foundation
import Observation
import Supabase
import SwiftData

/// Supabase connection. The anon key is public by design; Row Level Security protects each user's rows.
/// Leave both empty to run Prepboard locally without accounts.
enum CloudConfig {
    static let url = "https://abxwxpwhkcqtotjqsmxb.supabase.co"
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFieHd4cHdoa2NxdG90anFzbXhiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY0NTYxMjQsImV4cCI6MjEwMjAzMjEyNH0.YCUZsaqsn7iQuOQIvcWqX9QwhrokZTGoB6XIVOfSIYo"
    /// Launch with `-PrepboardLocalOnly YES` to run without accounts (development/testing).
    static var isConfigured: Bool { !url.isEmpty && !anonKey.isEmpty && !UserDefaults.standard.bool(forKey: "PrepboardLocalOnly") }
}

// MARK: - Row types (match supabase/migrations/*_prepboard.sql)

struct RoleRow: Codable {
    var user_id: UUID?
    var id: String
    var company, title, team, location, role_number, salary, link, stage: String
    var interview_at: String?
    var interview_note, notes: String
    var created_at: String?
    var updated_at: String?
}

struct CloudDocRow: Codable {
    var user_id: UUID?
    var id: String
    var role_id, title, body: String
    var tags: [String]
    var sort_order: Int
    var file_type: String?
    var file_path: String?
    var updated_at: String?
}

struct RefRow: Codable, Hashable { var doc: String; var heading: String }

struct SessionRow: Codable {
    var user_id: UUID?
    var id: String
    var role_id, title: String
    var start_at, end_at: String
    var kind: String
    var refs: [RefRow]
    var videos: [Video]
    var done: Bool
    var updated_at: String?
}

struct QuizRow: Codable {
    var user_id: UUID?
    var id: String
    var role_id, session_id, topic: String
    var score, total: Int
    var items: [QuizItem]
    var weak_topics: [String]
    var source: String
    var created_at: String?
    var updated_at: String?
}

struct ProblemRow: Codable {
    var user_id: UUID?
    var id: String
    var role_id, title, difficulty: String
    var topics: [String]
    var statement: String
    var starters, code: [String: String]
    var language: String
    var solved: Bool
    var notes: String
    var videos: [Video]?
    var created_at: String?
    var updated_at: String?
}

struct ProfileRow: Codable {
    var user_id: UUID?
    var name, headline: String
    var avatar: Int
    var photo: String
    var updated_at: String?
}

enum Stamp {
    static func string(_ d: Date?) -> String? { d.map { DateCoding.string($0) } }
    /// Postgres returns microseconds ("…:01.123456+00:00"); trim to what ISO8601DateFormatter accepts.
    static func date(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        if let dot = s.firstIndex(of: "."), let end = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            s.removeSubrange(dot..<end)
        }
        return DateCoding.date(s)
    }
}

// MARK: - Cloud service

@MainActor
@Observable
final class Cloud {
    enum Status: String { case local = "Local only", syncing = "Syncing…", synced = "Synced", error = "Sync error", offline = "Offline" }

    let client: SupabaseClient?
    private(set) var user: User?
    private(set) var ready = false               // auth state resolved
    var needsOnboarding = false                  // new, empty account → open "Start something new"
    var status: Status = .local
    var lastError: String?

    private var container: ModelContainer?
    private weak var profile: Profile?
    private var synced: SyncSnapshot?
    private var pushTask: Task<Void, Never>?
    private var pushing = false
    private var applyingRemote = false

    var configured: Bool { client != nil }

    init() {
        if CloudConfig.isConfigured, let url = URL(string: CloudConfig.url) {
            // Implicit flow: reset links open the web app, which must finish them without a PKCE verifier from this device.
            client = SupabaseClient(supabaseURL: url, supabaseKey: CloudConfig.anonKey,
                                    options: .init(auth: .init(flowType: .implicit)))
        } else {
            client = nil
            ready = true
        }
    }

    func attach(container: ModelContainer, profile: Profile) {
        self.container = container
        self.profile = profile
        profile.onChange = { [weak self] in self?.schedulePush() }
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.schedulePush() }
        }
        guard let client else { return }
        Task {
            for await (event, session) in client.auth.authStateChanges {
                switch event {
                case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                    if let session, user?.id != session.user.id { await start(session.user) }
                case .signedOut:
                    stop()
                default: break
                }
                ready = true
            }
        }
    }

    // MARK: auth

    func signIn(email: String, password: String) async throws {
        try await client?.auth.signIn(email: email, password: password)
    }

    /// Emails a 6-digit code. Works for new and existing accounts (the account is created on first verify).
    func sendCode(email: String) async throws {
        try await client?.auth.signInWithOTP(email: email, shouldCreateUser: true)
    }

    func verifyCode(email: String, code: String) async throws {
        guard let client else { return }
        do {
            try await client.auth.verifyOTP(email: email, token: code, type: .email)
        } catch {
            // A brand-new account's first code is a signup confirmation.
            try await client.auth.verifyOTP(email: email, token: code, type: .signup)
        }
    }

    /// The reset link opens the web app, which sets the new password; then sign in here.
    func sendResetLink(email: String) async throws {
        try await client?.auth.resetPasswordForEmail(email, redirectTo: URL(string: "https://prepboard.shivvyas.com/"))
    }

    func signOut() async {
        await push()
        try? await client?.auth.signOut()
    }

    // MARK: session lifecycle

    private func start(_ u: User) async {
        user = u
        status = .syncing
        guard let context = container?.mainContext else { return }
        do {
            let remote = try await pull()
            if remote.isEmpty {
                // New account: start empty (nothing from other accounts or earlier sessions) and open the planner.
                applyingRemote = true
                try remote.apply(to: context, profile: nil)
                applyingRemote = false
                synced = SyncSnapshot(context: context, profile: profile)
                status = .synced
                needsOnboarding = true
            } else {
                applyingRemote = true
                try remote.apply(to: context, profile: profile)
                applyingRemote = false
                synced = SyncSnapshot(context: context, profile: profile)
                status = .synced
            }
        } catch {
            applyingRemote = false
            report(error)
            if let ctx = container?.mainContext { synced = synced ?? SyncSnapshot(context: ctx, profile: profile) }
        }
    }

    private func stop() {
        user = nil
        synced = nil
        status = configured ? .local : .local
        if let context = container?.mainContext {
            try? context.delete(model: Role.self)
            try? context.delete(model: Doc.self)
            try? context.delete(model: PrepTask.self)
            try? context.delete(model: QuizAttempt.self)
            try? context.save()
        }
    }

    // MARK: sync

    func schedulePush() {
        guard user != nil, !applyingRemote else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.push()
        }
    }

    func refresh() async {
        guard user != nil, let context = container?.mainContext else { return }
        await push()
        do {
            let remote = try await pull()
            applyingRemote = true
            try remote.apply(to: context, profile: profile)
            applyingRemote = false
            synced = SyncSnapshot(context: context, profile: profile)
            status = .synced
        } catch { applyingRemote = false; report(error) }
    }

    private func pull() async throws -> RemoteData {
        guard let client, let user else { throw URLError(.userAuthenticationRequired) }
        async let roles: [RoleRow] = client.from("pb_roles").select().execute().value
        async let docs: [CloudDocRow] = client.from("pb_docs").select().execute().value
        async let sessions: [SessionRow] = client.from("pb_sessions").select().execute().value
        async let profiles: [ProfileRow] = client.from("pb_profiles").select().eq("user_id", value: user.id).execute().value
        async let quizzes: [QuizRow] = client.from("pb_quiz_attempts").select().order("created_at", ascending: false).limit(500).execute().value
        async let problems: [ProblemRow] = client.from("pb_problems").select().execute().value
        return try await RemoteData(roles: roles, docs: docs, sessions: sessions, quizzes: quizzes, problems: problems, profile: profiles.first)
    }

    func push() async {
        guard let client, let user, let context = container?.mainContext, var base = synced else { return }
        if pushing { schedulePush(); return }
        pushing = true
        status = .syncing
        defer { pushing = false }
        do {
            let now = SyncSnapshot(context: context, profile: profile)
            let stamp = DateCoding.string(.now)

            let roleRows = now.roles.filter { base.roles[$0.key] != $0.value }.compactMap { now.roleRows[$0.key] }
                .map { r -> RoleRow in var r = r; r.user_id = user.id; r.updated_at = stamp; return r }
            let docRows = now.docs.filter { base.docs[$0.key] != $0.value }.compactMap { now.docRows[$0.key] }
                .map { r -> CloudDocRow in var r = r; r.user_id = user.id; r.updated_at = stamp; return r }
            let sessionRows = now.sessions.filter { base.sessions[$0.key] != $0.value }.compactMap { now.sessionRows[$0.key] }
                .map { r -> SessionRow in var r = r; r.user_id = user.id; r.updated_at = stamp; return r }

            if !roleRows.isEmpty { try await client.from("pb_roles").upsert(roleRows, onConflict: "user_id,id").execute() }
            if !docRows.isEmpty { try await client.from("pb_docs").upsert(docRows, onConflict: "user_id,id").execute() }
            if !sessionRows.isEmpty { try await client.from("pb_sessions").upsert(sessionRows, onConflict: "user_id,id").execute() }
            let quizRows = now.quizzes.filter { base.quizzes[$0.key] != $0.value }.compactMap { now.quizRows[$0.key] }
                .map { r -> QuizRow in var r = r; r.user_id = user.id; r.updated_at = stamp; return r }
            if !quizRows.isEmpty { try await client.from("pb_quiz_attempts").upsert(quizRows, onConflict: "user_id,id").execute() }
            let problemRows = now.problems.filter { base.problems[$0.key] != $0.value }.compactMap { now.problemRows[$0.key] }
                .map { r -> ProblemRow in var r = r; r.user_id = user.id; r.updated_at = stamp; return r }
            if !problemRows.isEmpty { try await client.from("pb_problems").upsert(problemRows, onConflict: "user_id,id").execute() }

            for (table, removed) in [("pb_roles", Set(base.roles.keys).subtracting(now.roles.keys)),
                                     ("pb_docs", Set(base.docs.keys).subtracting(now.docs.keys)),
                                     ("pb_sessions", Set(base.sessions.keys).subtracting(now.sessions.keys)),
                                     ("pb_quiz_attempts", Set(base.quizzes.keys).subtracting(now.quizzes.keys)),
                                     ("pb_problems", Set(base.problems.keys).subtracting(now.problems.keys))] where !removed.isEmpty {
                try await client.from(table).delete().eq("user_id", value: user.id).in("id", values: Array(removed)).execute()
            }
            if now.profileJSON != base.profileJSON, var p = now.profileRow {
                p.user_id = user.id; p.updated_at = stamp
                try await client.from("pb_profiles").upsert(p).execute()
            }
            base = now
            synced = base
            status = .synced
            lastError = nil
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        lastError = error.localizedDescription
        status = (error as? URLError)?.code == .notConnectedToInternet ? .offline : .error
    }

    // MARK: files (PDFs in the private "pb-files" bucket, cached on device)

    static let bucket = "pb-files"

    private static func cacheURL(_ docId: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Prepboard/files", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(docId).pdf")
    }

    func pdfData(for doc: Doc) async throws -> Data {
        let local = Self.cacheURL(doc.id)
        if let data = try? Data(contentsOf: local) { return data }
        guard let client, user != nil, !doc.filePath.isEmpty else {
            throw Learning.Failure.message("This PDF is stored in your account. Sign in to view it.")
        }
        let data = try await client.storage.from(Self.bucket).download(path: doc.filePath)
        try? data.write(to: local)
        return data
    }

    /// Adds a PDF as a document: cached locally, and uploaded to the account when signed in.
    @discardableResult
    func importPDF(_ data: Data, fileName: String, roleId: String, context: ModelContext) async throws -> Doc {
        let doc = Doc(roleId: roleId, title: (fileName as NSString).deletingPathExtension, body: "", tags: ["pdf"], order: 950)
        doc.fileType = "pdf"
        try data.write(to: Self.cacheURL(doc.id))
        if let client, let user {
            let path = "\(user.id.uuidString.lowercased())/\(doc.id).pdf"
            _ = try await client.storage.from(Self.bucket).upload(path, data: data, options: FileOptions(contentType: "application/pdf", upsert: true))
            doc.filePath = path
        }
        context.insert(doc)
        try context.save()
        return doc
    }

    func deleteFile(for doc: Doc) async {
        try? FileManager.default.removeItem(at: Self.cacheURL(doc.id))
        if let client, user != nil, !doc.filePath.isEmpty {
            _ = try? await client.storage.from(Self.bucket).remove(paths: [doc.filePath])
        }
    }

    // MARK: planner function

    func invoke<Body: Encodable, Response: Decodable>(_ body: Body) async throws -> Response {
        guard let client else { throw PlannerError.notConfigured }
        do {
            return try await client.functions.invoke("prep-chat", options: FunctionInvokeOptions(body: body))
        } catch let FunctionsError.httpError(_, data) {
            // Surface the function's own error message ({"error": "..."}) instead of a generic status error.
            let msg = (try? JSONDecoder().decode(FunctionErrorBody.self, from: data))?.error ?? "The server couldn't complete that request."
            throw Learning.Failure.message(msg)
        }
    }
}

private struct FunctionErrorBody: Decodable { let error: String? }

enum PlannerError: LocalizedError {
    case notConfigured
    var errorDescription: String? { "Connect your Supabase project (CloudConfig in Cloud.swift) to use the planner." }
}

// MARK: - Snapshots

/// What was last synced, as one JSON string per row, so a push only sends changed rows.
struct SyncSnapshot {
    var roles: [String: String] = [:], docs: [String: String] = [:], sessions: [String: String] = [:], quizzes: [String: String] = [:]
    var quizRows: [String: QuizRow] = [:]
    var problems: [String: String] = [:], problemRows: [String: ProblemRow] = [:]
    var roleRows: [String: RoleRow] = [:], docRows: [String: CloudDocRow] = [:], sessionRows: [String: SessionRow] = [:]
    var profileJSON: String = ""
    var profileRow: ProfileRow?

    init() {}

    @MainActor
    init(context: ModelContext, profile: Profile?) {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        func key<T: Encodable>(_ v: T) -> String { String(decoding: (try? enc.encode(v)) ?? Data(), as: UTF8.self) }
        for r in (try? context.fetch(FetchDescriptor<Role>())) ?? [] {
            let row = RoleRow(id: r.id, company: r.company, title: r.title, team: r.team, location: r.location, role_number: r.roleNumber,
                              salary: r.salary, link: r.link, stage: r.stageRaw, interview_at: Stamp.string(r.interviewAt),
                              interview_note: r.interviewNote, notes: r.notes, created_at: Stamp.string(r.createdAt))
            roleRows[r.id] = row; roles[r.id] = key(row)
        }
        for d in (try? context.fetch(FetchDescriptor<Doc>())) ?? [] {
            let row = CloudDocRow(id: d.id, role_id: d.roleId, title: d.title, body: d.body, tags: d.tags, sort_order: d.order,
                                  file_type: d.fileType, file_path: d.filePath)
            docRows[d.id] = row; docs[d.id] = key(row)
        }
        for t in (try? context.fetch(FetchDescriptor<PrepTask>())) ?? [] {
            let row = SessionRow(id: t.id, role_id: t.roleId, title: t.title, start_at: DateCoding.string(t.start), end_at: DateCoding.string(t.end),
                                 kind: t.kindRaw, refs: t.refs.map { RefRow(doc: $0.docId, heading: $0.heading) }, videos: t.videos, done: t.done)
            sessionRows[t.id] = row; sessions[t.id] = key(row)
        }
        for q in (try? context.fetch(FetchDescriptor<QuizAttempt>())) ?? [] {
            let row = QuizRow(id: q.id, role_id: q.roleId, session_id: q.sessionId, topic: q.topic, score: q.score, total: q.total,
                              items: q.items, weak_topics: q.weakTopics, source: q.source, created_at: Stamp.string(q.createdAt))
            quizRows[q.id] = row; quizzes[q.id] = key(row)
        }
        for p in (try? context.fetch(FetchDescriptor<Problem>())) ?? [] {
            let row = ProblemRow(id: p.id, role_id: p.roleId, title: p.title, difficulty: p.difficulty, topics: p.topics, statement: p.statement,
                                 starters: p.starters, code: p.code, language: p.language, solved: p.solved, notes: p.notes,
                                 videos: p.videos, created_at: Stamp.string(p.createdAt))
            problemRows[p.id] = row; problems[p.id] = key(row)
        }
        if let profile {
            let row = ProfileRow(name: profile.name, headline: profile.headline, avatar: profile.avatar,
                                 photo: profile.photo.map { "data:image/jpeg;base64," + $0.base64EncodedString() } ?? "")
            profileRow = row; profileJSON = key(row)
        }
    }
}

struct RemoteData {
    let roles: [RoleRow], docs: [CloudDocRow], sessions: [SessionRow], quizzes: [QuizRow], problems: [ProblemRow], profile: ProfileRow?
    var isEmpty: Bool { roles.isEmpty && docs.isEmpty && sessions.isEmpty && quizzes.isEmpty && problems.isEmpty }

    /// Replaces the local store with the account's data.
    @MainActor
    func apply(to context: ModelContext, profile: Profile?) throws {
        try context.delete(model: Role.self)
        try context.delete(model: Doc.self)
        try context.delete(model: PrepTask.self)
        try context.delete(model: QuizAttempt.self)
        try context.delete(model: Problem.self)
        for p in problems {
            let problem = Problem(id: p.id, roleId: p.role_id, title: p.title, difficulty: p.difficulty, topics: p.topics, statement: p.statement,
                                  starters: p.starters, code: p.code, language: p.language, solved: p.solved, notes: p.notes,
                                  createdAt: Stamp.date(p.created_at) ?? .now, updatedAt: Stamp.date(p.updated_at) ?? .now)
            problem.videos = p.videos ?? []
            context.insert(problem)
        }
        for q in quizzes {
            context.insert(QuizAttempt(id: q.id, roleId: q.role_id, sessionId: q.session_id, topic: q.topic, items: q.items,
                                       source: q.source, createdAt: Stamp.date(q.created_at) ?? .now))
        }
        for r in roles {
            context.insert(Role(id: r.id, company: r.company, title: r.title, team: r.team, location: r.location, roleNumber: r.role_number,
                                salary: r.salary, link: r.link, stage: Stage(rawValue: r.stage) ?? .saved, interviewAt: Stamp.date(r.interview_at),
                                interviewNote: r.interview_note, notes: r.notes, createdAt: Stamp.date(r.created_at) ?? .now))
        }
        for d in docs {
            let doc = Doc(id: d.id, roleId: d.role_id, title: d.title, body: d.body, tags: d.tags,
                          updatedAt: Stamp.date(d.updated_at) ?? .now, order: d.sort_order)
            doc.fileType = d.file_type ?? "md"
            doc.filePath = d.file_path ?? ""
            context.insert(doc)
        }
        for s in sessions {
            guard let start = Stamp.date(s.start_at), let end = Stamp.date(s.end_at) else { continue }
            let task = PrepTask(id: s.id, roleId: s.role_id, title: s.title, start: start, end: end,
                                kind: SessionKind(rawValue: s.kind) ?? .study,
                                refs: s.refs.map { DocRef(docId: $0.doc, heading: $0.heading) }, done: s.done)
            task.videos = s.videos
            context.insert(task)
        }
        try context.save()
        if let p = self.profile, let profile {
            profile.applyRemote(name: p.name, headline: p.headline, avatar: p.avatar, photoDataURL: p.photo)
        }
    }
}
