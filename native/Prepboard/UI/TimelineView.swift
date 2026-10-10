import SwiftData
import SwiftUI

/// The prep plan: a horizontal day track, then one block per day with big date numerals and
/// time-blocked sessions. Each session links to the exact guide sections to study.
struct PrepTimelineView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \Role.createdAt) private var roles: [Role]
    @Query(sort: \PrepTask.start) private var allTasks: [PrepTask]
    @Query private var docs: [Doc]

    private var role: Role? {
        if let id = app.timelineRoleID, let r = roles.first(where: { $0.id == id }) { return r }
        return roles.filter { ($0.interviewAt ?? .distantPast) > .now.addingTimeInterval(-3600) }
            .min { ($0.interviewAt ?? .distantFuture) < ($1.interviewAt ?? .distantFuture) } ?? roles.first
    }

    @State private var containerWidth: CGFloat = 1000

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            content(now: ctx.date)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
    }

    private func content(now: Date) -> some View {
        let role = role
        let cal = Calendar.current
        let all = allTasks.filter { role == nil || $0.roleId == role?.id }
        let visible = all.filter { (app.kindFilter == nil || $0.kind == app.kindFilter) && (app.showBreaks || !$0.isBreak) }
        var dayStarts = Set(all.map { cal.startOfDay(for: $0.start) })
        if let at = role?.interviewAt { dayStarts.insert(cal.startOfDay(for: at)) }
        let days = dayStarts.sorted()
        let docsById = Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0) })

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(role)
                    if !days.isEmpty { track(days: days, all: all, role: role, now: now, proxy: proxy) }
                    filters(all)
                    VStack(spacing: 0) {
                        ForEach(Array(days.enumerated()), id: \.element) { idx, day in
                            dayBlock(day, first: idx == 0, tasks: visible.filter { cal.isDate($0.start, inSameDayAs: day) },
                                     allOfDay: all.filter { cal.isDate($0.start, inSameDayAs: day) },
                                     role: role, now: now, docsById: docsById)
                                .id("day-\(dayKey(day))")
                        }
                        if days.isEmpty {
                            Text("No sessions yet. Add one to build your plan.").foregroundStyle(PB.muted)
                                .frame(maxWidth: .infinity).padding(40).pbCard()
                        }
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .onAppear { scroll(proxy, to: app.scrollTarget ?? "now", animated: false) }
            .onChange(of: app.scrollTarget) { _, target in scroll(proxy, to: target, animated: true) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to target: String?, animated: Bool) {
        guard let target else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animated { withAnimation(.snappy) { proxy.scrollTo(target, anchor: .center) } }
            else { proxy.scrollTo(target, anchor: .center) }
            app.scrollTarget = nil
        }
    }

    // MARK: header & filters

    private func header(_ role: Role?) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Prep plan" + (role.map { " · \($0.company) — \($0.title)" } ?? "")).pbLabelStyle()
                Text("Timeline").font(.pbDisplay).kerning(-1.4)
            }
            Spacer(minLength: 0)
            if roles.count > 1 {
                Menu {
                    ForEach(roles) { r in Button("\(r.company) — \(r.title)") { app.timelineRoleID = r.id } }
                } label: {
                    Text(role?.company ?? "Role").font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.button).buttonStyle(PillButtonStyle(filled: false, compact: true)).fixedSize()
            }
            Button("Jump to now") { app.scrollTarget = "now" }.buttonStyle(PillButtonStyle(filled: false, compact: true))
            Button("+ Session") { app.newSession(roleId: role?.id) }.buttonStyle(PillButtonStyle())
        }
    }

    private func filters(_ all: [PrepTask]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill("All", count: all.filter { !$0.isBreak }.count, on: app.kindFilter == nil) { app.kindFilter = nil }
                ForEach(SessionKind.allCases.filter { $0 != .break }) { k in
                    filterPill(k.label, count: all.filter { $0.kind == k }.count, on: app.kindFilter == k, swatch: k.color) {
                        app.kindFilter = app.kindFilter == k ? nil : k
                    }
                }
                Button(app.showBreaks ? "Hide breaks" : "Show breaks") { app.showBreaks.toggle() }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true))
            }
        }
    }

    private func filterPill(_ title: String, count: Int, on: Bool, swatch: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let swatch { RoundedRectangle(cornerRadius: 2).fill(on ? Color.white : swatch).frame(width: 8, height: 8) }
                Text(title).font(.system(size: 13, weight: .medium))
                Text("\(count)").font(.pbMono).opacity(0.6)
            }
            .padding(.horizontal, 16).frame(height: 36)
            .foregroundStyle(on ? Color.white : PB.ink2)
            .background(Capsule().fill(on ? PB.cobalt : PB.card))
            .overlay(Capsule().strokeBorder(on ? PB.cobalt : PB.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: track

    private func track(days: [Date], all: [PrepTask], role: Role?, now: Date, proxy: ScrollViewProxy) -> some View {
        let cal = Calendar.current
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element) { idx, day in
                    let ds = all.filter { cal.isDate($0.start, inSameDayAs: day) }
                    let work = ds.filter { !$0.isBreak }
                    let isToday = cal.isDateInToday(day)
                    let isInterview = role?.interviewAt.map { cal.isDate($0, inSameDayAs: day) } ?? false
                    VStack(alignment: .leading, spacing: 12) {
                        Button { withAnimation(.snappy) { proxy.scrollTo("day-\(dayKey(day))", anchor: .top) } } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(day.formatted(.dateTime.day())).font(.system(size: 22, weight: .bold)).kerning(-0.6)
                                Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated)) + (isToday ? " · Today" : ""))
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(isToday ? PB.cobalt : PB.muted)
                            }
                        }
                        .buttonStyle(.plain)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(PB.line2).frame(height: 1).padding(.horizontal, -16)
                            HStack(spacing: 8) {
                                ForEach(ds) { t in dot(t, now: now) }
                                if isInterview {
                                    Button { app.scrollTarget = "interview" } label: {
                                        Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(PB.onSun)
                                            .frame(width: 34, height: 34).background(Circle().fill(PB.sun))
                                            .overlay(Circle().strokeBorder(PB.onSun, lineWidth: 1.5))
                                    }
                                    .buttonStyle(.plain).help("Interview")
                                }
                            }
                        }
                        .frame(height: 36)
                        Text([work.isEmpty ? nil : "\(work.filter(\.done).count)/\(work.count) done",
                              isInterview ? "interview \(TimeFmt.hm(role!.interviewAt!))" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.pbMono).foregroundStyle(PB.muted)
                    }
                    .padding(.horizontal, 16)
                    .frame(minWidth: 190, alignment: .leading)
                    .overlay(alignment: .leading) { if idx > 0 { Rectangle().fill(PB.line).frame(width: 1) } }
                }
            }
            .padding(.vertical, 4)
        }
        .pbCard(padding: 16)
    }

    private func dot(_ t: PrepTask, now: Date) -> some View {
        let st = t.status(at: now)
        let size = max(10, min(22, 8 + CGFloat(t.minutes) / 12))
        return Button { app.scrollTarget = t.id } label: {
            Circle()
                .fill(st == .done ? PB.cobalt : st == .current ? PB.sun : st == .missed ? PB.surface : PB.card)
                .overlay(Circle().strokeBorder(t.isBreak || st == .missed ? PB.line2 : st == .done || st == .current ? PB.cobalt : PB.ink,
                                               style: StrokeStyle(lineWidth: 1.5, dash: t.isBreak ? [2] : [])))
                .background(st == .current ? Circle().fill(PB.sunSoft).padding(-4) : nil)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .help("\(TimeFmt.hm(t.start)) · \(t.title)")
        .accessibilityLabel("\(TimeFmt.hm(t.start)) \(t.title)")
    }

    // MARK: day block

    private func dayBlock(_ day: Date, first: Bool, tasks: [PrepTask], allOfDay: [PrepTask], role: Role?, now: Date,
                          docsById: [String: Doc]) -> some View {
        let cal = Calendar.current
        let isToday = cal.isDateInToday(day)
        let isPast = day < cal.startOfDay(for: now)
        let work = allOfDay.filter { !$0.isBreak }
        let interviewAt = role?.interviewAt.flatMap { cal.isDate($0, inSameDayAs: day) ? $0 : nil }

        enum Item: Identifiable {
            case session(PrepTask), interview(Date), now(Date)
            var id: String {
                switch self { case .session(let t): t.id; case .interview: "interview"; case .now: "now" }
            }
            var at: Date {
                switch self { case .session(let t): t.start; case .interview(let d): d; case .now(let d): d }
            }
        }
        var items: [Item] = tasks.map { .session($0) }
        if let interviewAt { items.append(.interview(interviewAt)) }
        items.sort { $0.at < $1.at }
        if isToday {
            let idx = items.firstIndex { $0.at > now } ?? items.count
            items.insert(.now(now), at: idx)
        }

        let numeral = VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 4) {
                Text(day.formatted(.dateTime.day(.twoDigits)))
                    .font(.system(size: 80, weight: .heavy)).kerning(-4)
                    .foregroundStyle(isPast ? PB.line2 : PB.ink)
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(isToday ? PB.cobalt : PB.muted).padding(.top, 12)
            }
            .frame(height: 76, alignment: .top)
            Text(day.formatted(.dateTime.month(.wide)) + (isToday ? " · Today" : "")).font(.system(size: 12)).foregroundStyle(PB.muted)
            if !work.isEmpty {
                ProgressBar(value: Double(work.filter(\.done).count) / Double(work.count)).frame(width: 120)
                Text("\(work.filter(\.done).count)/\(work.count) sessions").font(.pbMono).foregroundStyle(PB.muted)
            }
            Button("+ Session") { app.newSession(roleId: role?.id, day: day) }
                .buttonStyle(PillButtonStyle(filled: false, compact: true))
        }

        let list = VStack(alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                switch item {
                case .session(let t): SessionCard(task: t, now: now, docsById: docsById).id(t.id)
                case .interview(let at): interviewCard(role!, at: at, now: now).id("interview")
                case .now(let d): nowLine(d).id("now")
                }
            }
            if items.isEmpty { Text("Nothing scheduled.").foregroundStyle(PB.muted).padding(.vertical, 16) }
        }

        return Group {
            if containerWidth >= 600 {
                HStack(alignment: .top, spacing: 16) { numeral.frame(width: 128, alignment: .leading); list.frame(maxWidth: .infinity) }
            } else {
                VStack(alignment: .leading, spacing: 16) { numeral; list }
            }
        }
        .padding(.vertical, 24)
        .overlay(alignment: .top) { Rectangle().fill(first ? PB.cobalt : PB.line2).frame(height: first ? 2 : 1) }
    }

    private func nowLine(_ now: Date) -> some View {
        HStack(spacing: 12) {
            Circle().fill(PB.cobalt).frame(width: 9, height: 9)
            Text("Now \(TimeFmt.hm(now))").font(.system(size: 12, weight: .semibold, design: .monospaced))
            Rectangle().fill(PB.cobalt).frame(height: 1.5)
        }
        .foregroundStyle(PB.cobalt)
    }

    private func interviewCard(_ role: Role, at: Date, now: Date) -> some View {
        let s = max(0, Int(at.timeIntervalSince(now)))
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(TimeFmt.hm(at)).font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text(TimeFmt.hm(at.addingTimeInterval(45 * 60))).font(.system(size: 12, design: .monospaced)).opacity(0.6)
            }
            .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("INTERVIEW").font(.pbLabel).kerning(0.9).opacity(0.55)
                Text("\(role.company) — \(role.title)").font(.system(size: 21, weight: .bold)).kerning(-0.4)
                if !role.interviewNote.isEmpty { Text(role.interviewNote).opacity(0.65) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                ForEach([(s / 86400, "days"), (s % 86400 / 3600, "hours"), (s % 3600 / 60, "min")], id: \.1) { v, l in
                    VStack(spacing: 0) {
                        Text(String(format: "%02d", v)).font(.system(size: 22, weight: .bold)).monospacedDigit()
                        Text(l).font(.system(size: 11)).opacity(0.55)
                    }
                    .frame(minWidth: 58).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: PB.rMD).fill(PB.card.opacity(0.55)))
                    .overlay(RoundedRectangle(cornerRadius: PB.rMD).strokeBorder(PB.onSun.opacity(0.12)))
                }
            }
        }
        .foregroundStyle(PB.onSun)
        .padding(.horizontal, 24).padding(.vertical, 24)
        .background(RoundedRectangle(cornerRadius: PB.rLG, style: .continuous).fill(PB.sun))
    }

    private func dayKey(_ d: Date) -> String { DateCoding.dayString(d) }
}

