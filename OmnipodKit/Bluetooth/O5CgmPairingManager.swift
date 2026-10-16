//
//  O5CgmPairingManager.swift
//  OmnipodKit
//
//  Manages CGM sensor registration with the Omnipod 5 pod.
//
//  The O5 pod does NOT connect directly to the Dexcom/Libre sensor.
//  The phone acts as a BLE relay: it reads CGM data from the sensor
//  and forwards EGV values to the pod via nudge commands.
//
//  During pod setup, the app sends CGM identification data to the pod
//  so it can validate incoming CGM data (crosscheck):
//    - Transmitter ID (TXID)
//    - Sensor BLE address
//    - G7: pairing code + serial number
//    - Sensor certificates (for authentication)
//

import Foundation
import os.log

// MARK: - CGM Sensor Configuration

/// Complete CGM sensor configuration to register with the O5 pod.
struct O5CgmSensorConfig: Codable {

    /// The type of CGM sensor.
    var sensorType: O5CgmType

    /// Transmitter ID string (e.g., "8G1234" for G6, longer for G7).
    var transmitterId: String?

    /// Sensor BLE address (6 bytes).
    var bleAddress: Data?

    /// BLE address type (public=0, random=1).
    var bleAddressType: UInt8 = 0

    /// G7 pairing code (4 digits).
    var pairingCode: String?

    /// G7 serial number.
    var serialNumber: String?

    /// Operating interval in seconds (G7 default: 300 = 5 min).
    var operatingIntervalSeconds: UInt32 = 300

    /// Advertisement reference time (G7 BLE timing).
    var advertisementReferenceTime: UInt64?

    /// Transmitter lifetime remaining in days.
    var transmitterLifetimeDays: UInt16?

    /// Sensor activation timestamp.
    var sensorActivationTime: Date?

    /// Sensor expiration timestamp.
    var sensorExpirationTime: Date?

    /// Sensor warmup duration in seconds.
    var warmupDurationSeconds: UInt32 = 7200  // 2 hours default

    /// Sensor wear duration in seconds (G7: 10.5 days = 907200).
    var wearDurationSeconds: UInt32 = 907200

    /// Sensor UID (unique identifier bytes).
    var sensorUid: Data?

    /// Sensor app certificate data (for pod-side authentication).
    var appCertificateData: Data?

    /// Sensor app private key (for pod-side authentication).
    var appPrivateKey: Data?

    /// Sensor patch public signing key.
    var patchPublicSigningKey: Data?

    /// Driver version string.
    var driverVersion: String?
}

// MARK: - CGM Pairing Manager

class O5CgmPairingManager {

    private let log = OSLog(category: "O5CgmPairingManager")

    /// Current CGM state on the pod.
    private(set) var cgmState: O5CgmState = .none

    /// Active sensor configuration.
    private(set) var activeSensorConfig: O5CgmSensorConfig?

    // MARK: - Full CGM Registration Sequence

    /// Registers a CGM sensor with the O5 pod during activation.
    /// This sends all necessary identification data so the pod can validate
    /// CGM data received via the phone relay.
    ///
    /// Sequence:
    /// 1. Set CGM interface manager (enable CGM subsystem)
    /// 2. Send transmitter info (TXID)
    /// 3. Send sensor-specific information (G6/G7/Libre)
    /// 4. Send CGM pairing information (certificates, keys)
    func registerSensor(
        config: O5CgmSensorConfig,
        transport: BlePodMessageTransport
    ) throws {

        self.activeSensorConfig = config

        log.default("Registering %{public}@ sensor with pod", config.sensorType.displayName)

        // Step 1: Enable CGM interface
        try enableCgmInterface(transport: transport, sensorType: config.sensorType)

        // Step 2: Send transmitter ID
        if let txId = config.transmitterId {
            try sendTransmitterId(txId, transport: transport)
        }

        // Step 3: Send sensor-specific data
        switch config.sensorType {
        case .dexcomG6:
            try sendG6SensorInfo(config: config, transport: transport)
        case .dexcomG7:
            try sendG7SensorInfo(config: config, transport: transport)
        case .libre2:
            try sendLibre2SensorInfo(config: config, transport: transport)
        case .libre3:
            try sendLibre3SensorInfo(config: config, transport: transport)
        case .none:
            break
        }

        // Step 4: Send pairing/certificate data
        if config.appCertificateData != nil || config.appPrivateKey != nil {
            try sendCgmPairingInfo(config: config, transport: transport)
        }

        cgmState = .pairing
        log.default("CGM sensor registration complete, state -> pairing")
    }

