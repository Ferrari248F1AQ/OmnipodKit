//
//  O5NudgeController.swift
//  OmnipodKit
//
//  Manages periodic communication with the O5 pod when Insulet AID is active.
//  Sends CGM updates, TDI recalculations, and target BG changes to the pod,
//  and reads back AID status (algorithm pulses, IOB, loop status).
//
//  This mirrors Insulet's NudgeController (v1/v2) from PodSimCore,
//  adapted for Loop's architecture where CGM data comes from GlucoseStore
//  and insulin history from DoseStore.
//

import Foundation
import os.log

protocol O5NudgeDataSource: AnyObject {
    /// Latest CGM value in mg/dL and its timestamp.
    func latestGlucose() -> (mgdl: Int, date: Date)?

    /// Recent glucose history for Kalman filter warmup (newest first, up to ~30 min).
    func recentGlucoseHistory(minutes: Int) -> [(mgdl: Int, date: Date)]

    /// Dose history for TDI calculation: (startDate, endDate, deliveredUnits, isBasal).
    func recentDoseHistory(since: Date) -> [(startDate: Date, endDate: Date, deliveredUnits: Double, isBasal: Bool)]

    /// Current glucose target schedule as (startTime seconds from midnight, target mg/dL).
    func currentGlucoseTargets() -> [(startTime: TimeInterval, targetMgdl: Double)]?

    /// Current correction factor (ISF) schedule as (startTime seconds from midnight, ISF mg/dL/U).
    func currentCorrectionFactors() -> [(startTime: TimeInterval, isf: Double)]?

    /// Whether activity mode is requested by the user.
    func isActivityModeRequested() -> (active: Bool, duration: Int, intensity: Int)?
}

/// Delegate for receiving pod-initiated nudge events (alarms, alerts).
protocol O5NudgeDelegate: AnyObject {
    func nudgeController(_ controller: O5NudgeController, didReceiveAlarm alarmCode: UInt8, podStatus: O5AidStatus)
    func nudgeController(_ controller: O5NudgeController, didReceiveAlert alertMask: O5AlertMask, podStatus: O5AidStatus)
    func nudgeController(_ controller: O5NudgeController, didUpdateAidStatus status: O5AidStatus)
    func nudgeController(_ controller: O5NudgeController, didEnterLimitedMode reason: String)
}

class O5NudgeController {

    private let log = OSLog(category: "O5NudgeController")

    weak var dataSource: O5NudgeDataSource?
    weak var delegate: O5NudgeDelegate?

    /// CGM pairing manager for sensor registration.
    private(set) var cgmPairingManager = O5CgmPairingManager()

    /// Last TDI sent to the pod.
    private(set) var lastTdiSent: UInt8?
    private(set) var lastTdiCalculation: Date?

    /// Last CGM value sent to the pod.
    private(set) var lastEgvSent: Int?
    private(set) var lastEgvSentDate: Date?

    /// Last AID status read from the pod.
    private(set) var lastAidStatus: O5AidStatus?

    /// Last correction factor profile sent.
    private(set) var lastCorrectionFactorSent: Date?

    /// Last loop state sent to the pod.
    private(set) var lastLoopStateSent: O5LoopStateValue?

    /// Count of consecutive missing EGV readings.
    private(set) var missingEgvCount: Int = 0

    /// Threshold before entering Automated Limited Mode.
    static let missingEgvLimitedModeThreshold = 12

    /// Minimum interval between TDI recalculations (1 hour).
    static let tdiRecalculationInterval: TimeInterval = 3600

    /// Minimum interval between CGM nudges (4.5 min, slightly less than CGM interval).
    static let cgmNudgeInterval: TimeInterval = 270

    /// Minimum interval between correction factor profile updates (1 hour).
    static let correctionFactorUpdateInterval: TimeInterval = 3600

    init(dataSource: O5NudgeDataSource? = nil) {
        self.dataSource = dataSource
    }

    // MARK: - Nudge Cycle

