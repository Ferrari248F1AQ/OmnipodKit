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

    /// Minimum TDI value to prevent division by zero in the pod's AID algorithm.
    /// The pod divides by TDI internally; sending 0 causes undefined behavior.
    /// 0.1 U/day is the absolute floor; the UInt8 encoding floor is 1.
    static let minimumTdi: Double = 0.1
    static let minimumTdiUInt8: UInt8 = 1

    /// Main TDI calculation from dose entries.
    /// Mirrors DefaultTdiCoordinator.calculateTDI() from PlatformCore.
    ///
    /// - Parameters:
    ///   - doseEntries: Array of (startDate, endDate, deliveredUnits, isBasal) tuples
    ///     representing all insulin deliveries from DoseStore.
    ///   - supplementalInsulin: Historical insulin entries imported from Nightscout,
    ///     used to fill gaps when DoseStore has insufficient coverage (fresh install,
    ///     phone change). These are only used for days not covered by doseEntries.
    ///   - windowDays: Lookback window (default 14 days per Insulet spec).
    ///   - seedTdi: Fallback TDI when insufficient data (default 14U).
    ///   - now: Current date (injectable for testing).
    /// - Returns: O5TdiResult with calculated TDI and data quality metrics.
    static func calculateTDI(
        from doseEntries: [(startDate: Date, endDate: Date, deliveredUnits: Double, isBasal: Bool)],
        supplementalInsulin: [(timestamp: Date, units: Double)] = [],
        windowDays: Int = defaultWindowDays,
        seedTdi: Double = defaultSeedTdi,
        now: Date = Date()
    ) -> O5TdiResult {

        let windowStart = now.addingTimeInterval(-Double(windowDays) * 86400)

        // Filter to window — mirrors filterRecordsForNewCalculations()
        let relevantDoses = doseEntries.filter { entry in
            entry.endDate >= windowStart && entry.startDate <= now
        }

        // Convert supplemental Nightscout insulin into dose-shaped entries
        // for days not covered by DoseStore data.
        let mergedDoses = mergeWithSupplementalInsulin(
            primary: relevantDoses,
            supplemental: supplementalInsulin,
            windowStart: windowStart,
            windowEnd: now
        )

        guard !mergedDoses.isEmpty else {
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
            doses: mergedDoses,
            windowStart: windowStart,
            windowEnd: now
        )

        let totalWindowSeconds = Double(windowDays) * 86400
        let coverageRatio = dataSeconds / totalWindowSeconds
        let isSufficient = coverageRatio >= minimumDataCoverageRatio

        // Sum all insulin delivered, clipping doses to the window boundaries
        var totalInsulin: Double = 0
        for dose in mergedDoses {
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

        // Floor at minimumTdi to prevent division by zero in the pod's AID algorithm.
        // The UInt8 encoding also needs a separate floor since values < 0.5 round to 0.
        let clampedTdi = max(minimumTdi, min(255.0, calculatedTdi))
        let tdiValueUInt8 = max(minimumTdiUInt8, UInt8(clamping: Int(clampedTdi.rounded())))

        return O5TdiResult(
            tdiValue: tdiValueUInt8,
            tdiUnitsDouble: clampedTdi,
            isSufficientData: isSufficient,
            dataSeconds: dataSeconds,
            gapSeconds: gapSeconds,
            calculationTimestamp: now,
            recordCount: relevantDoses.count
        )
    }

    /// Merges supplemental Nightscout insulin entries into the primary dose stream,
    /// only filling time ranges where DoseStore has no data (gaps > 6h).
    private static func mergeWithSupplementalInsulin(
        primary: [(startDate: Date, endDate: Date, deliveredUnits: Double, isBasal: Bool)],
        supplemental: [(timestamp: Date, units: Double)],
        windowStart: Date,
        windowEnd: Date
    ) -> [(startDate: Date, endDate: Date, deliveredUnits: Double, isBasal: Bool)] {

        guard !supplemental.isEmpty else { return primary }

        // Find time ranges covered by primary (DoseStore) data
        let sorted = primary.sorted { $0.startDate < $1.startDate }
        var coveredRanges: [(start: Date, end: Date)] = []
        for dose in sorted {
            let s = max(dose.startDate, windowStart)
            let e = min(dose.endDate, windowEnd)
            guard e > s else { continue }
            if let last = coveredRanges.last, s <= last.end.addingTimeInterval(3600) {
                coveredRanges[coveredRanges.count - 1].end = max(last.end, e)
            } else {
                coveredRanges.append((start: s, end: e))
            }
        }

        // Only use supplemental entries that fall in uncovered gaps
        let supplementalDoses: [(startDate: Date, endDate: Date, deliveredUnits: Double, isBasal: Bool)] = supplemental.compactMap { entry in
            guard entry.timestamp >= windowStart && entry.timestamp <= windowEnd else { return nil }
            let isCovered = coveredRanges.contains { entry.timestamp >= $0.start && entry.timestamp <= $0.end }
            if isCovered { return nil }
            return (startDate: entry.timestamp,
                    endDate: entry.timestamp.addingTimeInterval(recordInterval),
                    deliveredUnits: entry.units,
                    isBasal: false)
        }

        return primary + supplementalDoses
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
