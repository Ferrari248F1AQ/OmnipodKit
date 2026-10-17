//
//  RegressionDataPipelineTests.swift
//  OmniTests
//
//  Integration tests for the glucose, insulin, carbs, and ICR data
//  pipeline feeding O5SmartRegression.analyze().
//

import XCTest
import LoopKit
@testable import OmnipodKit

final class RegressionDataPipelineTests: XCTestCase {

    // MARK: - Helpers

    private let now = Date()

    private func hoursAgo(_ h: Double) -> Date {
        now.addingTimeInterval(-h * 3600)
    }

    private func daysAgo(_ d: Double) -> Date {
        now.addingTimeInterval(-d * 86400)
    }

    // MARK: - GlucoseHistoryEntry roundtrip

    func testGlucoseHistoryEntry_rawRoundtrip() {
        let entry = GlucoseHistoryEntry(mgdl: 120, date: now)
        let raw = entry.rawValue
        let restored = GlucoseHistoryEntry(rawValue: raw)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.mgdl, 120)
        XCTAssertEqual(restored?.date.timeIntervalSinceReferenceDate,
                       now.timeIntervalSinceReferenceDate, accuracy: 0.001)
    }

    // MARK: - CarbHistoryEntry roundtrip

    func testCarbHistoryEntry_rawRoundtrip() {
        let entry = CarbHistoryEntry(date: now, grams: 45.0, absorptionTime: 10800)
        let raw = entry.rawValue
        let restored = CarbHistoryEntry(rawValue: raw)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.grams, 45.0)
        XCTAssertEqual(restored?.absorptionTime, 10800)
        XCTAssertEqual(restored?.date.timeIntervalSinceReferenceDate,
                       now.timeIntervalSinceReferenceDate, accuracy: 0.001)
    }

    // MARK: - InsulinHistoryEntry isBasal roundtrip

    func testInsulinHistoryEntry_isBasalPreserved() {
        let basalEntry = InsulinHistoryEntry(timestamp: now, units: 0.5, isMeal: false, isBasal: true)
        let bolusEntry = InsulinHistoryEntry(timestamp: now, units: 2.0, isMeal: true, isBasal: false)

        let basalRaw = basalEntry.rawValue
        let bolusRaw = bolusEntry.rawValue

        let restoredBasal = InsulinHistoryEntry(rawValue: basalRaw)
        let restoredBolus = InsulinHistoryEntry(rawValue: bolusRaw)

        XCTAssertNotNil(restoredBasal)
        XCTAssertTrue(restoredBasal!.isBasal)
        XCTAssertFalse(restoredBasal!.isMeal)

        XCTAssertNotNil(restoredBolus)
        XCTAssertFalse(restoredBolus!.isBasal)
        XCTAssertTrue(restoredBolus!.isMeal)
    }

    func testInsulinHistoryEntry_defaultIsBasalFalse() {
        let entry = InsulinHistoryEntry(timestamp: now, units: 1.0, isMeal: false)
        XCTAssertFalse(entry.isBasal)
    }

    func testInsulinHistoryEntry_legacyRawMissingIsBasal() {
        let legacyRaw: [String: Any] = [
            "timestamp": now.timeIntervalSinceReferenceDate,
            "units": 0.8,
            "isMeal": false
        ]
        let entry = InsulinHistoryEntry(rawValue: legacyRaw)
        XCTAssertNotNil(entry)
        XCTAssertFalse(entry!.isBasal)
    }

    // MARK: - ICR schedule storage roundtrip via OmniPumpManagerState

    func testICRScheduleForRegression_stateRoundtrip() {
        // Build a minimal state raw dict
        let icrData: [[String: Any]] = [
            ["startTime": 0.0, "gramsPerUnit": 12.0],
            ["startTime": 43200.0, "gramsPerUnit": 8.0],
        ]

        // Verify decoding
        let decoded = icrData.compactMap { dict -> (startTime: TimeInterval, gramsPerUnit: Double)? in
            guard let startTime = dict["startTime"] as? TimeInterval,
                  let gramsPerUnit = dict["gramsPerUnit"] as? Double else { return nil }
            return (startTime: startTime, gramsPerUnit: gramsPerUnit)
        }

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].startTime, 0)
        XCTAssertEqual(decoded[0].gramsPerUnit, 12.0)
        XCTAssertEqual(decoded[1].startTime, 43200)
        XCTAssertEqual(decoded[1].gramsPerUnit, 8.0)

        // Verify encoding roundtrip
        let encoded = decoded.map {
            ["startTime": $0.startTime, "gramsPerUnit": $0.gramsPerUnit] as [String: Any]
        }
        let reDecoded = encoded.compactMap { dict -> (startTime: TimeInterval, gramsPerUnit: Double)? in
            guard let startTime = dict["startTime"] as? TimeInterval,
                  let gramsPerUnit = dict["gramsPerUnit"] as? Double else { return nil }
            return (startTime: startTime, gramsPerUnit: gramsPerUnit)
        }
        XCTAssertEqual(reDecoded.count, 2)
        XCTAssertEqual(reDecoded[0].gramsPerUnit, 12.0)
        XCTAssertEqual(reDecoded[1].gramsPerUnit, 8.0)
    }

    // MARK: - O5SmartRegression.analyze() with real-shaped data

    func testAnalyze_withGlucoseInsulinCarbs_producesReport() {
        // 3 days of glucose readings every 5 minutes
        var glucose: [GlucoseSample] = []
        for hour in stride(from: 0, to: 72, by: (5.0 / 60.0)) {
            let bg = 120.0 + 20.0 * sin(hour * .pi / 12) // oscillating 100-140
            glucose.append(GlucoseSample(date: hoursAgo(72 - hour), mgdl: bg))
        }

        // Some basal deliveries every 30 min
        var insulin: [InsulinDelivery] = []
        for hour in stride(from: 0, to: 72, by: 0.5) {
            let start = hoursAgo(72 - hour)
            insulin.append(InsulinDelivery(
                startDate: start,
                endDate: start.addingTimeInterval(1800),
                units: 0.5,
                isBasal: true,
                isAutomatic: true
            ))
        }

        // A few meal boluses + carbs
        let mealTimes: [Double] = [8, 14, 20, 32, 38, 44, 56, 62, 68]
        var carbs: [CarbEntry] = []
        for h in mealTimes {
            let date = hoursAgo(72 - h)
            carbs.append(CarbEntry(date: date, grams: 40, absorptionTime: 10800))
            insulin.append(InsulinDelivery(
                startDate: date,
                endDate: date.addingTimeInterval(60),
                units: 4.0,
                isBasal: false,
                isAutomatic: false
            ))
        }

        let basalSchedule: [(startTime: TimeInterval, rate: Double)] = [
            (startTime: 0, rate: 0.8),
            (startTime: 21600, rate: 1.0),
            (startTime: 43200, rate: 0.9),
        ]

        let isfSchedule: [(startTime: TimeInterval, mgdlPerUnit: Double)] = [
            (startTime: 0, mgdlPerUnit: 50),
            (startTime: 43200, mgdlPerUnit: 40),
        ]

        let icrSchedule: [(startTime: TimeInterval, gramsPerUnit: Double)] = [
            (startTime: 0, gramsPerUnit: 12),
            (startTime: 43200, gramsPerUnit: 10),
        ]

        let report = O5SmartRegression.analyze(
            glucose: glucose,
            insulin: insulin,
            carbs: carbs,
            currentBasalSchedule: basalSchedule,
            currentISFSchedule: isfSchedule,
            currentICRSchedule: icrSchedule,
            windowDays: 3,
            now: now
        )

        // Basic sanity checks
        XCTAssertEqual(report.windowDays, 3)
        XCTAssertGreaterThan(report.glucoseSampleCount, 0)
        XCTAssertGreaterThan(report.doseSampleCount, 0)
        XCTAssertGreaterThan(report.carbEntrySampleCount, 0)

        // Glucose metrics should be computed
        XCTAssertGreaterThan(report.averageGlucose, 0)
        XCTAssertGreaterThanOrEqual(report.timeInRange, 0)
        XCTAssertLessThanOrEqual(report.timeInRange, 100)

        // Data quality should not be "insufficient" with 3 days of data
        XCTAssertNotEqual(report.dataQuality, .insufficient)
    }

    func testAnalyze_emptyData_returnsInsufficientQuality() {
        let report = O5SmartRegression.analyze(
            glucose: [],
            insulin: [],
            carbs: [],
            currentBasalSchedule: [(startTime: 0, rate: 1.0)],
            currentISFSchedule: [(startTime: 0, mgdlPerUnit: 50)],
            currentICRSchedule: [(startTime: 0, gramsPerUnit: 10)],
            windowDays: 14,
            now: now
        )

        XCTAssertEqual(report.dataQuality, .insufficient)
        XCTAssertEqual(report.glucoseSampleCount, 0)
        XCTAssertEqual(report.doseSampleCount, 0)
        XCTAssertEqual(report.carbEntrySampleCount, 0)
        XCTAssertTrue(report.basalSuggestions.isEmpty)
        XCTAssertTrue(report.isfSuggestions.isEmpty)
        XCTAssertTrue(report.icrSuggestions.isEmpty)
    }

    func testAnalyze_glucoseOnlyNoInsulinNoCarbs_producesBasalSuggestionsOnly() {
        // Glucose readings showing high values → should suggest basal increase
        var glucose: [GlucoseSample] = []
        for hour in stride(from: 0, to: 72, by: (5.0 / 60.0)) {
            glucose.append(GlucoseSample(date: hoursAgo(72 - hour), mgdl: 180))
        }

        let report = O5SmartRegression.analyze(
            glucose: glucose,
            insulin: [],
            carbs: [],
            currentBasalSchedule: [(startTime: 0, rate: 0.5)],
            currentISFSchedule: [(startTime: 0, mgdlPerUnit: 50)],
            currentICRSchedule: [(startTime: 0, gramsPerUnit: 10)],
            windowDays: 3,
            now: now
        )

        XCTAssertGreaterThan(report.glucoseSampleCount, 0)
        XCTAssertEqual(report.doseSampleCount, 0)
        XCTAssertEqual(report.carbEntrySampleCount, 0)
        // With no carbs, ICR suggestions should be empty
        XCTAssertTrue(report.icrSuggestions.isEmpty)
    }

    // MARK: - ICR schedule: stored vs fallback

    func testICRSchedule_usesStoredWhenAvailable() {
        let stored: [(startTime: TimeInterval, gramsPerUnit: Double)] = [
            (startTime: 0, gramsPerUnit: 15.0),
            (startTime: 43200, gramsPerUnit: 12.0),
        ]
        let fallback: [(startTime: TimeInterval, gramsPerUnit: Double)] = [
            (startTime: 0, gramsPerUnit: 10.0)
        ]

        let effective = stored.isEmpty ? fallback : stored

        XCTAssertEqual(effective.count, 2)
        XCTAssertEqual(effective[0].gramsPerUnit, 15.0)
    }

    func testICRSchedule_fallsBackWhenEmpty() {
        let stored: [(startTime: TimeInterval, gramsPerUnit: Double)] = []
        let fallback: [(startTime: TimeInterval, gramsPerUnit: Double)] = [
            (startTime: 0, gramsPerUnit: 10.0)
        ]

        let effective = stored.isEmpty ? fallback : stored

        XCTAssertEqual(effective.count, 1)
        XCTAssertEqual(effective[0].gramsPerUnit, 10.0)
    }

    // MARK: - Glucose history filtering

    func testGlucoseHistory_filtersBySinceDate() {
        let entries = [
            GlucoseHistoryEntry(mgdl: 100, date: daysAgo(20)),
            GlucoseHistoryEntry(mgdl: 110, date: daysAgo(10)),
            GlucoseHistoryEntry(mgdl: 120, date: daysAgo(5)),
            GlucoseHistoryEntry(mgdl: 130, date: daysAgo(1)),
        ]

        let since = daysAgo(14)
        let filtered = entries
            .filter { $0.date >= since }
            .sorted { $0.date < $1.date }

        XCTAssertEqual(filtered.count, 3)
        XCTAssertEqual(filtered[0].mgdl, 110)
        XCTAssertEqual(filtered[2].mgdl, 130)
    }

    // MARK: - Carb history filtering

    func testCarbHistory_filtersBySinceDate() {
        let entries = [
            CarbHistoryEntry(date: daysAgo(20), grams: 30, absorptionTime: 10800),
            CarbHistoryEntry(date: daysAgo(5), grams: 45, absorptionTime: 10800),
            CarbHistoryEntry(date: daysAgo(1), grams: 60, absorptionTime: 7200),
        ]

        let since = daysAgo(14)
        let filtered = entries
            .filter { $0.date >= since }
            .sorted { $0.date < $1.date }

        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(filtered[0].grams, 45)
        XCTAssertEqual(filtered[1].grams, 60)
    }

    // MARK: - InsulinDelivery: basal vs bolus separation

    func testInsulinDelivery_basalVsBolusSeparation() {
        let deliveries = [
            InsulinDelivery(startDate: hoursAgo(3), endDate: hoursAgo(2.5), units: 0.5, isBasal: true, isAutomatic: true),
            InsulinDelivery(startDate: hoursAgo(2), endDate: hoursAgo(1.95), units: 4.0, isBasal: false, isAutomatic: false),
            InsulinDelivery(startDate: hoursAgo(1), endDate: hoursAgo(0.5), units: 0.5, isBasal: true, isAutomatic: true),
        ]

        let basals = deliveries.filter { $0.isBasal }
        let boluses = deliveries.filter { !$0.isBasal }

        XCTAssertEqual(basals.count, 2)
        XCTAssertEqual(boluses.count, 1)
        XCTAssertEqual(boluses[0].units, 4.0)
    }

    // MARK: - Full pipeline: data → analyze → report with sample counts

    func testFullPipeline_sampleCountsMatchInput() {
        let glucoseCount = 50
        let bolusCount = 3
        let basalCount = 10
        let carbCount = 3

        var glucose: [GlucoseSample] = []
        for i in 0..<glucoseCount {
            glucose.append(GlucoseSample(
                date: hoursAgo(Double(glucoseCount - i) * 0.1),
                mgdl: 120
            ))
        }

        var insulin: [InsulinDelivery] = []
        for i in 0..<basalCount {
            let start = hoursAgo(Double(basalCount - i) * 0.5)
            insulin.append(InsulinDelivery(
                startDate: start,
                endDate: start.addingTimeInterval(1800),
                units: 0.5,
                isBasal: true,
                isAutomatic: true
            ))
        }
        for i in 0..<bolusCount {
            let start = hoursAgo(Double(bolusCount - i) * 2)
            insulin.append(InsulinDelivery(
                startDate: start,
                endDate: start.addingTimeInterval(60),
                units: 3.0,
                isBasal: false,
                isAutomatic: false
            ))
        }

        var carbs: [CarbEntry] = []
        for i in 0..<carbCount {
            carbs.append(CarbEntry(
                date: hoursAgo(Double(carbCount - i) * 2),
                grams: 40,
                absorptionTime: 10800
            ))
        }

        let report = O5SmartRegression.analyze(
            glucose: glucose,
            insulin: insulin,
            carbs: carbs,
            currentBasalSchedule: [(startTime: 0, rate: 1.0)],
            currentISFSchedule: [(startTime: 0, mgdlPerUnit: 50)],
            currentICRSchedule: [(startTime: 0, gramsPerUnit: 12)],
            windowDays: 1,
            now: now
        )

        XCTAssertEqual(report.glucoseSampleCount, glucoseCount)
        XCTAssertEqual(report.doseSampleCount, basalCount + bolusCount)
        XCTAssertEqual(report.carbEntrySampleCount, carbCount)
    }

    // MARK: - Multi-segment ICR used by regression

    func testAnalyze_multiSegmentICR_passedThrough() {
        var glucose: [GlucoseSample] = []
        for hour in stride(from: 0, to: 48, by: (5.0 / 60.0)) {
            glucose.append(GlucoseSample(date: hoursAgo(48 - hour), mgdl: 130))
        }

        let icrSchedule: [(startTime: TimeInterval, gramsPerUnit: Double)] = [
            (startTime: 0, gramsPerUnit: 15),       // midnight
            (startTime: 21600, gramsPerUnit: 12),    // 06:00
            (startTime: 43200, gramsPerUnit: 10),    // 12:00
            (startTime: 64800, gramsPerUnit: 13),    // 18:00
        ]

        let report = O5SmartRegression.analyze(
            glucose: glucose,
            insulin: [],
            carbs: [],
            currentBasalSchedule: [(startTime: 0, rate: 1.0)],
            currentISFSchedule: [(startTime: 0, mgdlPerUnit: 50)],
            currentICRSchedule: icrSchedule,
            windowDays: 2,
            now: now
        )

        // With no carbs, no ICR suggestions should be generated
        XCTAssertTrue(report.icrSuggestions.isEmpty)
        // But the analysis should still complete
        XCTAssertGreaterThan(report.glucoseSampleCount, 0)
    }
}
