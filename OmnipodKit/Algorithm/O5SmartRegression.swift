//
//  O5SmartRegression.swift
//  OmnipodKit
//
//  15-day regression model for therapy parameter optimization.
//  Analyzes glucose outcomes, insulin delivery, and carb entries to
//  suggest improved basal rates, ISF, and ICR values per time-of-day.
//
//  This is independent of Insulet's on-pod algorithm — it runs in Loop
//  to help the user fine-tune their settings regardless of which
//  dosing algorithm (Loop or Insulet AID) is active.
//

import Foundation

// MARK: - Input Data Models

struct GlucoseSample {
    let date: Date
    let mgdl: Double
}

struct InsulinDelivery {
    let startDate: Date
    let endDate: Date
    let units: Double
    let isBasal: Bool
    let isAutomatic: Bool
}

struct CarbEntry {
    let date: Date
    let grams: Double
    let absorptionTime: TimeInterval
}

// MARK: - Output Models

struct BasalSuggestion {
    let startTime: TimeInterval    // seconds from midnight
    let endTime: TimeInterval
    let currentRate: Double        // U/hr
    let suggestedRate: Double      // U/hr
    let confidence: Double         // 0-1
    let reason: String
}

struct ISFSuggestion {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let currentISF: Double         // mg/dL per U
    let suggestedISF: Double
    let confidence: Double
    let reason: String
}

struct ICRSuggestion {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let currentICR: Double         // g per U
    let suggestedICR: Double
    let confidence: Double
    let reason: String
}

struct RegressionReport {
    let analysisDate: Date
    let windowDays: Int
    let basalSuggestions: [BasalSuggestion]
    let isfSuggestions: [ISFSuggestion]
    let icrSuggestions: [ICRSuggestion]
    let averageGlucose: Double
    let timeInRange: Double         // percentage 70-180
    let timeBelowRange: Double      // percentage <70
    let timeAboveRange: Double      // percentage >180
    let glucoseVariability: Double  // coefficient of variation
    let totalDataPoints: Int
    let dataQuality: DataQuality

    enum DataQuality: String {
        case excellent = "excellent"  // >90% coverage
        case good = "good"            // 70-90%
        case fair = "fair"            // 50-70%
        case insufficient = "insufficient" // <50%
    }
}

// MARK: - Time Block

struct TimeBlock {
    let index: Int
    let startHour: Int
    let endHour: Int
    let glucoseReadings: [GlucoseSample]
    let basalDeliveries: [InsulinDelivery]
    let bolusDeliveries: [InsulinDelivery]
    let carbEntries: [CarbEntry]

    var label: String {
        String(format: "%02d:00-%02d:00", startHour, endHour)
    }
}

// MARK: - Regression Engine

struct O5SmartRegression {

    static let defaultWindowDays: Int = 15
    static let targetRangeLow: Double = 70.0
    static let targetRangeHigh: Double = 180.0
    static let idealTarget: Double = 110.0
    static let hoursPerBlock: Int = 3          // analyze in 3-hour blocks
    static let minimumReadingsPerBlock: Int = 5
    static let minimumDaysForSuggestion: Int = 5
    static let maxBasalAdjustment: Double = 0.30   // max 30% change
    static let maxISFAdjustment: Double = 0.25     // max 25% change
    static let maxICRAdjustment: Double = 0.25     // max 25% change

    // MARK: - Main Analysis

