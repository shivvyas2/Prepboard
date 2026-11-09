import SwiftUI

/// Every application sent, newest first, grouped by day: when, which résumé, which account it went in under, the confirmation and
/// a link to the posting. Shown for the "Applied" filter on the Mac and the iPhone.
struct AppliedTimeline: View {
    let leads: [Lead]
    let roles: [Role]

    private struct Item: Identifiable {
        let lead: Lead
        let role: Role?
        var id: String { lead.id }
        var at: Date { role?.appliedAt ?? lead.updatedAt }
    }

    private var items: [Item] {
        let byId = Dictionary(roles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return leads.filter { $0.status == .submitted }.map { Item(lead: $0, role: byId[$0.roleId]) }.sorted { $0.at > $1.at }
    }

    var body: some View {
        let all = items
        let cal = Calendar.current
        let days = Dictionary(grouping: all) { cal.startOfDay(for: $0.at) }.sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: PB.s4) {
            summary(all)
            ForEach(days, id: \.key) { day, list in
                VStack(alignment: .leading, spacing: PB.s2) {
                    HStack {
                        Text(dayTitle(day)).font(.system(size: 13, weight: .semibold)).foregroundStyle(PB.ink)
                        Spacer()
                        Text("\(list.count) sent").font(.pbMono).foregroundStyle(PB.muted)
                    }
                    .padding(.horizontal, PB.s1)
                    VStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                            if i > 0 { Divider().overlay(PB.line) }
                            row(item)
                        }
                    }
                    .pbCard(padding: 0, radius: PB.rLG)
                }
            }
        }
    }

    private func summary(_ all: [Item]) -> some View {
        let cal = Calendar.current
        let today = all.filter { cal.isDateInToday($0.at) }.count
        let week = all.filter { $0.at > .now.addingTimeInterval(-7 * 86400) }.count
        return HStack(spacing: PB.s2) {
            stat("Today", today)
            stat("7 days", week)
            stat("All time", all.count)
        }
    }

    private func stat(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(n)").font(.system(size: 22, weight: .bold)).foregroundStyle(PB.ink)
            Text(label).pbLabelStyle()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pbCard(padding: PB.s3, radius: PB.rLG)
    }

    private func row(_ item: Item) -> some View {
        let details = item.lead.appliedDetails
        let resume = item.role?.resumeVariant ?? item.lead.variantName
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: PB.s2) {
                Circle().fill(PB.green).frame(width: 8, height: 8)
                Text(item.lead.company).font(.system(size: 15, weight: .semibold)).foregroundStyle(PB.ink).lineLimit(1)
                Spacer(minLength: PB.s2)
                Text(item.at.formatted(date: .omitted, time: .shortened)).font(.pbMono).foregroundStyle(PB.muted)
            }
            Text(item.lead.title).font(.system(size: 13)).foregroundStyle(PB.ink2).lineLimit(2)
            VStack(alignment: .leading, spacing: 3) {
                if !resume.isEmpty { detail("doc.text", resume) }
                if !details.account.isEmpty { detail("person.crop.circle.badge.checkmark", details.account) }
                if !details.confirmation.isEmpty { detail("checkmark.seal", details.confirmation) }
            }
            if let url = URL(string: item.lead.link), !item.lead.link.isEmpty {
                Link(destination: url) {
                    Label("Open posting", systemImage: "arrow.up.right.square").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(PB.cobalt)
                .frame(minHeight: PB.minTap)
            }
        }
        .padding(PB.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detail(_ icon: String, _ text: String) -> some View {
        Label { Text(text).lineLimit(3) } icon: { Image(systemName: icon).foregroundStyle(PB.muted) }
            .font(.system(size: 12)).foregroundStyle(PB.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}
