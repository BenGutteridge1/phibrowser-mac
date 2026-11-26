// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Fork: DeepL's translation API, for selection translate
/// (`ForkSelectionTranslate`), with the user's own API key.
///
/// The key is kept in a file only the user can read, in Phi+'s Application
/// Support folder. Not the Keychain: Phi+ is signed ad hoc, so every rebuild
/// would be a new app to the Keychain and ask for access again. Free keys
/// (ending ":fx") use DeepL's free endpoint.
enum ForkDeepLClient {
    enum Failure: Error {
        case noKey
        /// DeepL refused the key (403).
        case badKey
        /// The month's character allowance is used up (456).
        case quotaExceeded
        /// Too many requests (429).
        case busy
        case offline
        case failed(Int)

        var message: String {
            switch self {
            case .noKey:
                return NSLocalizedString("translate.error.noKey", value: "Add your DeepL API key to translate.",
                    comment: "Selection translate - no DeepL API key saved yet")
            case .badKey:
                return NSLocalizedString("translate.error.badKey", value: "DeepL didn't accept your API key.",
                    comment: "Selection translate - DeepL refused the API key")
            case .quotaExceeded:
                return NSLocalizedString("translate.error.quota", value: "You've used this month's DeepL allowance.",
                    comment: "Selection translate - DeepL monthly character allowance used up")
            case .busy:
                return NSLocalizedString("translate.error.busy", value: "DeepL is busy. Try again in a moment.",
                    comment: "Selection translate - DeepL rate limited the request")
            case .offline:
                return NSLocalizedString("translate.error.offline", value: "Couldn't reach DeepL. Check your connection.",
                    comment: "Selection translate - network error reaching DeepL")
            case .failed:
                return NSLocalizedString("translate.error.failed", value: "DeepL couldn't translate this.",
                    comment: "Selection translate - any other DeepL error")
            }
        }

        /// Whether Settings is where to fix it.
        var opensSettings: Bool {
            switch self {
            case .noKey, .badKey: return true
            default: return false
            }
        }
    }

    struct Translation {
        let text: String
        /// DeepL's language code for the source ("FR", "ZH", "PT"…).
        let sourceLanguage: String?
    }

    struct Usage {
        let used: Int
        let limit: Int
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static func base(for key: String) -> URL {
        URL(string: key.hasSuffix(":fx") ? "https://api-free.deepl.com/v2/" : "https://api.deepl.com/v2/")!
    }

    static func translate(_ text: String, target: String) async throws -> Translation {
        guard let key = readKey() else { throw Failure.noKey }
        var request = URLRequest(url: base(for: key).appendingPathComponent("translate"))
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": [text], "target_lang": target, "preserve_formatting": true
        ])
        let data = try await send(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (object["translations"] as? [[String: Any]])?.first,
              let translated = first["text"] as? String else { throw Failure.failed(0) }
        return Translation(text: translated, sourceLanguage: first["detected_source_language"] as? String)
    }

    /// This month's characters used and allowed: also checks a key works.
    static func usage(key: String) async throws -> Usage {
        var request = URLRequest(url: base(for: key).appendingPathComponent("usage"))
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        let data = try await send(request)
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return Usage(used: object["character_count"] as? Int ?? 0, limit: object["character_limit"] as? Int ?? 0)
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401, 403: throw Failure.badKey
        case 456: throw Failure.quotaExceeded
        case 429, 503: throw Failure.busy
        default: throw Failure.failed(status)
        }
    }

    // MARK: Key

    private static var keyFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.bengutteridge.phiplus", isDirectory: true)
            .appendingPathComponent("deepl-key")
    }

    static var hasKey: Bool { readKey() != nil }

    static func readKey() -> String? {
        guard let data = try? Data(contentsOf: keyFile),
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    static func writeKey(_ key: String) {
        let file = keyFile
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Created readable by the user alone, before the key is written.
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try? Data(key.utf8).write(to: file)
    }

    static func deleteKey() {
        try? FileManager.default.removeItem(at: keyFile)
    }
}
