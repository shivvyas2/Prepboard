import XCTest
@testable import Prepboard

final class ResumeContactTests: XCTestCase {
    static let header = #"""
    % APPLE VARIANT: iOS Engineer
    % reach me at old@example.com
    \begin{document}
    \begin{tabularx}{\linewidth}{@{} C @{}}
    \LARGE{Shiv Amitkumar Vyas} \\[2pt]
    \normalsize{Frontend Engineer \ $|$ \ TypeScript, React \ $|$ \ Agent Interfaces} \\[2pt]
    New Jersey \ $|$ \
    551-342-5622 \ $|$ \
    \href{mailto:shivvyas0209@gmail.com}{shivvyas0209@gmail.com} \ $|$ \
    \href{https://www.linkedin.com/in/shivvyas/}{linkedin.com/in/shivvyas} \ $|$ \
    \href{https://github.com/shivvyas2}{github.com/shivvyas2} \ $|$ \
    \href{https://shivvyas.com}{shivvyas.com} \\
    \end{tabularx}
    \section{Experience}
    \href{https://github.com/shivvyas2/astra}{Sanchara} 2025 -- 2026 (201) 555-0000
    """#

    func testReadsContactBlock() {
        let c = ResumeLibrary.contact(fromTex: Self.header)
        XCTAssertEqual(c.fullName, "Shiv Amitkumar Vyas")
        XCTAssertEqual(c.email, "shivvyas0209@gmail.com")
        XCTAssertEqual(c.phone, "551-342-5622")
        XCTAssertEqual(c.city, "New Jersey")
        XCTAssertEqual(c.linkedin, "https://www.linkedin.com/in/shivvyas/")
        XCTAssertEqual(c.github, "https://github.com/shivvyas2")
        XCTAssertEqual(c.portfolio, "https://shivvyas.com")
    }

    func testNoNameMeansNothing() {
        XCTAssertEqual(ResumeLibrary.contact(fromTex: "\\section{Work} a@b.co 5513425622"), AnswerBank())
    }

    func testFillingNeverOverwrites() {
        var bank = AnswerBank(); bank.email = "mine@x.com"; bank.city = " "
        var found = AnswerBank(); found.email = "other@x.com"; found.phone = "551-342-5622"; found.city = "New Jersey"
        let (result, filled) = ResumeLibrary.filling(bank, from: found)
        XCTAssertEqual(result.email, "mine@x.com")
        XCTAssertEqual(result.phone, "551-342-5622")
        XCTAssertEqual(result.city, "New Jersey")
        XCTAssertEqual(filled, ["phone", "city"])
    }
}

final class InterviewBriefTests: XCTestCase {
    static let apple = "Second technical round. 45 min, 12:00-12:45 PM ET on Webex with live coding in CoderPad. One interviewer: Mushegh, an AVKit team member. The candidate picks C, C++, Objective-C or Swift. Coordinator is Ash Powlesland (apowlesland@apple.com, +1-919-357-6770) and the sourcer is JC Domingo. If Webex fails, the interviewer will call 551-342-5622. Join no more than 10 minutes early. The confirmation email has no CoderPad link, unlike round 1."

    func testSplitsAppleNote() {
        let b = InterviewBrief(note: Self.apple)
        XCTAssertEqual(b.round, "Second technical round")
        XCTAssertEqual(b.minutes, 45)
        XCTAssertEqual(b.earlyMinutes, 10)
        XCTAssertEqual(b.tools, ["Webex", "CoderPad"])
        XCTAssertEqual(b.details.map(\.kind), [.person, .language, .contact, .phone, .warning])
        XCTAssertEqual(b.details[2].text, "Coordinator is Ash Powlesland (apowlesland@apple.com, +1-919-357-6770) and the sourcer is JC Domingo")
    }

    func testEmptyNote() {
        XCTAssertEqual(InterviewBrief(note: "  "), InterviewBrief(note: ""))
        XCTAssertTrue(InterviewBrief(note: "").details.isEmpty)
    }
}

@MainActor
final class DocOrderTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(DocKind(tags: ["guide"], isPDF: false), .guide)
        XCTAssertEqual(DocKind(tags: [], isPDF: false), .guide)
        XCTAssertEqual(DocKind(tags: ["essentials", "essentials:why"], isPDF: false), .essentials)
        XCTAssertEqual(DocKind(tags: ["claude"], isPDF: false), .research)
        XCTAssertEqual(DocKind(tags: ["jd"], isPDF: false), .material)
        XCTAssertEqual(DocKind(tags: ["pdf", "resume", "hunt"], isPDF: true), .resume)
        XCTAssertEqual(DocKind(tags: ["pdf", "resume", "original"], isPDF: true), .pdf)
    }

    func testArrangedGroupsKindsBeforeNumbers() {
        let research = Doc(title: "Research", tags: ["research"], order: 1)
        let essential = Doc(title: "Why", tags: ["essentials"], order: 1)
        let late = Doc(title: "Next round brief", tags: ["guide"], order: 1000)
        let first = Doc(title: "Start here", tags: ["guide"], order: 0)
        XCTAssertEqual(DocOrder.arranged([research, late, essential, first]).map(\.title), ["Start here", "Next round brief", "Why", "Research"])
    }
}
