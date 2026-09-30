// DayMarkersTests.swift
//
// Date markers in the message lists (James, 2026-09-30, before the release):
// "I want to see date markers before a message that is sent on a different
// day than the previous message." A marker goes above a message whose
// calendar day, in the device's time zone and calendar, is not the day of
// the message shown just above it, and above the first message loaded. It
// reads "Today", "Yesterday", or the weekday, day and month (with the year
// outside the current year), in the locale's own words.
//
// DayMarkers runs here for real, with the clock, calendar, time zone and
// locale injected: same day, midnight on both sides, DST change days
// (including a day that starts at 01:00), the year boundary, a time-zone
// change, the first item, paging prepend, a new message arriving, and
// out-of-order timestamps. The lists' wiring (DM and group, channel) needs
// SwiftUI, so it is asserted on the source, like NSEChannelPullTests.swift.
//
// Run from the workspace root with:
//
//   swiftc -o /private/tmp/claude-501/day-markers \
//     Retichat-ios/Retichat/Views/Conversation/DayMarkers.swift \
//     Retichat-ios/tests/DayMarkersTests.swift && \
//     /private/tmp/claude-501/day-markers

import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ ok: Bool, _ what: String, _ detail: String = "") {
    if ok {
        print("ok    - \(what)")
    } else {
        let message = detail.isEmpty ? what : "\(what) — \(detail)"
        failures.append(message)
        print("FAIL  - \(message)")
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func source(_ path: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
}

// MARK: - Fixtures

struct Msg: Identifiable {
    let id: String
    let t: TimeInterval
}

let gregorian = Calendar(identifier: .gregorian)
let enUS = Locale(identifier: "en_US")

func zone(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

/// Seconds since 1970 of a wall-clock time in `tz`.
func at(_ tz: String, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, _ s: Int = 0) -> TimeInterval {
    var cal = gregorian
    cal.timeZone = zone(tz)
    let parts = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
    return cal.date(from: parts)!.timeIntervalSince1970
}

func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

/// The markers of `msgs` shown in `tz` at `now`: one entry per message.
func markers(_ msgs: [Msg], tz: String, now: TimeInterval,
             locale: Locale = enUS, calendar: Calendar = gregorian) -> [String?] {
    DayMarkers.rows(msgs, timestamp: \.t, now: date(now), calendar: calendar,
                    timeZone: zone(tz), locale: locale).map(\.marker)
}

/// Which messages carry a marker, as booleans.
func marked(_ msgs: [Msg], tz: String, now: TimeInterval) -> [Bool] {
    markers(msgs, tz: tz, now: now).map { $0 != nil }
}

func label(_ day: TimeInterval, now: TimeInterval, tz: String, locale: Locale = enUS) -> String {
    var cal = gregorian
    cal.timeZone = zone(tz)
    return DayMarkers.label(day: date(day), now: date(now), calendar: cal, locale: locale)
}

let utc = "UTC"
let ny = "America/New_York"

// MARK: - Tests

func testFirstItem() {
    let now = at(utc, 2026, 9, 30, 12)
    check(markers([], tz: utc, now: now).isEmpty, "an empty list has no markers")
    let one = [Msg(id: "a", t: at(utc, 2026, 9, 30, 9))]
    check(markers(one, tz: utc, now: now) == ["Today"], "the first message loaded gets a marker",
          "\(markers(one, tz: utc, now: now))")
    let old = [Msg(id: "a", t: at(utc, 2026, 9, 21, 9))]
    check(markers(old, tz: utc, now: now) == ["Monday, September 21"],
          "the first message gets one whatever its day", "\(markers(old, tz: utc, now: now))")
}

func testSameDay() {
    let now = at(utc, 2026, 9, 30, 20)
    let msgs = [Msg(id: "a", t: at(utc, 2026, 9, 30, 0, 0, 1)),
                Msg(id: "b", t: at(utc, 2026, 9, 30, 9)),
                Msg(id: "c", t: at(utc, 2026, 9, 30, 19, 59))]
    check(marked(msgs, tz: utc, now: now) == [true, false, false],
          "messages on the same day share the one marker above the first",
          "\(marked(msgs, tz: utc, now: now))")
}

func testMidnightBoundary() {
    let now = at(utc, 2026, 9, 30, 12)
    // Across midnight: 23:59:59 then 00:00:00 are different days.
    let across = [Msg(id: "a", t: at(utc, 2026, 9, 29, 23, 59, 59)),
                  Msg(id: "b", t: at(utc, 2026, 9, 30, 0, 0, 0))]
    check(markers(across, tz: utc, now: now) == ["Yesterday", "Today"],
          "the first second after midnight starts a new day",
          "\(markers(across, tz: utc, now: now))")
    // Either side within one day: 00:00:00 and 23:59:59 are the same day.
    let within = [Msg(id: "a", t: at(utc, 2026, 9, 30, 0, 0, 0)),
                  Msg(id: "b", t: at(utc, 2026, 9, 30, 23, 59, 59))]
    check(marked(within, tz: utc, now: now) == [true, false],
          "midnight and the last second before the next midnight are one day",
          "\(marked(within, tz: utc, now: now))")

    // The clock crossing midnight while the screen is open relabels.
    let msg = at(utc, 2026, 9, 29, 23, 59)
    check(label(msg, now: at(utc, 2026, 9, 29, 23, 59, 59), tz: utc) == "Today",
          "just before midnight a message from that day is Today")
    check(label(msg, now: at(utc, 2026, 9, 30, 0, 0, 0), tz: utc) == "Yesterday",
          "at midnight the same message is Yesterday",
          label(msg, now: at(utc, 2026, 9, 30, 0, 0, 0), tz: utc))
    check(label(msg, now: at(utc, 2026, 9, 30, 23, 59, 59), tz: utc) == "Yesterday",
          "and still Yesterday at the end of the next day")
    check(label(msg, now: at(utc, 2026, 10, 1, 0, 0, 0), tz: utc) == "Tuesday, September 29",
          "two midnights on it is its weekday and date",
          label(msg, now: at(utc, 2026, 10, 1, 0, 0, 0), tz: utc))
}

func testDSTChangeDays() {
    // New York, spring forward 2026-03-08 (a 23-hour day) and fall back
    // 2026-11-01 (a 25-hour day).
    let changes = [(what: "spring forward", before: (3, 7), day: (3, 8), after: (3, 9)),
                   (what: "fall back", before: (10, 31), day: (11, 1), after: (11, 2))]
    for c in changes {
        let now = at(ny, 2026, c.day.0, c.day.1, 23, 45)
        let msgs = [Msg(id: "a", t: at(ny, 2026, c.before.0, c.before.1, 23, 30)),
                    Msg(id: "b", t: at(ny, 2026, c.day.0, c.day.1, 0, 30)),
                    Msg(id: "c", t: at(ny, 2026, c.day.0, c.day.1, 3, 30)),
                    Msg(id: "d", t: at(ny, 2026, c.day.0, c.day.1, 23, 30))]
        check(markers(msgs, tz: ny, now: now) == ["Yesterday", "Today", nil, nil],
              "\(c.what): the change day is one day, and the day before is another",
              "\(markers(msgs, tz: ny, now: now))")
        let justAfter = at(ny, 2026, c.after.0, c.after.1, 0, 15)
        check(label(at(ny, 2026, c.day.0, c.day.1, 0, 30), now: justAfter, tz: ny) == "Yesterday",
              "\(c.what): the change day is Yesterday just after the next midnight")
    }

    // Santiago springs forward at midnight: 2026-09-06 has no 00:00 and
    // starts at 01:00, so its start and the next day's are 23 hours apart
    // and a whole-day count between them is 0. Yesterday must still be
    // Yesterday.
    let cl = "America/Santiago"
    var santiago = gregorian
    santiago.timeZone = zone(cl)
    let start = santiago.startOfDay(for: date(at(cl, 2026, 9, 6, 12)))
    check(santiago.component(.hour, from: start) == 1,
          "(fixture) Santiago's 2026-09-06 starts at 01:00", "\(start)")
    check(label(at(cl, 2026, 9, 6, 1, 30), now: at(cl, 2026, 9, 7, 0, 30), tz: cl) == "Yesterday",
          "a day that starts at 01:00 is Yesterday just after the next midnight",
          label(at(cl, 2026, 9, 6, 1, 30), now: at(cl, 2026, 9, 7, 0, 30), tz: cl))
    check(label(at(cl, 2026, 9, 6, 1, 0), now: at(cl, 2026, 9, 6, 23, 0), tz: cl) == "Today",
          "and Today from its first minute to its last")
    let aroundGap = [Msg(id: "a", t: at(cl, 2026, 9, 5, 23, 59)),
                     Msg(id: "b", t: at(cl, 2026, 9, 6, 1, 0))]
    check(marked(aroundGap, tz: cl, now: at(cl, 2026, 9, 6, 12)) == [true, true],
          "the minute before the skipped hour and the minute after it are different days")
}

func testYearBoundary() {
    let msgs = [Msg(id: "a", t: at(utc, 2025, 12, 31, 23, 30)),
                Msg(id: "b", t: at(utc, 2026, 1, 1, 0, 30))]
    check(markers(msgs, tz: utc, now: at(utc, 2026, 1, 1, 10)) == ["Yesterday", "Today"],
          "New Year's Eve and New Year's Day are two days, and the relative words win over the year",
          "\(markers(msgs, tz: utc, now: at(utc, 2026, 1, 1, 10)))")
    let later = markers(msgs, tz: utc, now: at(utc, 2026, 1, 5, 10))
    check(later == ["Wednesday, December 31, 2025", "Thursday, January 1"],
          "a day of last year carries its year; one of this year does not", "\(later)")
    check(label(at(utc, 2026, 1, 1, 9), now: at(utc, 2026, 12, 31, 23, 59), tz: utc) == "Thursday, January 1",
          "the first day of the year is this year's to its last minute")
    check(label(at(utc, 2026, 1, 1, 9), now: at(utc, 2027, 1, 2, 0, 1), tz: utc) == "Thursday, January 1, 2026",
          "and carries its year once the year has turned")
}

func testTimeZoneChange() {
    // 23:30 and 00:30 UTC: two days in London's winter, one evening in New York.
    let msgs = [Msg(id: "a", t: at(utc, 2026, 9, 29, 23, 30)),
                Msg(id: "b", t: at(utc, 2026, 9, 30, 0, 30))]
    let now = at(utc, 2026, 9, 30, 2)
    check(marked(msgs, tz: utc, now: now) == [true, true], "in UTC they are two days")
    check(marked(msgs, tz: ny, now: now) == [true, false], "in New York the same messages are one day",
          "\(marked(msgs, tz: ny, now: now))")
    check(markers(msgs, tz: ny, now: now) == ["Today", nil],
          "and in New York at 22:00 on the 29th that day is Today", "\(markers(msgs, tz: ny, now: now))")
    check(markers(msgs, tz: "Asia/Tokyo", now: now) == ["Today", nil],
          "in Tokyo both are the morning of the 30th", "\(markers(msgs, tz: "Asia/Tokyo", now: now))")
}

func testPagingPrepend() {
    let now = at(utc, 2026, 9, 30, 12)
    let newer = [Msg(id: "c", t: at(utc, 2026, 9, 29, 10)),
                 Msg(id: "d", t: at(utc, 2026, 9, 29, 11)),
                 Msg(id: "e", t: at(utc, 2026, 9, 30, 9))]
    check(marked(newer, tz: utc, now: now) == [true, false, true], "the first page's markers")

    // An older page ending on the same day: the marker moves up to the
    // older page's first message of that day; the old first loses it.
    let sameDay = [Msg(id: "a", t: at(utc, 2026, 9, 28, 9)),
                   Msg(id: "b", t: at(utc, 2026, 9, 29, 8))]
    let merged = DayMarkers.rows(sameDay + newer, timestamp: \.t, now: date(now), calendar: gregorian,
                                 timeZone: zone(utc), locale: enUS)
    check(merged.map { $0.marker != nil } == [true, true, false, false, true],
          "a prepended page of the same day takes the marker from the old first message",
          "\(merged.map { $0.marker != nil })")
    check(merged.map(\.id) == ["a", "b", "c", "d", "e"],
          "every row's id is its message's id, so no row changes identity")

    // An older page ending on an earlier day: the old first keeps its marker.
    let earlier = [Msg(id: "a", t: at(utc, 2026, 9, 27, 9))]
    check(marked(earlier + newer, tz: utc, now: now) == [true, true, false, true],
          "a prepended page of an earlier day leaves the old first's marker")
}

func testNewMessageArrives() {
    let now = at(utc, 2026, 9, 30, 12)
    let list = [Msg(id: "a", t: at(utc, 2026, 9, 29, 22)),
                Msg(id: "b", t: at(utc, 2026, 9, 30, 9))]
    let sameDay = list + [Msg(id: "c", t: at(utc, 2026, 9, 30, 11, 59))]
    check(marked(sameDay, tz: utc, now: now) == [true, true, false],
          "a new message on the last message's day adds no marker")
    let later = at(utc, 2026, 10, 1, 0, 5)
    let nextDay = sameDay + [Msg(id: "d", t: later)]
    check(markers(nextDay, tz: utc, now: later) == ["Tuesday, September 29", "Yesterday", nil, "Today"],
          "one after midnight gets Today, and yesterday's marker says so",
          "\(markers(nextDay, tz: utc, now: later))")
}

func testOutOfOrder() {
    let now = at(utc, 2026, 9, 30, 12)
    let back = [Msg(id: "a", t: at(utc, 2026, 9, 30, 9)),
                Msg(id: "b", t: at(utc, 2026, 9, 29, 9)),
                Msg(id: "c", t: at(utc, 2026, 9, 30, 10))]
    check(markers(back, tz: utc, now: now) == ["Today", "Yesterday", "Today"],
          "adjacent messages in display order are compared, so each change of day is marked",
          "\(markers(back, tz: utc, now: now))")
    let sameDayBackwards = [Msg(id: "a", t: at(utc, 2026, 9, 30, 10)),
                            Msg(id: "b", t: at(utc, 2026, 9, 30, 9))]
    check(marked(sameDayBackwards, tz: utc, now: now) == [true, false],
          "out of order within one day is still one day")
}

func testLocalizedLabels() {
    let msg = at(utc, 2026, 9, 30, 9)
    let now = at(utc, 2026, 9, 30, 12)
    let tomorrow = at(utc, 2026, 10, 1, 12)
    let fr = Locale(identifier: "fr_FR")
    let de = Locale(identifier: "de_DE")
    check(label(msg, now: now, tz: utc, locale: fr) == "Aujourd’hui", "Today in French",
          label(msg, now: now, tz: utc, locale: fr))
    check(label(msg, now: tomorrow, tz: utc, locale: fr) == "Hier", "Yesterday in French",
          label(msg, now: tomorrow, tz: utc, locale: fr))
    check(label(msg, now: now, tz: utc, locale: de) == "Heute", "Today in German")
    check(label(msg, now: tomorrow, tz: utc, locale: de) == "Gestern", "Yesterday in German")
    let frDate = label(at(utc, 2026, 9, 21, 9), now: now, tz: utc, locale: fr)
    check(frDate.contains("septembre") && frDate.contains("21") && !frDate.contains("2026"),
          "a date in French is the locale's weekday, day and month", frDate)
    let frOld = label(at(utc, 2025, 9, 21, 9), now: now, tz: utc, locale: fr)
    check(frOld.contains("2025"), "and carries the year outside the current year", frOld)
    let jaDate = label(at(utc, 2026, 9, 21, 9), now: now, tz: utc, locale: Locale(identifier: "ja_JP"))
    check(jaDate.contains("9月21日"), "a date in Japanese is in the Japanese order", jaDate)
}

func testMarkersAreNotMessages() {
    let now = at(utc, 2026, 9, 30, 12)
    let msgs = (0..<10).map { Msg(id: "m\($0)", t: at(utc, 2026, 9, 20 + $0, 9)) }
    let rows = DayMarkers.rows(msgs, timestamp: \.t, now: date(now), calendar: gregorian,
                               timeZone: zone(utc), locale: enUS)
    check(rows.count == msgs.count, "a marker adds no row: one row per message")
    check(rows.map(\.id) == msgs.map(\.id), "rows keep their messages' ids and order")
    check(rows.allSatisfy { $0.marker != nil }, "ten days, ten markers")
}

// MARK: - Wiring

/// The body of `signature` in `text`, up to its closing brace at the same indent.
func body(of signature: String, in text: String) -> String {
    guard let start = text.range(of: signature) else { return "" }
    let rest = text[start.lowerBound...]
    guard let end = rest.range(of: "\n    }\n") else { return String(rest) }
    return String(rest[..<end.upperBound])
}

func occurrences(_ needle: String, in text: String) -> Int {
    text.components(separatedBy: needle).count - 1
}

func testTheWiring() {
    let view = source("Retichat/Views/Conversation/ConversationView.swift")
    check(!view.isEmpty, "reads ConversationView.swift")

    // Every message list: the DM/group list and the channel list are the
    // app's only ChatBubble lists.
    let dm = body(of: "private var messagesList: some View", in: view)
    check(dm.contains("ForEach(dayRows(viewModel.messages, timestamp: \\.timestamp))"),
          "the DM and group list goes through the day rows, on the bubble's timestamp")
    check(dm.contains("DayMarkerView(label: marker)"), "and shows the marker")
    let channel = body(of: "private func channelMessagesList(channel: Channel)", in: view)
    check(channel.contains("ForEach(dayRows(msgs, timestamp: Self.channelSeconds))"),
          "the channel list goes through the day rows")
    check(channel.contains("timestamp: Self.channelSeconds(msg)"),
          "and its bubble shows the same seconds the marker is placed on")
    check(channel.contains("DayMarkerView(label: marker)"), "and shows the marker")
    check(occurrences(".id(row.id)", in: view) == 2, "both rows keep their message's id as scroll target")
    check(!view.contains("ForEach(viewModel.messages)") && !view.contains("ForEach(msgs)"),
          "no list is left without markers")

    var bubbleUsers: [String] = []
    if let files = FileManager.default.enumerator(atPath: root.appendingPathComponent("Retichat").path) {
        for case let file as String in files where file.hasSuffix(".swift") {
            let text = source("Retichat/" + file)
            if text.contains("ChatBubble(") { bubbleUsers.append(file) }
        }
    }
    check(bubbleUsers.sorted() == ["Views/Conversation/ConversationView.swift"],
          "ChatBubble is used by ConversationView's lists alone", "\(bubbleUsers)")
    check(occurrences("ChatBubble(", in: view) == 2, "and by those two lists")

    // The device's calendar, time zone and locale, on a clock that moves.
    let rows = body(of: "private func dayRows<Item: Identifiable>(", in: view)
    check(rows.contains("now: markerNow"), "labels read on the markers' clock")
    check(rows.contains("calendar: .autoupdatingCurrent, timeZone: .autoupdatingCurrent")
          && rows.contains("locale: .autoupdatingCurrent"),
          "in the device's current calendar, time zone and locale")
    for name in ["NSCalendarDayChanged", ".NSSystemTimeZoneDidChange",
                 "NSLocale.currentLocaleDidChangeNotification",
                 "UIApplication.significantTimeChangeNotification"] {
        check(view.contains(name), "the markers' clock moves on \(name)")
    }
    check(view.contains(".onReceive(Self.markerClockChanges)"), "the clock changes are subscribed")
    check(view.contains("if phase == .active { advanceMarkerClock() }"),
          "and the clock is checked when the app comes back")
    let tick = view.components(separatedBy: ".onReceive(Timer.publish(every: 3").dropFirst().first ?? ""
    check(tick.prefix(600).contains("advanceMarkerClock()"),
          "and on every 3 s tick, in channels as well as DMs")

    let components = source("Retichat/Views/Components/GlassComponents.swift")
    let marker = components.components(separatedBy: "struct DayMarkerView: View").dropFirst().first ?? ""
    check(marker.contains(".allowsHitTesting(false)"), "the marker is not tappable")
    check(marker.contains(".foregroundColor(.retichatOnSurfaceVariant)"), "and is in the secondary colour")
}

@main
enum DayMarkersTests {
    static func main() {
        testFirstItem()
        testSameDay()
        testMidnightBoundary()
        testDSTChangeDays()
        testYearBoundary()
        testTimeZoneChange()
        testPagingPrepend()
        testNewMessageArrives()
        testOutOfOrder()
        testLocalizedLabels()
        testMarkersAreNotMessages()
        testTheWiring()
        if failures.isEmpty {
            print("all day marker tests passed")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s)")
            exit(1)
        }
    }
}