    // MARK: - CGM Interface

    private func enableCgmInterface(transport: BlePodMessageTransport, sensorType: O5CgmType) throws {
        var data = Data()
        let typeCode: UInt8
        switch sensorType {
        case .dexcomG6: typeCode = 0x01
        case .dexcomG7: typeCode = 0x02
        case .libre2: typeCode = 0x03
        case .libre3: typeCode = 0x04
        case .none: typeCode = 0x00
        }
        data.append(typeCode)
        data.append(0x01) // enabled

        let (payload, prefix) = O5AidCommands.CgmInterfaceManagerCommand.setGet(binaryData: data)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
    }

    // MARK: - Transmitter ID

    private func sendTransmitterId(_ txId: String, transport: BlePodMessageTransport) throws {
        guard let txIdData = txId.data(using: .utf8) else { return }

        var data = Data()
        data.appendBigEndian(UInt16(txIdData.count))
        data.append(txIdData)

        let (payload, prefix) = O5AidCommands.TransmitterInfoCommand.set(binaryData: data)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)

        log.default("Sent TXID: %{public}@ (%d bytes)", txId, txIdData.count)
    }

    // MARK: - G6 Sensor Info

    private func sendG6SensorInfo(config: O5CgmSensorConfig, transport: BlePodMessageTransport) throws {
        var data = Data()

        // BLE address (6 bytes)
        if let bleAddr = config.bleAddress {
            data.append(bleAddr)
        } else {
            data.append(Data(count: 6))
        }

        // BLE address type
        data.append(config.bleAddressType)

        // Sensor activation time (UInt32 unix timestamp)
        let activationTs = UInt32(config.sensorActivationTime?.timeIntervalSince1970 ?? 0)
        data.appendBigEndian(activationTs)

        // Sensor expiration time
        let expirationTs = UInt32(config.sensorExpirationTime?.timeIntervalSince1970 ?? 0)
        data.appendBigEndian(expirationTs)

        // Transmitter lifetime days
        data.appendBigEndian(config.transmitterLifetimeDays ?? 0)

        let (payload, prefix) = O5AidCommands.G6SensorInformationCommand.set(binaryData: data)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
    }

    // MARK: - G7 Sensor Info

    private func sendG7SensorInfo(config: O5CgmSensorConfig, transport: BlePodMessageTransport) throws {
        var data = Data()

        // Pairing code (4 bytes ASCII, padded)
        let pairCodeBytes = (config.pairingCode ?? "0000").data(using: .utf8) ?? Data(count: 4)
        data.append(pairCodeBytes.prefix(8))
        if pairCodeBytes.count < 8 { data.append(Data(count: 8 - pairCodeBytes.count)) }

        // Serial number (variable length, length-prefixed)
        let serialBytes = (config.serialNumber ?? "").data(using: .utf8) ?? Data()
        data.appendBigEndian(UInt16(serialBytes.count))
        data.append(serialBytes)

        // Operating interval in seconds
        data.appendBigEndian(config.operatingIntervalSeconds)

        // BLE address (6 bytes)
        if let bleAddr = config.bleAddress {
            data.append(bleAddr.prefix(6))
            if bleAddr.count < 6 { data.append(Data(count: 6 - bleAddr.count)) }
        } else {
            data.append(Data(count: 6))
        }

        // BLE address type
        data.append(config.bleAddressType)

        // Advertisement reference time (UInt64)
        data.appendBigEndian(config.advertisementReferenceTime ?? 0)

        // Transmitter lifetime in days
        data.appendBigEndian(config.transmitterLifetimeDays ?? 0)

        // Driver version (length-prefixed string)
        let driverBytes = (config.driverVersion ?? "1.0").data(using: .utf8) ?? Data()
        data.appendBigEndian(UInt16(driverBytes.count))
        data.append(driverBytes)

        let (payload, prefix) = O5AidCommands.G7SensorInformationCommand.set(binaryData: data)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)

        log.default("Sent G7 sensor info: pairCode=%{public}@, serial=%{public}@",
                    config.pairingCode ?? "nil", config.serialNumber ?? "nil")
    }

    // MARK: - Libre 2 Sensor Info

    private func sendLibre2SensorInfo(config: O5CgmSensorConfig, transport: BlePodMessageTransport) throws {
        var data = Data()

        // Sensor UID
        if let uid = config.sensorUid {
            data.appendBigEndian(UInt16(uid.count))
            data.append(uid)
        } else {
            data.appendBigEndian(UInt16(0))
        }

        // BLE address
        if let bleAddr = config.bleAddress {
            data.append(bleAddr.prefix(6))
            if bleAddr.count < 6 { data.append(Data(count: 6 - bleAddr.count)) }
        } else {
            data.append(Data(count: 6))
        }

        // Warmup duration
        data.appendBigEndian(config.warmupDurationSeconds)

        // Wear duration
        data.appendBigEndian(config.wearDurationSeconds)

        // Activation time
        let activationTs = UInt32(config.sensorActivationTime?.timeIntervalSince1970 ?? 0)
        data.appendBigEndian(activationTs)

        let (payload, prefix) = O5AidCommands.Libre2SensorInformationCommand.set(binaryData: data)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
    }

    // MARK: - Libre 3 Sensor Info

    private func sendLibre3SensorInfo(config: O5CgmSensorConfig, transport: BlePodMessageTransport) throws {
        var data = Data()

        // Sensor UID
        if let uid = config.sensorUid {
            data.appendBigEndian(UInt16(uid.count))
            data.append(uid)
        } else {
            data.appendBigEndian(UInt16(0))
        }

        // BLE address
        if let bleAddr = config.bleAddress {
            data.append(bleAddr.prefix(6))
            if bleAddr.count < 6 { data.append(Data(count: 6 - bleAddr.count)) }
        } else {
            data.append(Data(count: 6))
        }

        // Patch public signing key
        if let key = config.patchPublicSigningKey {
            data.appendBigEndian(UInt16(key.count))
            data.append(key)
        } else {
            data.appendBigEndian(UInt16(0))
        }

        // Warmup + wear durations
        data.appendBigEndian(config.warmupDurationSeconds)
        data.appendBigEndian(config.wearDurationSeconds)

        // Activation time
        let activationTs = UInt32(config.sensorActivationTime?.timeIntervalSince1970 ?? 0)
        data.appendBigEndian(activationTs)

        let (payload, prefix) = O5AidCommands.Libre3SensorInformationCommand.set(binaryData: data)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
    }

    // MARK: - CGM Pairing Information (Certificates)

    private func sendCgmPairingInfo(config: O5CgmSensorConfig, transport: BlePodMessageTransport) throws {
        var data = Data()

        // App certificate data
        if let cert = config.appCertificateData {
            data.appendBigEndian(UInt16(cert.count))
            data.append(cert)
        } else {
            data.appendBigEndian(UInt16(0))
        }

        // App private key
        if let key = config.appPrivateKey {
            data.appendBigEndian(UInt16(key.count))
            data.append(key)
        } else {
            data.appendBigEndian(UInt16(0))
        }

        let (payload, prefix) = O5AidCommands.CgmPairingInformationCommand.set(binaryData: data)
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)

        log.default("Sent CGM pairing certificates (%d bytes)", data.count)
    }

    // MARK: - CGM State Updates

    /// Updates the CGM state based on a special EGV value or pod status.
    func updateCgmState(from egvValue: Int) {
        if O5SpecialEgv.isSpecial(egvValue) {
            switch egvValue {
            case O5SpecialEgv.cgmPairing:
                cgmState = .pairing
            case O5SpecialEgv.cgmConnecting:
                cgmState = .pairing
            case O5SpecialEgv.cgmLinkLoss:
                cgmState = .activeLinkLoss
            case O5SpecialEgv.cgmNoTxId:
                cgmState = .noTxId
            case O5SpecialEgv.cgmSignalLoss:
                cgmState = .signalLoss
            case O5SpecialEgv.cgmScanStopped:
                cgmState = .scanStopped
            case O5SpecialEgv.cgmTxIdAuthError:
                cgmState = .txIdAuthError
            case O5SpecialEgv.cgmTxBleAuthError:
                cgmState = .txBleAuthError
            case O5SpecialEgv.cgmUnrecoverableError:
                cgmState = .unrecoverableError
            case O5SpecialEgv.incorrectBleAddress:
                cgmState = .invalidState
            case O5SpecialEgv.sensorOutOfCalibration:
                cgmState = .sensorOutOfCalibration
            default:
                break
            }
        } else if egvValue > 0 && egvValue < 600 {
            cgmState = .active
        }
    }

    /// Sends a special EGV value to the pod to indicate CGM state change.
    func sendSpecialEgv(_ specialValue: Int, transport: BlePodMessageTransport) throws {
        let (payload, prefix) = O5AidCommands.EgvCommand.payload(value: "\(specialValue)")
        let _ = try transport.sendO5AidCommand(payload, responsePrefix: prefix)
    }
}
