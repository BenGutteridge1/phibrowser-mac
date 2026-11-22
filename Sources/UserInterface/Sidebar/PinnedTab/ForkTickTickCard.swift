// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Fork: the TickTick pinned tab's native card (`ForkTickTickTasks`), laid
/// out like Apple Reminders: a list picker, sections by day, round
/// checkboxes in the priority's color, subtasks under their parent, tasks
/// edited in place, and swipe left to delete.
///
/// A plain scrolling stack rather than a native `List`: a list only lets a
/// text field in a row take the cursor once the row is selected, which a
/// task's title and notes need without one. Swipe to delete is therefore the
/// card's own (`ForkTickTickSwipeRow`).
struct ForkTickTickCardView: View {
    @ObservedObject var tasks: ForkTickTickTasks
    /// Opens a TickTick web page in a new Phi+ tab.
    let openURL: (URL) -> Void
    /// Makes the card take the keyboard (it doesn't on its own until a text
    /// field is clicked).
    let takeKeyboard: () -> Void
    @State private var expandedId: String?

    var body: some View {
        Group {
            switch tasks.status {
            case .needsToken, .unauthorized:
                ForkTickTickConnectView(tasks: tasks, openURL: openURL)
            case .ready:
                VStack(spacing: 0) {
                    header
                    Divider()
                    if let notice = tasks.notice {
                        noticeBar(notice)
                        Divider()
                    } else if tasks.isOffline {
                        offlineBar
                        Divider()
                    }
                    list.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .clipped()
        .onChange(of: tasks.listView) { _, _ in expandedId = nil }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Menu {
                    viewMenu
                } label: {
                    HStack(spacing: 4) {
                        Text(tasks.viewTitle)
                            .font(.system(size: 15, weight: .bold))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: startNewTask) {
                Image(systemName: "plus")
            }
            .help(NSLocalizedString("pinnedPreview.tasks.new", value: "New Task",
                comment: "TickTick task card - button that adds a task to the list on screen"))
            Button(action: tasks.refresh) {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(tasks.isRefreshing ? 360 : 0))
                    .animation(tasks.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: tasks.isRefreshing)
            }
            .help(NSLocalizedString("pinnedPreview.tasks.refresh", value: "Refresh",
                comment: "TickTick task card - button that reloads the task list"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 9)
        .background { Color.clear.contentShape(Rectangle()).onTapGesture(perform: collapse) }
    }

    @ViewBuilder
    private var viewMenu: some View {
        Button(tasks.title(for: .today)) { tasks.select(.today) }
        Button(tasks.title(for: .next7Days)) { tasks.select(.next7Days) }
        Button(tasks.title(for: .inbox)) { tasks.select(.inbox) }
        if !tasks.projects.isEmpty {
            Divider()
            ForEach(tasks.projects) { project in
                Button(project.name) { tasks.select(.project(project.id)) }
            }
        }
        Divider()
        Button(NSLocalizedString("pinnedPreview.tasks.openWebsite", value: "Open TickTick",
            comment: "TickTick task card - menu item that opens the TickTick website in a tab")) {
            openURL(URL(string: "https://ticktick.com/webapp/")!)
        }
        Button(NSLocalizedString("pinnedPreview.tasks.disconnect", value: "Disconnect TickTick",
            comment: "TickTick task card - menu item that forgets the TickTick API token")) {
            tasks.disconnect()
        }
    }

    private var subtitle: String {
        let open = tasks.tasks.filter { !tasks.ticked.contains($0.id) && !ForkTickTickTasks.isDraft($0) }
        guard tasks.hasLoaded else {
            return NSLocalizedString("pinnedPreview.tasks.subtitle", value: "TickTick",
                comment: "TickTick task card - subtitle naming the app the tasks come from")
        }
        let overdue = open.filter(ForkTickTickTasks.isPastDay).count
        if overdue > 0, !tasks.showsDates {
            return String(format: NSLocalizedString("pinnedPreview.tasks.overdueCount", value: "%d overdue",
                comment: "TickTick task card - subtitle with the number of overdue tasks"), overdue)
        }
        return String(format: NSLocalizedString("pinnedPreview.tasks.count", value: "%d tasks",
            comment: "TickTick task card - subtitle with the number of tasks in the list"), open.count)
    }

    private var offlineBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("pinnedPreview.tasks.offline", value: "Couldn't reach TickTick.",
                comment: "TickTick task card - slim notice above the list when the last refresh failed"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button(NSLocalizedString("pinnedPreview.tasks.retry", value: "Try Again",
                comment: "TickTick task card - link that retries loading the tasks"), action: tasks.refresh)
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if !tasks.hasLoaded {
            ProgressView().controlSize(.small)
        } else if tasks.tasks.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(NSLocalizedString("pinnedPreview.tasks.empty", value: "No Tasks",
                    comment: "TickTick task card - shown when the chosen list has no open tasks"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(tasks.sections) { section in
                            Section {
                                ForEach(section.rows) { row in
                                    ForkTickTickSwipeRow(enabled: !ForkTickTickTasks.isDraft(row.task),
                                                         deleteTitle: ForkTickTickRow.deleteTitle,
                                                         onDelete: { tasks.delete(row.task) }) {
                                        ForkTickTickRow(task: row.task, depth: row.depth, subtaskCount: row.subtaskCount,
                                                        tasks: tasks, isExpanded: expandedId == row.task.id,
                                                        openURL: openURL, toggleExpanded: { toggle(row.task) })
                                    }
                                    .id(row.id)
                                    .transition(.opacity)
                                }
                            } header: {
                                if let title = section.title { sectionHeader(title, section: section) }
                            }
                        }
                        // Clicking below the tasks closes an open one.
                        Color.clear
                            .frame(height: 60)
                            .contentShape(Rectangle())
                            .onTapGesture { collapse() }
                    }
                }
                .onChange(of: tasks.draftId) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, section: ForkTickTickTasks.Section) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(section.id == ForkTickTickTasks.overdueSectionId ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 3)
            .background(.bar)
    }

    private func toggle(_ task: ForkTickTickTasks.TaskItem) {
        guard !ForkTickTickTasks.isDraft(task) else { return }
        endEditing()
        withAnimation(.easeOut(duration: 0.2)) { expandedId = expandedId == task.id ? nil : task.id }
    }

    private func collapse() {
        endEditing()
        guard expandedId != nil else { return }
        withAnimation(.easeOut(duration: 0.2)) { expandedId = nil }
    }

    /// A click elsewhere in the card ends typing (AppKit leaves a field
    /// editing when a click lands on something that takes no keyboard), so
    /// an edit is saved and an empty new task goes away.
    private func endEditing() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Adds a new task to the list on screen, its title ready to type.
    private func startNewTask() {
        collapse()
        takeKeyboard()
        tasks.startDraft()
    }
}

/// Swipe left on a task to show Delete, or swipe all the way to delete it at
/// once, as in Reminders. The row sits in a horizontal scroll view whose
/// stopping points are closed, Delete shown, and swiped through; vertical
/// scrolling passes on to the list. Needs macOS 15's scroll geometry; on
/// macOS 14 the row's menu and Delete button remain.
private struct ForkTickTickSwipeRow<Content: View>: View {
    let enabled: Bool
    let deleteTitle: String
    let onDelete: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 15.0, *), enabled {
            ForkTickTickSwipeScroller(deleteTitle: deleteTitle, onDelete: onDelete, content: content)
        } else {
            content()
        }
    }
}

@available(macOS 15.0, *)
private struct ForkTickTickSwipeScroller<Content: View>: View {
    let deleteTitle: String
    let onDelete: () -> Void
    let content: () -> Content
    @State private var position = ScrollPosition(edge: .leading)
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 340
    @State private var deleted = false

