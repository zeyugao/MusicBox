import AppKit
import Observation
import SwiftUI

struct CloudFilesFeatureScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: CloudFilesFeatureModel
    @State private var fileToMatch: CloudMusicApi.CloudFile?

    init(repository: any MusicRepository) {
        _model = State(initialValue: CloudFilesFeatureModel(repository: repository))
    }

    var body: some View {
        ZStack {
            CloudFilesTable(
                files: model.filteredFiles,
                isFiltering: !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                onLoadMore: model.loadMore,
                onMatch: { fileToMatch = $0 },
                onUnmatch: unmatch
            )
            .searchable(
                text: Binding(get: { model.query }, set: { model.updateQuery($0) }),
                prompt: "Search by file name or song name"
            )

            if model.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial.opacity(0.3))
            }
        }
        .task { model.load() }
        .sheet(item: $fileToMatch) { file in
            CloudFileMatchSheet(
                cloudFile: file,
                playlists: app.account.playlists,
                repository: app.repository,
                match: { songID in await match(file, to: songID) }
            )
        }
    }

    private func unmatch(_ file: CloudMusicApi.CloudFile) {
        Task { await match(file, to: 0) }
    }

    private func match(_ file: CloudMusicApi.CloudFile, to songID: UInt64) async {
        guard let userID = app.account.profile?.userId else { return }
        do {
            try await model.match(file, to: songID, userID: userID)
        } catch {
            app.alerts.show(error.localizedDescription)
        }
    }
}

@MainActor
@Observable
private final class CloudFileMatchFeatureModel {
    private let repository: any MusicRepository
    private var task: Task<Void, Never>?

    var selectedPlaylist: CloudMusicApi.PlayListItem?
    var songs: [CloudMusicApi.Song] = []
    var isLoading = false
    var errorMessage: String?
    var playlistQuery = ""
    var songQuery = ""

    init(repository: any MusicRepository) {
        self.repository = repository
    }

    func select(_ playlist: CloudMusicApi.PlayListItem?) {
        selectedPlaylist = playlist
        songs = []
        errorMessage = nil
        guard let playlist else { return }
        task?.cancel()
        isLoading = true
        task = Task { [weak self, repository] in
            let detail = await repository.playlistDetail(id: playlist.id)
            guard let self, !Task.isCancelled else { return }
            self.songs = detail?.tracks ?? []
            self.isLoading = false
            if detail == nil {
                self.errorMessage = "Unable to load playlist"
            }
        }
    }

    func cancel() {
        task?.cancel()
    }
}

