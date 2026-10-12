# Job Hunt: find roles, tailor the résumé, apply with one tap

## Goal
Every day the Mac finds jobs for the user (LinkedIn *Recommended for you*, LinkedIn search for the user's target companies and regions, and those companies' careers sites), writes a keyword-matched résumé variant for each good match from the user's own `.tex` résumé variants, fills the application, and stops before Submit. The user reviews each application on any device and submits with one tap. Submitted applications become Roles; when a Role reaches Technical, Onsite or Offer, the variant that was sent counts as a *winner* and becomes the preferred base for the next variants.

## Decisions (agreed with the user)
- **Review queue, never fully automatic.** Submit always needs the user's tap. There is no setting to turn that off in v1.
- **Winners come from the Roles stage.** Every submitted application records which variant was sent. Technical, Onsite or Offer makes that variant a winner. The user tags past winners once (for example `Shiv-Vyas-Apple-ScreenSharing-SDE`) by setting *Résumé variant* on the Role.
- **Sources:** LinkedIn Recommended, LinkedIn company search, company careers sites. Discovery reads at human pace, never presses Easy Apply, and caps itself at about 150 listings per run.
- **Schedule:** once a day at a chosen hour while the Mac is awake, plus *Run now*. Up to **30 tailored résumés per day**, up to **30 submits per day**, submits at least 2 minutes apart, one at a time.
- **Honesty:** every claim in a new variant must already appear in an existing variant or in the user's GitHub material. Requirements with no evidence go in the variant's honesty ledger as "not claimed". A second pass checks the new file and sends anything untraceable back to the user.
- **Legal answers** (work authorization, sponsorship, EEO, salary) come only from the Answer Bank, never drafted.
- **Native only in v1.** The Mac runs the pipeline; iPhone and iPad see the queue through Supabase and can request a submit. The web app is unchanged.
- **Out of scope:** cover letters, recruiter follow-ups, cloud discovery.