    /// Runs the full 15-day regression analysis.
    ///
    /// - Parameters:
    ///   - glucose: CGM readings from the analysis window.
    ///   - insulin: All insulin deliveries (basal + bolus).
    ///   - carbs: Carb entries logged by user.
    ///   - currentBasalSchedule: Current basal rates as (startTime, rate) tuples.
    ///   - currentISFSchedule: Current ISF as (startTime, mgdlPerUnit) tuples.
    ///   - currentICRSchedule: Current ICR as (startTime, gramsPerUnit) tuples.
    ///   - windowDays: Analysis window (default 15).
    ///   - now: Current date (injectable for testing).
    static func analyze(
        glucose: [GlucoseSample],
        insulin: [InsulinDelivery],
        carbs: [CarbEntry],
        currentBasalSchedule: [(startTime: TimeInterval, rate: Double)],
        currentISFSchedule: [(startTime: TimeInterval, mgdlPerUnit: Double)],
        currentICRSchedule: [(startTime: TimeInterval, gramsPerUnit: Double)],
        windowDays: Int = defaultWindowDays,
        now: Date = Date()
    ) -> RegressionReport {

        let windowStart = now.addingTimeInterval(-Double(windowDays) * 86400)

        // Filter data to window
        let windowGlucose = glucose.filter { $0.date >= windowStart && $0.date <= now }
        let windowInsulin = insulin.filter { $0.endDate >= windowStart && $0.startDate <= now }
        let windowCarbs = carbs.filter { $0.date >= windowStart && $0.date <= now }

        // Compute overall glucose metrics
        let glucoseMetrics = computeGlucoseMetrics(windowGlucose)
        let dataQuality = assessDataQuality(glucose: windowGlucose, windowDays: windowDays)

        // Partition into 3-hour time blocks across all days
        let blocks = partitionIntoTimeBlocks(
            glucose: windowGlucose,
            insulin: windowInsulin,
            carbs: windowCarbs
        )

        // Analyze each block for basal, ISF, ICR
        let basalSuggestions = analyzeBasalRates(
            blocks: blocks,
            currentSchedule: currentBasalSchedule,
            dataQuality: dataQuality
        )

        let isfSuggestions = analyzeISF(
            blocks: blocks,
            currentSchedule: currentISFSchedule,
            dataQuality: dataQuality
        )

        let icrSuggestions = analyzeICR(
            blocks: blocks,
            currentSchedule: currentICRSchedule,
            dataQuality: dataQuality
        )

        return RegressionReport(
            analysisDate: now,
            windowDays: windowDays,
            basalSuggestions: basalSuggestions,
            isfSuggestions: isfSuggestions,
            icrSuggestions: icrSuggestions,
            averageGlucose: glucoseMetrics.average,
            timeInRange: glucoseMetrics.timeInRange,
            timeBelowRange: glucoseMetrics.timeBelowRange,
            timeAboveRange: glucoseMetrics.timeAboveRange,
            glucoseVariability: glucoseMetrics.cv,
            totalDataPoints: windowGlucose.count,
            dataQuality: dataQuality
        )
    }

    // MARK: - Glucose Metrics

    private struct GlucoseMetrics {
        let average: Double
        let stdDev: Double
        let cv: Double
        let timeInRange: Double
        let timeBelowRange: Double
        let timeAboveRange: Double
    }

    private static func computeGlucoseMetrics(_ samples: [GlucoseSample]) -> GlucoseMetrics {
        guard !samples.isEmpty else {
            return GlucoseMetrics(average: 0, stdDev: 0, cv: 0, timeInRange: 0, timeBelowRange: 0, timeAboveRange: 0)
        }

        let values = samples.map(\.mgdl)
        let avg = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(values.count)
        let sd = sqrt(variance)
        let cv = avg > 0 ? (sd / avg) * 100 : 0

        let inRange = Double(values.filter { $0 >= targetRangeLow && $0 <= targetRangeHigh }.count)
        let below = Double(values.filter { $0 < targetRangeLow }.count)
        let above = Double(values.filter { $0 > targetRangeHigh }.count)
        let total = Double(values.count)

        return GlucoseMetrics(
            average: avg,
            stdDev: sd,
            cv: cv,
            timeInRange: (inRange / total) * 100,
            timeBelowRange: (below / total) * 100,
            timeAboveRange: (above / total) * 100
        )
    }

    // MARK: - Data Quality

    private static func assessDataQuality(glucose: [GlucoseSample], windowDays: Int) -> RegressionReport.DataQuality {
        let expectedReadings = windowDays * 288 // 5-min intervals, 288/day
        let ratio = Double(glucose.count) / Double(expectedReadings)

        if ratio > 0.9 { return .excellent }
        if ratio > 0.7 { return .good }
        if ratio > 0.5 { return .fair }
        return .insufficient
    }

    // MARK: - Time Block Partitioning

