import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TransfersFeatureScreen: View {
    @Environment(AppModel.self) private var app
    @State private var isImporting = false
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var transfers = app.transfers

        ScrollView {
            HStack {
                Spacer()

                Group {
                    switch transfers.selectedTab {
                    case .upload:
                        uploadWorkspace
                    case .download:
                        downloadWorkspace
                    }
                }
                .frame(maxWidth: 780, alignment: .top)
                .padding(.horizontal, 24)
                .padding(.top, 12)

                Spacer()
            }
        }
        .contentMargins(.bottom, PlayerOverlayMetrics.contentClearance, for: .scrollContent)
        .frame(maxWidth: .infinity)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(
                    String(localized: "Transfer Direction"),
                    selection: $transfers.selectedTab
                ) {
                    Text(String(localized: "Uploads"))
                        .tag(TransferDirection.upload)
                    Text(String(localized: "Downloads"))
                        .tag(TransferDirection.download)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(String(localized: "Transfer Direction"))
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if transfers.selectedTab == .upload {
                    Button {
                        isImporting = true
                    } label: {
                        Image(systemName: "icloud.and.arrow.up")
                    }
                    .help(String(localized: "Upload to Cloud"))
                    .accessibilityLabel(String(localized: "Upload to Cloud"))
                }

                if app.transfers.hasPendingJobs(in: transfers.selectedTab) {
                    Button {
                        app.transfers.cancel(transfers.selectedTab)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .help(String(localized: transfers.selectedTab == .upload ? "Cancel Uploads" : "Cancel Downloads"))
                    .accessibilityLabel(String(localized: transfers.selectedTab == .upload ? "Cancel Uploads" : "Cancel Downloads"))
                }

                if hasFinishedJobs(in: transfers.selectedTab) {
                    Button {
                        app.transfers.clearFinished(in: transfers.selectedTab)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(String(localized: "Clear Finished Transfers"))
                    .accessibilityLabel(String(localized: "Clear Finished Transfers"))
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
    }

    private var uploadWorkspace: some View {
        let jobs = jobs(for: .upload)

        return VStack(alignment: .leading, spacing: 16) {
            TransferSummaryView(direction: .upload, jobs: jobs)

            switch TransferWorkspaceMode.forJobs(jobs) {
            case .dropZone:
                UploadDropSurface(isTargeted: $isDropTargeted, acceptDrop: acceptDrop)
            case .list:
                UploadTaskListSurface(
                    jobs: jobs,
                    isTargeted: $isDropTargeted,
                    acceptDrop: acceptDrop,
                    retry: { app.transfers.retry($0) }
                )
            }
        }
    }

    private var downloadWorkspace: some View {
        let jobs = jobs(for: .download)

        return VStack(alignment: .leading, spacing: 16) {
            TransferSummaryView(direction: .download, jobs: jobs)

            if jobs.isEmpty {
                TransferEmptyState(direction: .download)
            } else {
                TransferListSurface(jobs: jobs, retry: { app.transfers.retry($0) })
            }
        }
    }

    private func jobs(for direction: TransferDirection) -> [TransferJob] {
        app.transfers.jobs.filter { $0.direction == direction }
    }

    private func hasFinishedJobs(in direction: TransferDirection) -> Bool {
        jobs(for: direction).contains { $0.phase.isFinished }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            app.transfers.enqueueUploads(TransferFileSelection.audioURLs(from: urls))
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                app.alerts.show(error.localizedDescription)
            }
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            let urls = await TransferFileSelection.urls(from: providers)
            app.transfers.enqueueUploads(TransferFileSelection.audioURLs(from: urls))
        }
        return true
    }
}

enum TransferWorkspaceMode: Equatable {
    case dropZone
    case list

    static func forJobs(_ jobs: [TransferJob]) -> Self {
        jobs.isEmpty ? .dropZone : .list
    }
}

struct TransferOverview: Equatable {
    let active: Int
    let completed: Int
    let failed: Int

    init(jobs: [TransferJob]) {
        self.init(phases: jobs.map(\.phase))
    }

    init(phases: [TransferPhase]) {
        active = phases.count(where: { !$0.isFinished })
        completed = phases.count(where: {
            if case .succeeded = $0 { return true }
            return false
        })
        failed = phases.count(where: {
            if case .failed = $0 { return true }
            return false
        })
    }
}

private struct TransferSummaryView: View {
    let direction: TransferDirection
    let jobs: [TransferJob]

    private var overview: TransferOverview {
        TransferOverview(jobs: jobs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 25))
                    .foregroundStyle(Color.accentColor)

                Text(String(localized: direction == .upload ? "Upload Queue" : "Download Queue"))
                    .font(.title2.weight(.semibold))

                Spacer(minLength: 12)

                HStack(spacing: 14) {
                    TransferMetric(value: overview.active, label: "Active", tint: .accentColor)
                    Divider().frame(height: 24)
                    TransferMetric(value: overview.completed, label: "Completed", tint: .secondary)
                    Divider().frame(height: 24)
                    TransferMetric(value: overview.failed, label: "Failed", tint: overview.failed == 0 ? .secondary : .red)
                }
            }

            Divider()
        }
    }
}

