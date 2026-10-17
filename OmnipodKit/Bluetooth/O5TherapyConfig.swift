//
//  O5TherapyConfig.swift
//  OmnipodKit
//
//  Bridges Loop therapy settings to Omnipod 5 AID command parameters.
//  Converts glucoseTargetRangeSchedule, DIA, and TDI into the binary
//  formats expected by O5AidCommands during pod activation.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

extension Collection {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

struct O5TherapyConfig {

    // MARK: - Target BG Profile

    /// 48 half-hour BG target values (mg/dL) for a 24-hour day.
    /// Index 0 = 00:00–00:30, index 1 = 00:30–01:00, ..., index 47 = 23:30–24:00.
    let targetBgProfile: [UInt32]

    // MARK: - Duration of Insulin Action

    /// DIA in half-hour units (pod format). E.g., 8 = 4 hours, 10 = 5 hours, 12 = 6 hours.
    let diaHalfHours: Int

    // MARK: - Total Daily Insulin

    /// TDI in units, encoded as byte 3 of the TdiCommand binary payload.
    /// The pod uses this for its internal algorithm scaling.
    let tdiUnits: UInt8

    // MARK: - Insulin History

    /// 3 batches of 24 records (7 bytes each) covering 14 days of insulin delivery history.
    /// Each record summarizes ~4h 40m of bolus activity. nil = send all zeros (no history).
    let insulinHistoryBatches: [[Data]]?

    // MARK: - Initialization from Loop Settings

    /// Creates an O5TherapyConfig from Loop's therapy settings.
    ///
    /// - Parameters:
    ///   - glucoseTargetSchedule: Array of (startTime, targetMgdl) tuples where
    ///     startTime is seconds from midnight. Values are interpolated into 48 half-hour slots.
    ///   - diaHours: Duration of Insulin Action in hours (e.g., 5.0).
    ///   - totalDailyInsulin: Total Daily Insulin in units (e.g., 35.0). Clamped to 1–255.
    ///   - insulinHistory: Optional insulin history records for pod-to-pod transfers.
    init(glucoseTargetSchedule: [(startTime: TimeInterval, targetMgdl: Double)],
         diaHours: Double,
         totalDailyInsulin: Double,
         insulinHistory: [[Data]]? = nil) {

        self.targetBgProfile = O5TherapyConfig.buildTargetProfile(from: glucoseTargetSchedule)
        self.diaHalfHours = O5TherapyConfig.diaToHalfHours(diaHours)

        // Guard against TDI=0 reaching the pod: the pod's AID algorithm divides by TDI,
        // so a zero value causes undefined behavior. Enforce minimum of 1 in the UInt8 encoding.
        let safeTdi = max(O5TdiCalculator.minimumTdi, totalDailyInsulin)
        self.tdiUnits = max(O5TdiCalculator.minimumTdiUInt8, UInt8(clamping: Int(safeTdi.rounded())))

        self.insulinHistoryBatches = insulinHistory
    }

    /// Creates a default config (used when no Loop settings are available).
    static var `default`: O5TherapyConfig {
        return O5TherapyConfig(
            glucoseTargetSchedule: [(0, 110)],
            diaHours: 4.0,
            totalDailyInsulin: 14.0
        )
    }

    // MARK: - Conversion Utilities

    /// Converts a glucose target schedule into 48 half-hour slot values.
    ///
    /// Each schedule entry specifies a start time (seconds from midnight) and a target BG.
    /// The target holds until the next entry's start time. Values are sampled at
    /// the midpoint of each half-hour slot.
    static func buildTargetProfile(from schedule: [(startTime: TimeInterval, targetMgdl: Double)]) -> [UInt32] {
        guard !schedule.isEmpty else {
            return Array(repeating: 110, count: 48)
        }

        let sorted = schedule.sorted { $0.startTime < $1.startTime }
        var profile = [UInt32](repeating: 0, count: 48)

        for slot in 0..<48 {
            let slotMidpoint = TimeInterval(slot) * 1800.0 + 900.0 // midpoint of each 30-min slot

            // Find the active schedule entry for this time
            var activeTarget = sorted[0].targetMgdl
            for entry in sorted {
                if entry.startTime <= slotMidpoint {
                    activeTarget = entry.targetMgdl
                } else {
                    break
                }
            }

            // Clamp to valid pod range (70–180 mg/dL based on Omnipod 5 clinical limits)
            let clamped = max(70.0, min(180.0, activeTarget))
            profile[slot] = UInt32(clamped.rounded())
        }

        return profile
    }

    /// Converts DIA from hours to half-hour units (pod format).
    /// Pod accepts values 4–16 (2–8 hours). Clamped to this range.
    static func diaToHalfHours(_ hours: Double) -> Int {
        let halfHours = Int((hours * 2).rounded())
        return max(4, min(16, halfHours))
    }

    /// Builds the TDI binary payload with the configured TDI value.
    /// Format: [version(0x00), therapyType(0x03), deliveryMode(0x00), tdiUnits, reserved(0x00)]
    var tdiBinaryPayload: Data {
        return Data([0x00, 0x03, 0x00, tdiUnits, 0x00])
    }
}
