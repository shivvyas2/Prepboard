import XCTest
@testable import Prepboard

@MainActor
final class HuntTests: XCTestCase {
    // Lead and Role are built without a container: the helpers under test only read stored properties, and a second
    // ModelContainer for the same model classes traps inside the running app (the test host).

    private func variant(_ name: String, company: String = "", roleTag: String = "", jdMap: [String] = [], daysOld: Double = 30) -> ResumeVariant {
        ResumeVariant(name: name, path: "/tmp/\(name).tex", company: company, roleTag: roleTag, family: ResumeLibrary.family(of: roleTag),
                      jdMap: jdMap, ledger: [], modified: Date(timeIntervalSinceNow: -daysOld * 86400))
    }

    // MARK: header parsing

    static let appleHeader = """
    %-----------------------------------------------------------------------------------------------------------------------------------------------%
    %    The MIT License (MIT)
    %    Copyright (c) 2021 Jitin Nair
    %
    %    APPLE VARIANT: Software Development Engineer, Screen Sharing Experiences
    %    (iPhone Mirroring, Screen Sharing, Sidecar, FaceTime remote control).
    %    Role 200678056-0836, posted 20 Aug 2026. Built 26 Sep 2026.
    %
    %    SOURCE OF EVERY CLAIM: the repo audits recorded in the headers of the
    %    Wispr (15 Sep 2026) and DoorDash (10 Sep) variants in this folder.
    %
    %    JD MAP:
    %      * "Swift or Objective-C, 3+ years" -> Swift throughout; Feb 2023 to now
    %        is 3 years 7 months of software development (intern included).
    %      * "diagnose system issues through log analysis" -> VideoFailureLogger
    %        (KVO, error domain/code/underlying error).
    %      * "accessible apps" -> VoiceOver labels/hints/values, Dynamic Type.
    %
    %    HONESTY LEDGER (not claimed anywhere on the page):
    %      * OBJECTIVE-C: zero .m/.h files in any repo. If asked: "Swift throughout;
    %        I read Objective-C and have not shipped it."
    %      * ReplayKit, ScreenCaptureKit, VideoToolbox: none.
    %
    %    TODO, ONLY YOU CAN FIX:
    %      1. DATE OVERLAP: Futeur AI overlaps Contextual Intelligence.
    %
    %    ATS: single column, standard section names, no icons.
    %-----------------------------------------------------------------------------------------------------------------------------------------------%
    \\documentclass[letterpaper,10pt]{article}
    """

    func testParseRealHeaderShape() {
        let v = ResumeLibrary.parse(name: "Shiv-Vyas-Apple-ScreenSharing-SDE", path: "/x.tex", header: Self.appleHeader, modified: .now)
        XCTAssertEqual(v.company, "Apple")
        XCTAssertEqual(v.roleTag, "Software Development Engineer, Screen Sharing Experiences (iPhone Mirroring, Screen Sharing, Sidecar, FaceTime remote control). Role 200678056-0836, posted 20 Aug 2026. Built 26 Sep 2026.")
        XCTAssertEqual(v.family, "ios")
        XCTAssertEqual(v.jdMap.count, 3)
        XCTAssertEqual(v.jdMap[0], "\"Swift or Objective-C, 3+ years\" -> Swift throughout; Feb 2023 to now is 3 years 7 months of software development (intern included).")
        XCTAssertEqual(v.jdMap[2], "\"accessible apps\" -> VoiceOver labels/hints/values, Dynamic Type.")
        XCTAssertEqual(v.ledger.count, 2)
        XCTAssertTrue(v.ledger[0].hasPrefix("OBJECTIVE-C: zero .m/.h files"))
        XCTAssertTrue(v.ledger[0].hasSuffix("have not shipped it.\""))
        XCTAssertEqual(v.ledger[1], "ReplayKit, ScreenCaptureKit, VideoToolbox: none.")
        XCTAssertEqual(v.id, "Shiv-Vyas-Apple-ScreenSharing-SDE")
    }

    func testParseMultiWordCompanyInlineLedgerAndInitialism() {
        let gs = """
        %    GOLDMAN SACHS VARIANT: mid-level iOS Engineer, Marcus mobile team, AWM.
        %
        %    HONESTY LEDGER: no Objective-C, no gRPC, no GraphQL, no Realm or Core
        %    Data (SwiftData is named as SwiftData), no Fastlane.
        %------------------------------------------------------------%
        """
        let v = ResumeLibrary.parse(name: "gs", path: "", header: gs, modified: .now)
        XCTAssertEqual(v.company, "Goldman Sachs")
        XCTAssertEqual(v.roleTag, "mid-level iOS Engineer, Marcus mobile team, AWM.")
        XCTAssertEqual(v.jdMap, [])
        XCTAssertEqual(v.ledger, ["no Objective-C, no gRPC, no GraphQL, no Realm or Core Data (SwiftData is named as SwiftData), no Fastlane."])

        let jpmc = ResumeLibrary.parse(name: "j", path: "", header: "%    JPMC VARIANT: iOS Software Engineer III\n%    JD MAP (each line -> evidence):\n%      * one\n%      * two", modified: .now)
        XCTAssertEqual(jpmc.company, "JPMC")
        XCTAssertEqual(jpmc.jdMap, ["one", "two"])
        XCTAssertEqual(ResumeLibrary.parse(name: "n", path: "", header: "%    NEW YORK TIMES VARIANT: iOS Engineer", modified: .now).company, "New York Times")
    }

    func testParseWithoutVariantLine() {
        let v = ResumeLibrary.parse(name: "Shiv-Vyas-FullStack-React-RN", path: "", header: "%    FULL STACK REACT + REACT NATIVE VARIANT (consumer product), 11 Sept 2026\n%    JD MAP:\n%      * React", modified: .now)
        XCTAssertEqual(v.company, "")
        XCTAssertEqual(v.roleTag, "")
        XCTAssertEqual(v.jdMap, ["React"])
        XCTAssertEqual(v.family, "fullstack")   // from the file name when there is no role tag
        let none = ResumeLibrary.parse(name: "cover", path: "", header: "\\documentclass{article}", modified: .now)
        XCTAssertEqual(none.company, ""); XCTAssertTrue(none.jdMap.isEmpty && none.ledger.isEmpty)
    }

