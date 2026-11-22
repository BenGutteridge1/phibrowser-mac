// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

/// Fork: the TickTick pinned tab's native card model
/// (`ForkSettings.tickTickCardSource == .native`). It reads and changes the
/// user's tasks over TickTick's Open API (`ForkTickTickAPIClient`), so the
/// TickTick app need not be running.
///
/// The user's personal API token (TickTick web: Settings ▸ Account ▸ API
/// Token) is kept in a file only the user can read, in Phi+'s Application
/// Support folder. Not the Keychain: Phi+ is signed ad hoc, so every rebuild
/// would be a new app to the Keychain and ask for access again.
///
/// Each view's last list stays in memory, so the card paints at once; it
/// refreshes when shown (at most every `refreshInterval`) and on demand.
@MainActor
final class ForkTickTickTasks: ObservableObject {
    static let shared = ForkTickTickTasks()

    typealias TaskItem = ForkTickTickAPIClient.TaskItem
    typealias Project = ForkTickTickAPIClient.Project

    enum ListView: Hashable {
        case today
        case next7Days
        case inbox
        case project(String)
    }

    enum Status: Equatable {
        case needsToken
        /// TickTick refused the saved token.
        case unauthorized
        case ready
    }

    struct Section: Identifiable {
        let id: String
        let title: String?
        let rows: [Row]
    }

    /// A task in the list, indented under its parent when it is a subtask.
    struct Row: Identifiable {
        let task: TaskItem
        /// 0 for a task, 1 for its subtask, and so on.
        let depth: Int
        let subtaskCount: Int
        var id: String { task.rowKey }
    }

    /// Parents whose subtasks are folded away in the card.
    @Published private(set) var foldedParents: Set<String> = []

    func toggleSubtasks(of id: String) {
        withAnimation(Self.listAnimation) {
            if foldedParents.contains(id) { foldedParents.remove(id) } else { foldedParents.insert(id) }
        }
    }

    @Published private(set) var status: Status
    @Published private(set) var listView: ListView
    @Published private(set) var projects: [Project] = []
    @Published private(set) var tasks: [TaskItem] = []
    /// Whether the current view has loaded at least once.
    @Published private(set) var hasLoaded = false
    @Published private(set) var isRefreshing = false
    /// The last refresh could not reach TickTick; the last list stays up.
    @Published private(set) var isOffline = false
    /// Ticked in the card, sent to TickTick after `completeDelay` unless
    /// unticked first (as in Reminders).
    @Published private(set) var ticked: Set<String> = []
    /// A short notice when a change didn't reach TickTick.
    @Published private(set) var notice: String?

    private static let refreshInterval: TimeInterval = 30
    private static let completeDelay: TimeInterval = 1.2
    static let listAnimation = Animation.easeInOut(duration: 0.28)

    private var token: String?
    private var cache: [ListView: [TaskItem]] = [:]
    private var refreshedAt: [ListView: Date] = [:]
    private var refreshTask: Task<Void, Never>?
    private var completions: [String: Task<Void, Never>] = [:]
    /// The Inbox's real id ("inbox" plus a number), learned from its tasks.
    private var inboxId: String?
    private var noticeTask: Task<Void, Never>?

    private init() {
        token = Self.readToken()
        status = token == nil ? .needsToken : .ready
        listView = Self.savedListView()
    }

    // MARK: Card

    /// The card came on screen.
    func cardShown() {
        guard token != nil else { return }
        if let last = refreshedAt[listView], Date().timeIntervalSince(last) < Self.refreshInterval { return }
        refresh()
    }

    func select(_ view: ListView) {
        guard view != listView else { return }
        listView = view
        draftId = nil
        UserDefaults.standard.set(Self.key(for: view), forKey: ForkSettings.Key.tickTickCardView)
        tasks = cache[view] ?? []
        hasLoaded = cache[view] != nil
        refresh()
    }

    func refresh() {
        guard let token else { return }
        refreshTask?.cancel()
        let view = listView
        isRefreshing = true
        refreshTask = Task { [weak self] in
            let client = ForkTickTickAPIClient(token: token)
            do {
                async let projects = client.projects()
                let fetched = try await Self.fetch(view, client: client)
                let lists = try await projects
                guard let self, !Task.isCancelled else { return }
                self.projects = lists.filter { $0.closed != true }
                    .sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
                if let inbox = fetched.first(where: { $0.projectId.hasPrefix("inbox") }) { self.inboxId = inbox.projectId }
                self.finish(view, with: fetched)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.failed(error)
            }
        }
    }

