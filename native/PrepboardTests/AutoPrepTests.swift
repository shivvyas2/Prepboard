import XCTest
@testable import Prepboard

@MainActor
final class AutoPrepTests: XCTestCase {
    // Built without a container, like HuntTests: a second ModelContainer traps inside the test host.
    private let now = Date(timeIntervalSince1970: 1_791_900_000)

    private func role(interviewIn hours: Double?, stage: Stage = .technical) -> Role {
        Role(company: "Apple", title: "Senior Software Engineer, AVKit", stage: stage,
             interviewAt: hours.map { now.addingTimeInterval($0 * 3600) })
    }

    private func task(_ r: Role, startIn hours: Double) -> PrepTask {
        PrepTask(roleId: r.id, title: "Session", start: now.addingTimeInterval(hours * 3600), end: now.addingTimeInterval((hours + 1) * 3600))
    }

    func testPlansAnUpcomingInterviewWhenTheTimelineIsEmpty() {
        let r = role(interviewIn: 48)
        XCTAssertTrue(AutoPrep.needsPlan(r, tasks: [], now: now))
    }

    func testOnlyOldSessionsStillNeedANewPlan() {
        // The Apple case: round 1's sessions all ended before round 2 was scheduled.
        let r = role(interviewIn: 48)
        XCTAssertTrue(AutoPrep.needsPlan(r, tasks: [task(r, startIn: -60), task(r, startIn: -30)], now: now))
    }

    func testAnUpcomingSessionMeansThePlanExists() {
        let r = role(interviewIn: 48)
        XCTAssertFalse(AutoPrep.needsPlan(r, tasks: [task(r, startIn: 5)], now: now))
    }

    func testAnotherRolesSessionsDontCount() {
        let r = role(interviewIn: 48), other = role(interviewIn: 72)
        XCTAssertTrue(AutoPrep.needsPlan(r, tasks: [task(other, startIn: 5)], now: now))
    }

    func testSkipsInterviewsTooSoonTooFarOrNotInPlay() {
        XCTAssertFalse(AutoPrep.needsPlan(role(interviewIn: 2), tasks: [], now: now))
        XCTAssertFalse(AutoPrep.needsPlan(role(interviewIn: 24 * 40), tasks: [], now: now))
        XCTAssertFalse(AutoPrep.needsPlan(role(interviewIn: nil), tasks: [], now: now))
        XCTAssertFalse(AutoPrep.needsPlan(role(interviewIn: 48, stage: .closed), tasks: [], now: now))
        XCTAssertFalse(AutoPrep.needsPlan(role(interviewIn: 48, stage: .offer), tasks: [], now: now))
    }

    func testPromptCarriesTheEmailsGuidesAndRules() {
        let r = role(interviewIn: 48)
        r.activity = "- 2026-10-13 · Gmail · Passed; invited to second CoderPad round"
        let doc = Doc(roleId: r.id, title: "Swift CoderPad Cheatsheet", body: "", tags: ["guide"], order: 0)
        let p = AutoPrep.prompt(role: r, docs: [doc], past: [task(r, startIn: -30)], now: now)
        XCTAssertTrue(p.contains("second CoderPad round"))
        XCTAssertTrue(p.contains("existing:\(doc.id)"))
        XCTAssertTrue(p.contains("Do not ask questions"))
        XCTAssertTrue(p.contains("Google Calendar"))
    }
}
