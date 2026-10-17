//
//  NightscoutRegressionImporter.swift
//  OmnipodKit
//
//  Fetches 14 days of glucose, carbs, and insulin data from a
//  Nightscout server to seed the O5 regression analysis buffers.
//  Standalone — no dependency on NightscoutService or NightscoutKit.
//

import Foundation

public enum NightscoutImportError: LocalizedError {
    case invalidURL
    case httpError(Int)
    case networkError(Error)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Nightscout URL"
        case .httpError(let code): return "Nightscout returned HTTP \(code)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .decodingError(let msg): return "Data decoding error: \(msg)"
        }
    }
}

public struct NightscoutImportResult {
    public let glucoseCount: Int
    public let carbCount: Int
    public let insulinCount: Int
}

public final class NightscoutRegressionImporter {

    private let baseURL: URL
    private let apiSecret: String?
    private let token: String?
    private let session: URLSession

    public init(siteURL: String, apiSecret: String? = nil, token: String? = nil) throws {
        var cleaned = siteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasSuffix("/") { cleaned.removeLast() }
        guard let url = URL(string: cleaned) else {
            throw NightscoutImportError.invalidURL
        }
        self.baseURL = url
        self.apiSecret = apiSecret
        self.token = token
        self.session = URLSession(configuration: .ephemeral)
    }

    // MARK: - Public

    public func fetchRegressionData(
        days: Int = 14,
        completion: @escaping (Result<(glucose: [GlucoseHistoryEntry], carbs: [CarbHistoryEntry], insulin: [InsulinHistoryEntry]), NightscoutImportError>) -> Void
    ) {
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        let group = DispatchGroup()

        var glucoseResult: Result<[GlucoseHistoryEntry], NightscoutImportError> = .success([])
        var carbResult: Result<[CarbHistoryEntry], NightscoutImportError> = .success([])
        var insulinResult: Result<[InsulinHistoryEntry], NightscoutImportError> = .success([])

        group.enter()
        fetchGlucose(since: since) { result in
            glucoseResult = result
            group.leave()
        }

        group.enter()
        fetchTreatments(since: since) { result in
            switch result {
            case .success(let (carbs, insulin)):
                carbResult = .success(carbs)
                insulinResult = .success(insulin)
            case .failure(let err):
                carbResult = .failure(err)
                insulinResult = .failure(err)
            }
            group.leave()
        }

        group.notify(queue: .main) {
            switch (glucoseResult, carbResult, insulinResult) {
            case (.success(let g), .success(let c), .success(let i)):
                completion(.success((glucose: g, carbs: c, insulin: i)))
            case (.failure(let e), _, _):
                completion(.failure(e))
            case (_, .failure(let e), _):
                completion(.failure(e))
            case (_, _, .failure(let e)):
                completion(.failure(e))
            }
        }
    }

    // MARK: - Glucose (entries/sgv)