    private func finish(_ view: ListView, with fetched: [TaskItem]) {
        let list = Self.ordered(Self.keep(fetched, for: view), for: view)
        cache[view] = list
        refreshedAt[view] = Date()
        isRefreshing = false
        isOffline = false
        guard view == listView else { return }
        // Tasks ticked here but not yet sent stay until they are.
        let listed = Set(list.map(\.id))
        let merged = list + tasks.filter { (ticked.contains($0.id) || Self.isDraft($0)) && !listed.contains($0.id) }
        let next = Self.ordered(merged, for: view)
        if next != tasks {
            if hasLoaded {
                withAnimation(Self.listAnimation) { tasks = next }
            } else {
                tasks = next
            }
        }
        hasLoaded = true
    }

    private func failed(_ error: Error) {
        isRefreshing = false
        if case ForkTickTickAPIClient.ClientError.unauthorized = error {
            AppLogWarn("[ForkTickTick] TickTick refused the token")
            status = .unauthorized
        } else {
            AppLogWarn("[ForkTickTick] refresh failed: \(error)")
            isOffline = true
        }
    }

    /// A change in the card didn't reach TickTick: the card shows `message`
    /// for a few seconds (with TickTick's status code, if any).
    private func changeFailed(_ error: Error, message: String) {
        if case ForkTickTickAPIClient.ClientError.unauthorized = error {
            failed(error)
            return
        }
        AppLogWarn("[ForkTickTick] \(message): \(error)")
        var text = message
        if case let ForkTickTickAPIClient.ClientError.http(code, _) = error {
            text += String(format: NSLocalizedString("pinnedPreview.tasks.errorCode", value: " (error %d)",
                comment: "TickTick task card - appended to an error notice; %d is the HTTP status code"), code)
        }
        noticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { notice = text }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { self?.notice = nil }
        }
    }

    // MARK: Changes

    /// Ticks or unticks `task`. A ticked task is completed in TickTick after
    /// a moment, then leaves the list.
    func toggleComplete(_ task: TaskItem) {
        if ticked.contains(task.id) {
            completions.removeValue(forKey: task.id)?.cancel()
            ticked.remove(task.id)
            return
        }
        ticked.insert(task.id)
        completions[task.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.completeDelay))
            guard !Task.isCancelled, let self, let token = self.token else { return }
            self.completions[task.id] = nil
            do {
                try await ForkTickTickAPIClient(token: token).complete(task)
                self.ticked.remove(task.id)
                let hadSubtasks = self.tasks.contains { $0.parentId == task.id }
                self.removeEverywhere(task.id)
                // A repeating task comes back with its next date; TickTick
                // may have completed a parent's subtasks with it.
                if task.repeatFlag?.isEmpty == false || hadSubtasks {
                    try? await Task.sleep(for: .seconds(1.5))
                    self.refresh()
                }
            } catch {
                self.ticked.remove(task.id)
                self.changeFailed(error, message: NSLocalizedString("pinnedPreview.tasks.completeFailed",
                    value: "Couldn't complete the task", comment: "TickTick task card - notice when completing a task fails"))
            }
        }
    }

    // MARK: New task

    /// The new task being typed in the card, not yet in TickTick.
    @Published private(set) var draftId: String?

    static func isDraft(_ task: TaskItem) -> Bool { task.id.hasPrefix("draft-") }

    /// Puts a new, untitled task in the list where it will live, for its
    /// title to be typed. It reaches TickTick once it has one
    /// (`finishDraft`); left empty, it goes away. In Today and Next 7 Days
    /// it goes to the Inbox, due today; in a list, to that list.
    func startDraft() {
        guard token != nil, draftId == nil else { return }
        let view = listView
        var draft = TaskItem(id: "draft-\(UUID().uuidString)", projectId: inboxProjectId)
        switch view {
        case .today, .next7Days:
            let today = Calendar.current.startOfDay(for: Date())
            draft.startDate = today
            draft.dueDate = today
            draft.isAllDay = true
            draft.timeZone = TimeZone.current.identifier
        case .inbox:
            break
        case .project(let id):
            draft.projectId = id
        }
        // First among its neighbours, as TickTick puts new tasks.
        draft.sortOrder = (tasks.compactMap(\.sortOrder).min() ?? 0) - 1
        draft.status = 0
        draftId = draft.id
        withAnimation(Self.listAnimation) { tasks = Self.ordered(tasks + [draft], for: view) }
    }

    /// Ends typing the new task: creates it in TickTick with `title`, or
    /// removes it when the title is empty.
    func finishDraft(title raw: String) {
        guard let id = draftId else { return }
        draftId = nil
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !title.isEmpty, var draft = tasks.first(where: { $0.id == id }) else {
            withAnimation(Self.listAnimation) { tasks.removeAll { $0.id == id } }
            return
        }
        draft.title = title
        replaceEverywhere(draft)
        let view = listView
        let projectId: String? = draft.projectId.hasPrefix("inbox") ? inboxId : draft.projectId
        let day = draft.startDate
        Task { [weak self] in
            let client = ForkTickTickAPIClient(token: token)
            do {
                var created: TaskItem
                if let projectId {
                    created = try await client.createTask(title: title, projectId: projectId, day: day)
                } else {
                    // The Inbox's id isn't known until one of its tasks has
                    // loaded. TickTick's "inbox" alias works in some calls;
                    // without a list, a task goes to the Inbox.
                    do {
                        created = try await client.createTask(title: title, projectId: "inbox", day: day)
                    } catch ForkTickTickAPIClient.ClientError.http(let code, let body) {
                        AppLogInfo("[ForkTickTick] create with the inbox alias failed (\(code) \(body)); retrying without a list")
                        created = try await client.createTask(title: title, projectId: nil, day: day)
                    }
                }
                guard let self else { return }
                if created.projectId.hasPrefix("inbox") { self.inboxId = created.projectId }
                created.localKey = id
                self.cache[view, default: []].removeAll { $0.id == created.id }
                self.cache[view, default: []].append(created)
                if let index = self.tasks.firstIndex(where: { $0.id == id }) {
                    // A refresh may have brought it in already.
                    self.tasks.removeAll { $0.id == created.id }
                    if let index = self.tasks.firstIndex(where: { $0.id == id }) {
                        self.tasks[index] = created
                    } else {
                        self.tasks.insert(created, at: min(index, self.tasks.count))
                    }
                }
            } catch {
                guard let self else { return }
                withAnimation(Self.listAnimation) { self.tasks.removeAll { $0.id == id } }
                self.changeFailed(error, message: NSLocalizedString("pinnedPreview.tasks.addFailed",
                    value: "Couldn't add the task", comment: "TickTick task card - notice when adding a task fails"))
            }
        }
    }

    /// Applies `change` to `task` in the card at once and saves it to
    /// TickTick; puts it back if TickTick refuses.
    func update(_ task: TaskItem, _ change: (inout TaskItem) -> Void) {
        guard let token else { return }
        var edited = current(task)
        change(&edited)
        let before = current(task)
        guard edited != before else { return }
        replaceEverywhere(edited)
        Task { [weak self] in
            do {
                let saved = try await ForkTickTickAPIClient(token: token).update(edited)
                self?.replaceEverywhere(saved)
            } catch {
                self?.replaceEverywhere(before)
                self?.changeFailed(error, message: NSLocalizedString("pinnedPreview.tasks.saveFailed",
                    value: "Couldn't save the change", comment: "TickTick task card - notice when editing a task fails"))
            }
        }
    }

    /// Sets the task's date: all day when `time` is false, nil for no date.
    func setDate(_ task: TaskItem, to date: Date?, time: Bool) {
        update(task) { task in
            guard let date else {
                task.startDate = nil
                task.dueDate = nil
                task.isAllDay = false
                return
            }
            let value = time ? date : Calendar.current.startOfDay(for: date)
            task.startDate = value
            task.dueDate = value
            task.isAllDay = !time
            task.timeZone = TimeZone.current.identifier
        }
    }

    func toggleItem(_ itemId: String, in task: TaskItem) {
        update(task) { task in
            guard var items = task.items, let index = items.firstIndex(where: { $0.id == itemId }) else { return }
            items[index].status = (items[index].status ?? 0) == 0 ? 1 : 0
            task.items = items
        }
    }

    func move(_ task: TaskItem, to projectId: String) {
        guard let token, projectId != task.projectId else { return }
        let before = current(task)
        var moved = before
        moved.projectId = projectId
        replaceEverywhere(moved)
        Task { [weak self] in
            do {
                try await ForkTickTickAPIClient(token: token).move(before, to: projectId)
            } catch {
                self?.replaceEverywhere(before)
                self?.changeFailed(error, message: NSLocalizedString("pinnedPreview.tasks.moveFailed",
                    value: "Couldn't move the task", comment: "TickTick task card - notice when moving a task to another list fails"))
            }
        }
    }

    /// Deletes the task (TickTick keeps it in its Trash).
    func delete(_ task: TaskItem) {
        guard let token else { return }
        completions.removeValue(forKey: task.id)?.cancel()
        ticked.remove(task.id)
        let task = current(task)
        let view = listView
        let index = tasks.firstIndex { $0.id == task.id }
        removeEverywhere(task.id)
        Task { [weak self] in
            do {
                try await ForkTickTickAPIClient(token: token).delete(task)
            } catch {
                guard let self else { return }
                if self.listView == view, let index {
                    withAnimation(Self.listAnimation) { self.tasks.insert(task, at: min(index, self.tasks.count)) }
                }
                self.cache[view, default: []].append(task)
                self.changeFailed(error, message: NSLocalizedString("pinnedPreview.tasks.deleteFailed",
                    value: "Couldn't delete the task", comment: "TickTick task card - notice when deleting a task fails"))
            }
        }
    }

    /// The card's latest copy of `task`.
    private func current(_ task: TaskItem) -> TaskItem {
        tasks.first { $0.id == task.id } ?? task
    }

    /// Puts `task` in place of its old copy, in the list and every cached
    /// view. It stays where it is until the next refresh, so a row being
    /// edited doesn't jump or vanish.
    private func replaceEverywhere(_ task: TaskItem) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task }
        for view in cache.keys {
            if let index = cache[view]?.firstIndex(where: { $0.id == task.id }) { cache[view]?[index] = task }
        }
        if task.projectId.hasPrefix("inbox") { inboxId = task.projectId }
    }

    private func removeEverywhere(_ id: String) {
        for view in cache.keys { cache[view]?.removeAll { $0.id == id } }
        withAnimation(Self.listAnimation) { tasks.removeAll { $0.id == id } }
    }

    var inboxProjectId: String { inboxId ?? "inbox" }

    // MARK: Token

    /// Checks `token` with TickTick and keeps it when accepted.
    func connect(token raw: String) async -> Bool {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)) }
        guard !token.isEmpty else { return false }
        do {
            _ = try await ForkTickTickAPIClient(token: token).projects()
        } catch {
            AppLogWarn("[ForkTickTick] token check failed: \(error)")
            return false
        }
        Self.writeToken(token)
        self.token = token
        status = .ready
        cache.removeAll()
        refreshedAt.removeAll()
        tasks = []
        hasLoaded = false
        refresh()
        return true
    }

    /// Forgets the token (the card asks for one again).
    func disconnect() {
        refreshTask?.cancel()
        completions.values.forEach { $0.cancel() }
        completions.removeAll()
        Self.deleteToken()
        token = nil
        status = .needsToken
        cache.removeAll()
        refreshedAt.removeAll()
        tasks = []
        projects = []
        ticked = []
        hasLoaded = false
        isRefreshing = false
        isOffline = false
    }

    // MARK: Lists

    private static func fetch(_ view: ListView, client: ForkTickTickAPIClient) async throws -> [TaskItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch view {
        case .today, .next7Days:
            let days = view == .today ? 1 : 7
            let end = calendar.date(byAdding: .day, value: days, to: today)!.addingTimeInterval(-1)
            async let inbox = try? client.openTasks(projectIds: ["inbox"], endDate: end)
            let all = try await client.openTasks(projectIds: nil, endDate: end)
            // Whether "all" covers the Inbox is not documented; ask for both.
            var seen = Set(all.map(\.id))
            return all + ((await inbox) ?? []).filter { seen.insert($0.id).inserted }
        case .inbox:
            return try await client.openTasks(projectIds: ["inbox"], endDate: nil)
        case .project(let id):
            return try await client.openTasks(projectIds: [id], endDate: nil)
        }
    }

    private static func keep(_ tasks: [TaskItem], for view: ListView) -> [TaskItem] {
        let open = tasks.filter { ($0.status ?? 0) == 0 }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch view {
        case .today:
            return open.filter { sectionDay(of: $0).map { $0 <= today } ?? false }
        case .next7Days:
            let end = calendar.date(byAdding: .day, value: 7, to: today)!
            return open.filter { sectionDay(of: $0).map { $0 < end } ?? false }
        case .inbox, .project:
            return open
        }
    }

    private static func ordered(_ tasks: [TaskItem], for view: ListView) -> [TaskItem] {
        switch view {
        case .today, .next7Days:
            return tasks.sorted { a, b in
                let (da, db) = (sectionDay(of: a) ?? .distantFuture, sectionDay(of: b) ?? .distantFuture)
                if da != db { return da < db }
                let (ta, tb) = (timeOfDay(a), timeOfDay(b))
                if ta != tb { return (ta ?? .distantFuture) < (tb ?? .distantFuture) }
                if (a.priority ?? 0) != (b.priority ?? 0) { return (a.priority ?? 0) > (b.priority ?? 0) }
                return (a.sortOrder ?? 0) < (b.sortOrder ?? 0)
            }
        case .inbox, .project:
            return tasks.sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
        }
    }

    /// The current view's tasks in sections: Overdue, Today, Tomorrow and
    /// weekdays for the date views; one section for a list.
    var sections: [Section] {
        // A subtask whose parent is in the list sits under it (in the
        // parent's section); one whose parent isn't shows on its own.
        let ids = Set(tasks.map(\.id))
        let isNested: (TaskItem) -> Bool = { task in task.parentId.map { ids.contains($0) && $0 != task.id } ?? false }
        let subtasks = Dictionary(grouping: tasks.filter(isNested), by: { $0.parentId ?? "" })
        let folded = foldedParents
        func rows(_ task: TaskItem, depth: Int) -> [Row] {
            let children = (subtasks[task.id] ?? []).sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
            var result = [Row(task: task, depth: depth, subtaskCount: children.count)]
            // TickTick nests subtasks at most five deep.
            guard !folded.contains(task.id), depth < 5 else { return result }
            for child in children { result += rows(child, depth: depth + 1) }
            return result
        }
        let topLevel = tasks.filter { !isNested($0) }
        switch listView {
        case .inbox, .project:
            return topLevel.isEmpty ? [] : [Section(id: "all", title: nil, rows: topLevel.flatMap { rows($0, depth: 0) })]
        case .today, .next7Days:
            let today = Calendar.current.startOfDay(for: Date())
            var order: [Date] = []
            var groups: [Date: [TaskItem]] = [:]
            for task in topLevel {
                guard let day = Self.sectionDay(of: task) else { continue }
                let key = day < today ? .distantPast : day
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(task)
            }
            return order.sorted().map { key in
                Section(id: key == .distantPast ? Self.overdueSectionId : "\(key.timeIntervalSince1970)",
                        title: Self.sectionTitle(key, today: today),
                        rows: (groups[key] ?? []).flatMap { rows($0, depth: 0) })
            }
        }
    }

    static let overdueSectionId = "overdue"

    private static func sectionTitle(_ day: Date, today: Date) -> String {
        if day == .distantPast {
            return NSLocalizedString("pinnedPreview.tasks.overdue", value: "Overdue",
                comment: "TickTick task card - section of tasks whose date has passed")
        }
        let calendar = Calendar.current
        if day == today {
            return NSLocalizedString("pinnedPreview.tasks.today", value: "Today",
                comment: "TickTick task card - section of tasks due today, and the Today view's name")
        }
        if calendar.isDateInTomorrow(day) {
            return NSLocalizedString("pinnedPreview.tasks.tomorrow", value: "Tomorrow",
                comment: "TickTick task card - section of tasks due tomorrow")
        }
        return weekdayFormatter.string(from: day)
    }

    func project(_ id: String) -> Project? { projects.first { $0.id == id } }

    func isInbox(_ projectId: String) -> Bool { projectId.hasPrefix("inbox") }

    var viewTitle: String { title(for: listView) }

    func title(for view: ListView) -> String {
        switch view {
        case .today:
            return NSLocalizedString("pinnedPreview.tasks.today", value: "Today",
                comment: "TickTick task card - section of tasks due today, and the Today view's name")
        case .next7Days:
            return NSLocalizedString("pinnedPreview.tasks.next7Days", value: "Next 7 Days",
                comment: "TickTick task card - view of tasks due in the coming week")
        case .inbox:
            return NSLocalizedString("pinnedPreview.tasks.inbox", value: "Inbox",
                comment: "TickTick task card - the TickTick Inbox list")
        case .project(let id):
            return project(id)?.name ?? NSLocalizedString("pinnedPreview.tasks.list", value: "List",
                comment: "TickTick task card - fallback name for a list whose name has not loaded")
        }
    }

    var showsDates: Bool {
        switch listView {
        case .today, .next7Days: return false
        case .inbox, .project: return true
        }
    }

    // MARK: Dates

    /// The local day a task is shown on: its start, or today while it runs
    /// across today; nil without a date. Overdue tasks (ended before today)
    /// keep their end day, which sorts before today.
    static func sectionDay(of task: TaskItem) -> Date? {
        guard let start = startDay(of: task) else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        let end = endDay(of: task) ?? start
        if end < today { return end }
        return max(start, today)
    }

    /// Whether the task ended before today (the Overdue section).
    static func isPastDay(_ task: TaskItem) -> Bool {
        guard let end = endDay(of: task) else { return false }
        return end < Calendar.current.startOfDay(for: Date())
    }

    /// Whether the task's day, or its time today, has passed (shown in red).
    static func isOverdue(_ task: TaskItem) -> Bool {
        let now = Date()
        guard let end = endDay(of: task) else { return false }
        if end < Calendar.current.startOfDay(for: now) { return true }
        if task.isAllDay != true, let due = task.dueDate ?? task.startDate { return due < now }
        return false
    }

    private static func startDay(of task: TaskItem) -> Date? {
        (task.startDate ?? task.dueDate).map { localDay($0, task) }
    }

    private static func endDay(of task: TaskItem) -> Date? {
        guard var end = task.dueDate ?? task.startDate else { return nil }
        // An all-day span ends at midnight after its last day.
        if task.isAllDay == true, let start = task.startDate, end > start { end.addTimeInterval(-1) }
        return localDay(end, task)
    }

    /// An all-day date is a day in the task's own time zone; a timed one
    /// falls on the local day.
    private static func localDay(_ date: Date, _ task: TaskItem) -> Date {
        let calendar = Calendar.current
        if task.isAllDay == true, let identifier = task.timeZone, let zone = TimeZone(identifier: identifier) {
            var taskCalendar = Calendar(identifier: .gregorian)
            taskCalendar.timeZone = zone
            let parts = taskCalendar.dateComponents([.year, .month, .day], from: date)
            return calendar.date(from: parts) ?? calendar.startOfDay(for: date)
        }
        return calendar.startOfDay(for: date)
    }

    private static func timeOfDay(_ task: TaskItem) -> Date? {
        task.isAllDay == true ? nil : (task.dueDate ?? task.startDate)
    }

    /// The row's date: a time for a timed task today, otherwise a day.
    static func dateText(_ task: TaskItem, showsDay: Bool) -> String? {
        guard let day = sectionDay(of: task) else { return nil }
        let calendar = Calendar.current
        let time = timeOfDay(task).map { timeFormatter.string(from: $0) }
        guard showsDay || !calendar.isDateInToday(day) else { return time }
        let dayText: String
        if calendar.isDateInToday(day) {
            dayText = NSLocalizedString("pinnedPreview.tasks.today", value: "Today",
                comment: "TickTick task card - section of tasks due today, and the Today view's name")
        } else if calendar.isDateInTomorrow(day) {
            dayText = NSLocalizedString("pinnedPreview.tasks.tomorrow", value: "Tomorrow",
                comment: "TickTick task card - section of tasks due tomorrow")
        } else if calendar.isDateInYesterday(day) {
            dayText = NSLocalizedString("pinnedPreview.tasks.yesterday", value: "Yesterday",
                comment: "TickTick task card - date shown for a task that was due yesterday")
        } else {
            dayText = dayFormatter.string(from: day)
        }
        return time.map { "\(dayText), \($0)" } ?? dayText
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMM")
        return formatter
    }()

    // MARK: Saved state

    private static func key(for view: ListView) -> String {
        switch view {
        case .today: return "today"
        case .next7Days: return "next7"
        case .inbox: return "inbox"
        case .project(let id): return "project:\(id)"
        }
    }

    private static func savedListView() -> ListView {
        switch UserDefaults.standard.string(forKey: ForkSettings.Key.tickTickCardView) {
        case "next7": return .next7Days
        case "inbox": return .inbox
        case let value? where value.hasPrefix("project:"): return .project(String(value.dropFirst(8)))
        default: return .today
        }
    }

    private static var tokenFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.bengutteridge.phiplus", isDirectory: true)
            .appendingPathComponent("ticktick-token")
    }

    private static func readToken() -> String? {
        guard let data = try? Data(contentsOf: tokenFile),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    private static func writeToken(_ token: String) {
        let file = tokenFile
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Created readable by the user alone, before the token is written.
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try? Data(token.utf8).write(to: file)
    }

    private static func deleteToken() {
        try? FileManager.default.removeItem(at: tokenFile)
    }
}
