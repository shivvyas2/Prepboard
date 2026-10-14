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
