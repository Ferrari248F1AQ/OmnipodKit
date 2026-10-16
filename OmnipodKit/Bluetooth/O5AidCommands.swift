//
//  O5AidCommands.swift
//  OmnipodKit
//
//  Created for O5 AID setup commands sent between AssignAddress and SetupPod.
//  These use an ASCII key-value protocol different from legacy Omnipod commands.
//
//  Command formats:
//    SET+GET: S[feature].[attr]=[data],G[feature].[attr]
//    GET only: G[feature].[attr]
//    Extended SET: SE[feature].[attr]=[data]
//
//  Response formats:
//    SET+GET response: [feature].[attr]=[data]
//    GET response: [feature].[attr]=[data]
//    Extended SET response: ES[feature].[attr]=[data]
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// Constructs O5 AID command payloads for the pre-SetupPod activation sequence.
///
/// These commands use plain ASCII key-value format (NOT the SLPE length-prefixed encoding
/// used by standard S0.0= commands). The data values can be ASCII text
/// (e.g., "8" for DIA) or raw binary bytes (e.g., 0x0003000E00 for TDI).
///
struct O5AidCommands {

    // MARK: - AID Payload Construction
    //
    // AID commands use plain ASCII key-value format with NO length prefix.
    // This is different from standard Omnipod SLPE (S0.0=...,G0.0) which uses
    // 2-byte big-endian length prefixes via StringLengthPrefixEncoding.formatKeys().
    //
    // Confirmed wire format is: ASCII key + data + ASCII suffix
    // For BINARY commands, data is raw bytes. For ASCII commands, data is text.

    /// Constructs a SET+GET command payload with ASCII text data.
    ///
    /// Wire format: `S[f].[a]=[ASCII data],G[f].[a]`
    static func setGetPayload(feature: String, attribute: String, data: String) -> Data {
        let command = "S\(feature).\(attribute)=\(data),G\(feature).\(attribute)"
        return Data(command.utf8)
    }

    /// Constructs a SET+GET command payload with raw binary data.
    ///
    /// Wire format: `S[f].[a]=` + [raw binary bytes] + `,G[f].[a]`
    static func setGetPayload(feature: String, attribute: String, binaryData: Data) -> Data {
        let prefix = Data("S\(feature).\(attribute)=".utf8)
        let suffix = Data(",G\(feature).\(attribute)".utf8)
        return prefix + binaryData + suffix
    }

    /// Constructs a GET-only command payload.
    ///
    /// Wire format: `G[f].[a]`
    static func getPayload(feature: String, attribute: String) -> Data {
        let command = "G\(feature).\(attribute)"
        return Data(command.utf8)
    }

    /// Constructs an Extended SET command payload with ASCII text data.
    ///
    /// Wire format: `SE[f].[a]=[ASCII data]`
    static func extendedSetPayload(feature: String, attribute: String, data: String) -> Data {
        let command = "SE\(feature).\(attribute)=\(data)"
        return Data(command.utf8)
    }

    /// Constructs an Extended SET command payload with raw binary data.
    ///
    /// Wire format: `SE[f].[a]=` + [raw binary bytes]
    static func extendedSetPayload(feature: String, attribute: String, binaryData: Data) -> Data {
        let prefix = Data("SE\(feature).\(attribute)=".utf8)
        return prefix + binaryData
    }

    /// Returns the expected response prefix for a SET+GET or GET-only command.
    /// Response format: `[feature].[attribute]=`
    static func responsePrefix(feature: String, attribute: String) -> String {
        return "\(feature).\(attribute)="
    }

    /// Returns the expected response prefix for an Extended SET command.
    /// Response format: `ES[feature].[attribute]=`
    static func extendedSetResponsePrefix(feature: String, attribute: String) -> String {
        return "ES\(feature).\(attribute)="
    }

    // MARK: - AID Command Definitions

    /// Command 1: UTC time setting.
    /// Sends: `SE255.2=[unix_timestamp]`
    /// Response: `ES255.2=0`
    struct UtcCommand {
        static let feature = "255"
        static let attribute = "2"