    /// Performs a complete nudge cycle during a BLE session.
    /// Called by OmniPumpManager during its periodic loop when Insulet AID is active.
    ///
    /// - Parameter transport: The active BLE message transport for sending O5 AID commands.
    /// - Returns: Updated O5AidStatus from the pod.
    func performNudgeCycle(transport: BlePodMessageTransport) throws -> O5AidStatus {

        // 1. Send CGM update if we have a new reading
        let cgmSent = try nudgeCgm(transport: transport)

        // 2. Track missing EGV and manage Automated Limited Mode
        if !cgmSent {
            missingEgvCount += 1
            if missingEgvCount >= O5NudgeController.missingEgvLimitedModeThreshold {
                try enterLimitedMode(transport: transport)
            }
        } else {
            if missingEgvCount >= O5NudgeController.missingEgvLimitedModeThreshold {
                try exitLimitedMode(transport: transport)
            }
            missingEgvCount = 0
        }

        // 3. Recalculate and send TDI if enough time has passed
        try nudgeTdi(transport: transport)

        // 4. Update correction factor profile if changed
        try nudgeCorrectionFactor(transport: transport)

        // 5. Update activity mode if requested
        try nudgeActivityMode(transport: transport)

        // 6. Read full AID status from pod (SetAidPodStatus command)
        let status = try readFullAidStatus(transport: transport)
        self.lastAidStatus = status

        // 7. Notify delegate
        delegate?.nudgeController(self, didUpdateAidStatus: status)

        return status
    }

    // MARK: - CGM Nudge

    /// Sends the latest CGM value to the pod via EgvCommand.
    /// - Returns: true if a new EGV was sent, false if no data or skipped.
    @discardableResult
    private func nudgeCgm(transport: BlePodMessageTransport) throws -> Bool {
        guard let dataSource = dataSource,
              let (mgdl, date) = dataSource.latestGlucose() else {
            log.default("No CGM data available for nudge")
            return false
        }

        // Skip if we already sent this reading
        if let lastDate = lastEgvSentDate,
           date.timeIntervalSince(lastDate) < O5NudgeController.cgmNudgeInterval {
            return false
        }

        let egvString = String(mgdl)
        log.default("Nudge CGM: sending EGV=%{public}@ (%{public}@)", egvString, date.description)

        let (payload, prefix) = O5AidCommands.EgvCommand.payload(value: egvString)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)

        lastEgvSent = mgdl
        lastEgvSentDate = date

        // Update CGM pairing manager state
        cgmPairingManager.updateCgmState(from: mgdl)

