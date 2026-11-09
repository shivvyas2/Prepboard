import XCTest
import CoreText
@testable import Prepboard

final class HuntAutopilotTests: XCTestCase {
    private let ny = TimeZone(identifier: "America/New_York")!

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter(); f.timeZone = ny
        return f.date(from: s)!
    }

    // Stop messages copied from real leads that waited on the user.
    func testClassifiesRealStops() {
        let now = date("2026-10-21T10:53:26-04:00")
        XCTAssertEqual(HuntAutopilot.classify("You've hit your session limit · resets 12:30pm (America/New_York)", now: now, zone: ny),
                       .waitUntil(date("2026-10-21T12:31:00-04:00")))
        XCTAssertEqual(HuntAutopilot.classify("No résumé variants found in /Users/x/Documents/Career/Resumes (Downloads)"), .retailor)
        XCTAssertEqual(HuntAutopilot.classify("The PDF is missing; regenerate the résumé first"), .retailor)
        XCTAssertEqual(HuntAutopilot.classify("PrepBoard quit while the résumé was being written; press Regenerate"), .retailor)
        XCTAssertEqual(HuntAutopilot.classify("Honesty check could not run: Claude Code returned no result."), .retailor)
        XCTAssertEqual(HuntAutopilot.classify("Could not load LinkedIn: Could not load the page: The request timed out. Then press Submit again."), .retry)
        XCTAssertEqual(HuntAutopilot.classify("The PrepBoard browser (mcp__prepboard__ tools) failed to connect this session (connection timed out after 30 seconds)"), .retry)
        XCTAssertEqual(HuntAutopilot.classify("Submit ended without a result; check the Browser card before trying again"), .retry)
    }

    func testLeavesRealDecisionsToTheUser() {
        XCTAssertEqual(HuntAutopilot.classify("Below match threshold"), .none)
        XCTAssertEqual(HuntAutopilot.classify("Check these claims"), .none)
        XCTAssertEqual(HuntAutopilot.classify("The posting is closed"), .none)
        XCTAssertEqual(HuntAutopilot.classify("No submission confirmation was returned. Check the open application before trying again."), .none)
        XCTAssertEqual(HuntAutopilot.classify("Sign in to LinkedIn in the Browser card above, then run the hunt again."), .none)
    }

    func testResetTimeRollsToTomorrowAndHandlesMidnightAndNoon() {
        let late = date("2026-10-21T23:10:00-04:00")
        XCTAssertEqual(HuntAutopilot.resetTime("resets 7:30am (America/New_York)", now: late, zone: ny), date("2026-10-22T07:31:00-04:00"))
        XCTAssertEqual(HuntAutopilot.resetTime("resets 12am", now: late, zone: ny), date("2026-10-22T00:01:00-04:00"))
        XCTAssertEqual(HuntAutopilot.resetTime("limit resets at 12 PM", now: date("2026-10-21T09:00:00-04:00"), zone: ny),
                       date("2026-10-21T12:01:00-04:00"))
        XCTAssertNil(HuntAutopilot.resetTime("no time here", now: late, zone: ny))
    }

    func testUsageLimitWithoutTimeWaitsAnHour() {
        let now = date("2026-10-21T10:00:00-04:00")
        XCTAssertEqual(HuntAutopilot.classify("Claude usage limit reached", now: now, zone: ny), .waitUntil(now.addingTimeInterval(3600)))
    }

    func testMissingKeywordsIgnoresCaseAndPunctuation() {
        let text = "Built apps in SwiftUI and NodeJS with ci / cd and React Native; A/B testing"
        XCTAssertEqual(HuntAutopilot.missingKeywords(["SwiftUI", "Node.js", "CI/CD", "React Native", "A/B testing", "Kotlin", "kotlin"], in: text),
                       ["Kotlin"])
        XCTAssertEqual(HuntAutopilot.keywordScore(["Swift", "Kotlin"], in: "Swift"), 0.5, accuracy: 0.001)
        XCTAssertEqual(HuntAutopilot.keywordScore([], in: "x"), 1)
    }

    func testShortLinesCountWidowsNotHeadingsOrDates() {
        let text = """
        Shiv Vyas
        iOS Engineer | Swift
        Jersey City, NJ | email
        Experience
        • Built a decoder that buffers frames ahead of playback and keeps the
        fork.
        December 2024 – Present
        Skills
        or a Bluetooth LE strap
        """
        XCTAssertEqual(HuntAutopilot.shortLineCount(text), 2)
    }

    @MainActor func testPageFitFlags() {
        XCTAssertTrue(HuntAutopilot.PageFit(pages: 1, bottomGap: 0.09, shortLines: 0).underfilled)
        XCTAssertTrue(HuntAutopilot.PageFit(pages: 1, bottomGap: -0.03, shortLines: 0).overflows)
        XCTAssertTrue(HuntAutopilot.PageFit(pages: 2, bottomGap: 0.5, shortLines: 0).overflows)
        XCTAssertTrue(HuntAutopilot.PageFit(pages: 1, bottomGap: 0.03, shortLines: 2).isGood)
        let ask = JobHunt.fitInstructions(HuntAutopilot.PageFit(pages: 1, bottomGap: 0.09, shortLines: 1), missing: ["Kotlin"])
        XCTAssertTrue(ask.contains("blank space"))
        XCTAssertTrue(ask.contains("Kotlin"))
        XCTAssertTrue(ask.contains("only a few words"))
        XCTAssertFalse(JobHunt.fitInstructions(HuntAutopilot.PageFit(pages: 2, bottomGap: 0.5, shortLines: 3), missing: []).contains("only a few words"))
    }

    /// A letter page with text only in its top half measures as about half empty.
    func testMeasuresARealPDF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fit-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        for i in 0..<20 {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Line \(i) of the résumé body text",
                                                                           attributes: [.init(kCTFontAttributeName as String): font]))
            ctx.textPosition = CGPoint(x: 50, y: 740 - CGFloat(i) * 18)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage(); ctx.closePDF()
        let fit = try XCTUnwrap(HuntAutopilot.measure(pdfAt: url.path))
        XCTAssertEqual(fit.pages, 1)
        XCTAssertEqual(fit.bottomGap, 398.0 / 792, accuracy: 0.02)
        XCTAssertTrue(fit.underfilled)
    }

    @MainActor func testSubmitPromptAddsAutonomyOnlyWhenAsked() {
        let lead = Lead(company: "Acme", title: "iOS Engineer", location: "NYC", link: "https://jobs.example.com/1", roleNumber: "", source: "careers",
                        jd: "", score: 90, scoreReason: "")
        let auto = JobHunt.submitPrompt(lead: lead, pdfPath: "/tmp/r.pdf", bank: AnswerBank(), autonomous: true)
        let manual = JobHunt.submitPrompt(lead: lead, pdfPath: "/tmp/r.pdf", bank: AnswerBank())
        XCTAssertTrue(auto.contains("ANSWERING ON YOUR OWN"))
        XCTAssertFalse(manual.contains("ANSWERING ON YOUR OWN (I asked"))
        XCTAssertTrue(manual.contains("ALREADY APPLIED"))
    }
}