    private static func partitionIntoTimeBlocks(
        glucose: [GlucoseSample],
        insulin: [InsulinDelivery],
        carbs: [CarbEntry]
    ) -> [TimeBlock] {

        let blockCount = 24 / hoursPerBlock  // 8 blocks of 3 hours
        var blocks: [TimeBlock] = []

        for i in 0..<blockCount {
            let startHour = i * hoursPerBlock
            let endHour = startHour + hoursPerBlock

            let blockGlucose = glucose.filter { sample in
                let hour = Calendar.current.component(.hour, from: sample.date)
                return hour >= startHour && hour < endHour
            }

            let blockBasal = insulin.filter { delivery in
                let hour = Calendar.current.component(.hour, from: delivery.startDate)
                return hour >= startHour && hour < endHour && delivery.isBasal
            }

            let blockBolus = insulin.filter { delivery in
                let hour = Calendar.current.component(.hour, from: delivery.startDate)
                return hour >= startHour && hour < endHour && !delivery.isBasal
            }

            let blockCarbs = carbs.filter { entry in
                let hour = Calendar.current.component(.hour, from: entry.date)
                return hour >= startHour && hour < endHour
            }

            blocks.append(TimeBlock(
                index: i,
                startHour: startHour,
                endHour: endHour,
                glucoseReadings: blockGlucose,
                basalDeliveries: blockBasal,
                bolusDeliveries: blockBolus,
                carbEntries: blockCarbs
            ))
        }

        return blocks
    }

    // MARK: - Basal Rate Analysis

    /// Analyzes fasting periods (no carbs within 4h) per time block.
    /// If glucose drifts consistently up → basal too low.
    /// If glucose drifts consistently down → basal too high.
    private static func analyzeBasalRates(
        blocks: [TimeBlock],
        currentSchedule: [(startTime: TimeInterval, rate: Double)],
        dataQuality: RegressionReport.DataQuality
    ) -> [BasalSuggestion] {

        guard dataQuality != .insufficient else { return [] }

        var suggestions: [BasalSuggestion] = []

        for block in blocks {
            // Only analyze periods with no carb influence (fasting windows)
            let fastingReadings = filterFastingReadings(
                glucose: block.glucoseReadings,
                carbs: block.carbEntries,
                fastingHours: 4.0
            )

            guard fastingReadings.count >= minimumReadingsPerBlock else { continue }

            // Calculate glucose drift rate (mg/dL per hour) via linear regression
            let driftRate = linearRegressionSlope(samples: fastingReadings)

            // Find current basal rate for this time block
            let blockStartSeconds = TimeInterval(block.startHour * 3600)
            let blockEndSeconds = TimeInterval(block.endHour * 3600)
            let currentRate = findScheduleValue(at: blockStartSeconds, in: currentSchedule.map { ($0.startTime, $0.rate) })

            // Drift thresholds: ±5 mg/dL/hr indicates basal needs adjustment
            let driftThreshold: Double = 5.0

            if abs(driftRate) > driftThreshold {
                // Positive drift = rising BG = need more basal
                // Negative drift = falling BG = need less basal
                let adjustmentFactor: Double
                if driftRate > 0 {
                    // Rising: increase basal proportional to drift
                    adjustmentFactor = min(maxBasalAdjustment, driftRate / 30.0)
                } else {
                    // Falling: decrease basal proportional to drift
                    adjustmentFactor = max(-maxBasalAdjustment, driftRate / 30.0)
                }

                let suggestedRate = currentRate * (1.0 + adjustmentFactor)
                let clampedRate = max(0.05, round(suggestedRate * 20) / 20) // round to 0.05U increments

                let confidence = min(1.0, Double(fastingReadings.count) / 50.0)
                    * (dataQuality == .excellent ? 1.0 : dataQuality == .good ? 0.8 : 0.6)

                let direction = driftRate > 0 ? "rising" : "falling"
                suggestions.append(BasalSuggestion(
                    startTime: blockStartSeconds,
                    endTime: blockEndSeconds,
                    currentRate: currentRate,
                    suggestedRate: clampedRate,
                    confidence: confidence,
                    reason: "Fasting BG \(direction) ~\(String(format: "%.1f", abs(driftRate))) mg/dL/hr in \(block.label)"
                ))
            }
        }

        return suggestions
    }

    // MARK: - ISF Analysis