    private func fetchGlucose(since: Date, completion: @escaping (Result<[GlucoseHistoryEntry], NightscoutImportError>) -> Void) {
        let sinceMs = Int(since.timeIntervalSince1970 * 1000)
        let path = "/api/v1/entries/sgv.json"
        let query = "find[date][$gte]=\(sinceMs)&count=50000"

        request(path: path, query: query) { result in
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success(let data):
                do {
                    guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        completion(.failure(.decodingError("Expected array of entries")))
                        return
                    }
                    let glucose: [GlucoseHistoryEntry] = entries.compactMap { entry in
                        guard let sgv = entry["sgv"] as? Int,
                              let dateMs = entry["date"] as? Double else { return nil }
                        let date = Date(timeIntervalSince1970: dateMs / 1000.0)
                        guard sgv > 20 && sgv < 500 else { return nil }
                        return GlucoseHistoryEntry(mgdl: sgv, date: date)
                    }
                    completion(.success(glucose))
                } catch {
                    completion(.failure(.decodingError(error.localizedDescription)))
                }
            }
        }
    }

    // MARK: - Treatments (carbs + insulin)

    private func fetchTreatments(since: Date, completion: @escaping (Result<([CarbHistoryEntry], [InsulinHistoryEntry]), NightscoutImportError>) -> Void) {
        let sinceISO = ISO8601DateFormatter().string(from: since)
        let path = "/api/v1/treatments.json"
        let query = "find[created_at][$gte]=\(sinceISO)&count=50000"

        request(path: path, query: query) { result in
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success(let data):
                do {
                    guard let treatments = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                        completion(.failure(.decodingError("Expected array of treatments")))
                        return
                    }

                    var carbs: [CarbHistoryEntry] = []
                    var insulin: [InsulinHistoryEntry] = []
                    let isoFormatter = ISO8601DateFormatter()
                    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let isoFormatterNoFrac = ISO8601DateFormatter()

                    for t in treatments {
                        let date: Date
                        if let dateStr = t["created_at"] as? String {
                            if let d = isoFormatter.date(from: dateStr) {
                                date = d
                            } else if let d = isoFormatterNoFrac.date(from: dateStr) {
                                date = d
                            } else {
                                continue
                            }
                        } else if let mills = t["mills"] as? Double {
                            date = Date(timeIntervalSince1970: mills / 1000.0)
                        } else {
                            continue
                        }

                        // Carbs
                        if let grams = t["carbs"] as? Double, grams > 0 {
                            let absorption = t["absorptionTime"] as? Double ?? (t["duration"] as? Double).map { $0 * 60 } ?? 10800
                            carbs.append(CarbHistoryEntry(date: date, grams: grams, absorptionTime: absorption))
                        }

                        // Bolus
                        if let units = t["insulin"] as? Double, units > 0 {
                            let eventType = t["eventType"] as? String ?? ""
                            let isMeal = (t["carbs"] as? Double ?? 0) > 0
                            insulin.append(InsulinHistoryEntry(
                                timestamp: date,
                                units: units,
                                isMeal: isMeal,
                                isBasal: false
                            ))
                        }

                        // Temp basal
                        let eventType = t["eventType"] as? String ?? ""
                        if eventType == "Temp Basal" || eventType == "temp" {
                            let rate = t["rate"] as? Double ?? t["absolute"] as? Double ?? 0
                            let duration = t["duration"] as? Double ?? 30
                            if rate > 0 && duration > 0 {
                                let units = rate * (duration / 60.0)
                                insulin.append(InsulinHistoryEntry(
                                    timestamp: date,
                                    units: units,
                                    isMeal: false,
                                    isBasal: true
                                ))
                            }
                        }
                    }

                    completion(.success((carbs, insulin)))
                } catch {
                    completion(.failure(.decodingError(error.localizedDescription)))
                }
            }
        }
    }

    // MARK: - HTTP

    private func request(path: String, query: String, completion: @escaping (Result<Data, NightscoutImportError>) -> Void) {
        var urlString = baseURL.absoluteString + path + "?" + query
        if let token = token, !token.isEmpty {
            urlString += "&token=\(token)"
        }
        guard let url = URL(string: urlString) else {
            completion(.failure(.invalidURL))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let secret = apiSecret, !secret.isEmpty {
            req.setValue(secret.sha1(), forHTTPHeaderField: "api-secret")
        }
        req.timeoutInterval = 60

        session.dataTask(with: req) { data, response, error in
            if let error = error {
                completion(.failure(.networkError(error)))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                completion(.failure(.httpError(http.statusCode)))
                return
            }
            guard let data = data else {
                completion(.failure(.decodingError("Empty response")))
                return
            }
            completion(.success(data))
        }.resume()
    }
}

// MARK: - SHA1 for api-secret header

import CommonCrypto

private extension String {
    func sha1() -> String {
        let data = Data(self.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