    func testParseHeadingsByPrefixWithAsideBeforeColon() {
        // JPMC / HorizonDB style: text before the colon, so the all-caps heading rule alone would miss it.
        let jpmc = """
        %    JPMORGAN CHASE VARIANT: iOS Software Engineer III, Consumer & Community Banking
        %
        %    BUILT FROM A DIRECT AUDIT of four codebases, not from the job title. Every
        %    number below was counted on 1 September 2026, and the honesty ledger at the
        %    bottom of this comment lists what the audit did NOT find.
        %
        %    HONESTY LEDGER, the things this page deliberately does NOT claim:
        %      * CORE DATA. Zero `import CoreData` across all four codebases. The JD asks
        %        for it. Life OS uses SwiftData.
        %      * XCUITEST AT WORK. All six XCUITest files were written by teammates.
        %
        %    ATS: single column.
        """
        let v = ResumeLibrary.parse(name: "jpmc", path: "", header: jpmc, modified: .now)
        XCTAssertEqual(v.company, "Jpmorgan Chase")
        XCTAssertEqual(v.roleTag, "iOS Software Engineer III, Consumer & Community Banking")
        XCTAssertEqual(v.ledger.count, 2)
        XCTAssertTrue(v.ledger[0].hasPrefix("CORE DATA. Zero") && v.ledger[0].hasSuffix("uses SwiftData."))
        XCTAssertEqual(v.ledger[1], "XCUITEST AT WORK. All six XCUITest files were written by teammates.")
        XCTAssertEqual(v.jdMap, [])
        // Case does not matter for the heading itself.
        let lower = ResumeLibrary.parse(name: "l", path: "", header: "%    X VARIANT: iOS\n%    jd map:\n%      * swift\n%    Honesty Ledger (short):\n%      * none", modified: .now)
        XCTAssertEqual(lower.jdMap, ["swift"]); XCTAssertEqual(lower.ledger, ["none"])
    }

    func testParseAccumulatesRepeatedBlocks() {
        // Google-SWE style: "JD MAP (minimum):" then "JD MAP (preferred):" are one map.
        let google = """
        %    GOOGLE VARIANT: Software Engineer (generalist, early career).
        %    Locations offered include New York, NY. Built 26 Sep 2026.
        %
        %    JD MAP (minimum):
        %      * Bachelor's in CS or similar -> BE Computer Engineering (plus MS CS).
        %      * AI productivity tools -> Claude Code and Cursor, spec-first delivery
        %        (Life OS 25 specs).
        %    JD MAP (preferred):
        %      * MS CS: yes. Web and mobile: yes.
        %
        %    NOT CLAIMED: C, C++, Java, Go.
        """
        let v = ResumeLibrary.parse(name: "g", path: "", header: google, modified: .now)
        XCTAssertEqual(v.company, "Google")
        XCTAssertEqual(v.jdMap.count, 3)
        XCTAssertEqual(v.jdMap[1], "AI productivity tools -> Claude Code and Cursor, spec-first delivery (Life OS 25 specs).")
        XCTAssertEqual(v.jdMap[2], "MS CS: yes. Web and mobile: yes.")
        XCTAssertEqual(v.ledger, [])
    }

    // MARK: classification and selection

    func testFamily() {
        XCTAssertEqual(ResumeLibrary.family(of: "iOS Engineer"), "ios")
        XCTAssertEqual(ResumeLibrary.family(of: "Mobile App Developer"), "ios")
        XCTAssertEqual(ResumeLibrary.family(of: "Software Engineer, Full Stack, Google Beam"), "fullstack")
        XCTAssertEqual(ResumeLibrary.family(of: "Front End Engineer (React Native)"), "reactnative")
        XCTAssertEqual(ResumeLibrary.family(of: "Frontend Engineer, Rights Systems"), "frontend")
        XCTAssertEqual(ResumeLibrary.family(of: "Backend Engineer, Distributed Systems"), "backend")
        XCTAssertEqual(ResumeLibrary.family(of: "Software Development Engineer II"), "sde")
        XCTAssertEqual(ResumeLibrary.family(of: "Curious engineer for Studios"), "sde")   // "ios" inside a word does not count
    }

    func testWinnersOnlyCountLateStages() {
        let pairs: [(Stage, String)] = [(.applied, "a"), (.recruiter, "b"), (.technical, "c"), (.onsite, "d"), (.offer, "e"), (.closed, "f"), (.offer, "")]
        let roles = pairs.map { Role(company: "X", title: "T", stage: $0.0) }
        for (r, p) in zip(roles, pairs) { r.resumeVariant = p.1 }
        XCTAssertEqual(ResumeLibrary.winners(roles: roles), ["c", "d", "e"])
    }

    func testPickBaseOrder() {
        let lead = Lead(company: "Apple", title: "iOS Engineer", jd: "SwiftUI Combine Firestore listeners and video playback")
        let appleIOS = variant("Shiv-Vyas-Apple-iOS", company: "Apple", roleTag: "iOS Engineer")
        let doordashIOS = variant("Shiv-Vyas-DoorDash-iOS", company: "DoorDash", roleTag: "iOS Engineer")
        let googleFull = variant("Shiv-Vyas-Google-FullStack", company: "Google", roleTag: "Full Stack", jdMap: ["SwiftUI Combine Firestore listeners video playback"])

        // Winner with the same company and family beats a winner with the same family.
        var pick = ResumeLibrary.pickBase(for: lead, variants: [doordashIOS, appleIOS], winners: ["Shiv-Vyas-Apple-iOS", "Shiv-Vyas-DoorDash-iOS"])
        XCTAssertEqual(pick?.0.name, "Shiv-Vyas-Apple-iOS"); XCTAssertEqual(pick?.1, "Winner at Apple for ios roles")
        // Winner with the same family beats a non-winner with the same company and family.
        pick = ResumeLibrary.pickBase(for: lead, variants: [appleIOS, doordashIOS], winners: ["Shiv-Vyas-DoorDash-iOS"])
        XCTAssertEqual(pick?.0.name, "Shiv-Vyas-DoorDash-iOS"); XCTAssertEqual(pick?.1, "Winner for ios roles")
        // Same company and family beats keyword overlap.
        pick = ResumeLibrary.pickBase(for: lead, variants: [googleFull, appleIOS], winners: [])
        XCTAssertEqual(pick?.0.name, "Shiv-Vyas-Apple-iOS"); XCTAssertEqual(pick?.1, "Earlier Apple ios variant")
        // Keyword overlap when nothing else matches.
        let kotlin = variant("Shiv-Vyas-Android", company: "Meta", roleTag: "Android Engineer", jdMap: ["Kotlin Compose Room"])
        pick = ResumeLibrary.pickBase(for: lead, variants: [kotlin, googleFull], winners: [])
        XCTAssertEqual(pick?.0.name, "Shiv-Vyas-Google-FullStack"); XCTAssertEqual(pick?.1, "Most keyword overlap with the posting (6 terms)")
        // Overlap tie goes to the most recently modified variant.
        let old = variant("old", company: "A", roleTag: "Backend", jdMap: ["SwiftUI"], daysOld: 90)
        let new = variant("new", company: "B", roleTag: "Backend", jdMap: ["SwiftUI"], daysOld: 1)
        XCTAssertEqual(ResumeLibrary.pickBase(for: lead, variants: [old, new], winners: [])?.0.name, "new")
        XCTAssertNil(ResumeLibrary.pickBase(for: lead, variants: [], winners: []))
    }