    /// Analyzes correction bolus outcomes to estimate actual ISF per time block.
    /// Compares BG drop per unit of correction insulin delivered.
    private static func analyzeISF(
        blocks: [TimeBlock],
        currentSchedule: [(startTime: TimeInterval, mgdlPerUnit: Double)],
        dataQuality: RegressionReport.DataQuality
    ) -> [ISFSuggestion] {

        guard dataQuality != .insufficient else { return [] }

        var suggestions: [ISFSuggestion] = []

        for block in blocks {
            // Find correction boluses (non-meal, non-basal)
            let correctionBoluses = block.bolusDeliveries.filter { bolus in
                // A bolus with no carb entry within ±15 min is likely a correction
                let bolusTime = bolus.startDate
                let hasMealContext = block.carbEntries.contains { carb in
                    abs(carb.date.timeIntervalSince(bolusTime)) < 900
                }
                return !hasMealContext && bolus.units > 0.05
            }

            guard correctionBoluses.count >= 3 else { continue }

            // For each correction bolus, measure BG drop over 3 hours
            var observedISFs: [Double] = []
            for bolus in correctionBoluses {
                let bgBefore = findClosestGlucose(to: bolus.startDate, in: block.glucoseReadings, maxOffset: 600)
                let bgAfter = findClosestGlucose(
                    to: bolus.startDate.addingTimeInterval(10800),
                    in: block.glucoseReadings,
                    maxOffset: 1800
                )

                guard let before = bgBefore, let after = bgAfter, bolus.units > 0 else { continue }

                let drop = before - after
                let isf = drop / bolus.units

                // Sanity check: ISF should be between 5 and 500
                if isf > 5 && isf < 500 {
                    observedISFs.append(isf)
                }
            }

            guard observedISFs.count >= 2 else { continue }

            // Use median ISF to reduce outlier influence
            let medianISF = median(observedISFs)
            let blockStartSeconds = TimeInterval(block.startHour * 3600)
            let blockEndSeconds = TimeInterval(block.endHour * 3600)
            let currentISF = findScheduleValue(at: blockStartSeconds, in: currentSchedule.map { ($0.startTime, $0.mgdlPerUnit) })

            let deviation = abs(medianISF - currentISF) / currentISF
            if deviation > 0.10 { // >10% deviation
                let clampedISF: Double
                if medianISF > currentISF {
                    clampedISF = min(currentISF * (1.0 + maxISFAdjustment), medianISF)
                } else {
                    clampedISF = max(currentISF * (1.0 - maxISFAdjustment), medianISF)
                }

                let confidence = min(1.0, Double(observedISFs.count) / 10.0)
                    * (dataQuality == .excellent ? 1.0 : dataQuality == .good ? 0.8 : 0.6)

                suggestions.append(ISFSuggestion(
                    startTime: blockStartSeconds,
                    endTime: blockEndSeconds,
                    currentISF: currentISF,
                    suggestedISF: round(clampedISF),
                    confidence: confidence,
                    reason: "Observed ISF ~\(String(format: "%.0f", medianISF)) vs current \(String(format: "%.0f", currentISF)) in \(block.label) (\(observedISFs.count) corrections)"
                ))
            }
        }

        return suggestions
    }

    // MARK: - ICR Analysis

