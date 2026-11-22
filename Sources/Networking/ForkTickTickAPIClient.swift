// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Fork: a client for TickTick's Open API (`api.ticktick.com/open/v1`), the
/// backend of the TickTick pinned tab's native card (`ForkTickTickTasks`).
///
/// A dedicated per-backend client (AGENTS.md, Networking): TickTick is a
/// third-party service authorized by the user's own personal API token, which
/// the card's model keeps and passes in. It shares nothing with Phi's account
/// backends, so it does not go through `APIClient` or `AuthManager`. Requests
/// use an ephemeral session: no cookies, no cache on disk.
struct ForkTickTickAPIClient {
    struct Project: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let color: String?
        let closed: Bool?
        let kind: String?
        let sortOrder: Double?
    }

    struct ChecklistItem: Decodable, Identifiable, Equatable {
        let id: String
        var title: String?
        var status: Int?
        var sortOrder: Double?
    }

    struct TaskItem: Decodable, Identifiable, Equatable {
        let id: String
        var projectId: String
        var title: String?
        var content: String?
        var desc: String?
        var startDate: Date?
        var dueDate: Date?
        var isAllDay: Bool?
        var timeZone: String?
        /// None 0, low 1, medium 3, high 5.
        var priority: Int?
        /// Open 0, completed 2.
        var status: Int?
        var sortOrder: Double?
        var repeatFlag: String?
        var items: [ChecklistItem]?
        var tags: [String]?
        /// The task this one is a subtask of.
        var parentId: String?
        /// The task as TickTick sent it. An update sends it back with the
        /// edited fields changed, so fields the card doesn't know about
        /// (reminders, tags, subtask details) are kept.
        var raw: Data?
        /// The card's own key for the row: a task created in the card keeps
        /// the key of the new-task row it was typed into, so the row stays
        /// put when TickTick's copy arrives.
        var localKey: String?

        var rowKey: String { localKey ?? id }

        private enum CodingKeys: String, CodingKey {
            case id, projectId, title, content, desc, startDate, dueDate, isAllDay, timeZone
            case priority, status, sortOrder, repeatFlag, items, tags, parentId
        }

        /// The update request's body: TickTick's own copy with the card's
        /// edits applied.
        var updateBody: [String: Any] {
            var body = raw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            body["id"] = id
            body["projectId"] = projectId
            body["title"] = title ?? ""
            body["content"] = content ?? ""
            body["priority"] = priority ?? 0
            body["isAllDay"] = isAllDay ?? false
            body["startDate"] = startDate.map(ForkTickTickAPIClient.wireDate) ?? NSNull()
            body["dueDate"] = dueDate.map(ForkTickTickAPIClient.wireDate) ?? NSNull()
            if let timeZone { body["timeZone"] = timeZone }
            if let items {
                let rawItems = (body["items"] as? [[String: Any]]) ?? []
                body["items"] = items.map { item -> [String: Any] in
                    var entry = rawItems.first { ($0["id"] as? String) == item.id } ?? ["id": item.id]
                    entry["title"] = item.title ?? ""
                    entry["status"] = item.status ?? 0
                    return entry
                }
            }
            return body
        }
    }

    enum ClientError: Error {
        /// TickTick refused the token (401/403).
        case unauthorized
        case http(Int, String)
        case transport(Error)
    }

    let token: String

    private static let base = URL(string: "https://api.ticktick.com/open/v1/")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// TickTick's wire format: "2019-11-13T03:00:00+0000", sometimes with
    /// milliseconds.
    private static let formatters: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ"].map {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = $0
        return formatter
    }

    static func wireDate(_ date: Date) -> String { formatters[1].string(from: date) }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            for formatter in formatters {
                if let date = formatter.date(from: text) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown date \(text)"))
        }
        return decoder
    }()

    // MARK: Calls

    /// The user's lists (not the Inbox, which TickTick lists separately).
    func projects() async throws -> [Project] {
        try Self.decoder.decode([Project].self, from: await send("GET", "project"))
    }

    /// Open tasks, at most 200: in `projectIds` (all lists when nil; "inbox"
    /// names the Inbox), starting on or before `endDate` when given.
    func openTasks(projectIds: [String]?, endDate: Date?) async throws -> [TaskItem] {
        var body: [String: Any] = ["status": [0]]
        if let projectIds { body["projectIds"] = projectIds }
        if let endDate { body["endDate"] = Self.wireDate(endDate) }
        return try Self.tasks(from: await send("POST", "task/filter", body: body))
    }

    func complete(_ task: TaskItem) async throws {
        _ = try await send("POST", "project/\(task.projectId)/task/\(task.id)/complete")
    }

    /// A new task in `projectId` (the Inbox when nil), all day on `day`
    /// (local midnight) when given.
    func createTask(title: String, projectId: String?, day: Date?) async throws -> TaskItem {
        var body: [String: Any] = ["title": title]
        if let projectId { body["projectId"] = projectId }
        if let day {
            body["startDate"] = Self.wireDate(day)
            body["dueDate"] = Self.wireDate(day)
            body["isAllDay"] = true
            body["timeZone"] = TimeZone.current.identifier
        }
        return try Self.task(from: await send("POST", "task", body: body))
    }

    /// Saves `task`'s edited fields; returns TickTick's copy.
    func update(_ task: TaskItem) async throws -> TaskItem {
        try Self.task(from: await send("POST", "task/\(task.id)", body: task.updateBody))
    }

    func delete(_ task: TaskItem) async throws {
        _ = try await send("DELETE", "project/\(task.projectId)/task/\(task.id)")
    }

    func move(_ task: TaskItem, to projectId: String) async throws {
        _ = try await send("POST", "task/move", body: [["fromProjectId": task.projectId, "toProjectId": projectId, "taskId": task.id]])
    }

    // MARK: Decoding

    private static func task(from data: Data) throws -> TaskItem {
        var task = try decoder.decode(TaskItem.self, from: data)
        task.raw = data
        return task
    }

    private static func tasks(from data: Data) throws -> [TaskItem] {
        let objects = (try JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
        return try objects.map { object in
            try task(from: JSONSerialization.data(withJSONObject: object))
        }
    }

    // MARK: Transport

    private func send(_ method: String, _ path: String, body: Any? = nil) async throws -> Data {
        var request = URLRequest(url: Self.base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if method == "POST" {
            request.httpBody = Data()
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw ClientError.transport(error)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw ClientError.unauthorized }
        guard (200..<300).contains(code) else {
            throw ClientError.http(code, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return data
    }
}