        /// Creates the SLPE-wrapped payload for the UTC command.
        /// - Parameter timestamp: Unix timestamp (defaults to current time)
        /// - Returns: Tuple of (payload, responsePrefix)
        static func payload(timestamp: UInt64? = nil) -> (data: Data, responsePrefix: String) {
            let ts = timestamp ?? UInt64(Date().timeIntervalSince1970)
            let data = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, data: "\(ts)")
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (data, prefix)
        }
    }

    /// Command 2: TDI (Therapy Delivery Information) configuration.
    /// Binary wire format: `S3.2=` + [0x00,0x03,0x00,0x0E,0x00] + `,G3.2` (15 bytes)
    /// Response: `3.2=` + [5 binary bytes echoed back]
    ///
    /// The 5 data bytes: version(00), therapy type(03), delivery mode(00), bolus speed(0E=14U TDI), reserved(00).
    struct TdiCommand {
        static let feature = "3"
        static let attribute = "2"
        static let defaultBinaryData = Data([0x00, 0x03, 0x00, 0x0E, 0x00])

        static func payload(binaryData: Data? = nil) -> (data: Data, responsePrefix: String) {
            let data = binaryData ?? defaultBinaryData
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: data)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 3: Target BG profile — 48 half-hour BG target values for a 24-hour day.
    /// Binary wire format: `S3.1=` + [0x00,0xC0] + [48 x 4-byte-BE targets] + `,G3.1` (204 bytes)
    /// Response: `3.1=` + [194 binary bytes echoed back]
    ///
    /// The 0x00C0 prefix = 192 = 48 * 4 (byte count of the 48 target entries).
    /// Each target is a 4-byte big-endian value in mg/dL (e.g., 0x0000006E = 110).
    struct TargetBgProfileCommand {
        static let feature = "3"
        static let attribute = "1"
        static let defaultTargetMgdl: UInt32 = 110  // 0x006e

        static func payload(targets: [UInt32]? = nil) -> (data: Data, responsePrefix: String) {
            let targetValues = targets ?? Array(repeating: defaultTargetMgdl, count: 48)
            assert(targetValues.count == 48, "Target BG profile must have exactly 48 half-hour entries")

            var binaryData = Data()
            let totalBytes = UInt16(targetValues.count * 4)  // 192 = 0x00C0
            binaryData.appendBigEndian(totalBytes)
            for target in targetValues {
                binaryData.appendBigEndian(target)
            }
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 4: DIA (Duration of Insulin Action) setting.
    /// Sends: `S3.9=8,G3.9`
    /// Response: `3.9=8`
    ///
    /// Value "8" likely represents 8 half-hours = 4 hours DIA, but could be the raw value.
    struct DiaCommand {
        static let feature = "3"
        static let attribute = "9"
        static let defaultValue = "8"

        static func payload(value: String = defaultValue) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: value)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 5: EGV (Estimated Glucose Value) configuration.
    /// Sends: `S3.7=3670015,G3.7`
    /// Response: `3.7=3670015`
    ///
    /// The value `3670015` is a bitfield or composite config value for CGM/EGV settings.
    struct EgvCommand {
        static let feature = "3"
        static let attribute = "7"
        static let defaultValue = "3670015"

        static func payload(value: String = defaultValue) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: value)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 6: Algorithm Insulin History — sent 3 times with 24 records each.
    /// Binary wire format: `SE2.1=` + [0x00,0xA8] + [168 raw bytes] (176 bytes)
    /// Response: `ES2.1=0`
    ///
    /// The 0x00A8 prefix = 168 = 24 * 7 (byte count of the 24 history records).
    /// Each record is 7 bytes. For initial setup with no history, all records are zeros.
    struct AlgorithmInsulinHistoryCommand {
        static let feature = "2"
        static let attribute = "1"
        static let recordsPerBatch = 24
        static let bytesPerRecord = 7

        static func payload(records: [Data]? = nil) -> (data: Data, responsePrefix: String) {
            let recordData: [Data]
            if let records = records {
                assert(records.count == recordsPerBatch, "Must have exactly \(recordsPerBatch) records")
                recordData = records
            } else {
                // Default: 24 zero records of 7 bytes each
                recordData = Array(repeating: Data(count: bytesPerRecord), count: recordsPerBatch)
            }

            let totalBytes = UInt16(recordsPerBatch * bytesPerRecord)  // 168 = 0x00A8
            var binaryData = Data()
            binaryData.appendBigEndian(totalBytes)
            for record in recordData {
                assert(record.count == bytesPerRecord, "Each record must be exactly \(bytesPerRecord) bytes")
                binaryData.append(record)
            }
            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 7 (Gen1): AID Pod Status query.
    /// Sends: `G3.11`
    /// Response: `3.11=[fixed 30-byte payload: 2-byte length + 28-byte body]`
    ///
    /// Used for Gen1 pods (firmware majorVersion < 7).
    struct AidPodStatusCommand {
        static let feature = "3"
        static let attribute = "11"

        static func payload() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 7 (non-Gen1): Unified AID Pod Status query.
    /// Sends: `G3.12`
    /// Response: `3.12=[29 bytes of AID status data]`
    ///
    /// Used for non-Gen1 pods (firmware majorVersion >= 7).
    struct UnifiedAidPodStatusCommand {
        static let feature = "3"
        static let attribute = "12"

        static func payload() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    // MARK: - Algorithm Configuration Commands

    /// Correction Factor Profile — per-slot correction factors (ISF).
    /// Binary wire format: `S3.3=` + [correction factor data] + `,G3.3`
    struct CorrectionFactorProfileCommand {
        static let feature = "3"
        static let attribute = "3"

        static func setGet(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Hypo Protection settings — configures the pod's hypo protection threshold and behavior.
    /// Wire format: `S3.4=` + [hypo config data] + `,G3.4`
    struct HypoProtectionCommand {
        static let feature = "3"
        static let attribute = "4"

        static func setGet(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// EGV Threshold — configures glucose thresholds for alerts (e.g., below 55).
    /// Wire format: `S3.5=` + [threshold data] + `,G3.5`
    struct EgvThresholdCommand {
        static let feature = "3"
        static let attribute = "5"

        static func setGet(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Algorithm Clinical Parameters — advanced algorithm tuning.
    /// Wire format: `S3.6=` + [clinical params data] + `,G3.6`
    struct AlgorithmClinicalParamsCommand {
        static let feature = "3"
        static let attribute = "6"

        static func setGet(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Algorithm IOB — get/set algorithm's insulin-on-board state.
    /// Wire format: `S3.8=` + [IOB data] + `,G3.8`
    struct AlgorithmIobCommand {
        static let feature = "3"
        static let attribute = "8"

        static func setGet(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Algorithm Interface Manager — controls algorithm interface mode.
    /// Wire format: `S3.10=` + [interface data] + `,G3.10`
    struct AlgorithmInterfaceManagerCommand {
        static let feature = "3"
        static let attribute = "10"

        static func setGet(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    // MARK: - Loop State Commands

    /// AID Loop State — get/set closed-loop state (open, closed, limited).
    /// GET: `G3.13`  SET: `S3.13=[state],G3.13`
    struct AidLoopStateCommand {
        static let feature = "3"
        static let attribute = "13"

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func set(state: O5LoopStateValue) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: "\(state.rawValue)")
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Insulin History Length — number of records in the algorithm's insulin history buffer.
    /// GET: `G2.2`  SET: `S2.2=[length],G2.2`
    struct InsulinHistoryLengthCommand {
        static let feature = "2"
        static let attribute = "2"

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func set(length: Int) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: "\(length)")
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    // MARK: - CGM Pairing Commands

    /// CGM Pairing Information — registers CGM sensor with the pod.
    /// Wire format: `SE4.1=` + [pairing info binary data]
    struct CgmPairingInformationCommand {
        static let feature = "4"
        static let attribute = "1"

        static func set(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// CGM Interface Manager — controls CGM subsystem on the pod.
    /// Wire format: `S4.2=` + [interface data] + `,G4.2`
    struct CgmInterfaceManagerCommand {
        static let feature = "4"
        static let attribute = "2"

        static func setGet(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Transmitter Info — sends CGM transmitter identification to the pod.
    /// Wire format: `SE4.3=` + [transmitter info binary data]
    struct TransmitterInfoCommand {
        static let feature = "4"
        static let attribute = "3"

        static func set(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// G6 Sensor Information — Dexcom G6-specific sensor data sent to the pod.
    /// Wire format: `SE4.4=` + [G6 sensor data]
    struct G6SensorInformationCommand {
        static let feature = "4"
        static let attribute = "4"

        static func set(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// G7 Sensor Information — Dexcom G7-specific sensor data sent to the pod.
    /// Includes: pairing code, serial number, BLE address, operating interval,
    /// advertisement reference time, transmitter lifetime, driver version, BLE address type.
    /// Wire format: `SE4.5=` + [G7 sensor data]
    struct G7SensorInformationCommand {
        static let feature = "4"
        static let attribute = "5"

        static func set(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Libre 2 Sensor Information — Abbott Libre 2 sensor data.
    /// Wire format: `SE4.6=` + [Libre 2 sensor data]
    struct Libre2SensorInformationCommand {
        static let feature = "4"
        static let attribute = "6"

        static func set(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Libre 3 Sensor Information — Abbott Libre 3 sensor data.
    /// Wire format: `SE4.7=` + [Libre 3 sensor data]
    struct Libre3SensorInformationCommand {
        static let feature = "4"
        static let attribute = "7"

        static func set(binaryData: Data) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    // MARK: - Patient History Commands

    /// Patient History Log — read pod's internal therapy log (PHB).
    /// GET: `G5.1`
    struct PatientHistoryLogCommand {
        static let feature = "5"
        static let attribute = "1"

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Patient History Log Enabled — enable/disable PHB logging on the pod.
    /// SET: `S5.2=[0|1],G5.2`
    struct PatientHistoryLogEnabledCommand {
        static let feature = "5"
        static let attribute = "2"

        static func setGet(enabled: Bool) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: enabled ? "1" : "0")
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Patient History Buffer Index — read/reset PHB write position.
    /// GET: `G5.3`  SET: `SE5.3=[0]` (reset)
    struct PatientHistoryBufferIndexCommand {
        static let feature = "5"
        static let attribute = "3"

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func reset() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, data: "0")
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    // MARK: - Pod Status Commands

    /// General Status query — read pod general status (reservoir, delivery state, etc.).
    /// GET: `G6.1`
    struct GeneralStatusCommand {
        static let feature = "6"
        static let attribute = "1"

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Pod Core Info — read pod hardware/firmware identification.
    /// GET: `G6.2`
    struct PodCoreInfoCommand {
        static let feature = "6"
        static let attribute = "2"

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    // MARK: - Activity Mode

    /// QN Activity Mode — toggle activity mode (elevated target BG) on the pod.
    /// Wire format: `S3.14=` + [duration, intensity] + `,G3.14`
    struct ActivityModeCommand {
        static let feature = "3"
        static let attribute = "14"

        static func setGet(duration: Int, intensity: Int) -> (data: Data, responsePrefix: String) {
            var binaryData = Data()
            binaryData.appendBigEndian(UInt16(duration))
            binaryData.appendBigEndian(UInt16(intensity))
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    // MARK: - Basal Limited Mode

    /// Automated Limited Mode — the pod enters this when CGM data is unavailable.
    /// Delivers a safe basal rate based on TDI until CGM data resumes.
    /// Wire format: `S3.15=` + [0=off, 1=on] + `,G3.15`
    struct BasalLimitedModeCommand {
        static let feature = "3"
        static let attribute = "15"

        static func setGet(enabled: Bool) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: enabled ? "1" : "0")
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    // MARK: - Engineering / ELV Logs

    /// ELV (Engineering Log Volume) Buffer — diagnostic logs from the pod.
    /// GET: `G7.1`
    struct ElvBufferCommand {
        static let feature = "7"
        static let attribute = "1"

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// ELV Buffer Index — read/set ELV log buffer write position.
    /// GET: `G7.2`  SET: `S7.2=[index],G7.2`
    struct ElvBufferIndexCommand {
        static let feature = "7"
        static let attribute = "2"

        static func get() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func set(index: Int) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: "\(index)")
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }
}

// MARK: - Loop State Values

/// Wire values for the AID loop state command.
enum O5LoopStateValue: Int {
    case inactive = 0
    case closedLoop = 1
    case limitedMode = 2
    case safeBasal = 3
}

// MARK: - CGM Type

/// Supported CGM sensor types for the O5 pod.
enum O5CgmType: String, Codable, CaseIterable {
    case dexcomG6 = "g6"
    case dexcomG7 = "g7"
    case libre2 = "libre2"
    case libre3 = "libre3"
    case none = "none"

    var displayName: String {
        switch self {
        case .dexcomG6: return "Dexcom G6"
        case .dexcomG7: return "Dexcom G7"
        case .libre2: return "Libre 2"
        case .libre3: return "Libre 3"
        case .none: return "None"
        }
    }
}

// MARK: - CGM State (pod-side state machine)

/// The pod's internal CGM subsystem state.
enum O5CgmState: String, Codable {
    case none = "none"
    case pairing = "pairing"
    case warmingUp = "warmingUp"
    case active = "active"
    case noTxId = "noTxId"
    case signalLoss = "signalLoss"
    case scanStopped = "scanStopped"
    case txIdAuthError = "txIdAuthError"
    case activeLinkLoss = "activeLinkLoss"
    case txBleAuthError = "txBleAuthError"
    case unrecoverableError = "unrecoverableError"
    case sensorNotActive = "sensorNotActive"
    case sensorOutOfCalibration = "outOfCalibration"
    case temporarySensorFailure = "temporaryFailure"
    case predictionUnavailable = "predictionUnavailable"
    case invalidState = "invalid"

    var isReceivingData: Bool {
        return self == .active
    }

    var needsIntervention: Bool {
        switch self {
        case .txIdAuthError, .txBleAuthError, .unrecoverableError, .sensorNotActive:
            return true
        default:
            return false
        }
    }
}

// MARK: - Special EGV Values

/// Special EGV values sent to the pod to indicate CGM state changes.
enum O5SpecialEgv {
    static let cgmPairing = -1
    static let cgmConnecting = -2
    static let cgmLinkLoss = -3
    static let cgmNoTxId = -4
    static let cgmSignalLoss = -5
    static let cgmScanStopped = -6
    static let cgmTxIdAuthError = -7
    static let cgmTxBleAuthError = -8
    static let cgmUnrecoverableError = -9
    static let incorrectBleAddress = -10
    static let searchingBleAddress = -11
    static let powerAberration = -12
    static let sensorOutOfCalibration = -13
    static let noEgvValue = -99

    static func isSpecial(_ value: Int) -> Bool {
        return value < 0
    }
}

// MARK: - Alert Masks

/// Alert bitmask values for the pod's alert system.
struct O5AlertMask: OptionSet {
    let rawValue: UInt16

    static let autoOff             = O5AlertMask(rawValue: 1 << 0)
    static let egvBelow55          = O5AlertMask(rawValue: 1 << 1)
    static let existCloseLoop      = O5AlertMask(rawValue: 1 << 2)
    static let lowReservoir        = O5AlertMask(rawValue: 1 << 3)
    static let lumpOfCoal          = O5AlertMask(rawValue: 1 << 4)  // pod expiry warning
    static let missing12Egv        = O5AlertMask(rawValue: 1 << 5)
    static let podExpiration       = O5AlertMask(rawValue: 1 << 6)
    static let podExpireAtUserTime = O5AlertMask(rawValue: 1 << 7)
    static let podExpireImminent   = O5AlertMask(rawValue: 1 << 8)
    static let suspendEnded        = O5AlertMask(rawValue: 1 << 9)
    static let suspendInProgress   = O5AlertMask(rawValue: 1 << 10)
}