    /// Analyzes meal bolus outcomes to estimate actual ICR per time block.
    /// Compares post-meal BG excursion per gram of carbs with corresponding insulin.
    private static func analyzeICR(
        blocks: [TimeBlock],
        currentSchedule: [(startTime: TimeInterval, gramsPerUnit: Double)],
        dataQuality: RegressionReport.DataQuality
    ) -> [ICRSuggestion] {

        guard dataQuality != .insufficient else { return [] }

        var suggestions: [ICRSuggestion] = []

        for block in blocks {
            guard !block.carbEntries.isEmpty else { continue }

            // Match each carb entry with its meal bolus and glucose outcome
            var observedICRs: [Double] = []

            for carb in block.carbEntries {
                guard carb.grams > 5 else { continue } // skip tiny entries

                // Find bolus within ±30 min of carb entry
                let mealBolus = block.bolusDeliveries.first { bolus in
                    abs(bolus.startDate.timeIntervalSince(carb.date)) < 1800
                }

                guard let bolus = mealBolus, bolus.units > 0 else { continue }

                // Measure BG at meal time and 3h post-meal
                let bgAtMeal = findClosestGlucose(to: carb.date, in: block.glucoseReadings, maxOffset: 600)
                let bgPostMeal = findClosestGlucose(
                    to: carb.date.addingTimeInterval(10800),
                    in: block.glucoseReadings,
                    maxOffset: 1800
                )

                guard let preMeal = bgAtMeal, let postMeal = bgPostMeal else { continue }

                // If post-meal BG is significantly higher, the ICR is too high (not enough insulin per carb)
                // If post-meal BG is lower, the ICR is too low (too much insulin per carb)
                let bgDelta = postMeal - preMeal

                // Estimate what the "correct" bolus would have been
                // using observed ISF as conversion factor
                let blockStartSeconds = TimeInterval(block.startHour * 3600)
                let currentISFForBlock = findScheduleValue(
                    at: blockStartSeconds,
                    in: [(0, 50.0)] // fallback, should use actual ISF
                )

                let idealBolus = bolus.units + (bgDelta / max(currentISFForBlock, 10))

                if idealBolus > 0 {
                    let observedICR = carb.grams / idealBolus
                    // Sanity: ICR between 1 and 100
                    if observedICR > 1 && observedICR < 100 {
                        observedICRs.append(observedICR)
                    }
                }
            }

            guard observedICRs.count >= 3 else { continue }

            let medianICR = median(observedICRs)
            let blockStartSeconds = TimeInterval(block.startHour * 3600)
            let blockEndSeconds = TimeInterval(block.endHour * 3600)
            let currentICR = findScheduleValue(at: blockStartSeconds, in: currentSchedule.map { ($0.startTime, $0.gramsPerUnit) })

            let deviation = abs(medianICR - currentICR) / currentICR
            if deviation > 0.10 {
                let clampedICR: Double
                if medianICR > currentICR {
                    clampedICR = min(currentICR * (1.0 + maxICRAdjustment), medianICR)
                } else {
                    clampedICR = max(currentICR * (1.0 - maxICRAdjustment), medianICR)
                }

                let confidence = min(1.0, Double(observedICRs.count) / 10.0)
                    * (dataQuality == .excellent ? 1.0 : dataQuality == .good ? 0.8 : 0.6)

                suggestions.append(ICRSuggestion(
                    startTime: blockStartSeconds,
                    endTime: blockEndSeconds,
                    currentICR: currentICR,
                    suggestedICR: round(clampedICR * 10) / 10,
                    confidence: confidence,
                    reason: "Observed ICR ~\(String(format: "%.1f", medianICR)) vs current \(String(format: "%.1f", currentICR)) in \(block.label) (\(observedICRs.count) meals)"
                ))
            }
        }

        return suggestions
    }

    // MARK: - Helper Utilities

    /// Linear regression slope for glucose samples (mg/dL per hour).
    private static func linearRegressionSlope(samples: [GlucoseSample]) -> Double {
        guard samples.count >= 2 else { return 0 }

        let sorted = samples.sorted { $0.date < $1.date }
        let baseTime = sorted[0].date.timeIntervalSinceReferenceDate

        let n = Double(sorted.count)
        var sumX: Double = 0, sumY: Double = 0, sumXY: Double = 0, sumX2: Double = 0

        for sample in sorted {
            let x = (sample.date.timeIntervalSinceReferenceDate - baseTime) / 3600.0
            let y = sample.mgdl
            sumX += x
            sumY += y
            sumXY += x * y
            sumX2 += x * x
        }

        let denominator = n * sumX2 - sumX * sumX
        guard abs(denominator) > 1e-10 else { return 0 }

        return (n * sumXY - sumX * sumY) / denominator
    }

    /// Filters glucose readings to fasting periods (no carbs within the specified hours).
    private static func filterFastingReadings(
        glucose: [GlucoseSample],
        carbs: [CarbEntry],
        fastingHours: Double
    ) -> [GlucoseSample] {
        let fastingWindow = fastingHours * 3600
        return glucose.filter { sample in
            !carbs.contains { carb in
                let timeSinceCarb = sample.date.timeIntervalSince(carb.date)
                return timeSinceCarb >= 0 && timeSinceCarb < fastingWindow
            }
        }
    }

    /// Finds the closest glucose reading to a target time within maxOffset seconds.
    private static func findClosestGlucose(to date: Date, in samples: [GlucoseSample], maxOffset: TimeInterval) -> Double? {
        let closest = samples
            .filter { abs($0.date.timeIntervalSince(date)) <= maxOffset }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        return closest?.mgdl
    }

    /// Finds the active schedule value for a given time of day.
    private static func findScheduleValue(at timeOfDay: TimeInterval, in schedule: [(TimeInterval, Double)]) -> Double {
        guard !schedule.isEmpty else { return 1.0 }
        let sorted = schedule.sorted { $0.0 < $1.0 }
        var active = sorted[0].1
        for entry in sorted {
            if entry.0 <= timeOfDay {
                active = entry.1
            } else {
                break
            }
        }
        return active
    }

    /// Computes the median of a Double array.
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count == 0 { return 0 }
        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        }
        return sorted[count / 2]
    }
}
