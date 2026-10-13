import Foundation

/// The hosted applicant-tracking systems the hunt knows how to apply on. Pure functions, used by the submit prompt on the Mac
/// and compiled everywhere.
enum ATS: Equatable {
    case ashby, greenhouse, lever, workable, workday, linkedin, other

    /// By host: jobs.ashbyhq.com; *.greenhouse.io; jobs.lever.co; apply.workable.com / *.workable.com; *.myworkdayjobs.com; *.linkedin.com.
    static func kind(_ link: String) -> ATS {
        guard let host = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return .other }
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("jobs.ashbyhq.com") { return .ashby }
        if on("greenhouse.io") { return .greenhouse }
        if on("jobs.lever.co") { return .lever }
        if on("workable.com") { return .workable }
        if on("myworkdayjobs.com") { return .workday }
        if on("linkedin.com") { return .linkedin }
        return .other
    }

    /// Where Submit should start: Ashby `/<org>/<id>` gains `/application` before the query string (unchanged when present);
    /// Lever `/<org>/<id>` gains `/apply`; everything else is returned as is.
    static func applicationURL(_ link: String) -> String {
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)   // the same input `kind` sees
        let suffix: String
        switch kind(link) {
        case .ashby: suffix = "application"
        case .lever: suffix = "apply"
        default: return link
        }
        guard let url = URL(string: link), url.pathComponents.filter({ $0 != "/" }).count == 2 else { return link }
        let end = link.firstIndex { $0 == "?" || $0 == "#" } ?? link.endIndex
        var base = String(link[..<end])
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/" + suffix + link[end...]
    }

    /// Site-specific notes for the submit prompt ("" for .other). Written for the built-in browser's tool names;
    /// the Chrome path swaps upload_file for file_upload.
    static func formNotes(_ kind: ATS) -> String {
        switch kind {
        case .ashby:
            "Ashby: one page; required fields carry an asterisk. The résumé field (\"Resume\" or \"Resume/CV\") shows an \"Upload File\" "
            + "button over a hidden file input: use upload_file on that ref. Ignore the \"Autofill application\" / \"autofill from résumé\" "
            + "option. Dropdowns are custom comboboxes: click the field, then click the option. Yes/No questions are button groups. "
            + "The button is \"Submit Application\"; success shows \"Application submitted\" or \"Thank you\"."
        case .greenhouse:
            "Greenhouse: the form is on the job page under \"Apply for this job\" (or #app). The résumé \"Attach\" button opens a file "
            + "input: use upload_file on \"Attach\", never \"Enter manually\". Dropdowns are custom comboboxes: click the field, then click "
            + "the option. EEO questions sit at the bottom. The button is \"Submit Application\"; success shows \"Thank you for applying\"."
        case .lever:
            "Lever: the /apply page. The résumé field \"ATTACH RESUME/CV\" is a file input; the other fields are plain. "
            + "The button is \"Submit application\"; success shows \"Application submitted\"."
        case .workable:
            "Workable: an \"Apply\" button opens the form, which may have several steps (\"Next\"). Upload the résumé first. "
            + "The button is \"Submit application\"."
        case .workday:
            "Workday: this site needs an account. Do not create one: return status \"needs_you\" with reason \"Workday asks for an account\"."
        case .linkedin:
            "LinkedIn: use Easy Apply when it is offered (a multi-step dialog: Next, Review, then Submit application; the résumé upload "
            + "has its own step). Otherwise press Apply, and the company's own application page (Ashby, Greenhouse, Lever, Workable or a "
            + "company form) opens in this same browser: continue there with these same rules."
        case .other:
            ""
        }
    }
}
