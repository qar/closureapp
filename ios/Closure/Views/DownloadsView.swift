import SwiftUI

/// Google Drive downloads: overall progress and speed, then every file with its own
/// state. Failed files can be retried one by one or all together.
struct DownloadsView: View {
    @Environment(DriveDownloadManager.self) private var downloads
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                VStack(alignment: .leading, spacing: 0) {
                    Text("Downloads")
                        .font(Theme.serif(40))
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    MetaText("From Google Drive", size: 10.5).padding(.top, 6)
                    summary.padding(.top, 24)
                    if let job = downloads.job {
                        fileList(job)
                    }
                }
                .padding(.horizontal, Theme.horizontalMargin)
            }
            .padding(.bottom, 32)
        }
        .background(Theme.paper.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack {
            IconButton(systemName: "xmark", size: 18, weight: .semibold, label: "Close") { dismiss() }
            Spacer()
            if let job = downloads.job {
                Menu {
                    if job.isActive {
                        Button("Stop Downloads", systemImage: "stop.circle", role: .destructive) {
                            Task { await downloads.cancelRemaining() }
                        }
                    } else if !downloads.isImportingFiles {
                        Button("Clear List", systemImage: "xmark.circle") {
                            downloads.clearFinished()
                            dismiss()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("More")
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Summary

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            if downloads.isPreparing {
                Text("Looking through folders")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.ink)
                MetaText("\(downloads.preparedCount) file\(downloads.preparedCount == 1 ? "" : "s") found", size: 10)
                    .padding(.top, 8)
            } else if let job = downloads.job {
                HStack(alignment: .firstTextBaseline) {
                    Text(headline(job))
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    if job.isActive {
                        MetaText(speedText, size: 10.5, color: Theme.ink)
                    }
                }
                ProgressLine(fraction: job.fraction).padding(.top, 12)
                MetaText(detail(job), size: 10).padding(.top, 8)
                if job.failedCount > 0, !job.isActive || job.failedCount > 1 {
                    TextAction(title: "Retry All Failed", systemImage: "arrow.clockwise") {
                        Task { await downloads.retryAll() }
                    }
                    .padding(.top, 4)
                }
            } else if downloads.problem == nil {
                Text("Nothing is downloading.")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.muted)
            }
            if let problem = downloads.problem {
                VStack(alignment: .leading, spacing: 4) {
                    Text(problem)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let job = downloads.job, !job.isActive, job.items.contains(where: { $0.state == .done }) {
                        TextAction(title: "Add to Library Again", systemImage: "arrow.clockwise") {
                            Task { await downloads.importAgain() }
                        }
                    }
                }
                .padding(.top, 16)
            }
        }
    }

    private func headline(_ job: DownloadJob) -> String {
        let total = job.items.count
        if downloads.isImportingFiles { return "Adding to the library" }
        if job.isActive { return "\(job.finishedCount) of \(total) file\(total == 1 ? "" : "s")" }
        if job.failedCount > 0 { return "\(job.failedCount) of \(total) file\(total == 1 ? "" : "s") failed" }
        let added = downloads.importedAudioCount
        return added > 0 ? "\(added) track\(added == 1 ? "" : "s") added to the library" : "Done"
    }

    private func detail(_ job: DownloadJob) -> String {
        let received = ByteCountFormatter.string(fromByteCount: job.receivedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file)
        guard job.isActive else { return "\(total) downloaded" }
        var text = "\(received) of \(total)"
        let left = job.totalBytes - job.receivedBytes
        if downloads.bytesPerSecond > 0, left > 0 {
            text += " · " + Self.timeLeft(Double(left) / downloads.bytesPerSecond)
        }
        return text
    }

    private var speedText: String {
        downloads.bytesPerSecond > 0
            ? ByteCountFormatter.string(fromByteCount: Int64(downloads.bytesPerSecond), countStyle: .file) + "/s"
            : "Waiting"
    }

    static func timeLeft(_ seconds: Double) -> String {
        if seconds < 60 { return "under a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "about \(minutes) min left" }
        return String(format: "about %d h %02d min left", minutes / 60, minutes % 60)
    }

    // MARK: - Files

    /// Files grouped by the folder that was picked; single files last.
    private func fileList(_ job: DownloadJob) -> some View {
        let groups = Self.groups(job.items)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(groups, id: \.title) { group in
                HStack {
                    MetaText(group.title, size: 10, color: Theme.ink)
                    Spacer()
                    MetaText("\(group.items.filter(\.isFinished).count) / \(group.items.count)", size: 10)
                }
                .padding(.top, 32)
                .padding(.bottom, 10)
                Hairline()
                ForEach(group.items) { item in
                    DownloadRow(item: item, retryAt: downloads.retryAt[item.id]) {
                        Task { await downloads.retry(item.id) }
                    }
                    Hairline()
                }
            }
        }
    }

    static func groups(_ items: [DownloadItem]) -> [(title: String, items: [DownloadItem])] {
        var order: [String] = []
        var byTitle: [String: [DownloadItem]] = [:]
        for item in items {
            let top = item.relativePath.split(separator: "/").first.map(String.init) ?? ""
            let title = top == DownloadJob.looseFilesFolder ? "Single files" : top
            if byTitle[title] == nil { order.append(title) }
            byTitle[title, default: []].append(item)
        }
        order.sort { ($0 == "Single files" ? 1 : 0) < ($1 == "Single files" ? 1 : 0) }
        return order.map { ($0, byTitle[$0] ?? []) }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let retryAt: Date?
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(fileName)
                    .font(.system(size: 16))
                    .foregroundStyle(item.isFailed ? Theme.ink : (item.isFinished ? Theme.muted : Theme.ink))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let retryAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        MetaText("Retrying in \(max(0, Int(retryAt.timeIntervalSince(context.date).rounded()))) s · attempt \(item.attempts + 1) of \(RetryPolicy.maxAttempts)", size: 9.5, tracking: 0.8)
                    }
                } else {
                    MetaText(status, size: 9.5, color: item.isFailed ? Theme.ink : Theme.muted, tracking: 0.8)
                }
                if item.state == .downloading {
                    ProgressLine(fraction: fraction).padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// The file name, with the subfolder inside the album when there is one ("CD2 / 01.flac").
    private var fileName: String {
        let parts = item.relativePath.split(separator: "/").dropFirst()
        return parts.count > 1 ? parts.joined(separator: " / ") : item.name
    }

    private var fraction: Double {
        item.size > 0 ? min(1, Double(item.received) / Double(item.size)) : 0
    }

    private var status: String {
        let size = ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)
        switch item.state {
        case .queued: return "Waiting · \(size)"
        case .downloading:
            guard item.received > 0 else { return "Connecting · \(size)" }
            return "\(ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)) of \(size)"
        case .done: return "Downloaded · \(size)"
        case .imported: return "Added · \(size)"
        case let .failed(message): return "Failed · \(message)"
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.state {
        case .failed:
            Button(action: onRetry) {
                MetaText("Retry", size: 11, color: Theme.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 32)
                    .overlay(Capsule().stroke(Theme.ink, lineWidth: 1))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry \(item.name)")
        case .imported, .done:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
        case .downloading:
            MetaText("\(Int((fraction * 100).rounded(.down)))%", size: 10, color: Theme.ink)
        case .queued:
            EmptyView()
        }
    }
}

/// A 2 pt progress line on a hairline track.
struct ProgressLine: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.hairline)
                Rectangle().fill(Theme.ink).frame(width: proxy.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 2)
        .animation(.linear(duration: 0.25), value: fraction)
        .accessibilityHidden(true)
    }
}

