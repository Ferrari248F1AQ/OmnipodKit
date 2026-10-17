//
//  O5TherapyConfigBuilder.swift
//  OmnipodKit
//
//  Constructs O5TherapyConfig from Loop's therapy settings.
//  This is the bridge between Loop's LoopDataManager/TherapySettings
//  and the Omnipod 5 AID command parameters.
//
//  Usage in Loop's LoopDataManager or PumpManagerUI:
//
//    let config = O5TherapyConfigBuilder.build(
//        glucoseTargetRangeSchedule: settings.glucoseTargetRangeSchedule,
//        insulinModelDuration: settings.insulinModelSettings?.actionDuration,
//        totalDailyInsulin: doseStore.lastTotalDailyInsulin
//    )
//    pumpManager.pairAndPrime(therapyConfig: config, completion: ...)
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

struct O5TherapyConfigBuilder {

    /// Builds an O5TherapyConfig from Loop therapy settings.
    ///
    /// - Parameters:
    ///   - glucoseTargetRangeSchedule: Loop's GlucoseRangeSchedule as an array of
    ///     (startTime in seconds from midnight, lowerBound mg/dL, upperBound mg/dL).
    ///     The midpoint of lower/upper bounds is used as the pod target.
    ///   - insulinModelDuration: Duration of insulin action in seconds (from InsulinModelSettings).
    ///     Nil defaults to 4 hours (8 half-hour slots).
    ///   - totalDailyInsulin: Most recent TDI in units from DoseStore. Nil defaults to 14U.
    ///   - insulinDeliveryHistory: Optional recent insulin delivery history for pod-to-pod transfer.
    ///     Each batch is 24 records of 7 bytes. Typically 3 batches covering 72 records (~3 days).
    /// - Returns: O5TherapyConfig ready for pod activation.
    static func build(
        glucoseTargetRangeSchedule: [(startTime: TimeInterval, lowerBound: Double, upperBound: Double)]? = nil,
        insulinModelDuration: TimeInterval? = nil,
        totalDailyInsulin: Double? = nil,
        insulinDeliveryHistory: [[Data]]? = nil
    ) -> O5TherapyConfig {

        // Convert glucose target range schedule to (startTime, midpoint) pairs
        let targetSchedule: [(startTime: TimeInterval, targetMgdl: Double)]
        if let schedule = glucoseTargetRangeSchedule, !schedule.isEmpty {
            targetSchedule = schedule.map { entry in
                let midpoint = (entry.lowerBound + entry.upperBound) / 2.0
                return (startTime: entry.startTime, targetMgdl: midpoint)
            }
        } else {
            targetSchedule = [(startTime: 0, targetMgdl: 110)]
        }

        // Convert DIA from seconds to hours
        let diaHours: Double
        if let duration = insulinModelDuration {
            diaHours = duration / 3600.0
        } else {
            diaHours = 4.0
        }

        // TDI with sensible default — enforce minimum to prevent division by zero in pod AID algorithm
        let tdi = max(O5TdiCalculator.minimumTdi, totalDailyInsulin ?? O5TdiCalculator.defaultSeedTdi)

        return O5TherapyConfig(
            glucoseTargetSchedule: targetSchedule,
            diaHours: diaHours,
            totalDailyInsulin: tdi,
            insulinHistory: insulinDeliveryHistory
        )
    }

    /// Builds an O5TherapyConfig for a pod replacement scenario where insulin history
    /// should be transferred from the previous pod session.
    ///
    /// - Parameters:
    ///   - glucoseTargetRangeSchedule: Same as build()
    ///   - insulinModelDuration: Same as build()
    ///   - totalDailyInsulin: Same as build()
    ///   - recentDoses: Array of (timestamp, units, type) representing recent insulin deliveries.
    ///     These are converted to the 7-byte record format expected by the O5 algorithm.
    /// - Returns: O5TherapyConfig with populated insulin history.
    static func buildWithDoseHistory(
        glucoseTargetRangeSchedule: [(startTime: TimeInterval, lowerBound: Double, upperBound: Double)]? = nil,
        insulinModelDuration: TimeInterval? = nil,
        totalDailyInsulin: Double? = nil,
        recentDoses: [(timestamp: Date, units: Double, isMeal: Bool)]? = nil
    ) -> O5TherapyConfig {

        var historyBatches: [[Data]]? = nil

        if let doses = recentDoses, !doses.isEmpty {
            historyBatches = encodeInsulinHistory(doses: doses)
        }

        return build(
            glucoseTargetRangeSchedule: glucoseTargetRangeSchedule,
            insulinModelDuration: insulinModelDuration,
            totalDailyInsulin: totalDailyInsulin,
            insulinDeliveryHistory: historyBatches
        )
    }

    // MARK: - Insulin History Encoding

    /// Encodes recent dose history into 3 batches of 24 records (7 bytes each).
    ///
    /// Record format (7 bytes, from RE analysis):
    ///   Byte 0-3: recordTimestampInSeconds (UInt32 BE, seconds since pod activation)
    ///   Byte 4:   sumUserBolusCorrection (UInt8, in 0.05U pulses)
    ///   Byte 5:   sumUserBolusMeal (UInt8, in 0.05U pulses)
    ///   Byte 6:   sumAlgorithm (UInt8, algorithm-delivered pulses)
    ///
    /// Note: This format is derived from RE analysis of the PatientHistoryRecord structure.
    /// Field mapping may need adjustment based on real pod interaction testing.
    private static func encodeInsulinHistory(doses: [(timestamp: Date, units: Double, isMeal: Bool)]) -> [[Data]] {
        let totalRecords = 72 // 3 batches x 24 records
        let bytesPerRecord = 7

        // Sort doses by timestamp, most recent first
        let sortedDoses = doses.sorted { $0.timestamp > $1.timestamp }

        // Group doses into half-hour windows aligned to the most recent dose
        let referenceTime = sortedDoses.first?.timestamp ?? Date()
        var records: [Data] = []

        for recordIndex in 0..<totalRecords {
            let windowEnd = referenceTime.addingTimeInterval(-Double(recordIndex) * 1800.0)
            let windowStart = windowEnd.addingTimeInterval(-1800.0)

            // Find doses in this window
            let windowDoses = sortedDoses.filter { $0.timestamp > windowStart && $0.timestamp <= windowEnd }

            var record = Data(count: bytesPerRecord)
            let timestampSeconds = UInt32(max(0, windowEnd.timeIntervalSince(referenceTime.addingTimeInterval(-Double(totalRecords) * 1800.0))))
            record[0] = UInt8((timestampSeconds >> 24) & 0xFF)
            record[1] = UInt8((timestampSeconds >> 16) & 0xFF)
            record[2] = UInt8((timestampSeconds >> 8) & 0xFF)
            record[3] = UInt8(timestampSeconds & 0xFF)

            var correctionPulses: Double = 0
            var mealPulses: Double = 0
            for dose in windowDoses {
                let pulses = dose.units / 0.05 // Convert units to 0.05U pulses
                if dose.isMeal {
                    mealPulses += pulses
                } else {
                    correctionPulses += pulses
                }
            }

            record[4] = UInt8(clamping: Int(correctionPulses.rounded()))
            record[5] = UInt8(clamping: Int(mealPulses.rounded()))
            record[6] = 0 // sumAlgorithm: always 0 when Loop controls dosing

            records.append(record)
        }

        // Split into 3 batches of 24
        return stride(from: 0, to: records.count, by: 24).map { start in
            Array(records[start..<min(start + 24, records.count)])
        }
    }
}
