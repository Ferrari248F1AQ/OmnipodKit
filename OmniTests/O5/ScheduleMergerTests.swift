//
//  ScheduleMergerTests.swift
//  OmniTests
//
//  Tests for the ScheduleMerger utility that merges regression
//  suggestions into existing therapy schedules.
//

import XCTest
import LoopKit
@testable import OmnipodKit

final class ScheduleMergerTests: XCTestCase {

    // MARK: - Basal Merge

    func testMergeBasal_updatesEntriesWithinTimeRange() {
        // User's basal: 00:00=0.4, 04:30=0.45, 08:30=0.2, 12:00=0.25
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 0.4),
            RepeatingScheduleValue(startTime: 16200, value: 0.45),   // 04:30
            RepeatingScheduleValue(startTime: 30600, value: 0.2),    // 08:30
            RepeatingScheduleValue(startTime: 43200, value: 0.25),   // 12:00
        ]

        // Suggestion: 00:00-06:00, change to 0.5
        let merged = ScheduleMerger.mergeBasal(
            current: current,
            suggestionStart: 0,
            suggestionEnd: 21600,    // 06:00
            newRate: 0.5
        )

        XCTAssertEqual(merged.count, 4)
        // 00:00 is within [0, 21600) → updated
        XCTAssertEqual(merged[0].value, 0.5)
        XCTAssertEqual(merged[0].startTime, 0)
        // 04:30 (16200) is within [0, 21600) → updated
        XCTAssertEqual(merged[1].value, 0.5)
        XCTAssertEqual(merged[1].startTime, 16200)
        // 08:30 is outside → unchanged
        XCTAssertEqual(merged[2].value, 0.2)
        // 12:00 is outside → unchanged
        XCTAssertEqual(merged[3].value, 0.25)
    }

    func testMergeBasal_preservesBoundaryEntry() {
        // Entry at exact boundary should NOT be updated (endTime is exclusive)
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

        XCTAssertEqual(merged[0].value, 0.6)    // 00:00 updated
        XCTAssertEqual(merged[1].value, 0.5)     // 06:00 NOT updated
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

    func testMergeBasal_noOverlappingEntries() {
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 0.4),
            RepeatingScheduleValue(startTime: 43200, value: 0.25),   // 12:00
        ]

        // Suggestion for 06:00-12:00 — no entry starts in that range
        let merged = ScheduleMerger.mergeBasal(
            current: current,
            suggestionStart: 21600,
            suggestionEnd: 43200,
            newRate: 0.3
        )

        XCTAssertEqual(merged[0].value, 0.4)    // unchanged
        XCTAssertEqual(merged[1].value, 0.25)    // 12:00 = endTime, exclusive → unchanged
    }

    // MARK: - ISF Merge

    func testMergeISF_updatesCorrectEntries() {
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 50),
            RepeatingScheduleValue(startTime: 21600, value: 40),     // 06:00
            RepeatingScheduleValue(startTime: 43200, value: 45),     // 12:00
        ]

        let merged = ScheduleMerger.mergeISF(
            current: current,
            suggestionStart: 21600,
            suggestionEnd: 43200,
            newISF: 35
        )

        XCTAssertEqual(merged[0].value, 50)      // unchanged
        XCTAssertEqual(merged[1].value, 35)       // updated
        XCTAssertEqual(merged[2].value, 45)       // boundary, unchanged
    }

    // MARK: - ICR Merge

    func testMergeICR_updatesCorrectEntries() {
        // User's ICR: 00:00=8.7, 06:00=7, 10:30=7.5
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 8.7),
            RepeatingScheduleValue(startTime: 21600, value: 7.0),    // 06:00
            RepeatingScheduleValue(startTime: 37800, value: 7.5),    // 10:30
        ]

        // Suggestion for 06:00-12:00
        let merged = ScheduleMerger.mergeICR(
            current: current,
            suggestionStart: 21600,
            suggestionEnd: 43200,
            newICR: 8.0
        )

        XCTAssertEqual(merged[0].value, 8.7)     // unchanged
        XCTAssertEqual(merged[1].value, 8.0)      // 06:00 updated
        XCTAssertEqual(merged[2].value, 8.0)      // 10:30 within range, updated
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
        schedule = ScheduleMerger.mergeBasal(
            current: schedule,
            suggestionStart: 0,
            suggestionEnd: 21600,
            newRate: 0.5
        )

        // Apply suggestion 2: 12:00-18:00 → 0.3
        schedule = ScheduleMerger.mergeBasal(
            current: schedule,
            suggestionStart: 43200,
            suggestionEnd: 64800,
            newRate: 0.3
        )

        XCTAssertEqual(schedule[0].value, 0.5)    // updated by suggestion 1
        XCTAssertEqual(schedule[1].value, 0.5)    // updated by suggestion 1
        XCTAssertEqual(schedule[2].value, 0.2)    // untouched
        XCTAssertEqual(schedule[3].value, 0.3)    // updated by suggestion 2
        XCTAssertEqual(schedule[4].value, 0.35)   // untouched (18:00 = endTime)
    }

    // MARK: - Edge Cases

    func testMergePreservesStartTimes() {
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

        // All values updated but startTimes preserved
        XCTAssertEqual(merged[0].startTime, 0)
        XCTAssertEqual(merged[1].startTime, 16200)
        XCTAssertEqual(merged[2].startTime, 30600)
        XCTAssertEqual(merged[0].value, 1.0)
        XCTAssertEqual(merged[1].value, 1.0)
        XCTAssertEqual(merged[2].value, 1.0)
    }

    func testMergePreservesEntryCount() {
        let current: [RepeatingScheduleValue<Double>] = [
            RepeatingScheduleValue(startTime: 0, value: 0.4),
            RepeatingScheduleValue(startTime: 16200, value: 0.45),
            RepeatingScheduleValue(startTime: 30600, value: 0.2),
            RepeatingScheduleValue(startTime: 43200, value: 0.25),
            RepeatingScheduleValue(startTime: 48600, value: 0.35),
            RepeatingScheduleValue(startTime: 55800, value: 0.25),
            RepeatingScheduleValue(startTime: 61200, value: 0.35),
            RepeatingScheduleValue(startTime: 72000, value: 0.2),
            RepeatingScheduleValue(startTime: 81000, value: 0.35),
        ]

        let merged = ScheduleMerger.mergeBasal(
            current: current,
            suggestionStart: 43200,
            suggestionEnd: 64800,
            newRate: 0.3
        )

        // Entry count preserved — merge never adds or removes entries
        XCTAssertEqual(merged.count, current.count)
    }
}