/// One time block on the timeline.
struct SessionCard: View {
    @Bindable var task: PrepTask
    let now: Date
    let docsById: [String: Doc]
    @Environment(AppState.self) private var app

    var body: some View {
        let st = task.status(at: now)
        let current = st == .current
        let fg: Color = current ? .white : PB.ink
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(TimeFmt.hm(task.start)).font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(st == .missed ? PB.muted : fg)
                Text(TimeFmt.hm(task.end)).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(current ? Color.white.opacity(0.6) : PB.muted)
            }
            .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                if !task.isBreak {
                    HStack(spacing: 12) {
                        KindLabel(kind: task.kind, inverted: current)
                        Text(TimeFmt.duration(task.minutes)).font(.pbMono).foregroundStyle(current ? Color.white.opacity(0.6) : PB.muted)
                        if current {
                            Text("NOW").font(.system(size: 11, weight: .bold)).foregroundStyle(PB.onSun)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(PB.sun))
                        }
                    }
                }
                Text(task.title)
                    .font(.system(size: task.isBreak ? 14 : 16, weight: task.isBreak ? .medium : .semibold))
                    .foregroundStyle(task.isBreak || st == .done ? PB.muted : fg)
                    .strikethrough(st == .done)
                    .fixedSize(horizontal: false, vertical: true)
                if !task.refs.isEmpty {
                    FlowLayout(spacing: 8) {
                        ForEach(task.refs, id: \.self) { RefChip(ref: $0, doc: docsById[$0.docId], inverted: current) }
                    }
                    .padding(.top, 4)
                }
                if !task.isBreak { SessionLearnRow(task: task, inverted: current) }
            }
            .padding(.leading, 16)
            .overlay(alignment: .leading) { Rectangle().fill(current ? Color.white.opacity(0.15) : PB.line).frame(width: 1) }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if !task.isBreak {
                    Toggle("Done", isOn: $task.done).toggleStyle(CheckboxToggleStyle(inverted: current))
                }
                Button { app.editSession(task) } label: {
                    Image(systemName: "pencil").font(.system(size: 12))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(current ? Color.white : PB.ink2)
                        .overlay(Circle().strokeBorder(current ? Color.white.opacity(0.25) : PB.line))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help("Edit session")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, task.isBreak ? 10 : 16)
        .background(
            RoundedRectangle(cornerRadius: PB.rLG, style: .continuous)
                .fill(task.isBreak ? Color.clear : current ? PB.cobalt : st == .done ? PB.card.opacity(0.5) : PB.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PB.rLG, style: .continuous)
                .strokeBorder(current ? PB.cobalt : task.isBreak ? PB.line2 : PB.line, style: StrokeStyle(lineWidth: 1, dash: task.isBreak ? [4] : []))
        )
    }
}
