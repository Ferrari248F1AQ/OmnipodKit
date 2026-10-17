//
//  O5NudgeControllerTests.swift
//  OmniTests
//

import XCTest
@testable import OmnipodKit

// MARK: - Mock Data Source

class MockO5NudgeDataSource: O5NudgeDataSource {

    var glucoseValue: (mgdl: Int, date: Date)?
    var glucoseHistory: [(mgdl: Int, date: Date)] = []
    var doseHistory: [(startDate: Date, endDate: Date, deliveredUnits: Double, isBasal: Bool)] = []
    var glucoseTargets: [(startTime: TimeInterval, targetMgdl: Double)]?
    var correctionFactors: [(startTime: TimeInterval, isf: Double)]?
    var activityMode: (active: Bool, duration: Int, intensity: Int)?
    var sensorConfig: O5CgmSensorConfig?

    func latestGlucose() -> (mgdl: Int, date: Date)? {
        return glucoseValue
    }

    func recentGlucoseHistory(minutes: Int) -> [(mgdl: Int, date: Date)] {
        return glucoseHistory
    }

    func recentDoseHistory(since: Date) -> [(startDate: Date, endDate: Date, deliveredUnits: Double, isBasal: Bool)] {
        return doseHistory
    }

    func currentGlucoseTargets() -> [(startTime: TimeInterval, targetMgdl: Double)]? {
        return glucoseTargets
    }

    func currentCorrectionFactors() -> [(startTime: TimeInterval, isf: Double)]? {
        return correctionFactors
    }

    func isActivityModeRequested() -> (active: Bool, duration: Int, intensity: Int)? {
        return activityMode
    }

    func cgmSensorConfig() -> O5CgmSensorConfig? {
        return sensorConfig
    }
}

// MARK: - Mock Delegate

class MockO5NudgeDelegate: O5NudgeDelegate {

    var receivedAlarms: [(alarmCode: UInt8, podStatus: O5AidStatus)] = []
    var receivedAlerts: [(alertMask: O5AlertMask, podStatus: O5AidStatus)] = []
    var receivedStatusUpdates: [O5AidStatus] = []
    var limitedModeEntries: [String] = []

    func nudgeController(_ controller: O5NudgeController, didReceiveAlarm alarmCode: UInt8, podStatus: O5AidStatus) {
        receivedAlarms.append((alarmCode, podStatus))
    }

    func nudgeController(_ controller: O5NudgeController, didReceiveAlert alertMask: O5AlertMask, podStatus: O5AidStatus) {
        receivedAlerts.append((alertMask, podStatus))
    }

    func nudgeController(_ controller: O5NudgeController, didUpdateAidStatus status: O5AidStatus) {
        receivedStatusUpdates.append(status)
    }

    func nudgeController(_ controller: O5NudgeController, didEnterLimitedMode reason: String) {
        limitedModeEntries.append(reason)
    }
}

// MARK: - Tests

class O5NudgeControllerTests: XCTestCase {

    var controller: O5NudgeController!
    var dataSource: MockO5NudgeDataSource!
    var delegate: MockO5NudgeDelegate!

    override func setUp() {
        super.setUp()
        dataSource = MockO5NudgeDataSource()
        delegate = MockO5NudgeDelegate()
        controller = O5NudgeController(dataSource: dataSource)
        controller.delegate = delegate
    }

