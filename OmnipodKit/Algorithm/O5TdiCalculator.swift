//
//  O5TdiCalculator.swift
//  OmnipodKit
//
//  Replicates Insulet's DefaultTdiCoordinator.calculateTDI() logic.
//  Computes Total Daily Insulin from 14 days of dose history,
//  handling data gaps per the TdiCalculatorGap model.
//

import Foundation

struct O5TdiResult {
    let tdiValue: UInt8
    let tdiUnitsDouble: Double
    let isSufficientData: Bool
    let dataSeconds: TimeInterval
    let gapSeconds: TimeInterval
    let calculationTimestamp: Date
    let recordCount: Int
}

struct O5TdiGap {
    let dataInSeconds: TimeInterval
    let gapInSeconds: TimeInterval
    let gapStart: Date
    let gapEnd: Date
}

struct O5TdiCalculator {

    static let defaultWindowDays: Int = 14
    static let defaultSeedTdi: Double = 14.0
    static let minimumDataCoverageRatio: Double = 0.5
    static let maximumGapBeforeExclusion: TimeInterval = 3600 * 6 // 6 hours
    static let recordInterval: TimeInterval = 1800 // 30 min PHB record interval

    /// Main TDI calculation from dose entries.
    /// Mirrors DefaultTdiCoordinator.calculateTDI() from PlatformCore.
    ///
    /// - Parameters:
    ///   - doseEntries: Array of (startDate, endDate, deliveredUnits, isBasal) tuples
    ///     representing all insulin deliveries from DoseStore.
    ///   - windowDays: Lookback window (default 14 days per Insulet spec).
    ///   - seedTdi: Fallback TDI when insufficient data (default 14U).
    ///   - now: Current date (injectable for testing).
    /// - Returns: O5TdiResult with calculated TDI and data quality metrics.
    static func calculateTDI(
        from doseEntries: [(startDate: Date, endDate: Date, deliveredUnits: Double, isBasal: Bool)],
        windowDays: Int = defaultWindowDays,
        seedTdi: Double = defaultSeedTdi,
        now: Date = Date()
    ) -> O5TdiResult {

        let windowStart = now.addingTimeInterval(-Double(windowDays) * 86400)

        // Filter to window — mirrors filterRecordsForNewCalculations()
        let relevantDoses = doseEntries.filter { entry in
            entry.endDate >= windowStart && entry.startDate <= now
        }

        guard !relevantDoses.isEmpty else {
            return O5TdiResult(
                tdiValue: UInt8(clamping: Int(seedTdi.rounded())),
                tdiUnitsDouble: seedTdi,
                isSufficientData: false,
                dataSeconds: 0,
                gapSeconds: Double(windowDays) * 86400,
                calculationTimestamp: now,
                recordCount: 0
            )
        }

        // Analyze data continuity — mirrors getDataTimeAndGapTime()
        let (dataSeconds, gapSeconds, _) = analyzeDataContinuity(
            doses: relevantDoses,
            windowStart: windowStart,
            windowEnd: now
        )

        let totalWindowSeconds = Double(windowDays) * 86400
        let coverageRatio = dataSeconds / totalWindowSeconds
        let isSufficient = coverageRatio >= minimumDataCoverageRatio

        // Sum all insulin delivered, clipping doses to the window boundaries
        var totalInsulin: Double = 0
        for dose in relevantDoses {
            let effectiveStart = max(dose.startDate, windowStart)
            let effectiveEnd = min(dose.endDate, now)
            let durationRatio: Double
            let totalDuration = dose.endDate.timeIntervalSince(dose.startDate)
            if totalDuration > 0 {
                let effectiveDuration = effectiveEnd.timeIntervalSince(effectiveStart)
                durationRatio = effectiveDuration / totalDuration
            } else {
                durationRatio = 1.0
            }
            totalInsulin += dose.deliveredUnits * durationRatio
        }

        // Calculate effective days with data (excluding large gaps)
        let effectiveDataDays = max(1.0, dataSeconds / 86400.0)

        let calculatedTdi: Double
        if isSufficient {
            calculatedTdi = totalInsulin / effectiveDataDays
        } else {
            // Blend seed with available data proportional to coverage
            let dataWeight = coverageRatio / minimumDataCoverageRatio
            let dataTdi = effectiveDataDays > 0 ? totalInsulin / effectiveDataDays : seedTdi
            calculatedTdi = (dataTdi * dataWeight) + (seedTdi * (1.0 - dataWeight))
        }

        let clampedTdi = max(1.0, min(255.0, calculatedTdi))

        return O5TdiResult(
            tdiValue: UInt8(clamping: Int(clampedTdi.rounded())),
            tdiUnitsDouble: clampedTdi,
            isSufficientData: isSufficient,
            dataSeconds: dataSeconds,
            gapSeconds: gapSeconds,
            calculationTimestamp: now,
            recordCount: relevantDoses.count
        )
    }

    /// Analyzes temporal continuity of dose data within the window.
    /// Mirrors DefaultTdiCoordinator.getDataTimeAndGapTime().
    private static func analyzeDataContinuity(
        doses: [(startDate: Date, endDate: Date, deliveredUnits: Double, isBasal: Bool)],
        windowStart: Date,
        windowEnd: Date
    ) -> (dataSeconds: TimeInterval, gapSeconds: TimeInterval, gaps: [O5TdiGap]) {

        // Sort all dose events by start time
        let sorted = doses.sorted { $0.startDate < $1.startDate }

        var dataSeconds: TimeInterval = 0
        var gapSeconds: TimeInterval = 0
        var gaps: [O5TdiGap] = []
        var lastCoveredTime = windowStart

        for dose in sorted {
            let doseStart = max(dose.startDate, windowStart)
            let doseEnd = min(dose.endDate, windowEnd)

            guard doseEnd > doseStart else { continue }

            // Check for gap between last covered time and this dose
            if doseStart > lastCoveredTime {
                let gapDuration = doseStart.timeIntervalSince(lastCoveredTime)
                if gapDuration > maximumGapBeforeExclusion {
                    gaps.append(O5TdiGap(
                        dataInSeconds: 0,
                        gapInSeconds: gapDuration,
                        gapStart: lastCoveredTime,
                        gapEnd: doseStart
                    ))
                }
                gapSeconds += gapDuration
            }

            // Add data coverage from this dose
            let newCoveredEnd = max(lastCoveredTime, doseEnd)
            if newCoveredEnd > lastCoveredTime {
                let dataDuration = newCoveredEnd.timeIntervalSince(max(lastCoveredTime, doseStart))
                if dataDuration > 0 {
                    dataSeconds += dataDuration
                }
            }
            lastCoveredTime = max(lastCoveredTime, doseEnd)
        }

        // Trailing gap from last dose to window end
        if lastCoveredTime < windowEnd {
            let trailingGap = windowEnd.timeIntervalSince(lastCoveredTime)
            gapSeconds += trailingGap
            if trailingGap > maximumGapBeforeExclusion {
                gaps.append(O5TdiGap(
                    dataInSeconds: 0,
                    gapInSeconds: trailingGap,
                    gapStart: lastCoveredTime,
                    gapEnd: windowEnd
                ))
            }
        }

        return (dataSeconds, gapSeconds, gaps)
    }
}
