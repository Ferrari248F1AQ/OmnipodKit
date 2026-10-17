//
//  ScheduleMergerTests.swift
//  OmniTests
//
//  Tests for the ScheduleMerger utility that replaces regression
//  time blocks in existing therapy schedules.
//

import XCTest
import LoopKit
@testable import OmnipodKit

final class ScheduleMergerTests: XCTestCase {

    // MARK: - Replace mode: old entries in range removed, single new entry inserted

    func testMergeBasal_replacesEntriesWithSingleBlock() {
        // User's basal: 00:00=0.4, 04:30=0.45, 08:30=0.2, 12:00=0.25
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 0.4),
            RepeatingScheduleValue(startTime: 16200, value: 0.45),   // 04:30
            RepeatingScheduleValue(startTime: 30600, value: 0.2),    // 08:30
            RepeatingScheduleValue(startTime: 43200, value: 0.25),   // 12:00
        ]

        // Suggestion: 00:00-06:00, change to 0.5
        // Both 00:00 and 04:30 are in range → replaced by single 00:00=0.5
        let merged = ScheduleMerger.mergeBasal(
            current: current,
            suggestionStart: 0,
            suggestionEnd: 21600,    // 06:00
            newRate: 0.5
        )

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].startTime, 0)
        XCTAssertEqual(merged[0].value, 0.5)      // new block
        XCTAssertEqual(merged[1].startTime, 30600) // 08:30 preserved
        XCTAssertEqual(merged[1].value, 0.2)
        XCTAssertEqual(merged[2].startTime, 43200) // 12:00 preserved
        XCTAssertEqual(merged[2].value, 0.25)
    }

    func testMergeBasal_preservesBoundaryEntry() {
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 0.4),
            RepeatingScheduleValue(startTime: 21600, value: 0.5),    // 06:00
        ]

        let merged = ScheduleMerger.mergeBasal(
            current: current,
            suggestionStart: 0,
            suggestionEnd: 21600,    // 06:00 exclusive
            newRate: 0.6
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].startTime, 0)
        XCTAssertEqual(merged[0].value, 0.6)     // replaced
        XCTAssertEqual(merged[1].startTime, 21600)
        XCTAssertEqual(merged[1].value, 0.5)     // 06:00 NOT affected
    }

    func testMergeBasal_singleEntrySchedule() {
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 1.0),
        ]

        let merged = ScheduleMerger.mergeBasal(
            current: current,
            suggestionStart: 0,
            suggestionEnd: 86400,
            newRate: 1.2
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].value, 1.2)
    }

    func testMergeBasal_emptyScheduleReturnsEmpty() {
        let merged = ScheduleMerger.mergeBasal(
            current: [],
            suggestionStart: 0,
            suggestionEnd: 21600,
            newRate: 0.5
        )

        XCTAssertTrue(merged.isEmpty)
    }

    func testMergeBasal_noOverlappingEntries_insertsNewBlock() {
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 0.4),
            RepeatingScheduleValue(startTime: 43200, value: 0.25),   // 12:00
        ]

        // Suggestion for 06:00-12:00 — no entry starts in that range
        // A new 06:00 entry is inserted
        let merged = ScheduleMerger.mergeBasal(
            current: current,
            suggestionStart: 21600,
            suggestionEnd: 43200,
            newRate: 0.3
        )

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].startTime, 0)
        XCTAssertEqual(merged[0].value, 0.4)      // preserved
        XCTAssertEqual(merged[1].startTime, 21600) // 06:00 inserted
        XCTAssertEqual(merged[1].value, 0.3)
        XCTAssertEqual(merged[2].startTime, 43200) // 12:00 preserved
        XCTAssertEqual(merged[2].value, 0.25)
    }

    // MARK: - ISF Merge

    func testMergeISF_replacesCorrectEntries() {
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 50),
            RepeatingScheduleValue(startTime: 21600, value: 40),     // 06:00
            RepeatingScheduleValue(startTime: 43200, value: 45),     // 12:00
        ]

        // 06:00 replaced by new entry, 12:00 boundary preserved
        let merged = ScheduleMerger.mergeISF(
            current: current,
            suggestionStart: 21600,
            suggestionEnd: 43200,
            newISF: 35
        )

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].value, 50)       // preserved
        XCTAssertEqual(merged[1].startTime, 21600)
        XCTAssertEqual(merged[1].value, 35)       // replaced
        XCTAssertEqual(merged[2].value, 45)       // boundary, preserved
    }

    // MARK: - ICR Merge

    func testMergeICR_collapsesMultipleEntries() {
        // User's ICR: 00:00=8.7, 06:00=7, 10:30=7.5
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 8.7),
            RepeatingScheduleValue(startTime: 21600, value: 7.0),    // 06:00
            RepeatingScheduleValue(startTime: 37800, value: 7.5),    // 10:30
        ]

        // Suggestion for 06:00-12:00 — both 06:00 and 10:30 are in range
        // They collapse into single 06:00=8.0
        let merged = ScheduleMerger.mergeICR(
            current: current,
            suggestionStart: 21600,
            suggestionEnd: 43200,
            newICR: 8.0
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].startTime, 0)
        XCTAssertEqual(merged[0].value, 8.7)      // preserved
        XCTAssertEqual(merged[1].startTime, 21600)
        XCTAssertEqual(merged[1].value, 8.0)      // replaced, 10:30 removed
    }

    // MARK: - Multiple Suggestions

    func testApplyMultipleSuggestions_sequentially() {
        var schedule: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 0.4),
            RepeatingScheduleValue(startTime: 16200, value: 0.45),   // 04:30
            RepeatingScheduleValue(startTime: 30600, value: 0.2),    // 08:30
            RepeatingScheduleValue(startTime: 43200, value: 0.25),   // 12:00
            RepeatingScheduleValue(startTime: 64800, value: 0.35),   // 18:00
        ]

        // Apply suggestion 1: 00:00-06:00 → 0.5
        // Collapses 00:00 and 04:30 into single 00:00=0.5
        schedule = ScheduleMerger.mergeBasal(
            current: schedule,
            suggestionStart: 0,
            suggestionEnd: 21600,
            newRate: 0.5
        )

        XCTAssertEqual(schedule.count, 4)
        XCTAssertEqual(schedule[0].value, 0.5)     // new block
        XCTAssertEqual(schedule[1].value, 0.2)     // 08:30 preserved

        // Apply suggestion 2: 12:00-18:00 → 0.3
        schedule = ScheduleMerger.mergeBasal(
            current: schedule,
            suggestionStart: 43200,
            suggestionEnd: 64800,
            newRate: 0.3
        )

        XCTAssertEqual(schedule.count, 4)
        XCTAssertEqual(schedule[0].value, 0.5)     // from suggestion 1
        XCTAssertEqual(schedule[1].value, 0.2)     // 08:30 untouched
        XCTAssertEqual(schedule[2].startTime, 43200)
        XCTAssertEqual(schedule[2].value, 0.3)     // from suggestion 2
        XCTAssertEqual(schedule[3].startTime, 64800)
        XCTAssertEqual(schedule[3].value, 0.35)    // 18:00 preserved
    }

    // MARK: - Edge Cases

    func testMergeFullDay_collapsesToSingleEntry() {
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 0.4),
            RepeatingScheduleValue(startTime: 16200, value: 0.45),
            RepeatingScheduleValue(startTime: 30600, value: 0.2),
        ]

        let merged = ScheduleMerger.mergeBasal(
            current: current,
            suggestionStart: 0,
            suggestionEnd: 86400,
            newRate: 1.0
        )

        // All entries replaced by single 00:00=1.0
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].startTime, 0)
        XCTAssertEqual(merged[0].value, 1.0)
    }

    func testMergeReducesEntryCount() {
        // 9 entries, merge a block covering 4 of them
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 0.4),
            RepeatingScheduleValue(startTime: 16200, value: 0.45),   // 04:30
            RepeatingScheduleValue(startTime: 30600, value: 0.2),    // 08:30
            RepeatingScheduleValue(startTime: 43200, value: 0.25),   // 12:00
            RepeatingScheduleValue(startTime: 48600, value: 0.35),   // 13:30
            RepeatingScheduleValue(startTime: 55800, value: 0.25),   // 15:30
            RepeatingScheduleValue(startTime: 61200, value: 0.35),   // 17:00
            RepeatingScheduleValue(startTime: 72000, value: 0.2),    // 20:00
            RepeatingScheduleValue(startTime: 81000, value: 0.35),   // 22:30
        ]

        // Merge 12:00-18:00 → collapses 12:00, 13:30, 15:30, 17:00 into single 12:00
        let merged = ScheduleMerger.mergeBasal(
            current: current,
            suggestionStart: 43200,
            suggestionEnd: 64800,     // 18:00
            newRate: 0.3
        )

        // 4 entries in [43200,64800): 12:00, 13:30, 15:30, 17:00 → 9 - 4 + 1 = 6
        XCTAssertEqual(merged.count, 6)
        XCTAssertEqual(merged[3].startTime, 43200)
        XCTAssertEqual(merged[3].value, 0.3)
        XCTAssertEqual(merged[4].startTime, 72000) // 20:00 — first after range
        XCTAssertEqual(merged[4].value, 0.2)
        XCTAssertEqual(merged[5].startTime, 81000) // 22:30
        XCTAssertEqual(merged[5].value, 0.35)
    }

    func testMergeMiddleBlock_correctCounts() {
        // Clearer test: explicit about which entries are in range
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 0.4),        // outside
            RepeatingScheduleValue(startTime: 21600, value: 0.45),   // 06:00, in [06:00,12:00)
            RepeatingScheduleValue(startTime: 30600, value: 0.2),    // 08:30, in [06:00,12:00)
            RepeatingScheduleValue(startTime: 43200, value: 0.25),   // 12:00 = boundary, outside
            RepeatingScheduleValue(startTime: 64800, value: 0.35),   // 18:00, outside
        ]

        let merged = ScheduleMerger.mergeBasal(
            current: current,
            suggestionStart: 21600,   // 06:00
            suggestionEnd: 43200,     // 12:00
            newRate: 0.3
        )

        // 2 entries removed (06:00, 08:30), 1 inserted (06:00=0.3) → 5 - 2 + 1 = 4
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged[0].startTime, 0)
        XCTAssertEqual(merged[0].value, 0.4)
        XCTAssertEqual(merged[1].startTime, 21600)
        XCTAssertEqual(merged[1].value, 0.3)       // new block
        XCTAssertEqual(merged[2].startTime, 43200)
        XCTAssertEqual(merged[2].value, 0.25)       // boundary, preserved
        XCTAssertEqual(merged[3].startTime, 64800)
        XCTAssertEqual(merged[3].value, 0.35)
    }
}