    /// How much of Delete shows when the row stops open.
    static var revealWidth: CGFloat { 74 }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                content()
                    .containerRelativeFrame(.horizontal)
                    .overlay {
                        // While open, a click on the task closes it.
                        if offset > 1 {
                            Color.clear.contentShape(Rectangle()).onTapGesture(perform: close)
                        }
                    }
                Color.clear
                    .frame(width: width, height: 1)
            }
            .background(alignment: .trailing) {
                Color.red
                    .frame(width: width)
                    .overlay(alignment: .leading) {
                        VStack(spacing: 2) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 13))
                            Text(deleteTitle)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .frame(width: Self.revealWidth)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(perform: delete)
            }
        }
        .scrollIndicators(.never)
        .scrollPosition($position)
        .scrollTargetBehavior(ForkTickTickSwipeSnap(revealWidth: Self.revealWidth))
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in offset = x }
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.containerSize.width }) { _, w in
            if w > 0 { width = w }
        }
        .onScrollPhaseChange { _, phase in
            // A swipe that ends past halfway deletes.
            if phase == .idle, offset > width * 0.5 { delete() }
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .leading) }
    }

    private func delete() {
        guard !deleted else { return }
        deleted = true
        onDelete()
    }
}

/// Where a swiped row comes to rest: closed, Delete shown, or (past halfway)
/// swiped through to delete.
private struct ForkTickTickSwipeSnap: ScrollTargetBehavior {
    let revealWidth: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let x = target.rect.minX
        let width = context.containerSize.width
        if x > width * 0.5 {
            target.rect.origin.x = width
        } else if x > revealWidth * 0.5 {
            target.rect.origin.x = revealWidth
        } else {
            target.rect.origin.x = 0
        }
    }
}

