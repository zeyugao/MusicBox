import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TransfersFeatureScreen: View {
    @Environment(AppModel.self) private var app
    @State private var isImporting = false
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var transfers = app.transfers

        TabView(selection: $transfers.selectedTab) {
            uploadContent
                .tabItem {
                    Label(String(localized: "Uploads"), systemImage: "arrow.up.circle")
                }
                .tag(TransferDirection.upload)

            transferList(direction: .download)
                .tabItem {
                    Label(String(localized: "Downloads"), systemImage: "arrow.down.circle")
                }
                .tag(TransferDirection.download)
        }
        .padding(20)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
    }

    private var uploadContent: some View {
        VStack(spacing: 16) {
            Button {
                isImporting = true
            } label: {
                Label(String(localized: "Upload to Cloud"), systemImage: "icloud.and.arrow.up")
            }
            .controlSize(.large)

            VStack(spacing: 8) {
                Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                Text(String(localized: "Drop Audio Files Here"))
                    .font(.headline)
                Text(String(localized: "Audio files only"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                    )
            }
            .contentShape(Rectangle())
            .onDrop(
                of: [UTType.fileURL.identifier],
                isTargeted: $isDropTargeted,
                perform: acceptDrop
            )

            transferList(direction: .upload, maxHeight: 230)
        }
    }

    private func transferList(
        direction: TransferDirection,
        maxHeight: CGFloat = 360
    ) -> some View {
        let jobs = app.transfers.jobs.filter { $0.direction == direction }

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    String(localized: direction == .upload ? "Uploads" : "Downloads"),
                    systemImage: direction == .upload ? "arrow.up.circle" : "arrow.down.circle"
                )
                .font(.headline)
                Spacer()
                if app.transfers.hasPendingJobs(in: direction) {
                    Button {
                        app.transfers.cancel(direction)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: direction == .upload ? "Cancel Uploads" : "Cancel Downloads"))
                }
                Button {
                    app.transfers.clearFinished(in: direction)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Clear Finished Transfers"))
                .disabled(!jobs.contains(where: { $0.phase.isFinished }))
            }

            if jobs.isEmpty {
                Text(String(localized: "No Transfers"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(jobs) { job in
                            TransferJobRow(job: job, retry: { app.transfers.retry(job.id) })
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: maxHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct TransferJobRow: View {
    let job: TransferJob
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(job.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            status
                .frame(width: 260, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var status: some View {
        switch job.phase {
        case .waiting:
            Label(String(localized: "Waiting"), systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running:
            VStack(alignment: .trailing, spacing: 3) {
                if let fraction = job.progress?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                HStack(spacing: 6) {
                    Text(stageText)
                    Spacer()
                    Text(progressText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help(String(localized: "Transfer Completed"))
        case .failed(let message):
            HStack(spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(message)
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                retryButton
            }
        case .cancelled:
            HStack(spacing: 6) {
                Label(String(localized: "Cancelled"), systemImage: "slash.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                retryButton
            }
        }
    }

    private var retryButton: some View {
        Button(action: retry) {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Retry Transfer"))
    }

    private var stageText: String {
        switch job.progress?.stage {
        case .preparing, nil:
            String(localized: "Preparing")
        case .transferring:
            String(localized: job.direction == .upload ? "Uploading" : "Downloading")
        case .finalizing:
            String(localized: "Finalizing")
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
