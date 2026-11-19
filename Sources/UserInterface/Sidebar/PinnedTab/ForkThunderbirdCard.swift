// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// Fork: the Gmail pinned tab's card when it shows Thunderbird's Unified
/// Inbox (`ForkThunderbirdMail`), laid out like Apple Mail's message list.
struct ForkThunderbirdCardView: View {
    @ObservedObject var mail: ForkThunderbirdMail
    @State private var isRefreshing = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: mail.messages) { _, _ in isRefreshing = false }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(NSLocalizedString("pinnedPreview.mail.title", value: "Inbox",
                    comment: "Thunderbird mail card - title above the Unified Inbox list"))
                    .font(.system(size: 15, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if mail.status == .connected || (mail.status == .connecting && mail.hasSnapshot) {
                Button(action: mail.compose) {
                    Image(systemName: "square.and.pencil")
                }
                .help(NSLocalizedString("pinnedPreview.mail.compose", value: "New Message",
                    comment: "Thunderbird mail card - button that starts a new message in Thunderbird"))
                Button {
                    isRefreshing = true
                    mail.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 6) { isRefreshing = false }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                                   value: isRefreshing)
                }
                .help(NSLocalizedString("pinnedPreview.mail.refresh", value: "Refresh",
                    comment: "Thunderbird mail card - button that reloads the message list"))
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    private var subtitle: String {
        let unread = mail.messages.filter { !$0.read }.count
        guard mail.status == .connected, mail.hasSnapshot, unread > 0 else {
            return NSLocalizedString("pinnedPreview.mail.subtitle", value: "Thunderbird",
                comment: "Thunderbird mail card - subtitle naming the app the mail comes from")
        }
        return String(format: NSLocalizedString("pinnedPreview.mail.unread", value: "%d unread",
            comment: "Thunderbird mail card - subtitle with the number of unread messages in the list"), unread)
    }

    @ViewBuilder
    private var content: some View {
        switch mail.status {
        case .connected, .connecting where mail.hasSnapshot:
            // While the add-on reconnects, the last list stays up.
            if !mail.hasSnapshot {
                ProgressView().controlSize(.small)
            } else if mail.messages.isEmpty {
                Text(NSLocalizedString("pinnedPreview.mail.empty", value: "No Mail",
                    comment: "Thunderbird mail card - shown when the inbox has no recent messages"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(mail.messages) { message in
                            ForkMailRow(message: message, mail: mail)
                            Divider().padding(.leading, 26)
                        }
                    }
                }
            }
        case .connecting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("pinnedPreview.mail.connecting", value: "Connecting to Thunderbird…",
                    comment: "Thunderbird mail card - shown while waiting for the Thunderbird add-on to connect"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .thunderbirdClosed:
            message(
                title: NSLocalizedString("pinnedPreview.mail.closed.title", value: "Thunderbird Isn't Open",
                    comment: "Thunderbird mail card - title when Thunderbird is not running"),
                detail: NSLocalizedString("pinnedPreview.mail.closed.detail", value: "Your inbox shows here while Thunderbird is running.",
                    comment: "Thunderbird mail card - explains that Thunderbird must be running"),
                button: NSLocalizedString("pinnedPreview.mail.closed.button", value: "Open Thunderbird",
                    comment: "Thunderbird mail card - button that opens Thunderbird"),
                action: mail.openThunderbird)
        case .needsAddon:
            if mail.isThunderbirdInstalled {
                // Opening the file with Thunderbird attaches it to a new
                // message instead of installing it, so the card shows the
                // file and the steps.
                message(
                    title: NSLocalizedString("pinnedPreview.mail.setup.title", value: "Connect Thunderbird",
                        comment: "Thunderbird mail card - title when the Phi+ add-on is not installed in Thunderbird yet"),
                    detail: NSLocalizedString("pinnedPreview.mail.setup.steps", value: "Install the small Phi+ Mail add-on: in Thunderbird, choose Tools ▸ Add-ons and Themes, click the gear button, choose Install Add-on From File, and pick the file this button shows.",
                        comment: "Thunderbird mail card - steps for installing the Phi+ add-on file in Thunderbird"),
                    button: NSLocalizedString("pinnedPreview.mail.setup.reveal", value: "Show Add-on File",
                        comment: "Thunderbird mail card - button that shows the add-on file in Finder, to install it in Thunderbird"),
                    action: mail.revealAddon)
            } else {
                message(
                    title: NSLocalizedString("pinnedPreview.mail.missing.title", value: "Thunderbird Isn't Installed",
                        comment: "Thunderbird mail card - title when Thunderbird is not installed"),
                    detail: NSLocalizedString("pinnedPreview.mail.missing.detail", value: "Install Thunderbird, or show the Gmail website in this card in Settings → Spaces.",
                        comment: "Thunderbird mail card - explains what to do when Thunderbird is not installed"),
                    button: nil, action: {})
            }
        }
    }

    private func message(title: String, detail: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let button {
                Button(button, action: action)
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 28)
    }
}

/// One message, as in Apple Mail: unread dot, bold sender with the date on
/// the right, subject, and two lines of preview.
private struct ForkMailRow: View {
    let message: ForkThunderbirdMail.Message
    let mail: ForkThunderbirdMail
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .opacity(message.read ? 0 : 1)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.senderName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.flagged {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text(Self.dateText(message.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(message.subject.isEmpty
                     ? NSLocalizedString("pinnedPreview.mail.noSubject", value: "(No Subject)",
                         comment: "Thunderbird mail card - shown for a message without a subject")
                     : message.subject)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if !message.preview.isEmpty {
                    Text(message.preview)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { mail.open(message) }
        .contextMenu {
            Button(message.read
                   ? NSLocalizedString("pinnedPreview.mail.markUnread", value: "Mark as Unread",
                       comment: "Thunderbird mail card - context menu item that marks the message unread")
                   : NSLocalizedString("pinnedPreview.mail.markRead", value: "Mark as Read",
                       comment: "Thunderbird mail card - context menu item that marks the message read")) {
                mail.setRead(message, !message.read)
            }
            Button(NSLocalizedString("pinnedPreview.mail.open", value: "Open in Thunderbird",
                comment: "Thunderbird mail card - context menu item that opens the message in Thunderbird")) {
                mail.open(message)
            }
        }
    }

    /// Apple Mail's dates: a time today, "Yesterday", a weekday this week,
    /// otherwise a short date.
    static func dateText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return timeFormatter.string(from: date) }
        if calendar.isDateInYesterday(date) {
            return NSLocalizedString("pinnedPreview.mail.yesterday", value: "Yesterday",
                comment: "Thunderbird mail card - date shown for a message from yesterday")
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: Date())).day, days < 7 {
            return weekdayFormatter.string(from: date)
        }
        return dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}