    func testDedupeKey() {
        XCTAssertEqual(ResumeLibrary.dedupeKey(company: "Apple Inc.", title: "iOS Engineer", roleNumber: "200678056"), "appleinc|200678056")
        XCTAssertEqual(ResumeLibrary.dedupeKey(company: "Apple", title: "iOS Engineer", roleNumber: " "), "apple|iosengineer")
        XCTAssertEqual(ResumeLibrary.dedupeKey(company: "APPLE", title: "ios engineer", roleNumber: ""),
                       ResumeLibrary.dedupeKey(company: "apple", title: "iOS Engineer", roleNumber: ""))
    }

    func testVariantName() {
        XCTAssertEqual(ResumeLibrary.variantName(userName: "Shiv Vyas", company: "Apple", title: "Software Development Engineer, Screen Sharing", existing: []),
                       "Shiv-Vyas-Apple-SoftwareDevelopmentEngineer")
        XCTAssertEqual(ResumeLibrary.variantName(userName: "Shiv Amitkumar Vyas", company: "Goldman Sachs", title: "iOS Engineer", existing: []),
                       "Shiv-Amitkumar-GoldmanSachs-iOSEngineer")
        XCTAssertEqual(ResumeLibrary.variantName(userName: "Shiv Vyas", company: "Google", title: "Head of Platform", existing: []), "Shiv-Vyas-Google-HeadPlatform")
        let taken: Set<String> = ["Shiv-Vyas-Apple-iOSEngineer", "Shiv-Vyas-Apple-iOSEngineer-2"]
        XCTAssertEqual(ResumeLibrary.variantName(userName: "Shiv Vyas", company: "Apple", title: "iOS Engineer", existing: taken), "Shiv-Vyas-Apple-iOSEngineer-3")
        XCTAssertEqual(ResumeLibrary.variantName(userName: "", company: "", title: "", existing: []), "Resume-Role")
    }

    func testScanReadsOnlyTexFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hunt-scan-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.appleHeader.write(to: dir.appendingPathComponent("B-Apple.tex"), atomically: true, encoding: .utf8)
        try "%    GOOGLE VARIANT: Full Stack\n\\documentclass{article}".write(to: dir.appendingPathComponent("A-Google.tex"), atomically: true, encoding: .utf8)
        try "not a variant".write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        // Cover letters and short-answer files are not variants: by name, or by having no VARIANT line and no JD MAP / HONESTY LEDGER.
        try "%    APPLE VARIANT: cover letter\n\\documentclass{article}".write(to: dir.appendingPathComponent("C-Apple-CoverLetter.tex"), atomically: true, encoding: .utf8)
        try "%    Application short answers, as attachable text.\n%    LENGTHS:\n%      1. Domain summary 116 words\n\\documentclass{article}"
            .write(to: dir.appendingPathComponent("D-Short-Answers.tex"), atomically: true, encoding: .utf8)
        try "\\documentclass{article}\\begin{document}Dear team\\end{document}".write(to: dir.appendingPathComponent("E-Letter.tex"), atomically: true, encoding: .utf8)
        try "%    FULL STACK VARIANT (consumer product)\n%    JD MAP:\n%      * React\n\\documentclass{article}".write(to: dir.appendingPathComponent("F-FullStack.tex"), atomically: true, encoding: .utf8)
        let found = try ResumeLibrary.scan(folder: dir.path)
        XCTAssertEqual(found.map(\.name), ["A-Google", "B-Apple", "F-FullStack"])
        XCTAssertEqual(found.map(\.company), ["Google", "Apple", ""])
        XCTAssertEqual(found[1].jdMap.count, 3)
        XCTAssertEqual(found[0].path, dir.path + "/A-Google.tex")
    }

    // MARK: leads

    func testCanSubmitGate() {
        let lead = Lead(company: "Apple", title: "iOS Engineer")
        XCTAssertTrue(lead.canSubmit)   // nothing asked
        lead.answers = [FormAnswer(question: "Why Apple?", answer: "Because", kind: "drafted", required: true),
                        FormAnswer(question: "Portfolio", answer: "", kind: "bank", required: false)]
        XCTAssertTrue(lead.canSubmit)
        lead.answers = [FormAnswer(question: "Why Apple?", answer: "  ", kind: "drafted", required: true)]
        XCTAssertFalse(lead.canSubmit)
        lead.answers = [FormAnswer(question: "Sponsorship?", answer: "No", kind: "needs_you", required: false)]
        XCTAssertFalse(lead.canSubmit)
        XCTAssertEqual(lead.answers.count, 1)   // round-trips through answersJSON
    }

    func testCooldownBlocks() {
        let now = Date.now
        let recent = Role(company: "Apple Inc", title: "iOS Engineer", roleNumber: "111", stage: .applied)
        recent.appliedAt = now.addingTimeInterval(-3 * 86400)
        let old = Role(company: "Google", title: "SWE", stage: .applied)
        old.appliedAt = now.addingTimeInterval(-10 * 86400)
        let never = Role(company: "Meta", title: "SWE", stage: .saved)
        let roles = [recent, old, never]

        XCTAssertTrue(JobHunt.cooldownBlocks(lead: Lead(company: "Apple, Inc.", title: "Other", roleNumber: ""), roles: roles, now: now))
        XCTAssertTrue(JobHunt.cooldownBlocks(lead: Lead(company: "Apple Inc", title: "Other", roleNumber: "111"), roles: roles, now: now))
        XCTAssertFalse(JobHunt.cooldownBlocks(lead: Lead(company: "Apple Inc", title: "Other", roleNumber: "222"), roles: roles, now: now))
        XCTAssertFalse(JobHunt.cooldownBlocks(lead: Lead(company: "Google", title: "SWE", roleNumber: ""), roles: roles, now: now))
        XCTAssertFalse(JobHunt.cooldownBlocks(lead: Lead(company: "Meta", title: "SWE", roleNumber: ""), roles: roles, now: now))
        XCTAssertFalse(JobHunt.cooldownBlocks(lead: Lead(company: "", title: "SWE", roleNumber: ""), roles: roles, now: now))
        XCTAssertTrue(JobHunt.cooldownBlocks(lead: Lead(company: "Google", title: "SWE", roleNumber: ""), roles: roles, now: now.addingTimeInterval(-5 * 86400)))
    }

    func testMergeAnswersWithBank() {
        var bank = AnswerBank()
        bank.workAuthorization = "Authorized to work in the US (F-1 OPT)"
        bank.fullName = "Shiv Vyas"
        bank.saved = ["Why do you want to work here?": "Saved reason"]
        let merged = JobHunt.mergeAnswers([
            FormAnswer(question: "Are you legally authorized to work in the United States?", answer: "", kind: "needs_you", required: true),
            FormAnswer(question: "Will you now or in the future require sponsorship?", answer: "", kind: "needs_you", required: true),
            FormAnswer(question: "Gender", answer: "", kind: "needs_you", required: false),
            FormAnswer(question: "What city are you based in?", answer: "New York", kind: "drafted", required: false),
            FormAnswer(question: "Full name", answer: "", kind: "needs_you", required: true),
            FormAnswer(question: "Why do you want to work here?", answer: "Drafted reason", kind: "drafted", required: true),
            FormAnswer(question: "Describe a project you embraced", answer: "A project", kind: "drafted", required: true),
        ], bank: bank)
        XCTAssertEqual(merged.map(\.kind), ["bank", "needs_you", "bank", "drafted", "bank", "bank", "drafted"])
        XCTAssertEqual(merged[0].answer, bank.workAuthorization)
        XCTAssertEqual(merged[2].answer, "Decline to self-identify")
        XCTAssertEqual(merged[3].answer, "New York")      // bank city is empty, drafted answer kept
        XCTAssertEqual(merged[4].answer, "Shiv Vyas")
        XCTAssertEqual(merged[5].answer, "Saved reason")
        XCTAssertEqual(merged[6].answer, "A project")      // "embraced" is not the race question
    }

    func testCitizenshipQuestionsAreNeverDrafted() {
        var bank = AnswerBank()
        bank.workAuthorization = "Authorized"; bank.needsSponsorship = "No"
        bank.saved = ["What is your citizenship status?": "US citizen"]
        for q in ["What is your citizenship status?", "Immigration status", "Please state your nationality", "Are you a U.S. citizen or permanent resident?"] {
            let b = JobHunt.bankAnswer(for: q, bank: bank)
            XCTAssertEqual(b?.answer, ""); XCTAssertEqual(b?.kind, "needs_you"); XCTAssertEqual(b?.legal, true, q)
        }
        let merged = JobHunt.mergeAnswers([FormAnswer(question: "What is your citizenship status?", answer: "US citizen", kind: "drafted", required: true),
                                           FormAnswer(question: "Do you require visa sponsorship?", answer: "", kind: "needs_you", required: true)], bank: bank)
        XCTAssertEqual(merged.map(\.kind), ["needs_you", "bank"])
        XCTAssertEqual(merged[0].answer, ""); XCTAssertEqual(merged[1].answer, "No")
    }

    func testRelocationAndStartDateAreBankOnly() {
        var bank = AnswerBank()
        let drafted = [FormAnswer(question: "Are you willing to relocate?", answer: "Yes, happily", kind: "drafted", required: true),
                       FormAnswer(question: "What is your earliest start date?", answer: "Immediately", kind: "drafted", required: false)]
        var merged = JobHunt.mergeAnswers(drafted, bank: bank)
        XCTAssertEqual(merged.map(\.kind), ["needs_you", "needs_you"])
        XCTAssertEqual(merged.map(\.answer), ["", ""])   // an empty bank never keeps a drafted value
        bank.relocation = "Open to it"; bank.startDate = "Two weeks after offer"
        merged = JobHunt.mergeAnswers(drafted, bank: bank)
        XCTAssertEqual(merged.map(\.kind), ["bank", "bank"])
        XCTAssertEqual(merged.map(\.answer), ["Open to it", "Two weeks after offer"])
    }

    func testAddingUnknownQuestionsGatesSubmit() {
        let lead = Lead(company: "Apple", title: "iOS Engineer")
        lead.answers = [FormAnswer(question: "Why Apple?", answer: "Because", kind: "drafted", required: true)]
        XCTAssertTrue(lead.canSubmit)
        lead.answers = JobHunt.addingUnknown(["Desired salary", " why apple? ", "", "Desired salary", "How did you hear about us?"], to: lead.answers)
        XCTAssertEqual(lead.answers.map(\.question), ["Why Apple?", "Desired salary", "How did you hear about us?"])
        XCTAssertEqual(lead.answers[1], FormAnswer(question: "Desired salary", answer: "", kind: "needs_you", required: true))
        XCTAssertFalse(lead.canSubmit)
        XCTAssertEqual(JobHunt.addingUnknown([], to: lead.answers).count, 3)
    }

    func testDiscoverPromptListsKnownWithPostingIdAndTitle() {
        let prompt = JobHunt.discoverPrompt(settings: HuntSettings(), variants: [], known: ["Apple | 200678056 | iOS Engineer", "Google | - | SWE"])
        XCTAssertTrue(prompt.contains("company | posting id or - | title\n- Apple | 200678056 | iOS Engineer\n- Google | - | SWE"))
        XCTAssertTrue(prompt.contains("never open the apply flow to read them"))
    }

    // MARK: schema samples

    func testDecodeDiscoverSample() throws {
        let json = """
        {"leads":[{"company":"Apple","title":"Software Development Engineer","location":"Cupertino, CA","link":"https://jobs.apple.com/en-us/details/200678056",
          "role_number":"200678056","source":"careers","jd":"Minimum qualifications: Swift, 3+ years...","score":84,"score_reason":"Swift and accessibility covered; no Objective-C"},
         {"company":"Google","title":"Software Engineer, Full Stack","location":"New York, NY","link":"https://www.linkedin.com/jobs/view/4012345678/",
          "role_number":"","source":"linkedin-rec","jd":"...","score":55.0,"score_reason":"C++ required"}],
         "notes":"Read 62 LinkedIn recommendations and Apple careers; Google careers search timed out."}
        """
        let r = try JSONDecoder().decode(DiscoverResult.self, from: Data(json.utf8))
        XCTAssertEqual(r.leads.count, 2)
        XCTAssertEqual(r.leads[0].role_number, "200678056"); XCTAssertEqual(r.leads[0].score, 84); XCTAssertEqual(r.leads[1].score, 55)
        XCTAssertEqual(r.leads[1].source, "linkedin-rec")
        XCTAssertTrue(r.notes.hasPrefix("Read 62"))
    }

    // MARK: built-in browser

    func testDiscoverPromptUsesBuiltInBrowser() {
        let prompt = JobHunt.discoverPrompt(settings: HuntSettings(), variants: [], known: [])
        XCTAssertTrue(prompt.contains("mcp__prepboard__"))
        XCTAssertTrue(prompt.contains("read_page") && prompt.contains("back()"))
        XCTAssertFalse(prompt.contains("claude-in-chrome") || prompt.contains("Chrome"))
        XCTAssertTrue(prompt.contains("SIGNED_OUT:") && prompt.contains("Never press Apply or Easy Apply"))
        XCTAssertFalse(prompt.contains("upload_file"))   // Discover is read-only
    }

    func testSubmitPromptUsesBuiltInBrowser() {
        let prompt = JobHunt.submitPrompt(lead: Lead(company: "Apple", title: "iOS Engineer", link: "https://jobs.apple.com/x"), pdfPath: "/tmp/r.pdf", bank: AnswerBank())
        XCTAssertTrue(prompt.contains("mcp__prepboard__"))
        XCTAssertTrue(prompt.contains("upload_file(ref, path)") && prompt.contains("/tmp/r.pdf"))
        XCTAssertFalse(prompt.contains("claude-in-chrome") || prompt.contains("Chrome"))
        XCTAssertTrue(prompt.contains("STOP CONDITIONS") && prompt.contains("CAPTCHA") && prompt.contains("needs_you"))
    }

    func testSyncPromptUsesBuiltInBrowser() {
        let prompt = JobSync.prompt(since: .now, roles: [])
        XCTAssertTrue(prompt.contains("mcp__prepboard__"))
        XCTAssertTrue(prompt.contains("use the Gmail tools if available, otherwise skip Gmail"))
        XCTAssertFalse(prompt.contains("claude-in-chrome") || prompt.contains("Chrome"))
        XCTAssertTrue(JobSync.connectorTools.contains("mcp__claude_ai_Gmail") && !JobSync.connectorTools.contains("chrome"))
        // The sync's flags must not be strict (strict mode drops the connectors) and must not grant form or upload tools.
        let server = BrowserServer()
        let flags = server.claudeFlags(extraTools: JobSync.connectorTools, readOnly: true, strict: false)
        XCTAssertFalse(flags.contains("--strict-mcp-config"), flags)
        XCTAssertTrue(flags.contains("mcp__claude_ai_Gmail mcp__claude_ai_Google_Calendar"), flags)
        XCTAssertFalse(flags.contains("upload_file"), flags)
        XCTAssertTrue(server.claudeFlags(extraTools: "").contains("--strict-mcp-config"))
        server.stop()
    }

    // MARK: Chrome for heavy runs

    func testChromePromptsUseTheChromeTools() {
        let discover = JobHunt.discoverPrompt(settings: HuntSettings(), variants: [], known: [], chrome: true)
        XCTAssertTrue(discover.contains("mcp__claude-in-chrome__") && discover.contains("NO_CHROME"), discover)
        XCTAssertFalse(discover.contains("mcp__prepboard__") || discover.contains("built-in browser"), discover)
        XCTAssertTrue(discover.contains("tabs_context_mcp") && discover.contains("SIGNED_OUT:") && discover.contains("Never press Apply or Easy Apply"))
        XCTAssertFalse(discover.contains("file_upload") || discover.contains("form_input"))   // Discover is read-only
        XCTAssertFalse(discover.contains("computer for clicks"), discover)   // no clicking in the user's Chrome while only reading
        XCTAssertTrue(discover.contains("&start=25"), discover)

        let lead = Lead(company: "Apple", title: "iOS Engineer", link: "https://jobs.apple.com/x")
        let submit = JobHunt.submitPrompt(lead: lead, pdfPath: "/tmp/r.pdf", bank: AnswerBank(), chrome: true)
        XCTAssertTrue(submit.contains("mcp__claude-in-chrome__") && submit.contains("NO_CHROME"), submit)
        XCTAssertFalse(submit.contains("mcp__prepboard__") || submit.contains("built-in browser"), submit)
        XCTAssertTrue(submit.contains("file_upload") && submit.contains("form_input") && submit.contains("/tmp/r.pdf"))
        XCTAssertFalse(submit.contains("upload_file"))
        XCTAssertTrue(submit.contains("STOP CONDITIONS") && submit.contains("needs_you"))
        XCTAssertTrue(submit.contains("computer for clicks and scrolling"))
        XCTAssertTrue(submit.contains("leave the application tab open for me"))
        XCTAssertFalse(submit.contains("close it with tabs_close_mcp when done"))
        // Site notes name the Chrome upload tool when Chrome runs the submit.
        let ashby = JobHunt.submitPrompt(lead: Lead(company: "Mirage", title: "x", link: "https://jobs.ashbyhq.com/mirage/1"), pdfPath: "/tmp/r.pdf", bank: AnswerBank(), chrome: true)
        XCTAssertTrue(ashby.contains("use file_upload on that ref") && !ashby.contains("upload_file"), ashby)
    }

    func testChromeToolListsAndBrowserChoice() {
        for t in ["tabs_context_mcp", "tabs_create_mcp", "tabs_close_mcp", "navigate", "get_page_text", "read_page", "find"] {
            XCTAssertTrue(JobHunt.chromeDiscoverTools.contains("mcp__claude-in-chrome__\(t)"), t)
        }
        // Discover only reads: no clicking or typing (`computer`), no form or upload tools. Submit has all three.
        XCTAssertFalse(JobHunt.chromeDiscoverTools.contains("computer") || JobHunt.chromeDiscoverTools.contains("javascript_tool"))
        XCTAssertFalse(JobHunt.chromeDiscoverTools.contains("file_upload") || JobHunt.chromeDiscoverTools.contains("form_input"))
        XCTAssertTrue(JobHunt.chromeSubmitTools.contains("mcp__claude-in-chrome__computer"))
        XCTAssertTrue(JobHunt.chromeSubmitTools.contains("mcp__claude-in-chrome__file_upload") && JobHunt.chromeSubmitTools.contains("mcp__claude-in-chrome__form_input"))
        // A Chrome run loads only the Chrome tools: strict MCP config, and the command line drops every built-in tool.
        let flags = JobHunt.chromeFlags(tools: JobHunt.chromeDiscoverTools)
        XCTAssertTrue(flags.hasPrefix("--chrome --strict-mcp-config --allowedTools mcp__claude-in-chrome__tabs_context_mcp"), flags)
        XCTAssertTrue(JobHunt.chromeSubmitTools.hasPrefix(JobHunt.chromeDiscoverTools))
        XCTAssertTrue(JobHunt.chromeSubmitTools.split(separator: " ").allSatisfy { $0.hasPrefix("mcp__claude-in-chrome__") })
        XCTAssertFalse(JobHunt.chromeSubmitTools.contains("mcp__prepboard__"))

        let saved = UserDefaults.standard.string(forKey: "hunt.browser")
        defer { if let saved { UserDefaults.standard.set(saved, forKey: "hunt.browser") } else { UserDefaults.standard.removeObject(forKey: "hunt.browser") } }
        UserDefaults.standard.removeObject(forKey: "hunt.browser")
        XCTAssertEqual(HuntBrowserChoice.current, .builtin)
        HuntBrowserChoice.current = .chrome
        XCTAssertEqual(UserDefaults.standard.string(forKey: "hunt.browser"), "chrome")
        XCTAssertEqual(HuntBrowserChoice.current, .chrome)
        UserDefaults.standard.set("nonsense", forKey: "hunt.browser")
        XCTAssertEqual(HuntBrowserChoice.current, .builtin)
    }

    // MARK: LinkedIn sign-in

    /// The stored sign-in is filled in by PrepBoard itself: no prompt mentions the form fields or the Keychain entries.
    func testPromptsNeverCarryTheLinkedInSignIn() {
        let lead = Lead(company: "Apple", title: "iOS Engineer", link: "https://www.linkedin.com/jobs/view/4012345678/")
        let prompts = [JobHunt.discoverPrompt(settings: HuntSettings(), variants: [], known: []),
                       JobHunt.discoverPrompt(settings: HuntSettings(), variants: [], known: [], chrome: true),
                       JobHunt.submitPrompt(lead: lead, pdfPath: "/tmp/r.pdf", bank: AnswerBank()),
                       JobHunt.submitPrompt(lead: lead, pdfPath: "/tmp/r.pdf", bank: AnswerBank(), chrome: true),
                       JobSync.prompt(since: .now, roles: [])]
        for p in prompts {
            XCTAssertFalse(p.contains("session_password") || p.contains("session_key"))
            XCTAssertFalse(p.contains("linkedin.password") || p.contains("linkedin.email"))
            XCTAssertTrue(p.contains("already signed in"))
        }
        XCTAssertTrue(JobHunt.isLinkedIn(lead.link) && JobHunt.isLinkedIn("https://linkedin.com/jobs/view/1"))
        XCTAssertFalse(JobHunt.isLinkedIn("https://jobs.ashbyhq.com/mirage/1") || JobHunt.isLinkedIn("https://jobs.apple.com/x") || JobHunt.isLinkedIn(""))
        XCTAssertFalse(JobHunt.isLinkedIn("https://notlinkedin.com/jobs/1"))
        XCTAssertFalse(JobHunt.isLinkedIn("https://linkedin.com.example.org/jobs/1"))
    }

    /// Scratch Keychain entries, so the user's own saved sign-in is never read, replaced or removed by a test run.
    func testLinkedInCredentialsSaveAndRemove() {
        let real = LinkedInSignIn.accounts
        LinkedInSignIn.accounts = (email: "test.linkedin.email", password: "test.linkedin.password")
        defer { LinkedInSignIn.remove(); LinkedInSignIn.accounts = real }
        LinkedInSignIn.remove()
        XCTAssertFalse(LinkedInSignIn.hasCredentials)
        LinkedInSignIn.save(email: "someone@example.com", password: "not-a-real-password")
        XCTAssertTrue(LinkedInSignIn.hasCredentials)
        XCTAssertEqual(Keychain.read("test.linkedin.email"), "someone@example.com")
        LinkedInSignIn.remove()
        XCTAssertFalse(LinkedInSignIn.hasCredentials)
        XCTAssertNil(Keychain.read("test.linkedin.password"))
    }

    // MARK: ATS application pages

    func testATSKindAndApplicationURL() {
        let ashby = "https://jobs.ashbyhq.com/mirage/98bb152b-4d0a-4ef3-8754-54060c179523?utm_source=LEbxa7kWm6"
        let ashbyForm = "https://jobs.ashbyhq.com/mirage/98bb152b-4d0a-4ef3-8754-54060c179523/application?utm_source=LEbxa7kWm6"
        XCTAssertEqual(ATS.kind(ashby), .ashby)
        XCTAssertEqual(ATS.applicationURL(ashby), ashbyForm)
        XCTAssertEqual(ATS.applicationURL(ashbyForm), ashbyForm)
        XCTAssertEqual(ATS.applicationURL(" " + ashby + "\n"), ashbyForm)   // a stray space from Claude's JSON must not skip the suffix
        XCTAssertEqual(ATS.applicationURL("https://jobs.ashbyhq.com/mirage/98bb152b-4d0a-4ef3-8754-54060c179523/"),
                       "https://jobs.ashbyhq.com/mirage/98bb152b-4d0a-4ef3-8754-54060c179523/application")
        XCTAssertEqual(ATS.applicationURL("https://jobs.ashbyhq.com/mirage"), "https://jobs.ashbyhq.com/mirage")   // the org page, not a posting

        XCTAssertEqual(ATS.kind("https://jobs.lever.co/acme/1234-abcd"), .lever)
        XCTAssertEqual(ATS.applicationURL("https://jobs.lever.co/acme/1234-abcd"), "https://jobs.lever.co/acme/1234-abcd/apply")
        XCTAssertEqual(ATS.applicationURL("https://jobs.lever.co/acme/1234-abcd/apply"), "https://jobs.lever.co/acme/1234-abcd/apply")
        XCTAssertEqual(ATS.applicationURL("https://jobs.lever.co/acme/1234-abcd?lever-origin=applied"), "https://jobs.lever.co/acme/1234-abcd/apply?lever-origin=applied")

        let greenhouse = "https://boards.greenhouse.io/acme/jobs/4012345"
        XCTAssertEqual(ATS.kind(greenhouse), .greenhouse); XCTAssertEqual(ATS.applicationURL(greenhouse), greenhouse)
        XCTAssertEqual(ATS.kind("https://job-boards.greenhouse.io/acme/jobs/1"), .greenhouse)
        XCTAssertEqual(ATS.kind("https://apply.workable.com/acme/j/ABC123/"), .workable)
        XCTAssertEqual(ATS.kind("https://acme.workable.com/jobs/1"), .workable)
        XCTAssertEqual(ATS.kind("https://acme.myworkdayjobs.com/en-US/Careers/job/NYC/SWE_R123"), .workday)
        let linkedin = "https://www.linkedin.com/jobs/view/4012345678/"
        XCTAssertEqual(ATS.kind(linkedin), .linkedin); XCTAssertEqual(ATS.applicationURL(linkedin), linkedin)
        let careers = "https://jobs.apple.com/en-us/details/200678056"
        XCTAssertEqual(ATS.kind(careers), .other); XCTAssertEqual(ATS.applicationURL(careers), careers)
        XCTAssertEqual(ATS.kind("https://app.ashbyhq.com/x"), .other)
        XCTAssertEqual(ATS.kind(""), .other); XCTAssertEqual(ATS.applicationURL(""), "")

        XCTAssertEqual(ATS.formNotes(.other), "")
        XCTAssertTrue(ATS.formNotes(.ashby).contains("Upload File") && ATS.formNotes(.ashby).contains("Submit Application"))
        XCTAssertTrue(ATS.formNotes(.greenhouse).contains("Enter manually"))
        XCTAssertTrue(ATS.formNotes(.workday).contains("Workday asks for an account"))
    }

    func testSubmitPromptStartsAtTheApplicationPage() {
        let ashby = Lead(company: "Mirage", title: "iOS Engineer", link: "https://jobs.ashbyhq.com/mirage/98bb152b-4d0a-4ef3-8754-54060c179523?utm_source=LEbxa7kWm6")
        let prompt = JobHunt.submitPrompt(lead: ashby, pdfPath: "/tmp/r.pdf", bank: AnswerBank())
        XCTAssertTrue(prompt.contains("Start here: https://jobs.ashbyhq.com/mirage/98bb152b-4d0a-4ef3-8754-54060c179523/application?utm_source=LEbxa7kWm6"), prompt)
        XCTAssertTrue(prompt.contains("Posting: https://jobs.ashbyhq.com/mirage/98bb152b-4d0a-4ef3-8754-54060c179523?utm_source=LEbxa7kWm6"))
        XCTAssertTrue(prompt.contains("Form notes for this site: Ashby") && prompt.contains("Upload File") && prompt.contains("use upload_file on that ref"))
        XCTAssertFalse(prompt.contains("Chrome"))

        let linkedin = JobHunt.submitPrompt(lead: Lead(company: "Apple", title: "iOS Engineer", link: "https://www.linkedin.com/jobs/view/4012345678/"), pdfPath: "/tmp/r.pdf", bank: AnswerBank())
        XCTAssertTrue(linkedin.contains("Start here: https://www.linkedin.com/jobs/view/4012345678/"))
        XCTAssertTrue(linkedin.contains("use Easy Apply when it is offered; otherwise press Apply"), linkedin)
        XCTAssertTrue(linkedin.contains("Form notes for this site: LinkedIn"))

        // A careers posting gets no site notes but keeps the LinkedIn sentence: its Apply button may still go through LinkedIn.
        let careers = JobHunt.submitPrompt(lead: Lead(company: "Apple", title: "iOS Engineer", link: "https://jobs.apple.com/x"), pdfPath: "/tmp/r.pdf", bank: AnswerBank())
        XCTAssertTrue(careers.contains("Start here: https://jobs.apple.com/x\nPosting: https://jobs.apple.com/x"))
        XCTAssertFalse(careers.contains("Form notes for this site"))
        XCTAssertTrue(careers.contains("use Easy Apply when it is offered; otherwise press Apply"))
    }

    func testDiscoverPromptAsksForTheJobPageOnATSHosts() {
        let prompt = JobHunt.discoverPrompt(settings: HuntSettings(), variants: [], known: [])
        XCTAssertTrue(prompt.contains("Ashby, Greenhouse, Lever or Workable") && prompt.contains("not its application form"), prompt)
    }

    func testDecodeTailorSample() throws {
        let json = """
        {"tex":"%    APPLE VARIANT: SDE\\n\\\\documentclass{article}\\\\begin{document}Hi\\\\end{document}",
         "coverage":[{"term":"Swift","covered":true},{"term":"Objective-C","covered":false}],
         "answers":[{"question":"Why Apple?","answer":"Because of the platform work.","kind":"drafted","required":true},
                    {"question":"Do you require sponsorship?","answer":"","kind":"needs_you","required":true}],
         "ledger":["Objective-C: not claimed, no shipped Objective-C"],
         "notes":"Took bullets from the Wispr and DoorDash variants."}
        """
        let r = try JSONDecoder().decode(TailorResult.self, from: Data(json.utf8))
        XCTAssertTrue(r.tex.hasPrefix("%    APPLE VARIANT: SDE\n\\documentclass"))
        XCTAssertEqual(r.coverage, [Coverage(term: "Swift", covered: true), Coverage(term: "Objective-C", covered: false)])
        XCTAssertEqual(r.answers.map(\.kind), ["drafted", "needs_you"])
        XCTAssertEqual(r.ledger.count, 1)
    }

    func testDecodeHonestyAndSubmitSamples() throws {
        let ok = try JSONDecoder().decode(HonestyResult.self, from: Data(#"{"ok":true,"untraceable":[]}"#.utf8))
        XCTAssertTrue(ok.ok && ok.untraceable.isEmpty)
        let bad = try JSONDecoder().decode(HonestyResult.self, from: Data(#"{"ok":false,"untraceable":["\"Led a team of 4\": sources say \"worked with\""]}"#.utf8))
        XCTAssertFalse(bad.ok); XCTAssertEqual(bad.untraceable.count, 1)

        let submitted = try JSONDecoder().decode(SubmitResult.self, from: Data(#"{"status":"submitted","reason":"","unknown_questions":[],"confirmation":"Application received, ref 88213"}"#.utf8))
        XCTAssertEqual(submitted.status, "submitted"); XCTAssertEqual(submitted.confirmation, "Application received, ref 88213")
        let needs = try JSONDecoder().decode(SubmitResult.self, from: Data(#"{"status":"needs_you","reason":"Two questions not in the list","unknown_questions":["Desired salary","How did you hear about us?"],"confirmation":""}"#.utf8))
        XCTAssertEqual(needs.status, "needs_you"); XCTAssertEqual(needs.unknown_questions.count, 2)

        for schema in [JobHunt.discoverSchema, JobHunt.tailorSchema, JobHunt.honestySchema, JobHunt.submitSchema] {
            XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any], "schema is valid JSON")
        }
    }

    /// The .tex an edit opens: nil until a variant exists, else the résumé folder plus the variant name (the default folder
    /// before a settings record is attached).
    func testTexPathForLead() {
        let hunt = JobHunt()
        let lead = Lead(company: "Apple", title: "iOS Engineer")
        XCTAssertNil(hunt.texPath(for: lead))
        lead.variantName = "Shiv-Vyas-Apple-iOSEngineer"
        XCTAssertEqual(hunt.texPath(for: lead), HuntSettings.defaultResumeFolder + "/Shiv-Vyas-Apple-iOSEngineer.tex")
        XCTAssertTrue(hunt.texPath(for: lead)!.hasSuffix(".tex"))
    }

    /// `variantName` syncs from Supabase, so only a plain file name may become a path; anything else means "regenerate first".
    func testTexPathRejectsNamesThatLeaveTheFolder() {
        let hunt = JobHunt()
        let lead = Lead(company: "Apple", title: "iOS Engineer")
        for bad in ["../../.zshrc", "a/b", "/etc/passwd", ".hidden", "..", ".", "x\u{0}y"] {
            lead.variantName = bad
            XCTAssertNil(hunt.texPath(for: lead), bad)
            XCTAssertNil(JobHunt.plainName(bad), bad)
        }
        XCTAssertEqual(JobHunt.plainName("Shiv-Vyas-Apple-iOSEngineer"), "Shiv-Vyas-Apple-iOSEngineer")
        XCTAssertEqual(JobHunt.plainName("with space.v2"), "with space.v2")
        XCTAssertNil(JobHunt.plainName(""))
    }

    /// Every headless run names its built-in tool set outright, so the user's global Bash and web allowlist never applies to it.
    func testClaudeCommandPinsTheBuiltInTools() {
        let browser = JobHunt.claudeCommand(browserFlags: "--chrome --strict-mcp-config --allowedTools mcp__claude-in-chrome__navigate", tools: "", schemaPath: "/tmp/s.json", cwd: "/tmp")
        XCTAssertTrue(browser.contains("claude -p --chrome --strict-mcp-config --allowedTools mcp__claude-in-chrome__navigate --output-format json"), browser)
        XCTAssertTrue(browser.hasSuffix("--tools \"\""), browser)
        XCTAssertFalse(browser.contains("2>/dev/null"), "Keep CLI failures visible to the user")
        XCTAssertEqual(browser.components(separatedBy: "--allowedTools").count, 2, browser)   // only the browser's list
        let files = JobHunt.claudeCommand(browserFlags: nil, tools: JobHunt.fileTools, schemaPath: "/tmp/s.json", cwd: "/Users/x/Resumes")
        XCTAssertTrue(files.hasPrefix("cd '/Users/x/Resumes' && claude -p --output-format json"), files)
        XCTAssertTrue(files.hasSuffix("--tools \"Read,Grep,Glob\" --allowedTools Read Grep Glob"), files)
        XCTAssertFalse(files.contains("Bash") || files.contains("WebSearch") || files.contains("Write"))
    }

    func testBrowserLinksRequireAWebSchemeAndHost() {
        XCTAssertEqual(JobHunt.webURL("  https://jobs.example.com/a?ref=b  ")?.host, "jobs.example.com")
        for invalid in ["", "jobs.example.com", "file:///tmp/resume.pdf", "javascript:alert(1)", "https://"] {
            XCTAssertNil(JobHunt.webURL(invalid), invalid)
        }
    }

    func testClaudeResultKeepsJSONSeparateFromDiagnostics() throws {
        let output = ClaudeCode.ShellResult(
            stdout: "Shell banner {not json}\n" + #"{"is_error":false,"structured_output":{"status":"needs_you","reason":"Sign in","unknown_questions":[],"confirmation":""}}"#,
            stderr: "An extension warning", exitCode: 0)
        let result = try JobHunt.decodeResult(SubmitResult.self, output: output)
        XCTAssertEqual(result.status, "needs_you")
        XCTAssertEqual(result.reason, "Sign in")
    }

    func testClaudeResultSurfacesCLIAndStructuredFailures() {
        let failures: [(ClaudeCode.ShellResult, String)] = [
            (.init(stdout: "", stderr: "unknown option '--chrome'", exitCode: 1), "unknown option '--chrome'"),
            (.init(stdout: #"{"is_error":true,"errors":["Browser extension is not connected"]}"#, stderr: "", exitCode: 0), "Browser extension is not connected"),
            (.init(stdout: #"{"permission_denials":[{"tool_name":"file_upload"}]}"#, stderr: "", exitCode: 0), "permissions"),
        ]
        for (output, expected) in failures {
            XCTAssertThrowsError(try JobHunt.decodeResult(SubmitResult.self, output: output)) { error in
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
            }
        }
    }

    func testShellDrainsBothPipesAndPreservesExitStatus() async {
        let output = await ClaudeCode.shellResult("/usr/bin/yes 'extension unavailable' | /usr/bin/head -c 131072 >&2; /usr/bin/printf '%s' '{\"ok\":true}'; exit 7")
        XCTAssertTrue(output.stdout.hasSuffix(#"{"ok":true}"#), output.stdout)
        XCTAssertTrue(output.stderr.contains("extension unavailable"))
        XCTAssertGreaterThanOrEqual(output.stderr.utf8.count, 131072)
        XCTAssertEqual(output.exitCode, 7)
    }

    func testDailyCounterKeysAreDateScoped() {
        let day = Date(timeIntervalSince1970: 0)
        UserDefaults.standard.removeObject(forKey: "hunt.tailored.\(DateCoding.dayString(day))")
        XCTAssertEqual(JobHunt.dailyCount("tailored", on: day), 0)
        UserDefaults.standard.set(3, forKey: "hunt.tailored.\(DateCoding.dayString(day))")
        XCTAssertEqual(JobHunt.dailyCount("tailored", on: day), 3)
        UserDefaults.standard.removeObject(forKey: "hunt.tailored.\(DateCoding.dayString(day))")
    }

    func testEditPromptCarriesInstructionAndHonestyRules() throws {
        let lead = Lead(company: "Mirage", title: "Founding Engineer", jd: "Swift and Rust")
        lead.variantName = "Shiv-Vyas-Mirage-FoundingEngineer"
        let p = JobHunt.editPrompt(instruction: "Shorten the summary to two lines", tex: "\\documentclass{article}", lead: lead,
                                   sources: ["Shiv-Vyas-Apple-SDE"], github: "", folder: "/tmp/r")
        XCTAssertTrue(p.contains("MY INSTRUCTION:\nShorten the summary to two lines"))
        XCTAssertTrue(p.contains("HONESTY, the rule that matters most"))
        XCTAssertTrue(p.contains("Never invent numbers"))
        XCTAssertTrue(p.contains("Shiv-Vyas-Apple-SDE.tex"))
        XCTAssertTrue(p.contains("<tex>\n\\documentclass{article}\n</tex>"))
        XCTAssertTrue(p.contains("must not write files"))
        let r = try JSONDecoder().decode(EditResult.self, from: Data(#"{"tex":"\\documentclass{article}","notes":"Shortened."}"#.utf8))
        XCTAssertEqual(r.notes, "Shortened.")
    }
}
