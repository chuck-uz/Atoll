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

import AppKit
import Defaults
import SwiftUI

/// The Calendar tab: a month grid on the left and the agenda for the next
/// seven days on the right. Shown when `calendarAsSeparateTab` is on, in which
/// case Home leaves the calendar out and gives the player the full width.
struct NotchCalendarTabView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.hideAllDayEvents) private var hideAllDayEvents
    @Default(.hideCompletedReminders) private var hideCompletedReminders

    static let agendaDays = 7

    private let calendar = Calendar.current

    private var resolvedNotchHeight: CGFloat {
        let height = vm.notchSize.height
        return height > 0 ? height : openNotchSize.height
    }

    private var contentHeight: CGFloat {
        let header = max(24, vm.effectiveClosedNotchHeight)
        return max(130, resolvedNotchHeight - header - 36)
    }

    private var agendaEvents: [EventModel] {
        EventListView.filteredEvents(
            events: calendarManager.agendaEvents,
            hideCompletedReminders: hideCompletedReminders,
            hideAllDayEvents: hideAllDayEvents
        )
    }

    /// Agenda grouped by day, only days that have something on them.
    private var agendaDaysWithEvents: [(day: Date, events: [EventModel])] {
        let grouped = Dictionary(grouping: agendaEvents) { calendar.startOfDay(for: max($0.start, calendar.startOfDay(for: Date()))) }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    private var busyDays: Set<Date> {
        Set(agendaEvents.map { calendar.startOfDay(for: $0.start) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            MonthGridView(busyDays: busyDays)
                .frame(width: 196, alignment: .topLeading)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 0.5)

            agendaPane
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .frame(height: contentHeight, alignment: .top)
        .onAppear(perform: refresh)
        .onChange(of: vm.notchState) { _, state in
            if state == .open { refresh() }
        }
        .onChange(of: calendarManager.events) { _, _ in
            // The store changed (or Home's day moved); keep the week in step.
            refresh()
        }
    }

    private func refresh() {
        Task { await calendarManager.updateAgenda(days: Self.agendaDays) }
    }

    // MARK: Agenda

    @ViewBuilder
    private var agendaPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Button {
                    openCalendarApp()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(white: 0.6))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open Calendar"))
            }

            if !calendarManager.hasCalendarAccess {
                emptyState(
                    icon: "calendar.badge.exclamationmark",
                    title: String(localized: "No calendar access"),
                    subtitle: String(localized: "Allow it in Settings → Calendar.")
                )
            } else if agendaDaysWithEvents.isEmpty {
                emptyState(
                    icon: "calendar.badge.checkmark",
                    title: String(localized: "Nothing this week"),
                    subtitle: String(localized: "The next seven days are free.")
                )
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(agendaDaysWithEvents, id: \.day) { entry in
                            daySection(day: entry.day, events: entry.events)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func daySection(day: Date, events: [EventModel]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dayTitle(for: day))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(calendar.isDateInToday(day) ? .white : Color(white: 0.6))
                .textCase(.uppercase)

            ForEach(events) { event in
                AgendaRow(event: event)
            }
        }
    }

    private func dayTitle(for day: Date) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(day) { return String(localized: "Tomorrow") }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(Color(white: 0.55))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.55))
            }
        }
        .padding(.top, 10)
    }

    private func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}

// MARK: - Agenda row

private struct AgendaRow: View {
    let event: EventModel
    @Environment(\.openURL) private var openURL

    private var isPast: Bool {
        !event.isAllDay && event.end < Date()
    }

    private var timeText: String {
        if event.isAllDay { return String(localized: "All day") }
        return event.start.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Rectangle()
                .fill(Color(nsColor: event.calendar.color))
                .frame(width: 3, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))

            Text(timeText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color(white: 0.6))
                .frame(width: 52, alignment: .leading)

            Text(event.title)
                .font(.callout)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let conference = event.conferenceURL {
                Button {
                    openURL(conference)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(isPast ? 0.45 : 1)
        .contentShape(Rectangle())
    }
}

// MARK: - Month grid

private struct MonthGridView: View {
    let busyDays: Set<Date>
    @State private var displayedMonth = Date()

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard !symbols.isEmpty else { return symbols }
        let first = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[first...]) + Array(symbols[..<first])
    }

    /// Whole weeks covering the displayed month; days outside it are nil.
    private var cells: [Date?] {
        guard let month = calendar.dateInterval(of: .month, for: displayedMonth),
              let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: month.start)
        else { return [] }

        var result: [Date?] = []
        var day = firstWeek.start
        while day < month.end || result.count % 7 != 0 {
            result.append(calendar.isDate(day, equalTo: displayedMonth, toGranularity: .month) ? day : nil)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                monthButton("chevron.left", offset: -1)
                monthButton("chevron.right", offset: 1)
            }

            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(white: 0.5))
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    dayCell(day)
                }
            }
        }
    }

    private func monthButton(_ symbol: String, offset: Int) -> some View {
        Button {
            if let next = calendar.date(byAdding: .month, value: offset, to: displayedMonth) {
                withAnimation(.smooth(duration: 0.2)) { displayedMonth = next }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(white: 0.6))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func dayCell(_ day: Date?) -> some View {
        if let day {
            let isToday = calendar.isDateInToday(day)
            let isBusy = busyDays.contains(calendar.startOfDay(for: day))
            VStack(spacing: 1) {
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 11, weight: isToday ? .bold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? .black : .white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(isToday ? Color.white : Color.clear))
                Circle()
                    .fill(isBusy ? Color(white: 0.7) : Color.clear)
                    .frame(width: 3, height: 3)
            }
        } else {
            Color.clear.frame(height: 24)
        }
    }
}