final class LatexPaperTests: XCTestCase {
    func testA4BecomesUSLetterOnlyInOptions() {
        XCTAssertEqual(LatexBuild.usLetter(#"\documentclass[a4paper,9.5pt]{article}"#), #"\documentclass[letterpaper,9.5pt]{article}"#)
        XCTAssertEqual(LatexBuild.usLetter(#"\usepackage[a4paper, scale=0.97]{geometry}"#), #"\usepackage[letterpaper, scale=0.97]{geometry}"#)
        XCTAssertEqual(LatexBuild.usLetter(#"\documentclass[letterpaper]{article} % a4paper"#), #"\documentclass[letterpaper]{article} % a4paper"#)
    }
}

/// Questions copied from real application forms PrepBoard stopped on or answered wrongly.
final class ImmigrationAnswerTests: XCTestCase {
    private var stemOPT: AnswerBank {
        var b = AnswerBank(); b.visaStatus = AnswerBank.VisaStatus.f1stemopt.rawValue; b.citizenshipCountry = "India"
        b.workAuthorization = "Yes"; b.citizenship = "Yes"; b.needsSponsorship = "Yes"   // the old free-text values must not leak through
        b.employment = "Contextual Intelligence | Founding Product Engineer\nFuture AI | Founding Mobile Engineer"
        return b
    }

    func testF1StemOPTAnswersEveryShape() {
        let b = stemOPT
        func a(_ q: String) -> String? { b.answer(for: q)?.answer }
        XCTAssertEqual(a("Are you legally authorized to work in the United States?*"), "Yes")
        XCTAssertEqual(a("Are you currently authorized to work in the U.S.?*"), "Yes")
        XCTAssertEqual(a("Will you now or in the future require sponsorship to work in the US?*"), "Yes")
        XCTAssertEqual(a("Do you now or in the future anticipate needing visa sponsorship?"), "Yes")
        XCTAssertEqual(a("Will you now require immigration sponsorship by our company to attain or maintain your employment eligibility (e.g., H-1B, E-3, TN, O-1, STEM OPT, or any immigration work authorization requiring a written submission from the company to a government agency)?*"), "Yes")
        XCTAssertEqual(a("Do you currently require visa sponsorship?"), "No")
        XCTAssertEqual(a("If yes, what kind of sponsorship will you require?"), "H-1B")
        XCTAssertEqual(a("Are you a U.S. citizen?"), "No")
        XCTAssertEqual(a("Are you a US citizen or permanent resident?"), "No")
        XCTAssertEqual(a("Do you hold a green card?"), "No")
        XCTAssertEqual(a("What is your current visa status?"), "F-1 student on STEM OPT extension (EAD)")
        XCTAssertEqual(a("Which of the following best describes your work authorization?"), "F-1 student on STEM OPT extension (EAD)")
        XCTAssertEqual(a("Are you currently on OPT or CPT?"), "Yes")
        XCTAssertEqual(a("Country of citizenship"), "India")
        XCTAssertEqual(b.answer(for: "When does your work authorization expire?")?.kind, "needs_you")
    }

    func testCitizenAndUnsetStatus() {
        var c = AnswerBank(); c.visaStatus = "citizen"
        XCTAssertEqual(c.answer(for: "Are you a US citizen?")?.answer, "Yes")
        XCTAssertEqual(c.answer(for: "Will you now or in the future require sponsorship?")?.answer, "No")
        XCTAssertEqual(c.answer(for: "Are you a US citizen or permanent resident?")?.answer, "Yes")
        var none = AnswerBank(); none.needsSponsorship = "Yes"
        XCTAssertEqual(none.answer(for: "Will you require sponsorship?")?.answer, "Yes")   // the old field still works without a status
    }

    func testOldFreeTextCarriesOver() throws {
        let json = #"{"workAuthorization":"Authorized to work in the US (F-1 STEM OPT)"}"#
        let b = try JSONDecoder().decode(AnswerBank.self, from: Data(json.utf8))
        XCTAssertEqual(b.status, .f1stemopt)
        XCTAssertNil(AnswerBank.inferStatus("Yes"))
    }

    func testRoutineScreeningQuestions() {
        let b = stemOPT
        func a(_ q: String) -> String? { b.answer(for: q)?.answer }
        XCTAssertEqual(a("Have you worked at DoorDash?*"), "No")
        XCTAssertNil(b.screeningAnswer(for: "Have you worked at Contextual Intelligence before?"))
        XCTAssertEqual(a("Applicant Privacy Acknowledgement * (confirm that you have read and understand the Applicant Privacy Notice)"), "Yes, I acknowledge")
        XCTAssertEqual(a("Would you like to receive communications via SMS and/or WhatsApp to the number provided about your application process?*"), "No")
        XCTAssertEqual(a("Are you at least 18 years of age?"), "Yes")
        XCTAssertNil(b.screeningAnswer(for: "What are you most proud of?"))
    }

    @MainActor func testSubmitPromptSpellsOutStatus() {
        let lead = Lead(company: "Acme", link: "https://jobs.example.com/1")
        let p = JobHunt.submitPrompt(lead: lead, pdfPath: "/tmp/r.pdf", bank: stemOPT)
        XCTAssertTrue(p.contains("IMMIGRATION"))
        XCTAssertTrue(p.contains("US citizen: No"))
        XCTAssertFalse(p.contains("Citizenship / immigration status: Yes"))
    }
}

/// The rest of the questions real forms stopped on, the ATS parse check and the card badges.
final class ApplyGapsTests: XCTestCase {
    private var bank: AnswerBank {
        var b = AnswerBank(); b.fullName = "Shiv Vyas"; b.email = "shiv@example.com"; b.phone = "551-342-5622"
        b.city = "Jersey City"; b.state = "New Jersey"; b.zipCode = "07302"; b.visaStatus = "f1stemopt"
        return b
    }

    func testLocationAndEEOQuestions() {
        let b = bank
        func a(_ q: String) -> String? { b.answer(for: q)?.answer }
        XCTAssertEqual(a("Zip Code*"), "07302")
        XCTAssertEqual(a("Home zip code/postal code *"), "07302")
        XCTAssertEqual(a("Which U.S. State or Canadian Province do you reside in?*"), "New Jersey")
        XCTAssertEqual(a("State"), "New Jersey")
        XCTAssertEqual(a("Country*"), "United States")
        XCTAssertEqual(a("Discipline*"), b.major)
        XCTAssertEqual(a("Do you identify as transgender?*"), "Decline to self-identify")
        XCTAssertEqual(a("Are you able to complete the essential functions of this job, with or without reasonable accommodation?*"), "Yes")
        XCTAssertEqual(a("To the best of your knowledge, do you have any relatives currently working at Opentrons or Neochromosome?"), "No")
        var r = b; r.relatives = "Opentrons"
        XCTAssertEqual(r.answer(for: "Do you have any relatives currently working at Opentrons?")?.answer, "Yes")
        XCTAssertEqual(a("Country of citizenship"), "", "nationality still comes from the work status block, not Country")
    }

    func testHistoryConflictsAndThinness() {
        var b = AnswerBank()
        b.currentTitle = "Founding Software Engineer"; b.currentEmployer = "Contextual Intelligence (previously known as Clo)"
        b.employment = "Contextual Intelligence (formerly Luna Social) | Founding Product Engineer | New York | December 2024 – Present"
        b.education = "Pace University"
        XCTAssertEqual(b.historyConflicts.count, 2)   // title differs; education has no dates
        XCTAssertTrue(b.historyIsThin)
        b.currentTitle = "Founding Product Engineer"; b.education = "Pace University | MS, Computer Science | 2023 – 2025"
        XCTAssertTrue(b.historyConflicts.isEmpty)
        XCTAssertFalse(b.historyIsThin)
    }

    func testATSCheck() {
        let clean = "Shiv Vyas\nJersey City, NJ | 551-342-5622 | shiv@example.com\nSummary\nExperience\nEngineer Dec 2024 – Present\nSkills\nEducation\nMay 2025"
        XCTAssertEqual(HuntAutopilot.atsIssues(text: clean, name: "Shiv Vyas", email: "shiv@example.com", phone: "551-342-5622"), [])
        let broken = "Experience\nprofiling with \u{FB01}les 03/2024 and Dec 2024\n\u{E001} shiv at example"
        let issues = HuntAutopilot.atsIssues(text: broken, name: "Shiv Vyas", email: "shiv@example.com", phone: "551-342-5622")
        XCTAssertTrue(issues.contains { $0.contains("name") })
        XCTAssertTrue(issues.contains { $0.contains("email") })
        XCTAssertTrue(issues.contains { $0.contains("phone") })
        XCTAssertTrue(issues.contains { $0.contains("Education") })
        XCTAssertTrue(issues.contains { $0.contains("ligatures") })
        XCTAssertTrue(issues.contains { $0.contains("one format") })
    }

    func testLeadBadgesReadReason() {
        let lead = Lead(company: "Acme")
        lead.reason = "Built from the Hebbia base. Keywords: 92%. ATS: parses cleanly."
        XCTAssertEqual(lead.keywordScore, 92)
        XCTAssertEqual(lead.atsIssues, [])
        XCTAssertEqual(lead.displayReason, "Built from the Hebbia base.")
        lead.reason = "Ok. ATS: Dates use more than one format. No “Skills” heading."
        XCTAssertEqual(lead.atsIssues?.count, 2)
        lead.status = .skipped; lead.reason = Lead.byHandPrefix + "the site needs an account."
        XCTAssertTrue(lead.isByHand)
    }

    @MainActor func testPromptsCarryTheNewRules() {
        let lead = Lead(company: "Acme", link: "https://jobs.example.com/1")
        XCTAssertTrue(JobHunt.submitPrompt(lead: lead, pdfPath: "/tmp/r.pdf", bank: bank, autonomous: true).contains("ACCOUNT_REQUIRED"))
        let ask = JobHunt.fitInstructions(HuntAutopilot.PageFit(pages: 1, bottomGap: 0.02, shortLines: 0), missing: [], ats: ["No “Skills” heading."])
        XCTAssertTrue(ask.contains("Applicant tracking systems"))
    }
}

final class HuntRemoteTests: XCTestCase {
    func testRemoteRidesOnTheBankAndOldRowsDecode() throws {
        var b = AnswerBank(); b.remote.keepApplying = true; b.remote.runRequested = "2026-11-07T20:00:00Z"
        let back = try JSONDecoder().decode(AnswerBank.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(back.remote.keepApplying, true)
        XCTAssertEqual(back.remote.runRequested, "2026-11-07T20:00:00Z")
        let old = try JSONDecoder().decode(AnswerBank.self, from: Data(#"{"fullName":"A"}"#.utf8))
        XCTAssertNil(old.remote.keepApplying)
        XCTAssertFalse(old.remote.macOnline())
    }

    func testMacOnlineWindow() {
        var r = HuntRemote(); r.macStatusAt = DateCoding.string(.now.addingTimeInterval(-120))
        XCTAssertTrue(r.macOnline())
        r.macStatusAt = DateCoding.string(.now.addingTimeInterval(-1200))
        XCTAssertFalse(r.macOnline())
    }
}

final class OfflineAndRemoteTests: XCTestCase {
    func testHuntEndpointNeedsItsOwnToken() {
        let h = ["authorization": "Bearer hunt-token"]
        XCTAssertNil(BrowserServer.gate(method: "POST", path: "/hunt", headers: h, token: "hunt-token", endpoint: "/hunt"))
        XCTAssertEqual(BrowserServer.gate(method: "POST", path: "/hunt", headers: ["authorization": "Bearer browser-token"], token: "hunt-token", endpoint: "/hunt"), 401)
        XCTAssertEqual(BrowserServer.gate(method: "POST", path: "/mcp", headers: h, token: "hunt-token", endpoint: "/hunt"), 404)
        XCTAssertEqual(BrowserServer.gate(method: "POST", path: "/hunt", headers: h.merging(["origin": "https://evil.example"]) { a, _ in a }, token: "hunt-token", endpoint: "/hunt"), 403)
    }

    @MainActor func testHuntToolsListOverMCP() async throws {
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let (status, data) = await MCP.handle(body, tools: JobHunt.huntTools, server: BrowserServer.huntName, instructions: "x") { _, _ in .text("") }
        XCTAssertEqual(status, 200)
        let names = try XCTUnwrap(((try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])?["result"] as? [String: Any])?["tools"] as? [[String: Any]]).compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), ["status", "list_roles", "role", "answer", "approve_suggestions", "apply", "rewrite_resume", "skip", "find_roles", "keep_applying"])
    }

    func testVideoKeyPointsDecodeOldAndNew() throws {
        let old = try JSONDecoder().decode([Video].self, from: Data(#"[{"id":"abc","title":"T","channel":"C","why":"W"}]"#.utf8))
        XCTAssertEqual(old.first?.keyPoints, "")
        var v = Video(id: "abc", title: "T", channel: "C", why: "W", keyPoints: "- two pointers")
        v = try JSONDecoder().decode(Video.self, from: JSONEncoder().encode(v))
        XCTAssertEqual(v.keyPoints, "- two pointers")
    }

    func testPlaylistURL() {
        let vids = (0..<60).map { Video(id: "id\($0)", title: "", channel: "", why: "") } + [Video(id: "id0", title: "", channel: "", why: "")]
        let url = Video.playlistURL(vids)?.absoluteString ?? ""
        XCTAssertTrue(url.hasPrefix("https://www.youtube.com/watch_videos?video_ids=id0,id1,"))
        XCTAssertEqual(url.components(separatedBy: "=").last?.split(separator: ",").count, 50)
        XCTAssertNil(Video.playlistURL([]))
    }

    @MainActor func testSpeakableStripsMarkdown() {
        let md = "# Two pointers\n- Move **left** when [sum](https://x.y) is small\n```swift\nlet x = 1\n```\n| a | b |"
        let spoken = SpeechReader.speakable(md)
        XCTAssertTrue(spoken.contains("Two pointers."))
        XCTAssertTrue(spoken.contains("Move left when sum is small."))
        XCTAssertTrue(spoken.contains("Code example skipped."))
        XCTAssertFalse(spoken.contains("let x"))
        XCTAssertFalse(spoken.contains("https"))
    }
}

final class TitleConflictTests: XCTestCase {
    func testUsingTitleFixesBothPlaces() {
        var b = AnswerBank()
        b.currentTitle = "Founding Software Engineer"
        b.employment = "Acme (formerly Beta) | Founding Product Engineer | New York | December 2024 – Present\nOld Co | Intern | NY | 2023 – 2024"
        XCTAssertEqual(b.titleConflict?.history, "Founding Product Engineer")
        let fixed = b.usingTitle("Founding Software Engineer")
        XCTAssertNil(fixed.titleConflict)
        XCTAssertTrue(fixed.historyConflicts.isEmpty)
        XCTAssertEqual(fixed.employment, "Acme (formerly Beta) | Founding Software Engineer | New York | December 2024 – Present\nOld Co | Intern | NY | 2023 – 2024")
        XCTAssertEqual(b.usingTitle("Founding Product Engineer").currentTitle, "Founding Product Engineer")
    }
}
