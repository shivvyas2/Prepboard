import XCTest
@testable import Prepboard

final class ResumeFoldersTests: XCTestCase {
    func testCompanyComesAfterTheName() {
        XCTAssertEqual(ResumeFolders.company(of: "Shiv-Vyas-Apple-WatchSetup-SWE", firstName: "Shiv"), "Apple")
        XCTAssertEqual(ResumeFolders.company(of: "Shiv-Amitkumar-Google-SoftwareEngineerFront", firstName: "Shiv"), "Google")
        XCTAssertEqual(ResumeFolders.company(of: "Shiv_Vyas_Audible_iOS", firstName: "Shiv"), "Audible")
        XCTAssertEqual(ResumeFolders.company(of: "shiv-vyas-knot-ios", firstName: "Shiv"), "knot")
        XCTAssertNil(ResumeFolders.company(of: "Shiv Vyas copy 2", firstName: "Shiv"))
        XCTAssertNil(ResumeFolders.company(of: "Jainam_Resume", firstName: "Shiv"))
        XCTAssertNil(ResumeFolders.company(of: "Yahoo_Paranoids_Final_Round_Study_Plan", firstName: "Shiv"))
    }

    func testCopiesAreOneVariant() {
        XCTAssertEqual(ResumeFolders.variantKey("Shiv-Vyas-Apple-ScreenSharing-SDE copy"), ResumeFolders.variantKey("Shiv-Vyas-Apple-ScreenSharing-SDE"))
        XCTAssertEqual(ResumeFolders.variantKey("Shiv-Vyas-Apple-ScreenSharing-SDE_1"), ResumeFolders.variantKey("Shiv-Vyas-Apple-ScreenSharing-SDE"))
        XCTAssertEqual(ResumeFolders.variantKey("Shiv_Vyas_Audible_iOS"), ResumeFolders.variantKey("Shiv-Vyas-Audible-iOS"))
        XCTAssertNotEqual(ResumeFolders.variantKey("Shiv-Vyas-Arlo-ProductEngineer-2"), ResumeFolders.variantKey("Shiv-Vyas-Arlo-ProductEngineer"))
    }

    func testOnlyCompaniesWithTwoVariantsGetAFolder() {
        let place = ResumeFolders.placement(stems: [
            "Shiv-Vyas-Arlo-ProductEngineer", "Shiv-Vyas-Arlo-ProductEngineer-2", "Shiv-Vyas-Arlo-CoverLetter",
            "Shiv-Vyas-Audible-iOS", "Shiv_Vyas_Audible_iOS",
            "Shiv-Vyas-Netflix-SeniorSWEiOS", "Shiv-Vyas-Netflix-SeniorSWEiOS",
            "Shiv-Vyas-Google-SWE-CoverLetter", "Shiv Vyas",
        ], firstName: "Shiv")
        XCTAssertEqual(place["Shiv-Vyas-Arlo-ProductEngineer"], "Arlo")
        XCTAssertEqual(place["Shiv-Vyas-Arlo-CoverLetter"], "Arlo")          // follows its company
        XCTAssertEqual(place["Shiv-Vyas-Audible-iOS"], "")                  // a copy is not a second variant
        XCTAssertEqual(place["Shiv-Vyas-Netflix-SeniorSWEiOS"], "")         // its .tex and .pdf are one variant
        XCTAssertEqual(place["Shiv-Vyas-Google-SWE-CoverLetter"], "")       // a cover letter alone never makes a folder
        XCTAssertEqual(place["Shiv Vyas"], "")
    }

    func testOrganizeSortsAndRegroups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("resume-folders-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        for f in ["Shiv-Vyas-Ramp-iOS.tex", "Shiv-Vyas-Ramp-iOS.pdf", "Shiv-Vyas-Figma-SWE.tex", "Shiv-Vyas-Figma-SWE.pdf", "notes.md"] {
            try f.write(toFile: root + "/" + f, atomically: true, encoding: .utf8)
        }
        ResumeFolders.organize(root: root, firstName: "Shiv")
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: root + "/TeX/Shiv-Vyas-Ramp-iOS.tex"))
        XCTAssertTrue(fm.fileExists(atPath: root + "/PDF/Shiv-Vyas-Ramp-iOS.pdf"))
        XCTAssertTrue(fm.fileExists(atPath: root + "/notes.md"))            // not a résumé file: left alone

        // A second Ramp variant moves both into Ramp/ in each tree.
        try "x".write(toFile: root + "/TeX/Shiv-Vyas-Ramp-Frontend.tex", atomically: true, encoding: .utf8)
        let moves = ResumeFolders.organize(root: root, firstName: "Shiv")
        XCTAssertEqual(moves[root + "/PDF/Shiv-Vyas-Ramp-iOS.pdf"], root + "/PDF/Ramp/Shiv-Vyas-Ramp-iOS.pdf")
        XCTAssertTrue(fm.fileExists(atPath: root + "/TeX/Ramp/Shiv-Vyas-Ramp-Frontend.tex"))
        XCTAssertEqual(ResumeFolders.find("Shiv-Vyas-Ramp-iOS", ext: "tex", in: root), root + "/TeX/Ramp/Shiv-Vyas-Ramp-iOS.tex")
        XCTAssertEqual(ResumeFolders.pdfFolder(forTex: root + "/TeX/Ramp/Shiv-Vyas-Ramp-iOS.tex"), root + "/PDF/Ramp")
        XCTAssertTrue(ResumeFolders.organize(root: root, firstName: "Shiv").isEmpty)   // already tidy

        // Back to one variant: the folder goes away.
        try fm.removeItem(atPath: root + "/TeX/Ramp/Shiv-Vyas-Ramp-Frontend.tex")
        ResumeFolders.organize(root: root, firstName: "Shiv")
        XCTAssertTrue(fm.fileExists(atPath: root + "/TeX/Shiv-Vyas-Ramp-iOS.tex"))
        XCTAssertFalse(fm.fileExists(atPath: root + "/TeX/Ramp"))
        XCTAssertFalse(fm.fileExists(atPath: root + "/PDF/Ramp"))
    }
}
