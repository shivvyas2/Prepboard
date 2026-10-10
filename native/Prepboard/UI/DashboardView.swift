import SwiftData
import SwiftUI

/// Home: everything at a glance — time left, what's on now, today's hour strip, priorities,
/// today's checklist, the day-by-day countdown plan, pipeline and recent docs.
struct DashboardView: View {
    @Environment(AppState.self) private var app
    @Environment(Profile.self) private var profile
    @Environment(\.modelContext) private var context
    @Query(sort: \Role.createdAt) private var roles: [Role]
    @Query(sort: \Doc.updatedAt, order: .reverse) private var docs: [Doc]
    @Query(sort: \PrepTask.start) private var tasks: [PrepTask]

    private var nextInterview: Role? {
        roles.filter { ($0.interviewAt ?? .distantPast) > Date.now.addingTimeInterval(-3600) }
            .min { ($0.interviewAt ?? .distantFuture) < ($1.interviewAt ?? .distantFuture) }
    }
    private var activeRole: Role? {
        if let id = app.timelineRoleID, let r = roles.first(where: { $0.id == id }) { return r }
        return nextInterview ?? roles.first
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            GeometryReader { geo in
                ScrollView {
                    layout(width: geo.size.width, now: ctx.date).padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func layout(width: CGFloat, now: Date) -> some View {
        let sess = tasks.filter { $0.roleId == activeRole?.id }
        if width > 1100 {
            VStack(spacing: 18) {
                HStack(alignment: .top, spacing: 18) { hero(now).frame(maxHeight: .infinity); upNext(sess, now: now).frame(width: 380) }
                    .fixedSize(horizontal: false, vertical: true)
                stats(sess, now: now)
                todayStrip(sess, now: now)
                if width > 1260 {
                    HStack(alignment: .top, spacing: 18) {
                        priorities(sess, now: now)
                        todaysTasks(sess, now: now)
                        countdownPlan(sess, now: now).frame(width: 300)
                    }
                } else {
                    HStack(alignment: .top, spacing: 18) { priorities(sess, now: now); todaysTasks(sess, now: now) }
                    countdownPlan(sess, now: now)
                }
                HStack(alignment: .top, spacing: 18) { pipeline; recent.frame(width: 380) }
            }
        } else {
            VStack(spacing: 18) {
                hero(now)
                upNext(sess, now: now)
                stats(sess, now: now)
                todayStrip(sess, now: now)
                priorities(sess, now: now)
                todaysTasks(sess, now: now)
                countdownPlan(sess, now: now)
                pipeline
                recent
            }
        }
    }

    // MARK: hero & countdown

    private func hero(_ now: Date) -> some View {
        let next = nextInterview
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 20) { heroText(next); Spacer(minLength: 0); timeLeft(next, now: now) }
            VStack(alignment: .leading, spacing: 18) { heroText(next); timeLeft(next, now: now) }
        }
        .pbCard()
    }

    private func heroText(_ next: Role?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { app.showProfile = true } label: {
                HStack(spacing: 12) {
                    ProfileAvatar(size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(greeting + (profile.firstName.isEmpty ? "" : ", \(profile.firstName)")).font(.system(size: 15, weight: .semibold))
                        Text(profile.headline.isEmpty ? "Set up your profile" : profile.headline).font(.system(size: 12)).foregroundStyle(PB.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
            Text(next != nil ? "Next interview" : roles.isEmpty ? "Get started" : "No interview scheduled").pbLabelStyle()
            Text(next?.company ?? (roles.isEmpty ? "What are you preparing for?" : "No interview scheduled")).font(.pbDisplay).kerning(-1.4)
                .fixedSize(horizontal: false, vertical: true)
            Text(next.map { [$0.title, $0.interviewAt?.pbFull, $0.interviewNote].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ") }
                 ?? (roles.isEmpty ? "Chat with the planner: tell it the role and paste the job posting, and it builds your timeline, sessions and study guides."
                                   : "Add an interview date to a role to start a countdown."))
                .font(.system(size: 14)).foregroundStyle(PB.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let next {
                HStack(spacing: 8) {
                    Button("Open timeline") { app.timelineRoleID = next.id; app.section = .timeline; app.scrollTarget = "now" }
                        .buttonStyle(PillButtonStyle())
                    Button("Role details") { app.openRole(next.id) }
                        .buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
                .padding(.top, 10)
            } else {
                HStack(spacing: 8) {
                    Button("✦ Start something new") { app.showNewPrep = true }.buttonStyle(PillButtonStyle())
                    Button("Add a role manually") { app.newRole(context) }.buttonStyle(PillButtonStyle(filled: false, compact: true))
                }
                .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private func timeLeft(_ next: Role?, now: Date) -> some View {
        if let at = next?.interviewAt {
            let s = max(0, Int(at.timeIntervalSince(now)))
            VStack(alignment: .leading, spacing: 8) {
                Text("Time left").pbLabelStyle()
                HStack(spacing: 10) {
                    cell(s / 86400, "days"); cell(s % 86400 / 3600, "hours"); cell(s % 3600 / 60, "min")
                }
            }
        }
    }

    private func cell(_ v: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(String(format: "%02d", v)).font(.system(size: 28, weight: .bold)).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(PB.muted)
        }
        .frame(minWidth: 74).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: PB.rLG).fill(PB.sunSoft))
        .overlay(RoundedRectangle(cornerRadius: PB.rLG).strokeBorder(PB.sun.opacity(0.45)))
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    // MARK: up next

    @ViewBuilder
    private func upNext(_ sess: [PrepTask], now: Date) -> some View {
        let current = sess.first { $0.status(at: now) == .current && !$0.isBreak }
        let docsById = Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0) })
        if let t = current ?? sess.first(where: { !$0.done && !$0.isBreak && $0.end > now }) {
            VStack(alignment: .leading, spacing: 12) {
                Text(current != nil ? "Happening now" : "Up next").font(.pbLabel).kerning(0.9).textCase(.uppercase)
                    .foregroundStyle(PB.sun)
                Text("\(t.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(TimeFmt.hm(t.start))–\(TimeFmt.hm(t.end))")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                Text(t.title).font(.system(size: 21, weight: .semibold)).kerning(-0.3).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                if !t.refs.isEmpty {
                    FlowLayout(spacing: 6) { ForEach(t.refs, id: \.self) { RefChip(ref: $0, doc: docsById[$0.docId], inverted: true) } }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button("Mark done") { t.done = true }
                    Button("On timeline →") { app.gotoSession(t) }
                }
                .buttonStyle(InvertedGhostStyle())
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous).fill(PB.cobalt))
        } else if sess.contains(where: { !$0.isBreak }) {
            Text("All sessions done.").foregroundStyle(PB.muted).frame(maxWidth: .infinity, maxHeight: .infinity).pbCard()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Up next").font(.pbLabel).kerning(0.9).textCase(.uppercase).foregroundStyle(PB.sun)
                Text("No sessions yet").font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                Text("Your timeline fills in as soon as you create a plan.").font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 0)
                Button("✦ Start something new") { app.showNewPrep = true }.buttonStyle(InvertedGhostStyle())
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: PB.rXL, style: .continuous).fill(PB.cobalt))
        }
    }

    // MARK: stats

    private func stats(_ sess: [PrepTask], now: Date) -> some View {
        let work = sess.filter { !$0.isBreak }
        let remaining = work.filter { !$0.done && $0.end > now }
        let hoursLeft = remaining.reduce(0) { $0 + $1.end.timeIntervalSince(max($1.start, now)) } / 3600
        let missed = work.filter { !$0.done && $0.end <= now }.count
        let progress = tasks.progress(for: activeRole?.id ?? "")
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { statCells(remaining: remaining, work: work, hoursLeft: hoursLeft, missed: missed, progress: progress) }
                .frame(minWidth: 700)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                statCells(remaining: remaining, work: work, hoursLeft: hoursLeft, missed: missed, progress: progress)
            }
        }
    }

    @ViewBuilder
    private func statCells(remaining: [PrepTask], work: [PrepTask], hoursLeft: Double, missed: Int, progress: Double) -> some View {
            stat("Prep hours left", value: hoursLeft < 10 ? String(format: "%.1f", hoursLeft) : "\(Int(hoursLeft))", suffix: "h")
            stat("Sessions left", value: "\(remaining.count)", suffix: "/\(work.count)")
            stat("To catch up", value: "\(missed)", highlight: missed > 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("Prep progress").pbLabelStyle()
                HStack(alignment: .center, spacing: 12) {
                    Text("\(Int(progress * 100))%").font(.system(size: 26, weight: .bold)).kerning(-0.6)
                    ProgressBar(value: progress)
                }
            }
            .pbCard(padding: 14, fill: PB.surface, radius: PB.rLG)
    }

    private func stat(_ label: String, value: String, suffix: String? = nil, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).pbLabelStyle()
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value).font(.system(size: 26, weight: .bold)).kerning(-0.6)
                if let suffix { Text(suffix).font(.system(size: 15, weight: .semibold)).foregroundStyle(PB.muted) }
            }
        }
        .pbCard(padding: 14, fill: highlight ? PB.sunSoft : PB.surface, radius: PB.rLG)
    }

    // MARK: today's hour strip

    private func todayStrip(_ sess: [PrepTask], now: Date) -> some View {
        let cal = Calendar.current
        let today = sess.filter { cal.isDateInToday($0.start) }
        let startH = 7.0, endH = 23.0
        func x(_ d: Date, _ w: CGFloat) -> CGFloat {
            let h = Double(cal.component(.hour, from: d)) + Double(cal.component(.minute, from: d)) / 60
            return CGFloat(max(0, min(1, (h - startH) / (endH - startH)))) * w
        }
        let interview = activeRole?.interviewAt.flatMap { cal.isDateInToday($0) ? $0 : nil }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Today").font(.system(size: 15, weight: .semibold))
                Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.system(size: 13)).foregroundStyle(PB.muted)
                Spacer(minLength: 8)
                Button("Full timeline →") { app.section = .timeline; app.scrollTarget = "now" }
                    .buttonStyle(PillButtonStyle(filled: false, compact: true))
            }
            .padding(.bottom, 12)
            GeometryReader { outer in
              let w = max(720, outer.size.width)
              ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(stride(from: Int(startH), through: Int(endH), by: 2)), id: \.self) { h in
                            let px = CGFloat(Double(h) - startH) / CGFloat(endH - startH) * w
                            Text(TimeFmt.hour(h)).font(.system(size: 11, design: .monospaced)).foregroundStyle(PB.muted)
                                .fixedSize()
                                .position(x: min(max(px, 20), w - 20), y: 8)
                            Rectangle().fill(PB.line).frame(width: 1, height: 74).position(x: px, y: 24 + 37)
                        }
                        RoundedRectangle(cornerRadius: 14).strokeBorder(PB.line).frame(width: w, height: 74).offset(y: 24)
                        ForEach(today) { t in
                            let left = x(t.start, w), width = max(18, x(t.end, w) - left)
                            stripBlock(t, now: now).frame(width: width - 3, height: 58).offset(x: left + 1.5, y: 32)
                        }
                        if let interview {
                            Text("★ Interview \(TimeFmt.hm(interview))").font(.system(size: 11, weight: .bold)).foregroundStyle(PB.onSun)
                                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(PB.sun))
                                .fixedSize().offset(x: x(interview, w) + 4, y: 26)
                        }
                        let nowH = Double(cal.component(.hour, from: now)) + Double(cal.component(.minute, from: now)) / 60
                        if nowH >= startH && nowH <= endH {
                            Rectangle().fill(PB.cobalt).frame(width: 2, height: 82).offset(x: x(now, w) - 1, y: 20)
                            Text(TimeFmt.hm(now)).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1).background(RoundedRectangle(cornerRadius: 5).fill(PB.cobalt))
                                .fixedSize().offset(x: x(now, w) - 20, y: 102)
                        }
                        if today.isEmpty { Text("Nothing scheduled today.").foregroundStyle(PB.muted).offset(x: 14, y: 50) }
                    }
                    .frame(width: w, height: 120, alignment: .topLeading)
              }
            }
            .frame(height: 120)
        }
        .pbCard()
    }

    private func stripBlock(_ t: PrepTask, now: Date) -> some View {
        let st = t.status(at: now)
        let current = st == .current
        return Button { app.gotoSession(t) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.isBreak ? (t.title.components(separatedBy: CharacterSet(charactersIn: "+,.")).first ?? t.title) : t.title)
                    .font(.system(size: 12, weight: t.isBreak ? .medium : .semibold)).lineLimit(1)
                    .strikethrough(st == .done)
                    .foregroundStyle(current ? Color.white : t.isBreak ? PB.muted : PB.ink)
                Text(TimeFmt.hm(t.start)).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(current ? Color.white.opacity(0.7) : PB.muted)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(t.isBreak ? Color.clear : current ? PB.cobalt : PB.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(current ? PB.cobalt : PB.line2, style: StrokeStyle(lineWidth: 1, dash: t.isBreak ? [3] : [])))
            .overlay(alignment: .leading) {
                if !t.isBreak && !current { UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(t.kind.color).frame(width: 3) }
            }
            .opacity(st == .done ? 0.55 : 1)
            .clipped()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(TimeFmt.hm(t.start))–\(TimeFmt.hm(t.end)) · \(t.title)")
    }

    // MARK: priorities

    private func priorities(_ sess: [PrepTask], now: Date) -> some View {
        let work = sess.filter { !$0.isBreak && !$0.done }
        let cal = Calendar.current
        let items: [(PrepTask, String, Color, Color)] =
            work.filter { $0.status(at: now) == .current }.map { ($0, "Now", PB.sun, PB.onSun) }
            + work.filter { $0.end <= now }.map { ($0, "Catch up", Color(hex: 0xFBE4D8), Color(hex: 0xC2410C)) }
            + work.filter { $0.start > now }.prefix(4).map {
                ($0, cal.isDateInToday($0.start) ? "Today" : $0.start.formatted(.dateTime.weekday(.abbreviated)), PB.cobaltSoft, PB.cobalt)
            }
        let docsById = Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0) })
        return VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Priorities", count: "\(min(items.count, 6))")
            if items.isEmpty { Text("Nothing pending. Nice.").foregroundStyle(PB.muted).frame(maxWidth: .infinity).padding(20) }
            ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { idx, item in
                let (t, label, bg, fg) = item
                Button { app.gotoSession(t) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(fg)
                            .frame(width: 74).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(bg))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(t.title).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(["\(TimeFmt.hm(t.start))–\(TimeFmt.hm(t.end))", t.kind.label,
                                  t.refs.first.flatMap { r in docsById[r.docId].map { _ in TimeFmt.cleanHeading(r.heading) } }]
                                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 12)).foregroundStyle(PB.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { if idx < min(items.count, 6) - 1 { Rectangle().fill(PB.line).frame(height: 1) } }
            }
        }
        .pbCard()
    }

    // MARK: today's tasks

    private func todaysTasks(_ sess: [PrepTask], now: Date) -> some View {
        let today = sess.filter { Calendar.current.isDateInToday($0.start) }
        let tomorrow = sess.filter { Calendar.current.isDateInTomorrow($0.start) }
        let agenda = (today.isEmpty ? tomorrow : today).filter { !$0.isBreak }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(today.isEmpty ? "Tomorrow's tasks" : "Today's tasks").font(.system(size: 22, weight: .bold)).kerning(-0.4)
                Spacer()
                Text("\(agenda.filter(\.done).count) of \(agenda.count)").font(.system(size: 14)).foregroundStyle(PB.muted)
            }
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(PB.line2).frame(height: 1) }
            ForEach(agenda) { ChecklistRow(task: $0, now: now) }
            AddTaskRow(roleId: activeRole?.id ?? "", day: today.isEmpty && !tomorrow.isEmpty ? .now.addingTimeInterval(86400) : .now)
        }
        .pbCard(padding: 22)
    }

    // MARK: countdown plan

    private func countdownPlan(_ sess: [PrepTask], now: Date) -> some View {
        let cal = Calendar.current
        let work = sess.filter { !$0.isBreak }
        var days = Set(work.map { cal.startOfDay(for: $0.start) })
        if let at = activeRole?.interviewAt { days.insert(cal.startOfDay(for: at)) }
        return VStack(alignment: .leading, spacing: 6) {
            CardHeader(title: "Countdown plan")
            if days.isEmpty { Text("No plan yet.").foregroundStyle(PB.muted) }
            ForEach(days.sorted(), id: \.self) { day in
                let w = work.filter { cal.isDate($0.start, inSameDayAs: day) }
                let done = w.filter(\.done).count
                let isToday = cal.isDateInToday(day)
                let iv = activeRole?.interviewAt.flatMap { cal.isDate($0, inSameDayAs: day) ? $0 : nil }
                Button { app.section = .timeline; app.scrollTarget = "day-\(DateCoding.dayString(day))" } label: {
                    HStack(spacing: 12) {
                        Text(day.formatted(.dateTime.day(.twoDigits))).font(.system(size: 30, weight: .heavy)).kerning(-1.2)
                            .foregroundStyle(isToday ? PB.cobalt : PB.ink).frame(width: 46, alignment: .leading)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(day.formatted(.dateTime.weekday(.wide)) + (isToday ? " · Today" : "")).font(.system(size: 13, weight: .semibold))
                            if !w.isEmpty {
                                ProgressBar(value: Double(done) / Double(w.count))
                                Text("\(done)/\(w.count) sessions").font(.pbMono).foregroundStyle(PB.muted)
                            }
                            if let iv {
                                Text("★ Interview \(TimeFmt.hm(iv))").font(.system(size: 11, weight: .bold)).foregroundStyle(PB.onSun)
                                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(PB.sun))
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(isToday ? PB.cobaltSoft : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .pbCard()
    }

    // MARK: pipeline & recent

    private var pipeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Pipeline") {
                Text("Drag roles between stages").font(.system(size: 13)).foregroundStyle(PB.muted)
                CircleIconButton(systemImage: "plus", size: 34, label: "Add role") { app.newRole(context) }
            }
            .padding(.horizontal, 6)
            PipelineView(roles: roles, tasks: tasks)
        }
        .pbCard(padding: 14, fill: PB.surface.opacity(0.7))
    }

    private var recent: some View {
        let roleNames = Dictionary(uniqueKeysWithValues: roles.map { ($0.id, $0.company) })
        return VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Recently edited") {
                CircleIconButton(systemImage: "plus", size: 34, label: "New document") { app.newDoc(context) }
            }
            if docs.isEmpty { Text("No documents yet.").foregroundStyle(PB.muted).frame(maxWidth: .infinity).padding(30) }
            ForEach(docs.prefix(5)) { d in
                DocRow(doc: d, roleName: roleNames[d.roleId] ?? "General") { app.openDoc(d.id) }
            }
        }
        .pbCard()
    }
}

struct InvertedGhostStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).frame(height: 34)
            .foregroundStyle(.white)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.3)))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
