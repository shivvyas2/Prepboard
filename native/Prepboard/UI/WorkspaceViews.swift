#if os(macOS)
import AppKit
import SwiftUI

/// A section in its own window. It has its own AppState, so it can show something different from the main window.
struct DetachedSectionView: View {
    @Environment(AppState.self) private var app
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Menu {
                    ForEach(Section.allCases) { section in
                        Button {
                            app.section = section
                        } label: {
                            if app.section == section {
                                Label(section.rawValue, systemImage: "checkmark")
                            } else {
                                Label(section.rawValue, systemImage: section.icon)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Label(app.section.rawValue, systemImage: app.section.icon)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(PB.cobalt)
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(PB.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PB.line))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Section: \(app.section.rawValue)")
                .help("Switch the section in this window")
                Spacer(minLength: 0)
                Text("PrepBoard workspace").font(.system(size: 12)).foregroundStyle(PB.muted).lineLimit(1)
            }
            SectionContent(section: app.section)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16).padding(.top, 12)
            .frame(minWidth: 480, minHeight: 480)
            .background(PB.background)
            .foregroundStyle(PB.ink)
            .tint(PB.cobalt)
            .modifier(AppSheets())
            .background(HostWindowReader { if window !== $0 { window = $0 } })
            .onChange(of: app.section) { WorkspaceManager.shared.sectionChanged(in: window, to: app.section) }
    }
}

/// The docked video player, in its own window.
struct DetachedVideoView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if let v = app.sideVideo {
                ScrollView { SideVideoPanel(video: v) }
            } else {
                Text("No video playing. Play a walkthrough from Coding or Documents.")
                    .foregroundStyle(PB.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16).padding(.top, 12)
        .frame(minWidth: 420, minHeight: 320)
        .background(PB.background)
    }
}

/// Offered once per new screen setup: "3 screens connected — set up Command Center?"
struct WorkspaceBanner: View {
    let layouts: [WorkspaceLayout]
    @Environment(WorkspaceManager.self) private var workspace

    var body: some View {
        if let best = layouts.first {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PB.s4) {
                    summary(best).frame(minWidth: 220)
                    Spacer(minLength: PB.s2)
                    actions(best)
                }
                VStack(alignment: .leading, spacing: PB.s3) {
                    summary(best)
                    ViewThatFits(in: .horizontal) {
                        actions(best)
                        VStack(alignment: .leading, spacing: PB.s2) {
                            setupButton(best)
                            HStack(spacing: PB.s3) {
                                otherLayouts
                                dismissButton
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PB.s4).padding(.vertical, PB.s3)
            .background(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).fill(PB.card))
            .overlay(RoundedRectangle(cornerRadius: PB.rMD, style: .continuous).strokeBorder(PB.line2))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
    }

    private func summary(_ layout: WorkspaceLayout) -> some View {
        HStack(alignment: .top, spacing: PB.s3) {
            Image(systemName: "rectangle.3.group").font(.system(size: 18)).foregroundStyle(PB.cobalt)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(workspace.screens.count) screens connected").font(.system(size: 13, weight: .semibold))
                Text(Self.describe(layout, screens: workspace.screens))
                    .font(.system(size: 12)).foregroundStyle(PB.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func actions(_ best: WorkspaceLayout) -> some View {
        HStack(spacing: PB.s3) {
            setupButton(best)
            otherLayouts
            dismissButton
        }
    }

    private func setupButton(_ layout: WorkspaceLayout) -> some View {
        Button("Set up \(layout.name)") { workspace.apply(layout) }
            .buttonStyle(PillButtonStyle(compact: true)).fixedSize()
    }

    @ViewBuilder private var otherLayouts: some View {
        if layouts.count > 1 {
            Menu("Other layouts") {
                ForEach(layouts.dropFirst()) { layout in Button(layout.name) { workspace.apply(layout) } }
            }
            .menuStyle(.button).fixedSize()
        }
    }

    private var dismissButton: some View {
        Button("Not now") { workspace.dismissSuggestion() }
            .buttonStyle(.plain).foregroundStyle(PB.muted).fixedSize()
            .padding(.vertical, 8)
    }

    /// "Coding on Acer K272HUL · Browse and Claude on Smart M50C"
    static func describe(_ layout: WorkspaceLayout, screens: [WorkspaceScreen]) -> String {
        guard !screens.isEmpty else { return "" }
        var byScreen: [Int: [String]] = [:]
        for s in layout.slots { byScreen[min(s.screen, screens.count - 1), default: []].append(s.content.title) }
        return byScreen.keys.sorted().map { i in
            let names = byScreen[i]!
            return (names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names[0]) + " on " + screens[i].name
        }.joined(separator: " · ")
    }
}

/// Workspace menu: layouts, saving, and moving windows between screens.
struct WorkspaceCommands: Commands {
    let workspace: WorkspaceManager

    var body: some Commands {
        CommandMenu("Workspace") {
            Menu("Apply Layout") {
                SwiftUI.Section("Recommended for \(workspace.screens.count) screen\(workspace.screens.count == 1 ? "" : "s")") {
                    ForEach(workspace.recommended()) { l in Button(l.name) { workspace.apply(l) } }
                }
                if !workspace.namedLayouts.isEmpty {
                    SwiftUI.Section("Saved") {
                        ForEach(workspace.namedLayouts) { l in Button(l.name) { workspace.apply(l) } }
                    }
                }
            }
            Button("Save Current Layout…") { promptSave() }
            if !workspace.namedLayouts.isEmpty {
                Menu("Delete Saved Layout") {
                    ForEach(workspace.namedLayouts) { l in Button(l.name) { workspace.deleteNamed(l.name) } }
                }
            }
            Divider()
            Button("Move Window to Next Screen") { workspace.moveKeyWindowToNextScreen() }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .option, .command])
                .disabled(workspace.screens.count < 2)
            Menu("Move Window to") {
                ForEach(workspace.screens) { s in Button(s.name) { workspace.moveKeyWindow(to: s) } }
            }
            .disabled(workspace.screens.count < 2)
            Button("Gather Windows on This Screen") { workspace.gatherOnKeyScreen() }
            Divider()
            Menu("Open Section in New Window") {
                ForEach(Section.allCases) { s in Button(s.rawValue) { workspace.open(.section(s)) } }
            }
            Button("Open Claude in Its Own Window") { workspace.open(.claude) }
            Button("Close Extra Windows") { workspace.closeDetached() }
        }
    }

    private func promptSave() {
        let alert = NSAlert()
        alert.messageText = "Save this layout"
        alert.informativeText = "Saves which sections and panels are open, on which screen, and where."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Layout name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { workspace.saveCurrent(named: name) }
    }
}

extension WorkspaceScreen: Identifiable {}
#endif