    override func tearDown() {
        controller = nil
        dataSource = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - Constants

    func testLimitedModeThresholdIs4() {
        // Official OP5: Limited Mode after 20 min, nudge cycle ~5 min → 4 cycles
        XCTAssertEqual(O5NudgeController.missingEgvLimitedModeThreshold, 4)
    }

    func testCgmNudgeInterval() {
        XCTAssertEqual(O5NudgeController.cgmNudgeInterval, 270)
    }

    func testTdiRecalculationInterval() {
        XCTAssertEqual(O5NudgeController.tdiRecalculationInterval, 3600)
    }

    func testCorrectionFactorUpdateInterval() {
        XCTAssertEqual(O5NudgeController.correctionFactorUpdateInterval, 3600)
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertFalse(controller.isCgmSensorRegistered)
        XCTAssertNil(controller.registeredSensorType)
        XCTAssertEqual(controller.missingEgvCount, 0)
        XCTAssertNil(controller.lastEgvSent)
        XCTAssertNil(controller.lastEgvSentDate)
        XCTAssertNil(controller.lastTdiSent)
        XCTAssertNil(controller.lastTdiCalculation)
        XCTAssertNil(controller.lastAidStatus)
        XCTAssertNil(controller.lastLoopStateSent)
        XCTAssertNil(controller.lastCorrectionFactorSent)
    }

    // MARK: - CGM Registration Guards

    func testResetCgmRegistration() {
        controller.isCgmSensorRegistered = true
        controller.registeredSensorType = .dexcomG6

        controller.resetCgmRegistration()

        XCTAssertFalse(controller.isCgmSensorRegistered)
        XCTAssertNil(controller.registeredSensorType)
    }

    func testCgmRegistrationFlagsSetDuringSetup() {
        controller.isCgmSensorRegistered = true
        controller.registeredSensorType = .dexcomG7

        XCTAssertTrue(controller.isCgmSensorRegistered)
        XCTAssertEqual(controller.registeredSensorType, .dexcomG7)
    }

    func testResetCgmRegistrationClearsAll() {
        controller.isCgmSensorRegistered = true
        controller.registeredSensorType = .dexcomG6

        controller.resetCgmRegistration()

        XCTAssertFalse(controller.isCgmSensorRegistered)
        XCTAssertNil(controller.registeredSensorType)

        // Can register a different model after reset (new pod)
        controller.isCgmSensorRegistered = true
        controller.registeredSensorType = .dexcomG7
        XCTAssertEqual(controller.registeredSensorType, .dexcomG7)
    }

    // MARK: - CgmNudgeResult Enum

    func testCgmNudgeResultEnumCases() {
        let sent = O5NudgeController.CgmNudgeResult.sent
        let skip = O5NudgeController.CgmNudgeResult.timingSkip
        let noData = O5NudgeController.CgmNudgeResult.noData

        // Verify the three cases are distinct (compile-time check basically)
        switch sent {
        case .sent: break
        case .timingSkip: XCTFail("Should be .sent")
        case .noData: XCTFail("Should be .sent")
        }

        switch skip {
        case .timingSkip: break
        case .sent: XCTFail("Should be .timingSkip")
        case .noData: XCTFail("Should be .timingSkip")
        }

        switch noData {
        case .noData: break
        case .sent: XCTFail("Should be .noData")
        case .timingSkip: XCTFail("Should be .noData")
        }
    }

    // MARK: - AID Status Parsing

    func testParseAidStatusMinimum20Bytes() {
        let controller = O5NudgeController()

        // 20-byte response: EGV=120, timestamp=1000, TDI=45, loopStatus=closedLoop,
        // IOB=500000 microunits (0.5U), rate=+3, cgmAlgo=5, cgmTx=2, flags=0x01 (aidActivated),
        // pulses=10
        var data = Data()
        data.append(contentsOf: [0x00, 0x78])       // EGV = 120
        data.append(contentsOf: [0x00, 0x00, 0x03, 0xE8]) // timestamp = 1000
        data.append(contentsOf: [0x00, 0x2D])       // TDI = 45
        data.append(0x01)                             // loopStatus = closedLoop
        let iob: Int32 = 500_000
        withUnsafeBytes(of: iob.bigEndian) { data.append(contentsOf: $0) }
        let rate: Int16 = 3
        withUnsafeBytes(of: rate.bigEndian) { data.append(contentsOf: $0) }
        data.append(5)    // cgmAlgoState
        data.append(2)    // cgmTxState
        data.append(0x01) // flags: aidActivated=1
        data.append(contentsOf: [0x00, 0x0A]) // algorithmPulses = 10

        let status = controller.parseAidStatusResponse(data)

        XCTAssertEqual(status.egvValue, 120)
        XCTAssertEqual(status.podTimestamp, 1000)
        XCTAssertEqual(status.tdi, 45)
        XCTAssertEqual(status.loopStatus, .closedLoop)
        XCTAssertEqual(status.microUnitScaledIob, 500_000)
        XCTAssertEqual(status.iobUnits, 0.5, accuracy: 0.001)
        XCTAssertEqual(status.egvRate, 3)
        XCTAssertEqual(status.cgmAlgoState, 5)
        XCTAssertEqual(status.cgmTxState, 2)
        XCTAssertTrue(status.aidActivated)
        XCTAssertFalse(status.isActivityActive)
        XCTAssertFalse(status.safeBasalMode)
        XCTAssertFalse(status.limitedBasalMode)
        XCTAssertFalse(status.hypoProtectActive)
        XCTAssertEqual(status.algorithmPulses, 10)
    }

    func testParseAidStatusTooShort() {
        let controller = O5NudgeController()
        let data = Data(repeating: 0, count: 10)

        let status = controller.parseAidStatusResponse(data)
        XCTAssertNil(status.egvValue)
        XCTAssertEqual(status.loopStatus, .unknown)
    }

    func testParseAidStatusLoopStates() {
        let controller = O5NudgeController()

        func makeResponse(loopByte: UInt8) -> Data {
            var data = Data(repeating: 0, count: 20)
            data[0] = 0x00; data[1] = 0x64 // EGV = 100
            data[6] = 0x00; data[7] = 0x1E // TDI = 30
            data[8] = loopByte
            return data
        }

        XCTAssertEqual(controller.parseAidStatusResponse(makeResponse(loopByte: 0x00)).loopStatus, .inactive)
        XCTAssertEqual(controller.parseAidStatusResponse(makeResponse(loopByte: 0x01)).loopStatus, .closedLoop)
        XCTAssertEqual(controller.parseAidStatusResponse(makeResponse(loopByte: 0x02)).loopStatus, .limitedMode)
        XCTAssertEqual(controller.parseAidStatusResponse(makeResponse(loopByte: 0x03)).loopStatus, .safeBasal)
        XCTAssertEqual(controller.parseAidStatusResponse(makeResponse(loopByte: 0xFF)).loopStatus, .unknown)
    }

    func testParseAidStatusFlags() {
        let controller = O5NudgeController()

        var data = Data(repeating: 0, count: 20)
        data[0] = 0x00; data[1] = 0x64 // EGV = 100
        data[6] = 0x00; data[7] = 0x1E // TDI = 30
        // flags byte 17: all flags set (0x1F)
        data[17] = 0x1F

        let status = controller.parseAidStatusResponse(data)
        XCTAssertTrue(status.aidActivated)
        XCTAssertTrue(status.isActivityActive)
        XCTAssertTrue(status.safeBasalMode)
        XCTAssertTrue(status.hypoProtectActive)
        XCTAssertTrue(status.limitedBasalMode)
    }

    func testParseAidStatusNegativeIob() {
        let controller = O5NudgeController()

        var data = Data(repeating: 0, count: 20)
        data[0] = 0x00; data[1] = 0x64
        data[6] = 0x00; data[7] = 0x1E
        // Negative IOB = -200000 micro-units
        let iob: Int32 = -200_000
        withUnsafeBytes(of: iob.bigEndian) { ptr in
            data[9] = ptr[0]; data[10] = ptr[1]; data[11] = ptr[2]; data[12] = ptr[3]
        }

        let status = controller.parseAidStatusResponse(data)
        XCTAssertEqual(status.microUnitScaledIob, -200_000)
        XCTAssertEqual(status.iobUnits!, -0.2, accuracy: 0.001)
    }

    func testParseAidStatusNegativeEgvRate() {
        let controller = O5NudgeController()

        var data = Data(repeating: 0, count: 20)
        data[0] = 0x00; data[1] = 0x96 // EGV = 150
        data[6] = 0x00; data[7] = 0x28 // TDI = 40
        // Negative rate = -5 mg/dL per 5 min
        let rate: Int16 = -5
        withUnsafeBytes(of: rate.bigEndian) { ptr in
            data[13] = ptr[0]; data[14] = ptr[1]
        }

        let status = controller.parseAidStatusResponse(data)
        XCTAssertEqual(status.egvRate, -5)
    }

    func testParseAidStatusSpecialEgvIgnored() {
        let controller = O5NudgeController()

        // Special EGV values (negative encoded as UInt16) should not set egvValue
        var data = Data(repeating: 0, count: 20)
        data[0] = 0xFF; data[1] = 0xFF // -1 as UInt16 = cgmPairing special
        data[6] = 0x00; data[7] = 0x1E

        let status = controller.parseAidStatusResponse(data)
        XCTAssertNil(status.egvValue)
    }

    func testParseAidStatusZeroEgvIgnored() {
        let controller = O5NudgeController()

        var data = Data(repeating: 0, count: 20)
        // EGV = 0 should not be set
        data[6] = 0x00; data[7] = 0x1E

        let status = controller.parseAidStatusResponse(data)
        XCTAssertNil(status.egvValue)
    }

    func testParseAidStatusEgvOutOfRange() {
        let controller = O5NudgeController()

        var data = Data(repeating: 0, count: 20)
        data[0] = 0x02; data[1] = 0x58 // EGV = 600 — out of valid range
        data[6] = 0x00; data[7] = 0x1E

        let status = controller.parseAidStatusResponse(data)
        XCTAssertNil(status.egvValue)
    }

    func testParseAidStatusExtendedFields() {
        let controller = O5NudgeController()

        // 26-byte response includes QN + ER48 + activity fields
        var data = Data(repeating: 0, count: 26)
        data[0] = 0x00; data[1] = 0x64 // EGV = 100
        data[6] = 0x00; data[7] = 0x1E // TDI = 30
        data[20] = 0x03 // qnReadiness
        data[21] = 0x02 // qnTryTimes
        data[22] = 0x01 // er48Ready
        data[23] = 0x06 // activityDuration (6 * 5 = 30 min)
        data[24] = 0x02 // activityIntensity
        data[25] = 0x5A // transmitterLifetime = 90

        let status = controller.parseAidStatusResponse(data)
        XCTAssertEqual(status.qnReadiness, 3)
        XCTAssertEqual(status.qnTryTimes, 2)
        XCTAssertEqual(status.er48Ready, 1)
        XCTAssertEqual(status.activityDuration, 30) // 6 blocks * 5 min
        XCTAssertEqual(status.activityIntensity, 2)
        XCTAssertEqual(status.transmitterLifetime, 90)
    }

    // MARK: - IOB Conversion

    func testIobUnitsConversion() {
        var status = O5AidStatus()

        status.microUnitScaledIob = 1_000_000
        XCTAssertEqual(status.iobUnits, 1.0, accuracy: 0.001)

        status.microUnitScaledIob = 0
        XCTAssertEqual(status.iobUnits, 0.0, accuracy: 0.001)

        status.microUnitScaledIob = 1_500_000
        XCTAssertEqual(status.iobUnits, 1.5, accuracy: 0.001)

        status.microUnitScaledIob = nil
        XCTAssertNil(status.iobUnits)
    }

    // MARK: - O5AlgorithmMode

    func testAlgorithmModeProperties() {
        XCTAssertTrue(O5AlgorithmMode.loopAlgorithm.loopControlsDosing)
        XCTAssertFalse(O5AlgorithmMode.loopAlgorithm.podAidActive)

        XCTAssertFalse(O5AlgorithmMode.insuletAID.loopControlsDosing)
        XCTAssertTrue(O5AlgorithmMode.insuletAID.podAidActive)
    }

    // MARK: - O5LoopStatus

    func testLoopStatusDisplayNames() {
        XCTAssertEqual(O5LoopStatus.closedLoop.displayName, "Closed Loop")
        XCTAssertEqual(O5LoopStatus.limitedMode.displayName, "Limited Mode")
        XCTAssertEqual(O5LoopStatus.safeBasal.displayName, "Safe Basal")
        XCTAssertEqual(O5LoopStatus.inactive.displayName, "Inactive")
    }

    // MARK: - O5CgmType

    func testCgmTypeDisplayNames() {
        XCTAssertEqual(O5CgmType.dexcomG6.displayName, "Dexcom G6")
        XCTAssertEqual(O5CgmType.dexcomG7.displayName, "Dexcom G7")
        XCTAssertEqual(O5CgmType.libre2.displayName, "Libre 2")
        XCTAssertEqual(O5CgmType.libre3.displayName, "Libre 3")
        XCTAssertEqual(O5CgmType.none.displayName, "None")
    }

    func testCgmTypeRawValues() {
        XCTAssertEqual(O5CgmType.dexcomG6.rawValue, "g6")
        XCTAssertEqual(O5CgmType.dexcomG7.rawValue, "g7")
        XCTAssertEqual(O5CgmType.libre2.rawValue, "libre2")
    }

    // MARK: - O5CgmSensorConfig

    func testSensorConfigDefaults() {
        let config = O5CgmSensorConfig(sensorType: .dexcomG6)
        XCTAssertEqual(config.sensorType, .dexcomG6)
        XCTAssertNil(config.transmitterId)
        XCTAssertEqual(config.operatingIntervalSeconds, 300)
        XCTAssertEqual(config.warmupDurationSeconds, 7200)
        XCTAssertEqual(config.wearDurationSeconds, 907200)
        XCTAssertEqual(config.bleAddressType, 0)
    }

    func testSensorConfigWithTransmitter() {
        var config = O5CgmSensorConfig(sensorType: .dexcomG6)
        config.transmitterId = "8G1234"

        XCTAssertEqual(config.sensorType, .dexcomG6)
        XCTAssertEqual(config.transmitterId, "8G1234")
    }

    func testSensorConfigCodable() throws {
        var config = O5CgmSensorConfig(sensorType: .dexcomG7)
        config.transmitterId = "ABC123DEF"
        config.pairingCode = "1234"

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(O5CgmSensorConfig.self, from: encoded)

        XCTAssertEqual(decoded.sensorType, .dexcomG7)
        XCTAssertEqual(decoded.transmitterId, "ABC123DEF")
        XCTAssertEqual(decoded.pairingCode, "1234")
    }

    // MARK: - CGM Registration State Machine

    func testRegistrationStateAfterSetup_G6() {
        controller.isCgmSensorRegistered = true
        controller.registeredSensorType = .dexcomG6

        // Same-model transmitter change should be allowed (state allows it)
        XCTAssertTrue(controller.isCgmSensorRegistered)
        XCTAssertEqual(controller.registeredSensorType, .dexcomG6)
    }

    func testRegistrationStateAfterSetup_G7() {
        controller.isCgmSensorRegistered = true
        controller.registeredSensorType = .dexcomG7

        XCTAssertTrue(controller.isCgmSensorRegistered)
        XCTAssertEqual(controller.registeredSensorType, .dexcomG7)
    }

    func testResetBetweenPods() {
        // Simulate G6 pod
        controller.isCgmSensorRegistered = true
        controller.registeredSensorType = .dexcomG6

        // Pod deactivated
        controller.resetCgmRegistration()
        XCTAssertFalse(controller.isCgmSensorRegistered)
        XCTAssertNil(controller.registeredSensorType)

        // New pod can use G7
        controller.isCgmSensorRegistered = true
        controller.registeredSensorType = .dexcomG7
        XCTAssertEqual(controller.registeredSensorType, .dexcomG7)
    }

    // MARK: - O5LoopStateValue

    func testLoopStateValues() {
        XCTAssertEqual(O5LoopStateValue.inactive.rawValue, 0)
        XCTAssertEqual(O5LoopStateValue.closedLoop.rawValue, 1)
        XCTAssertEqual(O5LoopStateValue.limitedMode.rawValue, 2)
        XCTAssertEqual(O5LoopStateValue.safeBasal.rawValue, 3)
    }

    // MARK: - Data Source Mock Behavior

    func testDataSourceReturnsNilGlucose() {
        dataSource.glucoseValue = nil
        XCTAssertNil(dataSource.latestGlucose())
    }

    func testDataSourceReturnsGlucose() {
        let now = Date()
        dataSource.glucoseValue = (mgdl: 120, date: now)
        let result = dataSource.latestGlucose()
        XCTAssertEqual(result?.mgdl, 120)
        XCTAssertEqual(result?.date, now)
    }

    func testDataSourceReturnsSensorConfig() {
        var config = O5CgmSensorConfig(sensorType: .dexcomG6)
        config.transmitterId = "8G1234"
        dataSource.sensorConfig = config

        let result = dataSource.cgmSensorConfig()
        XCTAssertEqual(result?.sensorType, .dexcomG6)
        XCTAssertEqual(result?.transmitterId, "8G1234")
    }

    func testDataSourceReturnsNilSensorConfig() {
        dataSource.sensorConfig = nil
        XCTAssertNil(dataSource.cgmSensorConfig())
    }

    // MARK: - Delegate Captures

    func testDelegateLimitedModeEntry() {
        delegate.limitedModeEntries = []
        XCTAssertEqual(delegate.limitedModeEntries.count, 0)

        // Simulate delegate call
        delegate.nudgeController(controller, didEnterLimitedMode: "Missing 4 consecutive EGV readings")
        XCTAssertEqual(delegate.limitedModeEntries.count, 1)
        XCTAssertTrue(delegate.limitedModeEntries[0].contains("4"))
    }

    func testDelegateStatusUpdate() {
        var status = O5AidStatus()
        status.egvValue = 150
        status.loopStatus = .closedLoop
        status.aidActivated = true

        delegate.nudgeController(controller, didUpdateAidStatus: status)
        XCTAssertEqual(delegate.receivedStatusUpdates.count, 1)
        XCTAssertEqual(delegate.receivedStatusUpdates[0].egvValue, 150)
        XCTAssertEqual(delegate.receivedStatusUpdates[0].loopStatus, .closedLoop)
    }

    // MARK: - AID Status Codable

    func testAidStatusCodable() throws {
        var status = O5AidStatus()
        status.egvValue = 120
        status.tdi = 45
        status.loopStatus = .closedLoop
        status.aidActivated = true
        status.microUnitScaledIob = 1_500_000
        status.algorithmPulses = 20

        let encoded = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(O5AidStatus.self, from: encoded)

        XCTAssertEqual(decoded.egvValue, 120)
        XCTAssertEqual(decoded.tdi, 45)
        XCTAssertEqual(decoded.loopStatus, .closedLoop)
        XCTAssertTrue(decoded.aidActivated)
        XCTAssertEqual(decoded.microUnitScaledIob, 1_500_000)
        XCTAssertEqual(decoded.iobUnits, 1.5, accuracy: 0.001)
        XCTAssertEqual(decoded.algorithmPulses, 20)
    }

    func testAidStatusEquatable() {
        var a = O5AidStatus()
        var b = O5AidStatus()
        XCTAssertEqual(a, b)

        a.egvValue = 120
        XCTAssertNotEqual(a, b)

        b.egvValue = 120
        XCTAssertEqual(a, b)
    }

    // MARK: - Edge Cases

    func testParseAidStatusEmptyData() {
        let controller = O5NudgeController()
        let status = controller.parseAidStatusResponse(Data())
        XCTAssertNil(status.egvValue)
        XCTAssertNil(status.tdi)
        XCTAssertEqual(status.loopStatus, .unknown)
        XCTAssertFalse(status.aidActivated)
    }

    func testParseAidStatusExactly20Bytes() {
        let controller = O5NudgeController()
        var data = Data(repeating: 0, count: 20)
        data[0] = 0x01; data[1] = 0x00 // EGV = 256
        data[6] = 0x00; data[7] = 0x20 // TDI = 32
        data[8] = 0x01 // closedLoop

        let status = controller.parseAidStatusResponse(data)
        XCTAssertEqual(status.egvValue, 256)
        XCTAssertEqual(status.tdi, 32)
        XCTAssertEqual(status.loopStatus, .closedLoop)
        XCTAssertNil(status.qnReadiness)
        XCTAssertNil(status.activityDuration)
    }

    func testParseAidStatusZeroTdiIgnored() {
        let controller = O5NudgeController()
        var data = Data(repeating: 0, count: 20)
        data[0] = 0x00; data[1] = 0x64
        // TDI = 0 should not be set
        data[6] = 0x00; data[7] = 0x00

        let status = controller.parseAidStatusResponse(data)
        XCTAssertNil(status.tdi)
    }

    func testParseAidStatusLargeAlgorithmPulses() {
        let controller = O5NudgeController()
        var data = Data(repeating: 0, count: 20)
        data[0] = 0x00; data[1] = 0x64
        data[6] = 0x00; data[7] = 0x1E
        data[18] = 0xFF; data[19] = 0xFF // 65535 pulses

        let status = controller.parseAidStatusResponse(data)
        XCTAssertEqual(status.algorithmPulses, 65535)
    }
}