        return true
    }

    // MARK: - CGM History Burst

    /// Sends recent CGM history to the pod to accelerate Kalman filter warmup.
    /// Called when switching from Loop algorithm to Insulet AID so the pod
    /// doesn't spend ~30 min in limited mode waiting for enough EGV data.
    ///
    /// Sends up to 6 readings (oldest first) from the last 30 minutes,
    /// one EgvCommand per reading. The pod's Kalman filter uses the sequence
    /// to estimate glucose rate of change (x1) and acceleration (x2).
    func sendCgmHistoryBurst(transport: BlePodMessageTransport) throws -> Int {
        guard let dataSource = dataSource else { return 0 }

        let history = dataSource.recentGlucoseHistory(minutes: 30)
        guard !history.isEmpty else {
            log.default("CGM burst: no recent glucose history available")
            return 0
        }

        // history is newest-first; take up to 6 most recent, then reverse to
        // send oldest-first so Kalman processes them in chronological order.
        let readings = Array(history.prefix(6).reversed())

        var sentCount = 0
        var lastSent: (mgdl: Int, date: Date)?
        for reading in readings {
            guard reading.mgdl > 0 && reading.mgdl < 600 else { continue }
            let egvString = String(reading.mgdl)
            let (payload, prefix) = O5AidCommands.EgvCommand.payload(value: egvString)
            do {
                let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
                sentCount += 1
                lastSent = reading
            } catch {
                log.error("CGM burst: failed at reading %d/%d: %{public}@",
                          sentCount + 1, readings.count, String(describing: error))
                break
            }
        }

        if let last = lastSent {
            lastEgvSent = last.mgdl
            lastEgvSentDate = last.date
        }

        log.default("CGM burst: sent %d/%d historical EGV readings for Kalman warmup",
                    sentCount, readings.count)
        return sentCount
    }

    // MARK: - TDI Nudge

    /// Recalculates and sends TDI if the recalculation interval has elapsed.
    private func nudgeTdi(transport: BlePodMessageTransport) throws {
        // Only recalculate hourly
        if let lastCalc = lastTdiCalculation,
           Date().timeIntervalSince(lastCalc) < O5NudgeController.tdiRecalculationInterval {
            return
        }

        guard let dataSource = dataSource else { return }

        let windowStart = Date().addingTimeInterval(-14 * 86400)
        let doses = dataSource.recentDoseHistory(since: windowStart)

        let tdiResult = O5TdiCalculator.calculateTDI(
            from: doses.map { (startDate: $0.startDate, endDate: $0.endDate,
                               deliveredUnits: $0.deliveredUnits, isBasal: $0.isBasal) }
        )

        // Guard: never send TDI=0 to the pod — its AID algorithm divides by TDI.
        let safeTdiValue = max(O5TdiCalculator.minimumTdiUInt8, tdiResult.tdiValue)

        // Only send if TDI changed or first calculation
        if lastTdiSent == nil || lastTdiSent != safeTdiValue {
            if tdiResult.tdiValue == 0 {
                log.error("TDI calculator returned 0 — clamping to minimum %{public}dU to prevent pod division by zero",
                          O5TdiCalculator.minimumTdiUInt8)
            }

            log.default("Nudge TDI: sending TDI=%{public}dU (was %{public}@, sufficient=%{public}@)",
                        safeTdiValue,
                        lastTdiSent.map(String.init) ?? "nil",
                        String(tdiResult.isSufficientData))

            let binaryPayload = Data([0x00, 0x03, 0x00, safeTdiValue, 0x00])
            let (payload, prefix) = O5AidCommands.TdiCommand.payload(binaryData: binaryPayload)
            let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)

            lastTdiSent = safeTdiValue
        }

        lastTdiCalculation = Date()
    }

    // MARK: - Correction Factor Nudge

    private func nudgeCorrectionFactor(transport: BlePodMessageTransport) throws {
        if let lastSent = lastCorrectionFactorSent,
           Date().timeIntervalSince(lastSent) < O5NudgeController.correctionFactorUpdateInterval {
            return
        }

        guard let factors = dataSource?.currentCorrectionFactors(), !factors.isEmpty else { return }

        // Build binary correction factor profile (48 half-hour slots)
        var binaryData = Data()
        let slotCount: UInt16 = 48
        binaryData.appendBigEndian(UInt16(slotCount * 4))

        for slotIndex in 0..<48 {
            let slotStart = TimeInterval(slotIndex) * 1800.0
            var isfValue: Double = 50.0
            for factor in factors.reversed() {
                if factor.startTime <= slotStart {
                    isfValue = factor.isf
                    break
                }
            }
            binaryData.appendBigEndian(UInt32(isfValue))
        }

        let (payload, prefix) = O5AidCommands.CorrectionFactorProfileCommand.setGet(binaryData: binaryData)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
        lastCorrectionFactorSent = Date()

        log.default("Nudge CorrectionFactor: updated %d-slot profile", factors.count)
    }

    // MARK: - Activity Mode

    private func nudgeActivityMode(transport: BlePodMessageTransport) throws {
        guard let (active, duration, intensity) = dataSource?.isActivityModeRequested() else { return }

        let currentlyActive = lastAidStatus?.isActivityActive ?? false
        if active == currentlyActive { return }

        if active {
            let (payload, prefix) = O5AidCommands.ActivityModeCommand.setGet(duration: duration, intensity: intensity)
            let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            log.default("Nudge ActivityMode: ON duration=%d intensity=%d", duration, intensity)
        } else {
            let (payload, prefix) = O5AidCommands.ActivityModeCommand.setGet(duration: 0, intensity: 0)
            let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
            log.default("Nudge ActivityMode: OFF")
        }
    }

    // MARK: - Automated Limited Mode

    private func enterLimitedMode(transport: BlePodMessageTransport) throws {
        log.default("Entering Automated Limited Mode after %d missing EGV readings", missingEgvCount)

        let (payload, prefix) = O5AidCommands.BasalLimitedModeCommand.setGet(enabled: true)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)

        // Send special EGV to signal CGM loss
        try cgmPairingManager.sendSpecialEgv(O5SpecialEgv.cgmSignalLoss, transport: transport)

        delegate?.nudgeController(self, didEnterLimitedMode: "Missing \(missingEgvCount) consecutive EGV readings")
    }

    private func exitLimitedMode(transport: BlePodMessageTransport) throws {
        log.default("Exiting Automated Limited Mode — CGM data restored")

        let (payload, prefix) = O5AidCommands.BasalLimitedModeCommand.setGet(enabled: false)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
    }

    // MARK: - Full AID Status Read

    private func readFullAidStatus(transport: BlePodMessageTransport) throws -> O5AidStatus {
        // Try UnifiedAidPodStatus (G3.12) first, fall back to AidPodStatus (G3.11)
        let response: Data
        do {
            let (payload, prefix) = O5AidCommands.UnifiedAidPodStatusCommand.payload()
            response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
        } catch {
            log.default("UnifiedAidPodStatus failed, trying legacy AidPodStatus: %{public}@", String(describing: error))
            let (payload, prefix) = O5AidCommands.AidPodStatusCommand.payload()
            response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
        }

        return parseAidStatusResponse(response)
    }

    /// Parses the raw AID status response from the pod.
    /// Full field set from RE of SetAidPodStatusCommand:
    ///   egvValue, egvTimestamp, tdi, loopStatus, microUnitScaledIob,
    ///   utcTimestamp, aidActivated, isActivityActive, safeBasalMode,
    ///   egvRate, cgmAlgoState, cgmTxState, hypoProtect, limitedBasal,
    ///   qnReadiness, qnTryTimes, er48, algorithmPulses
    private func parseAidStatusResponse(_ data: Data) -> O5AidStatus {
        var status = O5AidStatus()

        guard data.count >= 20 else {
            log.error("AID status response too short: %{public}d bytes", data.count)
            return status
        }

        // Bytes 0-1: EGV value (UInt16 BE)
        let egv = Int(data[0]) << 8 | Int(data[1])
        if O5SpecialEgv.isSpecial(egv) {
            cgmPairingManager.updateCgmState(from: egv)
        } else if egv > 0 && egv < 600 {
            status.egvValue = egv
        }

        // Bytes 2-5: EGV timestamp (UInt32 BE, seconds since pod activation)
        if data.count >= 6 {
            let ts = UInt32(data[2]) << 24 | UInt32(data[3]) << 16 | UInt32(data[4]) << 8 | UInt32(data[5])
            status.podTimestamp = ts
        }

        // Bytes 6-7: TDI (UInt16 BE)
        let tdi = Int(data[6]) << 8 | Int(data[7])
        if tdi > 0 {
            status.tdi = tdi
        }

        // Byte 8: Loop status
        switch data[8] {
        case 0x01: status.loopStatus = .closedLoop
        case 0x02: status.loopStatus = .limitedMode
        case 0x03: status.loopStatus = .safeBasal
        case 0x00: status.loopStatus = .inactive
        default: status.loopStatus = .unknown
        }

        // Bytes 9-12: microUnitScaledIob (Int32 BE)
        if data.count >= 13 {
            let iob = Int(Int32(bigEndian: data[9...12].withUnsafeBytes { $0.load(as: Int32.self) }))
            status.microUnitScaledIob = iob
        }

        // Bytes 13-14: EGV rate (Int16 BE, mg/dL per 5 min)
        if data.count >= 15 {
            let rate = Int(Int16(bigEndian: data[13...14].withUnsafeBytes { $0.load(as: Int16.self) }))
            status.egvRate = rate
        }

        // Byte 15: CGM algorithm state
        if data.count >= 16 {
            status.cgmAlgoState = Int(data[15])
        }

        // Byte 16: CGM transmitter state
        if data.count >= 17 {
            status.cgmTxState = Int(data[16])
        }

        // Byte 17: flags
        if data.count >= 18 {
            let flags = data[17]
            status.aidActivated = (flags & 0x01) != 0
            status.isActivityActive = (flags & 0x02) != 0
            status.safeBasalMode = (flags & 0x04) != 0
            status.hypoProtectActive = (flags & 0x08) != 0
            status.limitedBasalMode = (flags & 0x10) != 0
        }

        // Bytes 18-19: algorithm pulses (UInt16 BE)
        if data.count >= 20 {
            status.algorithmPulses = Int(data[18]) << 8 | Int(data[19])
        }

        // Bytes 20-21: QN readiness + try times (if available)
        if data.count >= 22 {
            status.qnReadiness = Int(data[20])
            status.qnTryTimes = Int(data[21])
        }

        // Bytes 22-23: ER48 readiness + activity duration
        if data.count >= 24 {
            status.er48Ready = Int(data[22])
            status.activityDuration = Int(data[23]) * 5 // stored as 5-min blocks
        }

        // Bytes 24-25: Activity intensity + transmitter lifetime
        if data.count >= 26 {
            status.activityIntensity = Int(data[24])
            status.transmitterLifetime = Int(data[25])
        }

        return status
    }

    // MARK: - Loop State Control

    /// Sets the pod's AID loop state (closed loop, limited, safe basal, inactive).
    func setLoopState(_ state: O5LoopStateValue, transport: BlePodMessageTransport) throws {
        let (payload, prefix) = O5AidCommands.AidLoopStateCommand.set(state: state)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
        lastLoopStateSent = state
        log.default("Set loop state: %d", state.rawValue)
    }

    /// Reads the current loop state from the pod.
    func getLoopState(transport: BlePodMessageTransport) throws -> O5LoopStateValue {
        let (payload, prefix) = O5AidCommands.AidLoopStateCommand.get()
        let response = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
        guard response.count >= 1 else { return .inactive }
        return O5LoopStateValue(rawValue: Int(response[0])) ?? .inactive
    }

    // MARK: - Target BG Update

    func sendTargetBgUpdate(transport: BlePodMessageTransport) throws {
        guard let targets = dataSource?.currentGlucoseTargets(), !targets.isEmpty else {
            return
        }

        let profile = O5TherapyConfig.buildTargetProfile(
            from: targets.map { (startTime: $0.startTime, targetMgdl: $0.targetMgdl) }
        )

        log.default("Nudge TargetBG: updating %{public}d-slot profile", profile.count)

        let (payload, prefix) = O5AidCommands.TargetBgProfileCommand.payload(targets: profile)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
    }

    // MARK: - Hypo Protection

    func setHypoProtection(enabled: Bool, transport: BlePodMessageTransport) throws {
        var data = Data()
        data.append(enabled ? 0x01 : 0x00)
        let (payload, prefix) = O5AidCommands.HypoProtectionCommand.setGet(binaryData: data)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
        log.default("Set hypo protection: %{public}@", String(enabled))
    }

    // MARK: - Patient History

    func readPatientHistoryLog(transport: BlePodMessageTransport) throws -> Data {
        let (payload, prefix) = O5AidCommands.PatientHistoryLogCommand.get()
        return try transport.sendO5AidCommand(payload, responsePrefix: prefix)
    }

    func enablePatientHistoryLogging(_ enabled: Bool, transport: BlePodMessageTransport) throws {
        let (payload, prefix) = O5AidCommands.PatientHistoryLogEnabledCommand.setGet(enabled: enabled)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
    }

    // MARK: - Pod-Initiated Nudge Handling

    /// Processes a pod-initiated nudge message received during a BLE session.
    /// The pod sends these asynchronously: periodic status, alarms, and alerts.
    func handlePodNudge(data: Data, transport: BlePodMessageTransport) {
        guard data.count >= 2 else { return }

        let nudgeType = data[0]
        let nudgePayload = data.subdata(in: 1..<data.count)

        switch nudgeType {
        case 0x01: // Periodic nudge
            let status = parseAidStatusResponse(nudgePayload)
            self.lastAidStatus = status
            delegate?.nudgeController(self, didUpdateAidStatus: status)

        case 0x02: // Alarm nudge
            let status = parseAidStatusResponse(nudgePayload)
            self.lastAidStatus = status
            let alarmCode = nudgePayload.count > 0 ? nudgePayload[0] : 0
            delegate?.nudgeController(self, didReceiveAlarm: alarmCode, podStatus: status)

        case 0x03: // Alert nudge
            let status = parseAidStatusResponse(nudgePayload)
            self.lastAidStatus = status
            let alertRaw = nudgePayload.count >= 2 ? UInt16(nudgePayload[0]) << 8 | UInt16(nudgePayload[1]) : 0
            let alertMask = O5AlertMask(rawValue: alertRaw)
            delegate?.nudgeController(self, didReceiveAlert: alertMask, podStatus: status)

        default:
            log.default("Unknown nudge type: 0x%02X (%d bytes)", nudgeType, nudgePayload.count)
        }
    }
}
