/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI

/// The Claude card on the Usage tab: cost first and tokens second, the week as
/// a bar per day, and where the week's spend went by model.
///
/// Costs are API-equivalent estimates from the local logs, not the bill for a
/// subscription, and the header says so.
struct ClaudeUsageCard: View {
    let result: UsageResult

    static let accent = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch result {
            case .loading:
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failure(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            case .success(let snap):
                content(snap)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Self.accent)
                .frame(width: 16, height: 16)
                .overlay {
                    Image(systemName: "sparkle")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                }
            Text("Claude")
                .font(.system(size: 14, weight: .semibold))
            if case .success(let snap) = result, let plan = snap.plan {
                Text(plan)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if case .success(let snap) = result {
                Text(updatedText(snap.lastUpdated))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help(String(localized: "Estimated API-equivalent cost from local token counts, not your subscription bill."))
            }
        }
    }

    private func updatedText(_ date: Date) -> String {
        let relative = date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
        return String(localized: "≈ API prices · \(relative)")
    }

    // MARK: Content

    /// Share of the width the tiles take; the model breakdown gets the rest.
    /// Fixed rather than negotiated: left to SwiftUI, the tiles' flexible
    /// frames took nearly all of it and squeezed the models to a sliver.
    private static let tilesShare: CGFloat = 0.52

    private func content(_ snap: UsageSnapshot) -> some View {
        GeometryReader { geo in
            let spacing: CGFloat = 12
            let tilesWidth = (geo.size.width - spacing) * Self.tilesShare
            HStack(alignment: .top, spacing: spacing) {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        tile(String(localized: "Today"), snap.today)
                        tile(String(localized: "Session · 5 h"), snap.session, limit: snap.sessionLimit)
                    }
                    weekTile(snap)
                }
                .frame(width: tilesWidth)

                ModelBreakdown(models: snap.models, hasUnpriced: snap.week.hasUnpricedModel)
                    .padding(.leading, spacing)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.1)).frame(width: 0.5)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private func tile(_ title: String, _ totals: UsageTotals, limit: UsageLimit? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Self.cost(totals.costUSD))
                .font(.system(size: 21, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(Self.tokens(totals.totalTokens))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let limit {
                LimitBar(fraction: limit.fraction)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
    }

    private func weekTile(_ snap: UsageSnapshot) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Week")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(Self.cost(snap.week.costUSD))
                    .font(.system(size: 21, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(Self.tokens(snap.week.totalTokens))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let limit = snap.weekLimit {
                    LimitBar(fraction: limit.fraction)
                        .frame(width: 60)
                        .padding(.top, 2)
                }
            }
            .fixedSize()

            DayBars(days: snap.days)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
    }

    // MARK: Formatting

    /// Dollars, whole above $100 where cents are noise.
    static func cost(_ value: Double) -> String {
        value.formatted(
            .currency(code: "USD")
                .locale(Locale(identifier: "en_US"))
                .precision(.fractionLength(value >= 100 ? 0 : 2))
        )
    }

    /// 18.2M, 398M, 950K.
    static func tokens(_ count: Int) -> String {
        let value = Double(count)
        let text: String
        switch value {
        case 1_000_000_000...: text = String(format: "%.1fB", value / 1_000_000_000)
        case 100_000_000...: text = String(format: "%.0fM", value / 1_000_000)
        case 1_000_000...: text = String(format: "%.1fM", value / 1_000_000)
        case 1_000...: text = String(format: "%.0fK", value / 1_000)
        default: text = "\(count)"
        }
        return String(localized: "\(text) tokens")
    }
}

// MARK: - Limit bar

private struct LimitBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(fraction > 0.85 ? Color.red : ClaudeUsageCard.accent)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
    }
}

// MARK: - Week by day

private struct DayBars: View {
    let days: [DailyUsage]
    private let calendar = Calendar.current
    private let maxBarHeight: CGFloat = 36

    var body: some View {
        let peak = max(days.map(\.totals.costUSD).max() ?? 0, 0.01)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(days) { day in
                let isToday = calendar.isDateInToday(day.day)
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isToday ? Color.white : ClaudeUsageCard.accent)
                        .frame(maxWidth: 16)
                        .frame(height: max(2, maxBarHeight * day.totals.costUSD / peak))
                        .help(ClaudeUsageCard.cost(day.totals.costUSD))
                    Text(day.day.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.system(size: 9, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: maxBarHeight + 14, alignment: .bottom)
    }
}

// MARK: - Models

/// The week's spend by model family, the way the models are known by name:
/// "Opus 4.5" rather than claude-opus-4-5-20251101.
private struct ModelBreakdown: View {
    let models: [ModelUsage]
    let hasUnpriced: Bool

    private struct Family: Identifiable {
        let name: String
        var cost: Double
        var unpriced: Bool
        var id: String { name }
    }

    private var families: [Family] {
        var byName: [String: Family] = [:]
        for model in models {
            let name = Self.prettyName(model.model)
            var family = byName[name] ?? Family(name: name, cost: 0, unpriced: false)
            family.cost += model.totals.costUSD
            family.unpriced = family.unpriced || model.totals.hasUnpricedModel
            byName[name] = family
        }
        return byName.values
            .filter { $0.cost > 0 }
            .sorted { $0.cost > $1.cost }
    }

    private static let palette: [Color] = [
        ClaudeUsageCard.accent,
        Color(red: 0xE8 / 255, green: 0xB4 / 255, blue: 0x9A / 255),
        Color(white: 0.5),
        Color(white: 0.32)
    ]

    var body: some View {
        let all = families
        let shown = Array(all.prefix(3))
        let restCost = all.dropFirst(3).reduce(0) { $0 + $1.cost }
        let total = max(all.reduce(0) { $0 + $1.cost }, 0.0001)
        let rows: [(String, Double)] = shown.map { ($0.name, $0.cost) } + (restCost > 0 ? [(String(localized: "Other"), restCost)] : [])

        VStack(alignment: .leading, spacing: 6) {
            Text("Models · week")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text("No usage this week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            Rectangle()
                                .fill(Self.palette[min(index, Self.palette.count - 1)])
                                .frame(width: max(1, geo.size.width * row.1 / total))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 6)
                .padding(.bottom, 2)

                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.palette[min(index, Self.palette.count - 1)])
                            .frame(width: 8, height: 8)
                        Text(row.0)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(ClaudeUsageCard.cost(row.1)) · \(Int((row.1 / total * 100).rounded()))%")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            }

            if hasUnpriced {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 10))
                    Text("Some models have no known price and are not counted")
                        .font(.system(size: 10))
                        .lineLimit(2)
                }
                .foregroundStyle(.tertiary)
            }
        }
    }

    /// "claude-opus-4-5-20251101" → "Opus 4.5"; "claude-3-5-haiku-20241022" →
    /// "Haiku 3.5". Anything that does not look like a Claude model name keeps
    /// its own name.
    static func prettyName(_ raw: String) -> String {
        var parts = raw.lowercased()
            .replacingOccurrences(of: "claude-", with: "")
            .split(separator: "-")
            .map(String.init)
        // Drop a trailing date stamp.
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let familyIndex = parts.firstIndex(where: { ["opus", "sonnet", "haiku"].contains($0) }) else {
            return raw
        }
        let family = parts[familyIndex].prefix(1).uppercased() + parts[familyIndex].dropFirst()
        let version = parts.enumerated()
            .filter { $0.offset != familyIndex && Int($0.element) != nil }
            .map(\.element)
            .joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }
}