## Where things live on disk
- Résumé variants: `~/Documents/Career/Resumes (Downloads)` (the user's `.tex` files; each starts with a comment header holding a `… VARIANT:` line, a `JD MAP:` block and a `HONESTY LEDGER:` block). New variants are written to the same folder as `Shiv-Vyas-<Company>-<RoleTag>.tex` plus the built `.pdf`.
- `tectonic` builds PDFs (`/usr/local/bin/tectonic`, found through `ClaudeCode.searchPath`).
- Claude Code runs headless like `JobSync` does: `claude -p --chrome --output-format json --json-schema … --allowedTools …` through `ClaudeCode.shell`.

## Data (SwiftData models in `Models.swift`, synced through `Cloud.swift`, tables in `supabase/migrations/20261012120000_prepboard_hunt.sql`)

### `Role` gains one field
```swift
var resumeVariant: String = ""   // file name without extension of the .tex variant sent, e.g. "Shiv-Vyas-Apple-ScreenSharing-SDE"
```
Column `resume_variant text not null default ''` on `pb_roles`; `RoleRow.resume_variant: String?`; synced in `SyncSnapshot`, `merge`, `apply`, `makeRole`. `source` may now also be `"hunt"`.

### `Lead` — one discovered job
```swift
enum LeadStatus: String, CaseIterable, Codable {
    case new, tailoring, ready, needsYou = "needs_you", submitting, submitted, skipped, failed
}

@Model final class Lead {
    @Attribute(.unique) var id: String            // "lead-" + 8 hex
    var company, title, location, link: String
    var roleNumber: String                        // posting id if visible, else ""
    var source: String                            // "linkedin-rec" | "linkedin-search" | "careers"
    var jd: String                                // full job description text
    var score: Int                                // 0–100
    var scoreReason: String                       // one line
    var statusRaw: String                         // LeadStatus
    var baseVariant: String                       // file name (no extension) of the base .tex, "" until tailored
    var baseReason: String                        // why that base was picked
    var variantName: String                       // file name (no extension) of the generated .tex, "" until tailored
    var pdfDocId: String                          // Doc id of the built PDF (uploaded so every device can view it), "" until built
    var coverageJSON: Data                        // [Coverage] — JD terms and whether the new variant covers them
    var answersJSON: Data                         // [FormAnswer] — planned answers for the application form
    var flagged: String                           // newline-separated questions/blocks that need the user
    var reason: String                            // last status reason / error (shown on the card)
    var roleId: String                            // Role created on submit, else ""
    var submitRequested: Bool                     // set from any device; the Mac submits
    var foundAt: Date
    var updatedAt: Date
    // computed: status (get/set LeadStatus), coverage: [Coverage], answers: [FormAnswer] (JSON get/set)
}

struct Coverage: Codable, Hashable { var term: String; var covered: Bool }
struct FormAnswer: Codable, Hashable {
    var question: String
    var answer: String
    var kind: String        // "bank" (from Answer Bank) | "drafted" (job-specific, Claude wrote it) | "needs_you"
    var required: Bool
}
```
Table `pb_leads` (`user_id uuid`, `id text`, all columns above in snake_case; `coverage jsonb`, `answers jsonb`, `status text` with a check on the enum values, `found_at`, `updated_at`; primary key `(user_id, id)`; owner-only RLS like the other tables).

### `HuntSettings` — one record, id `"hunt"`
```swift
@Model final class HuntSettings {
    @Attribute(.unique) var id: String = "hunt"
    var regions: [String]          // "United States", "United States / New York", "United States / California"
    var companies: [String]        // "Apple", "Google", or "Apple | https://jobs.apple.com/en-us/search?…" (name, optional careers URL after " | ")
    var keywords: [String]         // "iOS Engineer", "Software Development Engineer", "Full Stack"
    var auto: Bool                 // daily run on/off
    var runHour: Int               // 0–23 local, default 8
    var minScore: Int              // default 60
    var dailyTailorLimit: Int      // default 30
    var dailySubmitLimit: Int      // default 30
    var resumeFolder: String       // Mac path; default "~/Documents/Career/Resumes (Downloads)" expanded
    var answersJSON: Data          // AnswerBank
    var updatedAt: Date
    // computed: answerBank: AnswerBank (JSON get/set)
}

struct AnswerBank: Codable, Equatable {
    var fullName = "", email = "", phone = "", city = ""
    var linkedin = "", github = "", portfolio = ""
    var workAuthorization = ""      // e.g. "Authorized to work in the US (F-1 OPT)"
    var needsSponsorship = ""       // "Yes" | "No" | ""
    var startDate = ""
    var relocation = ""             // "Yes" | "No" | "Open to it"
    var salary = ""                 // "" = decline / leave blank
    var gender = "", race = "", veteran = "", disability = ""   // "" = decline to answer
    var saved: [String: String] = [:]   // reusable free-text answers keyed by question
    var isComplete: Bool { !fullName.isEmpty && !email.isEmpty && !phone.isEmpty && !workAuthorization.isEmpty && !needsSponsorship.isEmpty }
}
```
Table `pb_hunt_settings` (`user_id uuid primary key`, columns above; `regions/companies/keywords text[]`, `answers jsonb`). Synced like the profile row (one row per user, upsert on change).

## Components

### `ResumeLibrary.swift` (all platforms for the pure logic; folder scanning is Mac-only)
```swift
struct ResumeVariant: Identifiable, Hashable {
    var id: String { name }
    var name: String            // file name without extension
    var path: String
    var company: String         // from "APPLE VARIANT:" → "Apple"; "" if no VARIANT line
    var roleTag: String         // rest of the VARIANT line, e.g. "Software Development Engineer, Screen Sharing Experiences"
    var family: String          // see ResumeLibrary.family(of:)
    var jdMap: [String]         // bullet lines of the JD MAP block
    var ledger: [String]        // bullet lines of the HONESTY LEDGER block
    var modified: Date
}

enum ResumeLibrary {
    /// "ios" | "fullstack" | "frontend" | "reactnative" | "backend" | "sde" from a title or role tag (lowercased keyword match; "react native" before "frontend"; "ios|swift|mobile|apple platforms" → ios; "full stack|fullstack|full-stack" → fullstack; "front end|frontend|react|web" → frontend; "backend|back end|distributed|infrastructure|platform" → backend; else "sde").
    static func family(of text: String) -> String
    /// Parses the comment header of one .tex file (the leading lines that start with "%").
    static func parse(name: String, path: String, header: String, modified: Date) -> ResumeVariant
    /// Winners: variant names attached to roles whose stage is Technical, Onsite or Offer.
    static func winners(roles: [Role]) -> Set<String>
    /// Base-variant choice, in order: a winner with the same company (JobMerge.key equality) and family; a winner with the same family; any variant with the same company and family; the variant with the most JD-MAP/roleTag keyword overlap with the lead's title + jd (ties → most recently modified). Returns (variant, reason).
    static func pickBase(for lead: Lead, variants: [ResumeVariant], winners: Set<String>) -> (ResumeVariant, String)?
    /// Dedupe key for a lead: JobMerge.key(company) + "|" + (roleNumber non-empty ? roleNumber : JobMerge.key(title)).
    static func dedupeKey(company: String, title: String, roleNumber: String) -> String
    /// "Shiv-Vyas-<Company>-<RoleTag>" style name: "<first two words of the user's name joined with '-'>-<Company letters/digits>-<up to three CamelCase words from the title>", unique against existing names by appending -2, -3…
    static func variantName(userName: String, company: String, title: String, existing: Set<String>) -> String
    #if os(macOS)
    static func scan(folder: String) throws -> [ResumeVariant]      // reads every *.tex in the folder (not subfolders), parses headers
    #endif
}
```

### `LatexBuild.swift` (Mac)
```swift
enum LatexBuild {
    struct Failure: Error { var log: String }
    /// Runs `tectonic <file>` in the file's folder through ClaudeCode.shell; returns the PDF path or throws Failure with the tail of the log.
    static func build(texPath: String) async throws -> String
}
```

### `JobHunt.swift` (Mac) — the orchestrator, modelled on `JobSync`
```swift
@MainActor @Observable final class JobHunt {
    enum Phase: Equatable { case idle, discovering, tailoring(done: Int, total: Int), submitting(String), honesty(String) }
    private(set) var phase: Phase
    private(set) var lastRun: Date?        // UserDefaults "hunt.lastRun"
    private(set) var lastSummary: String?  // UserDefaults "hunt.summary"
    var error: String?
    private(set) var variants: [ResumeVariant]   // last scan of the folder

    func attach(container: ModelContainer, claude: ClaudeCode, cloud: Cloud, github: GitHub)
    // Timer every 5 min: runIfDue() → starts a run when settings.auto, Claude is ready, and today's runHour has passed with no run today.
    // Timer every 60 s: processSubmitQueue() → for leads with submitRequested && status == .ready, submit one at a time, ≥ 2 min apart, ≤ dailySubmitLimit per day.
    func run() async                 // discover → tailor each new lead ≥ minScore (≤ dailyTailorLimit) → mark ready / needsYou / failed
    func rescan()                    // refresh `variants` from settings.resumeFolder
    func tailor(_ lead: Lead) async  // also used by "Regenerate" on a card
    func submit(_ lead: Lead) async  // the only place that presses Submit
    func skip(_ lead: Lead)          // status = skipped (all platforms do this directly on the model; here for symmetry)
}
```
Claude runs (each a `claude -p` call with a JSON schema, like `JobSync.check`):
1. **Discover** (`--chrome`; tools: Chrome read/navigate/find/get_page_text/computer only). Prompt lists regions, companies (with careers URLs), keywords, the variant index (name, family, company, roleTag, first 6 JD MAP lines), already-known dedupe keys (leads + roles), and the rules: read only, human pace, never Easy Apply, ≤ 150 listings, open each promising posting to copy the full JD. Returns `{leads: [{company, title, location, link, role_number, source, jd, score, score_reason}], notes}`. Swift dedupes against existing Leads/Roles with `ResumeLibrary.dedupeKey`, inserts `Lead`s with `status = .new`, auto-skips `score < minScore` (`status = .skipped`, reason "Below match threshold").
2. **Tailor** (no Chrome; tools `Read Grep Glob`; cwd = resume folder). Input: the lead's JD, the base variant's full `.tex`, the names of the other variants (Claude may Read them for evidence), `GitHub.context` if loaded, the answer bank's non-legal facts, the variant name to use. Output `{tex, coverage: [{term, covered}], answers: [{question, answer, kind, required}], ledger: [string], notes}`. Rules in the prompt: keep the base's preamble and macros unchanged, keep the comment-header convention (VARIANT line, JD MAP, HONESTY LEDGER), reuse only claims found in the variants or GitHub material, never invent numbers, no emoji; `answers` are only for questions visible in the JD/listing and are `kind: "drafted"`; legal questions are `kind: "needs_you"` with an empty answer. Swift writes `<variantName>.tex`, runs `LatexBuild.build`; on failure retries Tailor once with the compile log appended; on second failure `status = .failed`. On success the PDF is imported with `Cloud.importPDF(data, fileName:, roleId: "", context:)` (tags `["pdf", "resume", "hunt"]`) and `pdfDocId` set.
3. **Honesty check** (tools `Read Grep Glob`; cwd = resume folder). Input: the new `.tex`, list of source variant names, GitHub context. Output `{ok, untraceable: [string]}`. Any untraceable bullet → `status = .needsYou`, `flagged` lists them, `reason = "Check these claims"`. Otherwise answers are merged with the Answer Bank (`kind: "bank"` for name/email/phone/links/work authorization/sponsorship/relocation/start date/EEO; `needs_you` if the bank value is empty) and `status = .ready`.
4. **Submit** (`--chrome`; Chrome tools including `form_input`, `file_upload`, `computer`). Input: the posting link, the PDF path, the approved `answers`, the rule "fill every field from the answers given; upload the PDF; press Submit only if every required field has an answer from this list; if there is a question not in this list, a login wall, a CAPTCHA, an assessment, or anything unexpected, stop, leave the tab open and report needs_you". Output `{status: "submitted" | "needs_you" | "failed", reason, unknown_questions: [string], confirmation: string}`. On `submitted`: create a `Role` (company, title, location, link, roleNumber, stage `.applied`, `source = "hunt"`, `appliedAt = .now`, `resumeVariant = lead.variantName`, activity line `- yyyy-MM-dd · Hunt · Applied with <variant>`), set `lead.roleId`, `status = .submitted`. On `needs_you`: `status = .needsYou`, `flagged = unknown_questions`. Always clear `submitRequested`.

Daily counters (`hunt.tailored.<yyyy-MM-dd>`, `hunt.submitted.<yyyy-MM-dd>` in UserDefaults) enforce the limits. A per-company cooldown: skip a lead when a Role for the same company was applied to in the last 7 days unless the lead's `roleNumber` differs and is non-empty.

### UI
- `Section.hunt = "Hunt"`, icon `paperplane`, placed after `.roles`. `SectionContent` shows `HuntView`.
- **`HuntView.swift`** (all platforms): header "Applications / Hunt" with buttons *Settings* (opens `HuntSettingsSheet`) and, on the Mac, `HuntRunCard` (phase text, last run + summary, *Run now*, *Rescan résumés*, daily toggle). Lists in this order, each a card with a `CardHeader` and count: **Ready to submit**, **Needs you**, **In progress** (new/tailoring/submitting), **Submitted**, **Skipped** (collapsed by default, with *Show*). Empty state: "No jobs found yet. Run the hunt on your Mac."
- **`LeadCard`**: company — title, location, `Chip` with score, source, `scoreReason`; base variant and `baseReason`; coverage chips (covered = dark, missing = plain); the *Résumé* button opens the PDF with the existing `PDFDocView` for the `pdfDocId` Doc; *Answers* list (editable `PBTextField`s; editing writes back to `answersJSON`); `flagged` lines in red; buttons: **Submit** (`submitRequested = true`; disabled until every `required` answer is non-empty and no `needs_you` answers remain; label "Queued for your Mac" once requested), **Skip**, **Open posting**, and on the Mac **Regenerate**. Submitted cards show *Open role*.
- **`HuntSettingsSheet`**: regions, companies, keywords as editable lists (one per line `PBTextField` with `.vertical` axis is fine); daily toggle and hour; min score; daily limits; résumé folder (Mac: path + *Choose…* with `NSOpenPanel`); **Answer Bank** fields; **Résumé variants** (Mac): the scanned list with family, company and outcome (★ Winner / stage reached / —) and a *Rescan* button.
- **`RoleDetailView`**: a *Résumé variant* `PBTextField` in Details (Mac: a menu beside it listing scanned variant names).
- `PrepboardApp`: register `Lead.self, HuntSettings.self` in the container; create `JobHunt` on the Mac, inject it everywhere `jobSync` is injected, `attach` it after `jobSync.attach`. `Cloud.stop()` and `RemoteData.apply` also clear/replace `Lead` and `HuntSettings`.

## Error handling
Every stage writes `status` and `reason` on the lead. Claude Code not connected → the run doesn't start and `HuntRunCard` says so. LinkedIn signed out or a checkpoint page → Discover returns it in `notes`, the run stops, `error` tells the user to sign in to Chrome. `tectonic` fails twice → `failed` with the log tail in `reason`. A careers site that doesn't load → noted in `notes`, other sources continue.

## Testing (`native/PrepboardTests/HuntTests.swift`)
- `ResumeLibrary.parse`: company/roleTag/jdMap/ledger from the real header shape (sample header in the test).
- `family(of:)` for iOS / full stack / React Native / frontend / backend / default.
- `winners(roles:)`: only Technical/Onsite/Offer count.
- `pickBase`: winner same company+family beats winner same family beats same company beats keyword overlap; keyword overlap tie → newest.
- `dedupeKey` and `variantName` (uniqueness suffix).
- Lead `answers` gate: `Lead.canSubmit` is false with an empty required answer or any `needs_you`, true otherwise.
- JSON decoding of recorded sample outputs for the four schemas (`DiscoverResult`, `TailorResult`, `HonestyResult`, `SubmitResult`).
- `JobHunt.cooldownBlocks(lead:roles:now:)` pure helper for the 7-day rule.
