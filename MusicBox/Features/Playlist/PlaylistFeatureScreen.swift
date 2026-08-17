import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PlaylistFeatureScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model: PlaylistFeatureModel
    @State private var selectedSongsToAdd: [CloudMusicApi.Song] = []

    init(
        destination: PlaylistDestination,
        repository: any PlaylistRepository,
        initialSongs: [CloudMusicApi.Song]? = nil
    ) {
        _model = State(
            initialValue: PlaylistFeatureModel(
                destination: destination,
                repository: repository,
                initialSongs: initialSongs
            )
        )
    }

    var body: some View {
        ZStack {
            PlaylistSongTable(
                songs: model.visibleSongs,
                likedSongIDs: app.account.likedSongIDs,
                currentSongID: app.playback.currentItem?.id,
                explicitNextSongIDs: Set(
                    app.playbackPresentation.queueEntries.filter(\.isExplicitNext).map(\.item.id)
                ),
                allowsPlaylistMutations: model.isRemotePlaylist
                    && model.destination.id != CloudMusicApi.RecommandSongPlaylistId,
                allowsDownloads: model.isRemotePlaylist,
                canDownload: !app.transfers.hasPendingJobs(in: .download),
                sort: model.sort,
                onActivate: play,
                onPlayNext: { songs in
                    app.playback.enqueueNext(songs.map(model.item(for:)))
                },
                onAddToNowPlaying: { songs in
                    app.playback.appendSource(songs.map(model.item(for:)))
                },
                onToggleLike: toggleLike,
                onAddToPlaylist: { selectedSongsToAdd = $0 },
                onDeleteFromPlaylist: delete,
                onDownload: { songs in
                    app.transfers.enqueueDownloads(songs.map(model.item(for:)))
                },
                onUpload: { url, song in
                    upload(url, song)
                },
                onViewComments: showComments,
                onCopy: copyToPasteboard,
                onLoadMore: model.loadMore,
                onCycleSort: model.cycleSort
            )
            .searchable(
                text: Binding(get: { model.query }, set: { model.updateQuery($0) }),
                prompt: "Search in Playlist"
            )
            .toolbar { toolbar }

            if model.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial.opacity(0.3))
            }
        }
        .task { model.load() }
        .onChange(of: app.router.playlistLocateRequest) { _, request in
            guard let request, request.playlistID == model.destination.id else { return }
            // The AppKit bridge owns the scroll positioning when a locate target is added.
        }
        .sheet(
            isPresented: Binding(
                get: { !selectedSongsToAdd.isEmpty },
                set: { if !$0 { selectedSongsToAdd = [] } }
            )
        ) {
            PlaylistPickerSheet(songs: selectedSongsToAdd) { playlist in
                Task {
                    do {
                        try await model.add(selectedSongsToAdd, to: playlist.id)
                        if playlist.id == model.destination.id { model.load() }
                    } catch {
                        app.alerts.show(error.localizedDescription)
                    }
                    selectedSongsToAdd = []
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.isRemotePlaylist {
            ToolbarItemGroup {
                Button {
                    app.playback.replaceSource(model.items)
                } label: {
                    Image(systemName: "play.fill")
                }
                .help(String(localized: "Play All"))
                .disabled(model.items.isEmpty)

                Menu {
                    Button {
                        app.transfers.enqueueDownloads(model.items)
                    } label: {
                        Label(String(localized: "Download All"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.items.isEmpty || app.transfers.hasPendingJobs(in: .download))

                    Button {
                        app.playback.appendSource(model.items)
                    } label: {
                        Label("Add All to Playlist", systemImage: "plus")
                    }
                    .disabled(model.items.isEmpty)

                    Button {
                        model.load()
                    } label: {
                        Label("Refresh Playlist", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("More Actions")
            }
        }
    }

    private func play(_ song: CloudMusicApi.Song) {
        guard let index = model.songs.firstIndex(where: { $0.id == song.id }) else { return }
        switch app.settings.doubleClickPlayAction {
        case .replaceSource:
            app.playback.replaceSource(model.items, startIndex: index)
        case .appendSource:
            app.playback.playNow(model.item(for: song))
        }
    }

    private func toggleLike(_ song: CloudMusicApi.Song) {
        Task {
            do {
                try await app.account.setLiked(song.id, liked: !app.account.likedSongIDs.contains(song.id))
            } catch {
                app.alerts.show(error.localizedDescription)
            }
        }
    }

    private func delete(_ songs: [CloudMusicApi.Song]) {
        Task {
            do {
                try await model.delete(songs)
                await app.account.refreshPlaylists()
            } catch {
                app.alerts.show(error.localizedDescription)
            }
        }
    }

    private func upload(_ url: URL, _ song: CloudMusicApi.Song?) {
        app.transfers.enqueueUpload(
            fileURL: url,
            title: song?.name,
            artist: song.map { $0.ar.compactMap(\.name).joined(separator: ", ") },
            album: song?.albumName
        )
    }

    private func showComments(_ song: CloudMusicApi.Song) {
        CommentsWindowManager.shared.show(
            target: CommentsTarget(
                kind: .song,
                resourceID: song.id,
                name: song.name,
                subtitle: song.ar.compactMap(\.name).joined(separator: ", ")
            )
        )
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private struct PlaylistPickerSheet: View {
    @Environment(AppModel.self) private var app
    let songs: [CloudMusicApi.Song]
    let select: (CloudMusicApi.PlayListItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add to Playlist")
                .font(.title3.weight(.semibold))
                .padding(16)
            List(app.account.playlists) { playlist in
                Button {
                    select(playlist)
                } label: {
                    HStack(spacing: 8) {
                        AsyncImage(url: URL(string: playlist.coverImgUrl.https)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray.opacity(0.2)
                        }
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        Text(playlist.name)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 360, height: 440)
    }
}

private struct PlaylistSongTable: NSViewControllerRepresentable {
    let songs: [CloudMusicApi.Song]
    let likedSongIDs: Set<UInt64>
    let currentSongID: UInt64?
    let explicitNextSongIDs: Set<UInt64>
    let allowsPlaylistMutations: Bool
    let allowsDownloads: Bool
    let canDownload: Bool
    let sort: PlaylistSongSort?
    let onActivate: (CloudMusicApi.Song) -> Void
    let onPlayNext: ([CloudMusicApi.Song]) -> Void
    let onAddToNowPlaying: ([CloudMusicApi.Song]) -> Void
    let onToggleLike: (CloudMusicApi.Song) -> Void
    let onAddToPlaylist: ([CloudMusicApi.Song]) -> Void
    let onDeleteFromPlaylist: ([CloudMusicApi.Song]) -> Void
    let onDownload: ([CloudMusicApi.Song]) -> Void
    let onUpload: (URL, CloudMusicApi.Song?) -> Void
    let onViewComments: (CloudMusicApi.Song) -> Void
    let onCopy: (String) -> Void
    let onLoadMore: () -> Void
    let onCycleSort: (PlaylistSongSortColumn) -> Void

    func makeNSViewController(context: Context) -> SongTableViewController {
        SongTableViewController()
    }

    func updateNSViewController(_ controller: SongTableViewController, context: Context) {
        controller.songs = songs
        controller.likedSongIDs = likedSongIDs
        controller.currentSongID = currentSongID
        controller.explicitNextSongIDs = explicitNextSongIDs
        controller.allowsPlaylistMutations = allowsPlaylistMutations
        controller.allowsDownloads = allowsDownloads
        controller.canDownload = canDownload
        controller.sort = sort
        controller.onActivate = onActivate
        controller.onPlayNext = onPlayNext
        controller.onAddToNowPlaying = onAddToNowPlaying
        controller.onToggleLike = onToggleLike
        controller.onAddToPlaylist = onAddToPlaylist
        controller.onDeleteFromPlaylist = onDeleteFromPlaylist
        controller.onDownload = onDownload
        controller.onUpload = onUpload
        controller.onViewComments = onViewComments
        controller.onCopy = onCopy
        controller.onLoadMore = onLoadMore
        controller.onCycleSort = onCycleSort
        controller.refresh()
    }
}

final class SongTableViewController: NSViewController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var isSynchronizingSort = false
    private var pendingDropURLs: [URL] = []
    private var displayedSongIDs: [UInt64] = []
    private var displayedLikedSongIDs: Set<UInt64> = []
    private var displayedCurrentSongID: UInt64?
    private var displayedExplicitNextSongIDs: Set<UInt64> = []
    private var displayedSort: PlaylistSongSort?
    private var hasRendered = false

    var songs: [CloudMusicApi.Song] = []
    var likedSongIDs: Set<UInt64> = []
    var currentSongID: UInt64?
    var explicitNextSongIDs: Set<UInt64> = []
    var allowsPlaylistMutations = false
    var allowsDownloads = false
    var canDownload = false
    var sort: PlaylistSongSort?
    var onActivate: ((CloudMusicApi.Song) -> Void)?
    var onPlayNext: (([CloudMusicApi.Song]) -> Void)?
    var onAddToNowPlaying: (([CloudMusicApi.Song]) -> Void)?
    var onToggleLike: ((CloudMusicApi.Song) -> Void)?
    var onAddToPlaylist: (([CloudMusicApi.Song]) -> Void)?
    var onDeleteFromPlaylist: (([CloudMusicApi.Song]) -> Void)?
    var onDownload: (([CloudMusicApi.Song]) -> Void)?
    var onUpload: ((URL, CloudMusicApi.Song?) -> Void)?
    var onViewComments: ((CloudMusicApi.Song) -> Void)?
    var onCopy: ((String) -> Void)?
    var onLoadMore: (() -> Void)?
    var onCycleSort: ((PlaylistSongSortColumn) -> Void)?

    override func loadView() {
        view = NSView()
        configureTable()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureColumns()
    }

    func refresh() {
        let songIDs = songs.map(\.id)
        let songsChanged = songIDs != displayedSongIDs
        let rowAppearanceChanged = likedSongIDs != displayedLikedSongIDs
            || currentSongID != displayedCurrentSongID
            || explicitNextSongIDs != displayedExplicitNextSongIDs
        let sortChanged = sort != displayedSort
        guard !hasRendered || songsChanged || rowAppearanceChanged || sortChanged else { return }

        if !hasRendered || songsChanged || rowAppearanceChanged {
            tableView.reloadData()
        }
        if !hasRendered || sortChanged {
            syncSortDescriptors()
        }

        displayedSongIDs = songIDs
        displayedLikedSongIDs = likedSongIDs
        displayedCurrentSongID = currentSongID
        displayedExplicitNextSongIDs = explicitNextSongIDs
        displayedSort = sort
        hasRendered = true

        if songsChanged {
            tableView.deselectAll(nil)
        }
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick(_:))
        tableView.registerForDraggedTypes([.fileURL])

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

    private func configureColumns() {
        addColumn(id: "favorite", title: "", width: 16, min: 16, max: 16, sortable: nil)
        addColumn(id: "title", title: "Title", width: 200, min: 150, max: nil, sortable: .title)
        addColumn(id: "artist", title: "Artist", width: 100, min: 80, max: nil, sortable: .artist)
        addColumn(id: "album", title: "Album", width: 100, min: 80, max: nil, sortable: .album)
        addColumn(id: "duration", title: "Duration", width: 60, min: 60, max: 60, sortable: .duration)
    }

    private func addColumn(
        id: String,
        title: String,
        width: CGFloat,
        min: CGFloat,
        max: CGFloat?,
        sortable: PlaylistSongSortColumn?
    ) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = min
        if let max { column.maxWidth = max }
        if id == "title" {
            column.resizingMask = [.autoresizingMask, .userResizingMask]
        } else if sortable != nil {
            column.resizingMask = [.userResizingMask]
        } else {
            column.resizingMask = []
        }
        if let sortable {
            column.sortDescriptorPrototype = NSSortDescriptor(key: sortable.rawValue, ascending: true)
        }
        tableView.addTableColumn(column)
    }

    private func syncSortDescriptors() {
        isSynchronizingSort = true
        defer { isSynchronizingSort = false }
        guard let sort else {
            tableView.sortDescriptors = []
            return
        }
        tableView.sortDescriptors = [
            NSSortDescriptor(key: sort.column.rawValue, ascending: sort.order == .forward)
        ]
    }

    @objc private func contentBoundsDidChange() {
        let visible = scrollView.documentVisibleRect
        let documentHeight = tableView.bounds.height
        guard documentHeight > 0, visible.maxY >= documentHeight - 140 else { return }
        onLoadMore?()
    }

    @objc private func handleDoubleClick(_ sender: NSTableView) {
        activateSong(at: sender.clickedRow)
    }

    func activateSong(at row: Int) {
        guard songs.indices.contains(row) else { return }
        onActivate?(songs[row])
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)
        guard songs.indices.contains(row) else { return }
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let selection = selectedSongs(fallback: row)
        NSMenu.popUpContextMenu(menu(for: selection), with: event, for: tableView)
    }

    private func selectedSongs(fallback row: Int) -> [CloudMusicApi.Song] {
        let selected = Self.songs(for: tableView.selectedRowIndexes, in: songs)
        return selected.isEmpty ? [songs[row]] : selected
    }

    static func songs(
        for selection: IndexSet,
        in songs: [CloudMusicApi.Song]
    ) -> [CloudMusicApi.Song] {
        selection.compactMap { songs.indices.contains($0) ? songs[$0] : nil }
    }

    private func menu(for selected: [CloudMusicApi.Song]) -> NSMenu {
        let menu = NSMenu()
        let multiple = selected.count > 1
        if !multiple, let song = selected.first {
            menu.addItem(item("Play", symbol: "play.fill", action: #selector(play(_:)), object: song))
        }
        if allowsDownloads {
            let download = item(
                String(localized: "Download Selected"),
                symbol: "arrow.down.circle",
                action: #selector(download(_:)),
                object: selected
            )
            download.isEnabled = canDownload
            menu.addItem(download)
        }
        menu.addItem(item(multiple ? "Play \(selected.count) Songs Next" : "Play Next", symbol: "text.badge.plus", action: #selector(playNext(_:)), object: selected))
        menu.addItem(item(multiple ? "Add \(selected.count) Songs to Now Playing" : "Add to Now Playing", symbol: "music.note.list", action: #selector(addToNowPlaying(_:)), object: selected))
        menu.addItem(item(multiple ? "Add \(selected.count) Songs to Playlist" : "Add to Playlist", symbol: "plus.rectangle.on.rectangle", action: #selector(addToPlaylist(_:)), object: selected))
        if allowsPlaylistMutations {
            menu.addItem(item(multiple ? "Delete \(selected.count) Songs from Playlist" : "Delete from Playlist", symbol: "trash", action: #selector(deleteFromPlaylist(_:)), object: selected))
        }
        if !multiple, let song = selected.first {
            menu.addItem(.separator())
            menu.addItem(item("Upload to Cloud", symbol: "icloud.and.arrow.up", action: #selector(upload(_:)), object: song))
            menu.addItem(item("Copy Title", symbol: "doc.on.doc", action: #selector(copyTitle(_:)), object: song))
            menu.addItem(item("查看评论", symbol: "text.bubble", action: #selector(viewComments(_:)), object: song))
        }
        menu.addItem(.separator())
        menu.addItem(item(multiple ? "Copy \(selected.count) Links" : "Copy Link", symbol: "link", action: #selector(copyLinks(_:)), object: selected))
        return menu
    }

    private func item(_ title: String, symbol: String, action: Selector, object: Any) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    @objc private func play(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? CloudMusicApi.Song else { return }
        onActivate?(song)
    }

    @objc private func playNext(_ sender: NSMenuItem) {
        onPlayNext?(songs(from: sender))
    }

    @objc private func addToNowPlaying(_ sender: NSMenuItem) {
        onAddToNowPlaying?(songs(from: sender))
    }

    @objc private func addToPlaylist(_ sender: NSMenuItem) {
        onAddToPlaylist?(songs(from: sender))
    }

    @objc private func deleteFromPlaylist(_ sender: NSMenuItem) {
        onDeleteFromPlaylist?(songs(from: sender))
    }

    @objc private func download(_ sender: NSMenuItem) {
        onDownload?(songs(from: sender))
    }

    @objc private func upload(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? CloudMusicApi.Song else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.onUpload?(url, song)
        }
    }

    @objc private func copyTitle(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? CloudMusicApi.Song else { return }
        onCopy?(song.name)
    }

    @objc private func viewComments(_ sender: NSMenuItem) {
        guard let song = sender.representedObject as? CloudMusicApi.Song else { return }
        onViewComments?(song)
    }

    @objc private func copyLinks(_ sender: NSMenuItem) {
        let links = songs(from: sender).map { "https://music.163.com/#/song?id=\($0.id)" }.joined(separator: "\n")
        onCopy?(links)
    }

    private func songs(from sender: NSMenuItem) -> [CloudMusicApi.Song] {
        if let songs = sender.representedObject as? [CloudMusicApi.Song] { return songs }
        if let song = sender.representedObject as? CloudMusicApi.Song { return [song] }
        return []
    }
}

extension SongTableViewController: NSTableViewDataSource {
    func numberOfRows(in _: NSTableView) -> Int {
        songs.isEmpty ? 0 : songs.count + PlayerOverlayMetrics.tableBottomPaddingRows
    }

    func tableView(
        _: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation _: NSTableView.DropOperation
    ) -> NSDragOperation {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        pendingDropURLs = urls.filter { $0.pathExtension.isEmpty == false }
        guard !pendingDropURLs.isEmpty, songs.indices.contains(max(0, min(row, songs.count - 1))) else { return [] }
        tableView.setDropRow(max(0, min(row, songs.count - 1)), dropOperation: .on)
        return .copy
    }

    func tableView(
        _: NSTableView,
        acceptDrop _: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard dropOperation == .on, songs.indices.contains(row), let url = pendingDropURLs.first else { return false }
        pendingDropURLs = []
        onUpload?(url, songs[row])
        return true
    }
}

extension SongTableViewController: NSTableViewDelegate {
    func tableView(_: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        guard songs.indices.contains(row) else { return NSView() }
        let song = songs[row]
        switch column.identifier.rawValue {
        case "favorite":
            let cell = reusable(FavoriteSongCell.self, identifier: "FavoriteSongCell")
            cell.configure(song: song, isLiked: likedSongIDs.contains(song.id)) { [weak self] in
                self?.onToggleLike?(song)
            }
            return cell
        case "title":
            let cell = reusable(PlaylistSongTitleCell.self, identifier: "PlaylistSongTitleCell")
            cell.configure(
                song: song,
                isCurrent: song.id == currentSongID,
                isExplicitNext: explicitNextSongIDs.contains(song.id)
            )
            return cell
        case "artist":
            return textCell(song.ar.compactMap(\.name).joined(separator: ", "), identifier: "SongArtistCell")
        case "album":
            return textCell(song.albumName.isEmpty ? "Unknown Album" : song.albumName, identifier: "SongAlbumCell")
        case "duration":
            let seconds = song.dt / 1_000
            let cell = textCell(String(format: "%02lld:%02lld", seconds / 60, seconds % 60), identifier: "SongDurationCell")
            cell.textField?.alignment = .right
            return cell
        default:
            return nil
        }
    }

    func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        songs.indices.contains(row)
    }

    func tableView(_: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
        guard !isSynchronizingSort,
              let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              let column = PlaylistSongSortColumn(rawValue: key)
        else { return }
        onCycleSort?(column)
    }

    private func textCell(_ text: String, identifier: String) -> NSTableCellView {
        let cell = reusable(NSTableCellView.self, identifier: identifier)
        let field: NSTextField
        if let existing = cell.textField {
            field = existing
        } else {
            field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            cell.textField = field
            cell.addSubview(field)
            field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        field.stringValue = text
        return cell
    }

    private func reusable<T: NSView>(_ type: T.Type, identifier: String) -> T {
        let itemID = NSUserInterfaceItemIdentifier(identifier)
        if let view = tableView.makeView(withIdentifier: itemID, owner: self) as? T {
            return view
        }
        let view = T()
        view.identifier = itemID
        return view
    }
}

private final class FavoriteSongCell: NSTableCellView {
    private let button = NSButton()
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.isBordered = false
        button.target = self
        button.action = #selector(toggle)
        addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 16),
            button.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(song _: CloudMusicApi.Song, isLiked: Bool, action: @escaping () -> Void) {
        self.action = action
        button.image = NSImage(systemSymbolName: isLiked ? "heart.fill" : "heart", accessibilityDescription: nil)
        button.toolTip = isLiked ? "Unfavor" : "Favor"
    }

    @objc private func toggle() { action?() }
}

private final class PlaylistSongTitleCell: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let aliasLabel = NSTextField(labelWithString: "")
    private let playbackIcon = NSImageView()
    private let statusIcon = NSImageView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.lineBreakMode = .byTruncatingTail
        aliasLabel.textColor = .secondaryLabelColor
        aliasLabel.lineBreakMode = .byTruncatingTail
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(aliasLabel)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(playbackIcon)
        stack.addArrangedSubview(statusIcon)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            playbackIcon.widthAnchor.constraint(equalToConstant: 16),
            playbackIcon.heightAnchor.constraint(equalToConstant: 16),
            statusIcon.widthAnchor.constraint(equalToConstant: 18),
            statusIcon.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(song: CloudMusicApi.Song, isCurrent: Bool, isExplicitNext: Bool) {
        titleLabel.stringValue = song.name
        let alias = song.tns?.first ?? song.alia.first
        aliasLabel.stringValue = alias.map { "( \($0) )" } ?? ""
        aliasLabel.isHidden = alias == nil

        if isCurrent {
            playbackIcon.image = NSImage(systemSymbolName: "speaker.3.fill", accessibilityDescription: nil)
            playbackIcon.contentTintColor = .controlAccentColor
            playbackIcon.toolTip = nil
            playbackIcon.isHidden = false
        } else if isExplicitNext {
            playbackIcon.image = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: nil)
            playbackIcon.contentTintColor = .systemOrange
            playbackIcon.toolTip = "Play next"
            playbackIcon.isHidden = false
        } else {
            playbackIcon.isHidden = true
        }

        if song.pc != nil {
            statusIcon.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)
            statusIcon.toolTip = "Cloud"
            statusIcon.isHidden = false
            return
        }

        switch song.fee {
        case .vip:
            statusIcon.image = NSImage(systemSymbolName: "crown.fill", accessibilityDescription: nil)
            statusIcon.toolTip = "VIP required"
            statusIcon.isHidden = false
        case .album:
            statusIcon.image = NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: nil)
            statusIcon.toolTip = "Purchase album"
            statusIcon.isHidden = false
        case .trial:
            statusIcon.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: nil)
            statusIcon.toolTip = "Free trial quality"
            statusIcon.isHidden = false
        default:
            statusIcon.isHidden = true
        }
    }
}