/// One task, as in Reminders: a round checkbox in the priority's color, the
/// title, and a line with its date, list and markers; subtasks are indented
/// under their parent, which can fold them away. Opened (clicked), its title
/// and notes can be edited in place, with its date, priority, list and
/// checklist below. A new task (`ForkTickTickTasks.startDraft`) starts with
/// its title being typed.
private struct ForkTickTickRow: View {
    let task: ForkTickTickTasks.TaskItem
    let depth: Int
    let subtaskCount: Int
    @ObservedObject var tasks: ForkTickTickTasks
    let isExpanded: Bool
    let openURL: (URL) -> Void
    let toggleExpanded: () -> Void
    @State private var isHovering = false
    @State private var title = ""
    @State private var notes = ""
    @State private var choosingDate = false
    @FocusState private var field: Field?

    private enum Field { case title, notes }

    private var isTicked: Bool { tasks.ticked.contains(task.id) }
    /// A new task: being typed, or on its way to TickTick.
    private var isNew: Bool { ForkTickTickTasks.isDraft(task) }
    private var isTyping: Bool { isNew && tasks.draftId == task.id }
    private var indent: CGFloat { CGFloat(depth) * 22 }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button { tasks.toggleComplete(task) } label: { checkbox }
                .buttonStyle(.plain)
                .disabled(isNew)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if isTyping {
                    titleField
                } else if isExpanded {
                    editor
                } else {
                    Text(displayTitle)
                        .font(.system(size: 13))
                        .strikethrough(isTicked, color: .secondary)
                        .foregroundStyle(isTicked || isNew ? Color.secondary : Color.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    details
                }
            }
            Spacer(minLength: 0)
            if subtaskCount > 0 {
                Button { tasks.toggleSubtasks(of: task.id) } label: {
                    HStack(spacing: 3) {
                        Text("\(subtaskCount)")
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(tasks.foldedParents.contains(task.id) ? 0 : 90))
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("pinnedPreview.tasks.subtasks", value: "Show or Hide Subtasks",
                    comment: "TickTick task card - button on a task that folds or unfolds its subtasks"))
                .padding(.top, 1)
            }
        }
        .padding(.leading, 14 + indent)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .background {
            // Clicks on the row's empty space open or close it; text,
            // fields and buttons above keep their own.
            Rectangle()
                .fill(isHovering && !isExpanded && !isTyping ? Color.primary.opacity(0.06) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture(perform: toggleExpanded)
        }
        .overlay(alignment: .bottom) {
            // A drawn line: a Divider inside the swipe row's horizontal
            // stack would turn vertical.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .padding(.leading, 40 + indent)
        }
        .contentShape(Rectangle())
        // A click on the closed row's text opens it too.
        .gesture(TapGesture().onEnded(toggleExpanded), including: isExpanded || isTyping ? .subviews : .all)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isTicked)
        .onAppear {
            loadFields()
            if isTyping { DispatchQueue.main.async { field = .title } }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded { loadFields() } else { saveFields() }
        }
        .onChange(of: field) { old, _ in
            guard old != nil else { return }
            if isTyping {
                tasks.finishDraft(title: title)
            } else {
                saveFields()
            }
        }
        .contextMenu {
            if !isNew {
                Button(isTicked
                       ? NSLocalizedString("pinnedPreview.tasks.untick", value: "Mark as Not Completed",
                           comment: "TickTick task card - context menu item that unticks a task before it is completed")
                       : NSLocalizedString("pinnedPreview.tasks.complete", value: "Complete",
                           comment: "TickTick task card - context menu item that completes the task")) {
                    tasks.toggleComplete(task)
                }
                Button(NSLocalizedString("pinnedPreview.tasks.openTask", value: "Open in TickTick",
                    comment: "TickTick task card - opens the task on the TickTick website in a tab")) {
                    openURL(webURL)
                }
                Divider()
                Button(Self.deleteTitle, role: .destructive) { tasks.delete(task) }
            }
        }
    }

    static var deleteTitle: String {
        NSLocalizedString("pinnedPreview.tasks.delete", value: "Delete",
            comment: "TickTick task card - swipe, menu and button action that deletes the task")
    }

    private var displayTitle: String {
        let text = task.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? NSLocalizedString("pinnedPreview.tasks.untitled", value: "Untitled",
            comment: "TickTick task card - shown for a task without a title") : text
    }

    private var webURL: URL {
        URL(string: "https://ticktick.com/webapp/#p/\(task.projectId)/tasks/\(task.id)")
            ?? URL(string: "https://ticktick.com/webapp/")!
    }

    // MARK: Editing

    private func loadFields() {
        title = task.title ?? ""
        notes = notesText
    }

    /// Saves the title and notes if they changed. An emptied title keeps the
    /// old one.
    private func saveFields() {
        guard !isNew else { return }
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleChanged = !newTitle.isEmpty && newTitle != (task.title ?? "")
        let notesChanged = newNotes != notesText
        if newTitle.isEmpty { title = task.title ?? "" }
        guard titleChanged || notesChanged else { return }
        tasks.update(task) { task in
            if titleChanged { task.title = newTitle }
            if notesChanged { task.content = newNotes }
        }
    }

    private var titleField: some View {
        TextField("", text: $title, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($field, equals: .title)
            .onSubmit { field = nil }
            .onExitCommand {
                if isTyping { title = "" }
                field = nil
            }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleField
            notesEditor
            checklist
            controls
        }
        .padding(.bottom, 2)
        .transition(.opacity)
    }

    /// The notes, in a text view so Return starts a new line (a text field's
    /// Return ends editing). It grows with its text; the card scrolls.
    private var notesEditor: some View {
        ZStack(alignment: .topLeading) {
            // Sizes the editor to its text, with room for a last empty line.
            Text(notes.isEmpty || notes.hasSuffix("\n") ? notes + " " : notes)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
            if notes.isEmpty {
                Text(NSLocalizedString("pinnedPreview.tasks.notes", value: "Notes",
                    comment: "TickTick task card - placeholder of a task's notes field"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $notes)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .scrollContentBackground(.hidden)
                // Its own scrolling would hold on to the wheel over the
                // notes; the card's list scrolls instead.
                .scrollDisabled(true)
                // The text view's line padding, so the text lines up with
                // the title.
                .padding(.horizontal, -5)
                .focused($field, equals: .notes)
        }
    }

    @ViewBuilder
    private var checklist: some View {
        let items = (task.items ?? []).sorted { ($0.sortOrder ?? 0) < ($1.sortOrder ?? 0) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items) { item in
                    let done = (item.status ?? 0) != 0
                    Button { tasks.toggleItem(item.id, in: task) } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: done ? "checkmark.square.fill" : "square")
                                .font(.system(size: 11))
                                .foregroundStyle(done ? Color.accentColor : Color.secondary)
                                .padding(.top, 1)
                            Text(item.title ?? "")
                                .font(.system(size: 12))
                                .strikethrough(done, color: .secondary)
                                .foregroundStyle(done ? Color.secondary : Color.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Date, priority and list, as small menus, then open and delete.
    private var controls: some View {
        HStack(spacing: 6) {
            Menu {
                dateMenu
            } label: {
                chip(systemImage: "calendar",
                     text: ForkTickTickTasks.dateText(task, showsDay: true)
                        ?? NSLocalizedString("pinnedPreview.tasks.addDate", value: "Add Date",
                            comment: "TickTick task card - date button of a task without a date"),
                     tint: ForkTickTickTasks.isOverdue(task) ? .red : nil)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .popover(isPresented: $choosingDate, arrowEdge: .bottom) {
                ForkTickTickDatePicker(task: task) { date, time in
                    choosingDate = false
                    tasks.setDate(task, to: date, time: time)
                }
            }
            Menu {
                priorityMenu
            } label: {
                chip(systemImage: (task.priority ?? 0) > 0 ? "flag.fill" : "flag", text: nil,
                     tint: (task.priority ?? 0) > 0 ? priorityColor : nil)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help(NSLocalizedString("pinnedPreview.tasks.priority", value: "Priority",
                comment: "TickTick task card - menu that sets a task's priority"))
            Menu {
                listMenu
            } label: {
                chip(systemImage: nil, text: listName, tint: nil, dot: listColor)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            Spacer(minLength: 0)
            Button { openURL(webURL) } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("pinnedPreview.tasks.openTask", value: "Open in TickTick",
                comment: "TickTick task card - opens the task on the TickTick website in a tab"))
            Button { tasks.delete(task) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(Self.deleteTitle)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func chip(systemImage: String?, text: String?, tint: Color?, dot: Color? = nil) -> some View {
        HStack(spacing: 3) {
            if let dot {
                Circle().fill(dot).frame(width: 6, height: 6)
            }
            if let systemImage { Image(systemName: systemImage) }
            if let text { Text(text).lineLimit(1) }
        }
        .font(.system(size: 11))
        .foregroundStyle(tint ?? Color.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .contentShape(Capsule())
    }

    @ViewBuilder
    private var dateMenu: some View {
        let today = Calendar.current.startOfDay(for: Date())
        Button(NSLocalizedString("pinnedPreview.tasks.today", value: "Today",
            comment: "TickTick task card - section of tasks due today, and the Today view's name")) {
            tasks.setDate(task, to: today, time: false)
        }
        Button(NSLocalizedString("pinnedPreview.tasks.tomorrow", value: "Tomorrow",
            comment: "TickTick task card - section of tasks due tomorrow")) {
            tasks.setDate(task, to: Calendar.current.date(byAdding: .day, value: 1, to: today), time: false)
        }
        Button(NSLocalizedString("pinnedPreview.tasks.nextWeek", value: "Next Week",
            comment: "TickTick task card - date menu item that moves a task a week ahead")) {
            tasks.setDate(task, to: Calendar.current.date(byAdding: .day, value: 7, to: today), time: false)
        }
        Button(NSLocalizedString("pinnedPreview.tasks.chooseDate", value: "Choose Date…",
            comment: "TickTick task card - date menu item that opens a calendar to pick a date and time")) {
            choosingDate = true
        }
        if task.startDate != nil || task.dueDate != nil {
            Divider()
            Button(NSLocalizedString("pinnedPreview.tasks.noDate", value: "No Date",
                comment: "TickTick task card - date menu item that removes a task's date")) {
                tasks.setDate(task, to: nil, time: false)
            }
        }
    }

    @ViewBuilder
    private var priorityMenu: some View {
        ForEach([(5, NSLocalizedString("pinnedPreview.tasks.priority.high", value: "High",
                    comment: "TickTick task card - high priority")),
                 (3, NSLocalizedString("pinnedPreview.tasks.priority.medium", value: "Medium",
                    comment: "TickTick task card - medium priority")),
                 (1, NSLocalizedString("pinnedPreview.tasks.priority.low", value: "Low",
                    comment: "TickTick task card - low priority")),
                 (0, NSLocalizedString("pinnedPreview.tasks.priority.none", value: "None",
                    comment: "TickTick task card - no priority"))], id: \.0) { value, name in
            Button {
                tasks.update(task) { $0.priority = value }
            } label: {
                if (task.priority ?? 0) == value {
                    Label(name, systemImage: "checkmark")
                } else {
                    Text(name)
                }
            }
        }
    }

    @ViewBuilder
    private var listMenu: some View {
        Button(tasks.title(for: .inbox)) { tasks.move(task, to: tasks.inboxProjectId) }
        if !tasks.projects.isEmpty {
            Divider()
            ForEach(tasks.projects) { project in
                Button(project.name) { tasks.move(task, to: project.id) }
            }
        }
    }

    private var listName: String {
        tasks.project(task.projectId)?.name ?? tasks.title(for: .inbox)
    }

    private var listColor: Color? {
        tasks.project(task.projectId).flatMap { Color(tickTickHex: $0.color) }
    }

    // MARK: Look

    /// TickTick's priority colors: high red, medium orange, low blue.
    private var priorityColor: Color {
        switch task.priority ?? 0 {
        case 5: return Color(red: 0.84, green: 0.17, blue: 0.14)
        case 3: return Color(red: 0.98, green: 0.66, blue: 0.05)
        case 1: return Color(red: 0.28, green: 0.45, blue: 0.98)
        default: return Color.secondary.opacity(0.7)
        }
    }

    private var checkbox: some View {
        ZStack {
            Circle()
                .strokeBorder(isTicked ? Color.accentColor : priorityColor, lineWidth: 1.5)
            if isTicked {
                Circle()
                    .fill(Color.accentColor)
                    .padding(3.5)
                    .transition(.scale.combined(with: .opacity))
            } else if (task.priority ?? 0) > 0 {
                Circle().fill(priorityColor.opacity(0.12))
            }
        }
        .frame(width: 17, height: 17)
        .contentShape(Circle())
    }

    @ViewBuilder
    private var details: some View {
        let date = ForkTickTickTasks.dateText(task, showsDay: tasks.showsDates)
        let project = tasks.project(task.projectId)
        // Subtasks share their parent's list; only top-level tasks name it.
        let showsList = !tasks.showsDates && depth == 0
        let checklist = task.items ?? []
        if date != nil || (showsList && (project != nil || tasks.isInbox(task.projectId)))
            || task.repeatFlag?.isEmpty == false || !checklist.isEmpty || !notesText.isEmpty {
            HStack(spacing: 6) {
                if let date {
                    Text(date)
                        .foregroundStyle(ForkTickTickTasks.isOverdue(task) ? Color.red : Color.secondary)
                }
                if task.repeatFlag?.isEmpty == false {
                    Image(systemName: "repeat")
                }
                if !checklist.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: "checklist")
                        Text("\(checklist.filter { ($0.status ?? 0) != 0 }.count)/\(checklist.count)")
                    }
                }
                if !notesText.isEmpty {
                    Image(systemName: "note.text")
                }
                if showsList {
                    if let project {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Color(tickTickHex: project.color) ?? Color.secondary)
                                .frame(width: 6, height: 6)
                            Text(project.name).lineLimit(1)
                        }
                    } else if tasks.isInbox(task.projectId) {
                        Text(tasks.title(for: .inbox))
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private var notesText: String {
        let text = (task.content?.isEmpty == false ? task.content : task.desc) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A calendar for a task's date, with an optional time.
private struct ForkTickTickDatePicker: View {
    let task: ForkTickTickTasks.TaskItem
    let choose: (Date, Bool) -> Void
    @State private var date: Date
    @State private var hasTime: Bool

    init(task: ForkTickTickTasks.TaskItem, choose: @escaping (Date, Bool) -> Void) {
        self.task = task
        self.choose = choose
        let current = task.startDate ?? task.dueDate
        let hasTime = current != nil && task.isAllDay != true
        // Without a time yet, offer the next whole hour.
        let fallback = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0),
                                                 matchingPolicy: .nextTime) ?? Date()
        _date = State(initialValue: current ?? fallback)
        _hasTime = State(initialValue: hasTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Toggle(NSLocalizedString("pinnedPreview.tasks.time", value: "Time",
                    comment: "TickTick task card - toggle that gives a task a time of day"), isOn: $hasTime)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Spacer()
                if hasTime {
                    DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .fixedSize()
                }
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("pinnedPreview.tasks.setDate", value: "Done",
                    comment: "TickTick task card - button that applies the picked date")) {
                    choose(date, hasTime)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 250)
    }
}

/// Asks for the user's TickTick API token, the first time and when TickTick
/// stops accepting it.
private struct ForkTickTickConnectView: View {
    @ObservedObject var tasks: ForkTickTickTasks
    let openURL: (URL) -> Void
    @State private var token = ""
    @State private var isChecking = false
    @State private var wasRefused = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(NSLocalizedString("pinnedPreview.tasks.connect.title", value: "Connect TickTick",
                comment: "TickTick task card - title of the screen that asks for a TickTick API token"))
                .font(.system(size: 14, weight: .semibold))
            Text(NSLocalizedString("pinnedPreview.tasks.connect.steps", value: "In TickTick on the web, open Settings ▸ Account ▸ API Token, create a token and paste it here. It stays on this Mac.",
                comment: "TickTick task card - steps for creating a TickTick API token"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if tasks.status == .unauthorized || wasRefused {
                Text(NSLocalizedString("pinnedPreview.tasks.connect.refused", value: "TickTick didn't accept the token. Create a new one and paste it here.",
                    comment: "TickTick task card - shown when TickTick refuses the API token"))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                SecureField(NSLocalizedString("pinnedPreview.tasks.connect.field", value: "API Token",
                    comment: "TickTick task card - placeholder of the field for the TickTick API token"), text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(connect)
                if isChecking {
                    ProgressView().controlSize(.small)
                } else {
                    Button(NSLocalizedString("pinnedPreview.tasks.connect.button", value: "Connect",
                        comment: "TickTick task card - button that checks and saves the API token"), action: connect)
                        .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.top, 4)
            Button(NSLocalizedString("pinnedPreview.tasks.connect.open", value: "Open TickTick Settings",
                comment: "TickTick task card - link that opens TickTick's website in a tab, to create a token")) {
                openURL(URL(string: "https://ticktick.com/webapp/#settings/account")!)
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            Text(NSLocalizedString("pinnedPreview.tasks.connect.website", value: "Or show the TickTick website in this card in Settings → Spaces.",
                comment: "TickTick task card - hint that the card can show the TickTick website instead"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() {
        guard !isChecking else { return }
        isChecking = true
        wasRefused = false
        Task {
            let accepted = await tasks.connect(token: token)
            isChecking = false
            wasRefused = !accepted
            if accepted { token = "" }
        }
    }
}

private extension Color {
    /// A "#RRGGBB" color, as TickTick gives lists.
    init?(tickTickHex hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
