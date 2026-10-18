//
//  DayMarkers.swift
//  Retichat
//
//  Date markers in the message lists (James, 2026-09-30): a row above a
//  message sent on a different day than the message shown just above it,
//  and above the first message loaded. Foundation only, and the clock, the
//  calendar, the time zone and the locale are all passed in, so
//  tests/DayMarkersTests.swift runs it as it is.
//
//  A marker is not a message: it rides in its message's row (Row.id is the
//  message's id), so the lists' identity, scroll targets and counts are the
//  messages' alone.
//

import Foundation

enum DayMarkers {

    /// A message and the label of the marker above it, nil for none.
    struct Row<Item: Identifiable>: Identifiable {
        let item: Item
        let marker: String?
        var id: Item.ID { item.id }
    }

    /// `items` in display order, each with its marker. `timestamp` is the
    /// seconds since 1970 the item's bubble shows; days are the calendar
    /// days of `calendar` in `timeZone`, and labels read relative to `now`.
    static func rows<Item: Identifiable>(_ items: [Item],
                                         timestamp: (Item) -> TimeInterval,
                                         now: Date,
                                         calendar: Calendar,
                                         timeZone: TimeZone,
                                         locale: Locale) -> [Row<Item>] {
        let markers = markers(timestamps: items.map(timestamp), now: now, calendar: calendar,
                              timeZone: timeZone, locale: locale)
        return zip(items, markers).map { Row(item: $0, marker: $1) }
    }

    /// For each timestamp in display order, the label of the marker above
    /// it, nil for none: the markers `rows` gives its items.
    static func markers(timestamps: [TimeInterval],
                        now: Date,
                        calendar: Calendar,
                        timeZone: TimeZone,
                        locale: Locale) -> [String?] {
        var calendar = calendar
        calendar.timeZone = timeZone
        calendar.locale = locale
        return days(timestamps: timestamps, calendar: calendar).map { day in
            day.map { label(day: $0, now: now, calendar: calendar, locale: locale) }
        }
    }

    /// `rows`, keeping the markers of the last list it was given (L83). A
    /// list's rows are asked for at every render, and the conversation
    /// renders at every keystroke in the compose field, where working out
    /// every message's day again took ~6 ms at 1000 messages. The markers
    /// are worked out again only when a timestamp, the clock, the calendar,
    /// the time zone or the locale is not what it was. Only the markers are
    /// kept, never the items, so each row carries its item as it is now: a
    /// message's status changes, its id and time do not.
    final class Memo {
        private struct Key: Equatable {
            let timestamps: [TimeInterval]
            let now: Date
            let calendar: Calendar.Identifier
            let timeZone: String
            let locale: String
        }

        private var key: Key?
        private var markers: [String?] = []
        /// How many times the markers have been worked out.
        private(set) var computed = 0

        func rows<Item: Identifiable>(_ items: [Item],
                                      timestamp: (Item) -> TimeInterval,
                                      now: Date,
                                      calendar: Calendar,
                                      timeZone: TimeZone,
                                      locale: Locale) -> [Row<Item>] {
            let timestamps = items.map(timestamp)
            let key = Key(timestamps: timestamps, now: now, calendar: calendar.identifier,
                          timeZone: timeZone.identifier, locale: locale.identifier)
            if key != self.key {
                markers = DayMarkers.markers(timestamps: timestamps, now: now, calendar: calendar,
                                             timeZone: timeZone, locale: locale)
                self.key = key
                computed += 1
            }
            return zip(items, markers).map { Row(item: $0, marker: $1) }
        }
    }

    /// For each timestamp in display order, the start of its day when a
    /// marker goes above it, else nil: above the first, and above each one
    /// whose day differs from the day of the one just before it. Adjacent
    /// items are compared, not sorted, so out-of-order timestamps get a
    /// marker at every change of day.
    static func days(timestamps: [TimeInterval], calendar: Calendar) -> [Date?] {
        var previous: Date?
        return timestamps.map { seconds in
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: seconds))
            defer { previous = day }
            return day == previous ? nil : day
        }
    }

    /// "Today", "Yesterday", or the weekday, day and month, with the year
    /// when `day` is not in the current year, all in `locale`'s words.
    /// Yesterday is found by calendar arithmetic, never by counting hours or
    /// subtracting starts of days: a day can be 23 or 25 hours long, and
    /// where a clock change skips midnight it starts at 01:00.
    static func label(day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return relative(days: 0, calendar: calendar, locale: locale)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return relative(days: -1, calendar: calendar, locale: locale)
        }
        let style = Date.FormatStyle(date: nil, time: nil, locale: locale, calendar: calendar,
                                     timeZone: calendar.timeZone,
                                     capitalizationContext: .beginningOfSentence)
            .weekday(.wide).day().month(.wide)
        return calendar.isDate(day, equalTo: now, toGranularity: .year)
            ? day.formatted(style)
            : day.formatted(style.year())
    }

    /// The locale's named relative day ("Today", "Yesterday", "Hier"...).
    private static func relative(days: Int, calendar: Calendar, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        formatter.formattingContext = .beginningOfSentence
        return formatter.localizedString(from: DateComponents(day: days))
    }
}
