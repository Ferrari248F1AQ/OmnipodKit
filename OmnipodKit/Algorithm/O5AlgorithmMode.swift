//
//  O5AlgorithmMode.swift
//  OmnipodKit
//
//  Defines the dual-algorithm mode for Omnipod 5 pods.
//  Allows switching between Loop's native algorithm and
//  Insulet's on-pod AID algorithm within the same pod session.
//

import Foundation

/// The active dosing algorithm for an O5 pod session.
/// Both modes maintain the same BLE connection and pod session —
/// only the decision-making authority shifts.
public enum O5AlgorithmMode: String, Codable, CaseIterable {

    /// Loop's native algorithm controls dosing via temp basals and auto-boluses.
    /// The pod's on-board algorithm is dormant — pod acts as a simple delivery device.
    /// Loop calls enactTempBasal / enactBolus as usual.
    case loopAlgorithm = "loop"

    /// Insulet's on-pod AID algorithm controls dosing autonomously.
    /// Loop sends CGM data and configuration (TDI, target BG, DIA) via nudge commands,
    /// and reads back algorithmPulses, IOB, and loop status.
    /// Loop does NOT send temp basals or auto-boluses — it becomes an observer.
    /// Manual boluses from the user are still sent through Loop's UI.
    case insuletAID = "insulet"

    var displayName: String {
        switch self {
        case .loopAlgorithm: return "Loop Algorithm"
        case .insuletAID: return "Insulet AID (On-Pod)"
        }
    }

    var shortName: String {
        switch self {
        case .loopAlgorithm: return "Loop"
        case .insuletAID: return "Insulet"
        }
    }

    /// Whether Loop should send automatic temp basals and auto-boluses.
    var loopControlsDosing: Bool {
        return self == .loopAlgorithm
    }

    /// Whether the pod's on-board algorithm should be activated.
    var podAidActive: Bool {
        return self == .insuletAID
    }
}

/// Status of the Insulet on-pod AID algorithm, read from GetAidStatus / G3.11 / G3.12.
public struct O5AidStatus: Codable, Equatable {

    // MARK: - Core EGV / Algorithm State

    /// Current estimated glucose value the pod is working with (mg/dL).
    public var egvValue: Int?

    /// Timestamp of the last EGV sent to the pod.
    public var egvTimestamp: Date?

    /// Rate of glucose change (mg/dL per 5 min).
    public var egvRate: Int?

    /// Current TDI value the pod is using (units).
    public var tdi: Int?

    /// Pod's internal loop status.
    public var loopStatus: O5LoopStatus

    /// IOB as calculated by the pod's Kalman filter (micro-units, ScalingFactorMillion).
    public var microUnitScaledIob: Int?

    /// IOB in standard units (derived from microUnitScaledIob).
    public var iobUnits: Double? {
        guard let micro = microUnitScaledIob else { return nil }
        return Double(micro) / 1_000_000.0
    }

    /// UTC timestamp from the pod.
    public var utcTimestamp: Date?

    /// Pod internal timestamp (seconds since pod activation).
    public var podTimestamp: UInt32?

    /// Pod communication timestamp (last BLE exchange).
    public var podCommunicationTimestamp: Date?

    // MARK: - Algorithm Flags

    /// Whether the pod's AID algorithm is active.
    public var aidActivated: Bool

    /// Whether activity mode (elevated target) is active.
    public var isActivityActive: Bool

    /// Whether the pod has fallen back to safe basal delivery.
    public var safeBasalMode: Bool

    /// Whether the pod is in automated limited mode (no CGM data, safe basal).
    public var limitedBasalMode: Bool

    // MARK: - Activity Mode

    /// Activity mode duration remaining (minutes).
    public var activityDuration: Int?

    /// Activity mode intensity level.
    public var activityIntensity: Int?

    // MARK: - Hypo Protection

    /// Whether hypo protection is active.
    public var hypoProtectActive: Bool

    // MARK: - Insulin Delivery

    /// Number of insulin pulses decided by the algorithm this cycle.
    public var algorithmPulses: Int?

    /// Correction pulses this cycle.
    public var bolusCorrectionPulses: Int?

    /// Meal-related pulses this cycle.
    public var mealPulses: Int?

    /// Immediate correction volume.
    public var immediateCorrectionVolume: Double?

    // MARK: - Kalman Filter State

    /// Kalman filter state vector (persisted by the pod).
    /// x0 = glucose estimate, x1 = rate of change, x2 = acceleration.
    public var lastX0State: Double?
    public var lastX1State: Double?
    public var lastX2State: Double?

    // MARK: - CGM Sensor State (varies by sensor type)

    /// CGM algorithm state (G6: CGMG6AlgorithmState, G7: CGMG7AlgorithmState).
    public var cgmAlgoState: Int?

    /// CGM transmitter state.
    public var cgmTxState: Int?

    /// Transmitter lifetime remaining (days or hours depending on sensor type).
    public var transmitterLifetime: Int?

    /// CGM sensor timestamp (G7-specific).
    public var cgmSensorTimestamp: Date?

    /// EGV rate validity flag (G7: whether the rate value is trustworthy).
    public var egvRateValidity: Bool?

    // MARK: - Patient History Buffer

    /// Last PHB record index written on an alarm event.
    public var lastPHBWrittenOnAlarm: UInt32?

    /// Last PHB record index the app requested.
    public var lastPHBRequested: UInt32?

    // MARK: - QN (Query/Nudge) State

    /// QN readiness state (pod's readiness for nudge operations).
    public var qnReadiness: Int?

    /// Number of QN retry attempts.
    public var qnTryTimes: Int?

    /// ER48 readiness flag (firmware error recovery state).
    public var er48Ready: Int?

    // MARK: - Init

    public init() {
        self.loopStatus = .unknown
        self.aidActivated = false
        self.isActivityActive = false
        self.safeBasalMode = false
        self.limitedBasalMode = false
        self.hypoProtectActive = false
    }
}

/// The pod's internal loop status.
public enum O5LoopStatus: String, Codable, CaseIterable {
    case closedLoop = "closedLoop"
    case limitedMode = "limitedMode"
    case safeBasal = "safeBasal"
    case inactive = "inactive"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .closedLoop: return "Closed Loop"
        case .limitedMode: return "Limited Mode"
        case .safeBasal: return "Safe Basal"
        case .inactive: return "Inactive"
        case .unknown: return "Unknown"
        }
    }

    var isAutomaticDelivery: Bool {
        return self == .closedLoop || self == .limitedMode
    }
}
