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
        XCTAssertFalse(JobHunt.discoverTools.contains("Gmail"))
        XCTAssertTrue(JobHunt.submitTools.contains("mcp__claude-in-chrome__file_upload") && JobHunt.submitTools.contains("mcp__claude-in-chrome__form_input"))
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

    func testDailyCounterKeysAreDateScoped() {
        let day = Date(timeIntervalSince1970: 0)
        UserDefaults.standard.removeObject(forKey: "hunt.tailored.\(DateCoding.dayString(day))")
        XCTAssertEqual(JobHunt.dailyCount("tailored", on: day), 0)
        UserDefaults.standard.set(3, forKey: "hunt.tailored.\(DateCoding.dayString(day))")
        XCTAssertEqual(JobHunt.dailyCount("tailored", on: day), 3)
        UserDefaults.standard.removeObject(forKey: "hunt.tailored.\(DateCoding.dayString(day))")
    }
}