private struct CloudFileMatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: CloudFileMatchFeatureModel
    let cloudFile: CloudMusicApi.CloudFile
    let playlists: [CloudMusicApi.PlayListItem]
    let match: (UInt64) async -> Void
    @State private var selectedSong: CloudMusicApi.Song?
    @State private var isMatching = false

    init(
        cloudFile: CloudMusicApi.CloudFile,
        playlists: [CloudMusicApi.PlayListItem],
        repository: any MusicRepository,
        match: @escaping (UInt64) async -> Void
    ) {
        self.cloudFile = cloudFile
        self.playlists = playlists
        self.match = match
        _model = State(initialValue: CloudFileMatchFeatureModel(repository: repository))
    }

    private var filteredPlaylists: [CloudMusicApi.PlayListItem] {
        let query = model.playlistQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? playlists : playlists.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var filteredSongs: [CloudMusicApi.Song] {
        let query = model.songQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? model.songs : model.songs.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.ar.compactMap(\.name).joined(separator: ", ").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Search playlists", text: $model.playlistQuery)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                if filteredPlaylists.isEmpty {
                    ContentUnavailableView("No matching playlists", systemImage: "magnifyingglass")
                } else {
                    List(
                        filteredPlaylists,
                        selection: Binding(
                            get: { model.selectedPlaylist },
                            set: { model.select($0) }
                        )
                    ) { playlist in
                        CloudMatchPlaylistRow(playlist: playlist)
                            .tag(playlist)
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationTitle("Select Playlist")
        } detail: {
            VStack(spacing: 0) {
                if let playlist = model.selectedPlaylist {
                    HStack {
                        Text(playlist.name)
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Button("Match") {
                            guard let selectedSong else { return }
                            isMatching = true
                            Task {
                                await match(selectedSong.id)
                                isMatching = false
                                dismiss()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedSong == nil || isMatching)
                    }
                    .padding(16)
                    TextField("Search songs", text: $model.songQuery)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                    if model.isLoading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = model.errorMessage {
                        ContentUnavailableView("Unable to load playlist", systemImage: "exclamationmark.triangle", description: Text(error))
                    } else {
                        List(filteredSongs, selection: $selectedSong) { song in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.name)
                                Text(song.ar.compactMap(\.name).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(song)
                        }
                    }
                } else {
                    ContentUnavailableView("Select a playlist", systemImage: "music.note.list")
                }
            }
            .navigationTitle("Match \(cloudFile.fileName)")
        }
        .frame(width: 900, height: 620)
        .onDisappear { model.cancel() }
    }
}

private struct CloudMatchPlaylistRow: View {
    let playlist: CloudMusicApi.PlayListItem

    var body: some View {
        HStack(spacing: 8) {
            AsyncImage(url: URL(string: playlist.coverImgUrl.https)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.gray.opacity(0.2)
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.name).lineLimit(1)
                Text("\((playlist.trackCount ?? 0) + (playlist.cloudTrackCount ?? 0))首 • \(playlist.creator.nickname)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct CloudFilesTable: NSViewControllerRepresentable {
    let files: [CloudMusicApi.CloudFile]
    let isFiltering: Bool
    let onLoadMore: () -> Void
    let onMatch: (CloudMusicApi.CloudFile) -> Void
    let onUnmatch: (CloudMusicApi.CloudFile) -> Void

    func makeNSViewController(context _: Context) -> CloudFilesTableViewController {
        CloudFilesTableViewController()
    }

    func updateNSViewController(_ controller: CloudFilesTableViewController, context _: Context) {
        controller.files = files
        controller.isFiltering = isFiltering
        controller.onLoadMore = onLoadMore
        controller.onMatch = onMatch
        controller.onUnmatch = onUnmatch
        controller.refresh()
    }
}

private final class CloudFilesTableViewController: NSViewController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    var files: [CloudMusicApi.CloudFile] = []
    var isFiltering = false
    var onLoadMore: (() -> Void)?
    var onMatch: ((CloudMusicApi.CloudFile) -> Void)?
    var onUnmatch: ((CloudMusicApi.CloudFile) -> Void)?

    override func loadView() {
        view = NSView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addColumn(id: "status", title: "", width: 16, min: 16, max: 16)
        addColumn(id: "name", title: "File Name", width: 300, min: 80, max: nil)
        addColumn(id: "info", title: "Matched Song", width: 300, min: 80, max: nil)
        addColumn(id: "size", title: "Size", width: 80, min: 40, max: 100)
    }

    func refresh() { tableView.reloadData() }

    private func addColumn(id: String, title: String, width: CGFloat, min: CGFloat, max: CGFloat?) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = min
        if let max { column.maxWidth = max; column.resizingMask = [] }
        tableView.addTableColumn(column)
    }

    @objc private func contentBoundsDidChange() {
        guard !isFiltering else { return }
        let visible = scrollView.documentVisibleRect
        guard tableView.bounds.height > 0, visible.maxY >= tableView.bounds.height - 300 else { return }
        onLoadMore?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        guard files.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let file = files[row]
        let menu = NSMenu()
        let match = NSMenuItem(title: "Match with", action: #selector(match(_:)), keyEquivalent: "")
        match.target = self
        match.representedObject = file
        menu.addItem(match)
        let unmatch = NSMenuItem(title: "Unmatch", action: #selector(unmatch(_:)), keyEquivalent: "")
        unmatch.target = self
        unmatch.representedObject = file
        menu.addItem(unmatch)
        NSMenu.popUpContextMenu(menu, with: event, for: tableView)
    }

    @objc private func match(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? CloudMusicApi.CloudFile else { return }
        onMatch?(file)
    }

    @objc private func unmatch(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? CloudMusicApi.CloudFile else { return }
        onUnmatch?(file)
    }
}

extension CloudFilesTableViewController: NSTableViewDataSource {
    func numberOfRows(in _: NSTableView) -> Int {
        files.isEmpty ? 0 : files.count + PlayerOverlayMetrics.tableBottomPaddingRows
    }
}

extension CloudFilesTableViewController: NSTableViewDelegate {
    func tableView(_: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let column else { return nil }
        guard files.indices.contains(row) else { return NSView() }
        let file = files[row]
        switch column.identifier.rawValue {
        case "status":
            let view = reusable(CloudStatusCell.self, identifier: "CloudStatusCell")
            view.configure(file)
            return view
        case "name":
            return textCell(file.fileName.replacingOccurrences(of: "\n", with: " "), identifier: "CloudNameCell")
        case "info":
            let info = if let song = file.simpleSong {
                [song.name, song.ar?.first?.name, song.al?.name]
                    .compactMap { $0?.replacingOccurrences(of: "\n", with: " ") }
                    .joined(separator: " - ")
            } else { "" }
            return textCell(info, identifier: "CloudInfoCell")
        case "size":
            let view = textCell(file.parseFileSize(), identifier: "CloudSizeCell")
            view.textField?.alignment = .right
            view.textField?.textColor = .secondaryLabelColor
            return view
        default:
            return nil
        }
    }

    func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat { 24 }

    func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        files.indices.contains(row)
    }

    private func textCell(_ text: String, identifier: String) -> NSTableCellView {
        let view = reusable(NSTableCellView.self, identifier: identifier)
        let field: NSTextField
        if let existing = view.textField {
            field = existing
        } else {
            field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            view.textField = field
            view.addSubview(field)
            field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
        }
        field.stringValue = text
        return view
    }

    private func reusable<T: NSView>(_ type: T.Type, identifier: String) -> T {
        let itemID = NSUserInterfaceItemIdentifier(identifier)
        if let view = tableView.makeView(withIdentifier: itemID, owner: self) as? T { return view }
        let view = T()
        view.identifier = itemID
        return view
    }
}

private final class CloudStatusCell: NSTableCellView {
    private let statusImageView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(statusImageView)
        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusImageView.widthAnchor.constraint(equalToConstant: 16),
            statusImageView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ file: CloudMusicApi.CloudFile) {
        statusImageView.image = NSImage(
            systemSymbolName: file.isMatched ? "checkmark.circle.fill" : "xmark.circle.fill",
            accessibilityDescription: nil
        )
        statusImageView.contentTintColor = file.isMatched ? .systemGreen : .systemRed
    }
}
