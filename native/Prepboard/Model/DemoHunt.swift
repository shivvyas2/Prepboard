#if DEBUG
import Foundation
import SwiftData

/// Sample Hunt data for simulator screenshots; never used outside the in-memory preview store.
enum DemoHunt {
    @MainActor static func seed(_ context: ModelContext) {
        let s = HuntSettings()
        var bank = AnswerBank()
        bank.fullName = "Alex Rivera"; bank.email = "alex@example.com"; bank.phone = "555-010-2000"; bank.city = "Jersey City"
        bank.visaStatus = "f1stemopt"
        bank.remote.macStatus = "Applying to Ramp…"; bank.remote.macStatusAt = DateCoding.string(.now.addingTimeInterval(-40))
        bank.remote.macKeepApplying = true
        s.answerBank = bank
        context.insert(s)
        func lead(_ company: String, _ title: String, _ status: LeadStatus, score: Int, reason: String, queued: Bool = false) {
            let l = Lead(company: company, title: title, location: "New York, NY", link: "https://jobs.example.com/\(company)", source: "linkedin-search",
                         score: score, scoreReason: "Swift, SwiftUI and AVFoundation match; no Kotlin.", status: status)
            l.reason = reason; l.submitRequested = queued; l.baseVariant = "Alex-Rivera-iOS"
            l.coverage = [Coverage(term: "SwiftUI", covered: true), Coverage(term: "AVFoundation", covered: true), Coverage(term: "Kotlin", covered: false)]
            context.insert(l)
        }
        lead("Ramp", "iOS Engineer", .submitting, score: 91, reason: "Applying now.")
        lead("Figma", "Software Engineer, Mobile", .ready, score: 88, reason: "Built from the iOS base. Keywords: 94%. ATS: parses cleanly.")
        lead("Robinhood", "iOS Engineer II", .ready, score: 84, reason: "Keywords: 81%. ATS: parses cleanly.", queued: true)
        lead("Yuzu", "Fullstack Engineer", .needsYou, score: 76, reason: "Claude suggested 2 answers. Keywords: 72%. ATS: Dates use more than one format.")
        lead("Hebbia", "Frontend Engineer", .submitted, score: 82, reason: "Application received.")
        lead("iBegin", "Software Engineer", .skipped, score: 74, reason: Lead.byHandPrefix + "the site needs an account.")
        try? context.save()
    }
}
#endif