/// The library's reminder that downloads are running or need attention. Opens the
/// Downloads page.
struct DownloadStrip: View {
    @Environment(DriveDownloadManager.self) private var downloads
    let onOpen: () -> Void

    static func isVisible(_ downloads: DriveDownloadManager) -> Bool {
        downloads.isWorking || (downloads.job?.failedCount ?? 0) > 0 || downloads.problem != nil
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 0) {
                ProgressLine(fraction: downloads.job?.isActive == true ? downloads.job?.fraction ?? 0 : 0)
                HStack(spacing: 8) {
                    if downloads.isWorking {
                        ProgressView().controlSize(.mini).tint(Theme.ink)
                    }
                    MetaText(text, size: 10, color: Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, Theme.horizontalMargin)
                .frame(minHeight: 44)
            }
            .background(Theme.paper2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Downloads, \(text)")
    }

    private var text: String {
        if downloads.isPreparing { return "Looking through folders · \(downloads.preparedCount) files" }
        if downloads.isImportingFiles { return "Adding to the library" }
        guard let job = downloads.job else { return downloads.problem == nil ? "Downloads" : "Download problem" }
        if job.isActive {
            var text = "Downloading \(job.finishedCount) / \(job.items.count)"
            if downloads.bytesPerSecond > 0 {
                text += " · " + ByteCountFormatter.string(fromByteCount: Int64(downloads.bytesPerSecond), countStyle: .file) + "/s"
            }
            return text
        }
        if job.failedCount > 0 { return "\(job.failedCount) download\(job.failedCount == 1 ? "" : "s") failed" }
        return downloads.problem == nil ? "Downloads finished" : "Download problem"
    }
}