private struct TransferMetric: View {
    let value: Int
    let label: LocalizedStringKey
    let tint: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct UploadDropSurface: View {
    @Binding var isTargeted: Bool
    let acceptDrop: ([NSItemProvider]) -> Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text(String(localized: "Drop Audio Files Here"))
                .font(.title3.weight(.semibold))
            Text(String(localized: "Audio files only"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [7, 5])
                )
        }
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isTargeted,
            perform: acceptDrop
        )
    }
}

private struct UploadTaskListSurface: View {
    let jobs: [TransferJob]
    @Binding var isTargeted: Bool
    let acceptDrop: ([NSItemProvider]) -> Bool
    let retry: (UUID) -> Void

    var body: some View {
        ZStack {
            TransferListSurface(jobs: jobs, retry: retry)

            if isTargeted {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 34))
                    Text(String(localized: "Drop to Add Uploads"))
                        .font(.title3.weight(.semibold))
                    Text(String(localized: "Release to add audio files"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isTargeted,
            perform: acceptDrop
        )
    }
}

private struct TransferListSurface: View {
    let jobs: [TransferJob]
    let retry: (UUID) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                TransferJobRow(job: job, retry: { retry(job.id) })
                if index < jobs.count - 1 {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TransferEmptyState: View {
    let direction: TransferDirection

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(String(localized: direction == .upload ? "No Uploads Yet" : "No Downloads Yet"))
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 132)
    }
}

private struct TransferJobRow: View {
    let job: TransferJob
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(job.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(phaseText)
                        .font(.caption)
                        .foregroundStyle(phaseColor)
                }

                if case .running = job.phase {
                    if let fraction = job.progress?.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    HStack(spacing: 8) {
                        Text(stageText)
                        Spacer()
                        Text(progressText)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else if case .failed(let message) = job.phase {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(message)
                }
            }

            if isRetryable {
                Button(action: retry) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Retry Transfer"))
            }
        }
        .padding(.vertical, 12)
    }

    private var statusIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(phaseColor)
            .frame(width: 28, height: 28)
            .background(phaseColor.opacity(0.12), in: Circle())
    }

    private var iconName: String {
        switch job.phase {
        case .waiting: "clock"
        case .running: job.direction == .upload ? "arrow.up" : "arrow.down"
        case .succeeded: "checkmark"
        case .failed: "exclamationmark"
        case .cancelled: "slash"
        }
    }

    private var phaseText: String {
        switch job.phase {
        case .waiting: String(localized: "Waiting")
        case .running: stageText
        case .succeeded: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    private var phaseColor: Color {
        switch job.phase {
        case .waiting: .secondary
        case .running: .accentColor
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    private var isRetryable: Bool {
        switch job.phase {
        case .failed, .cancelled: true
        case .waiting, .running, .succeeded: false
        }
    }

    private var stageText: String {
        switch job.progress?.stage {
        case .preparing, nil: String(localized: "Preparing")
        case .transferring: String(localized: job.direction == .upload ? "Uploading" : "Downloading")
        case .finalizing: String(localized: "Finalizing")
        }
    }

    private var progressText: String {
        guard let progress = job.progress else { return "0%" }
        let percent = progress.fraction.map { "\(Int($0 * 100))%" } ?? ""
        guard let total = progress.totalBytes else {
            return ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
        }
        let completedText = ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file)
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(percent)  \(completedText) / \(totalText)"
    }
}

enum TransferFileSelection {
    static func audioURLs(from urls: [URL]) -> [URL] {
        urls.filter { url in
            guard url.isFileURL else { return false }
            if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
                return contentType.conforms(to: .audio)
            }
            return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
        }
    }

    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: URL?.self, returning: [URL].self) { group in
            for provider in providers {
                group.addTask {
                    await url(from: provider)
                }
            }
            var urls: [URL] = []
            for await url in group {
                if let url { urls.append(url) }
            }
            return urls
        }
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
