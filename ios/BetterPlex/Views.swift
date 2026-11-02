import SwiftUI
import AVKit

struct LibraryView: View {
    @EnvironmentObject var library: LibraryStore
    @State private var selected: LibrarySection?
    @State private var items: [MediaItem] = []
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var account = false
    private var filtered: [MediaItem] { search.isEmpty ? items : items.filter { $0.title.localizedStandardContains(search) } }
    var body: some View {
        Group {
            if let server = library.server {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Label(server.name, systemImage: "externaldrive.connected.to.line.below").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if loading || library.busy { ProgressView().controlSize(.small) }
                        }
                        if !library.sections.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(library.sections) { section in
                                        Button { selected = section } label: {
                                            Label(section.title, systemImage: section.type == "movie" ? "film" : "tv")
                                                .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 11)
                                                .background(selected == section ? accent : panel, in: Capsule())
                                                .foregroundStyle(selected == section ? .black : .white)
                                        }.accessibilityIdentifier("section-\(section.id)")
                                    }
                                }
                            }
                        }
                        if let message = error ?? library.error {
                            ErrorCard(message: message) { Task { await library.reloadSections(); await load() } }
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text(selected?.title ?? "Your library").font(.title2.bold())
                            Spacer()
                            Text("\(filtered.count) titles").font(.caption).foregroundStyle(.secondary)
                        }
                        if filtered.isEmpty && !loading && !library.busy && error == nil && library.error == nil {
                            ContentUnavailableView(search.isEmpty ? "Your library is quiet" : "No matches", systemImage: search.isEmpty ? "film.stack" : "magnifyingglass", description: Text(search.isEmpty ? "Movies and TV libraries from this server appear here." : "Try another title in this library."))
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], spacing: 24) {
                            ForEach(filtered) { item in
                                NavigationLink { DetailView(item: item, server: server) } label: {
                                    VStack(alignment: .leading, spacing: 9) {
                                        PosterView(item: item, server: server).aspectRatio(2.0/3, contentMode: .fit)
                                        Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        WatchBadge(item: item, server: server)
                                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                                }.buttonStyle(.plain).accessibilityIdentifier("media-\(item.id)")
                            }
                        }
                    }.padding(20)
                }
                .searchable(text: $search, prompt: "Search this library")
                .refreshable { await library.reloadSections(); await load() }
                .task(id: "\(server.id)-\(selected?.id ?? "")") { await load() }
                .onChange(of: library.sections) { _, sections in
                    if !sections.contains(where: { $0.id == selected?.id }) { selected = sections.first }
                }
                .onAppear { if selected == nil { selected = library.sections.first } }
            } else { WelcomeView { account = true } }
        }
        .background(canvas).navigationTitle("better-plex")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Image(systemName: "play.rectangle.fill").foregroundStyle(accent) } }
        .sheet(isPresented: $account) { NavigationStack { AccountView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { account = false } } } } }
        .onChange(of: library.connected) { _, connected in if connected { account = false } }
    }
    private func load() async {
        guard let server = library.server, let selected else { items = []; return }
        loading = true; error = nil; items = []
        do {
            let result = try await PlexAPI.items("/library/sections/\(selected.id)/all", server: server, query: [URLQueryItem(name: "sort", value: "titleSort")])
            try Task.checkCancellation()
            items = result
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        if !Task.isCancelled { loading = false }
    }
}

struct WelcomeView: View {
    var connect: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ZStack {
                    RoundedRectangle(cornerRadius: 34).fill(accent.opacity(0.07))
                    RoundedRectangle(cornerRadius: 22).fill(panel).frame(width: 132, height: 178).rotationEffect(.degrees(-15)).offset(x: -65, y: 8)
                        .overlay(Image(systemName: "film").font(.system(size: 42)).foregroundStyle(.white.opacity(0.25)).offset(x: -65))
                    RoundedRectangle(cornerRadius: 22).fill(accent.gradient).frame(width: 132, height: 178).rotationEffect(.degrees(12)).offset(x: 48, y: -2)
                        .overlay(Image(systemName: "arrow.down").font(.system(size: 50, weight: .bold)).foregroundStyle(.black).offset(x: 48))
                }.frame(height: 245).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 12) {
                    Text("YOUR LIBRARY. TO GO.").font(.caption.weight(.bold)).tracking(2).foregroundStyle(accent)
                    Text("Good things.\nSaved for later.").font(.system(size: 39, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                    Text("Your movies and shows, with a download button that gets straight to the point.").font(.body).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 17) {
                    Label("Browse your Plex movies and shows", systemImage: "rectangle.stack")
                    Label("Pick an episode, a season, or a movie", systemImage: "arrow.down.circle")
                    Label("Take the original files with you", systemImage: "iphone")
                }.font(.subheadline)
            }.padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(action: connect) { Text("Connect to Plex").frame(maxWidth: .infinity).padding(.vertical, 9) }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black).controlSize(.large)
                Text("Direct to your Plex server. Every download is your choice.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(.horizontal, 24).padding(.vertical, 14).background(canvas)
        }
    }
}

struct WatchBadge: View {
    var item: MediaItem
    var server: ServerSession
    @ObservedObject private var history = PlaybackHistory.shared
    var body: some View {
        let saved = history.record(for: item, server: server)
        let offset = saved?.offset ?? item.viewOffset ?? 0
        let watched = saved?.watched ?? ((item.viewCount ?? 0) > 0)
        if !item.isContainer && (offset > 0 || watched) {
            Label(offset > 0 ? "Resume \(playbackTime(offset))" : "Watched", systemImage: offset > 0 ? "clock" : "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(accent)
        }
    }
}

struct PosterView: View {
    var item: MediaItem
    var server: ServerSession
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.18, green: 0.20, blue: 0.24), panel], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else {
                    VStack(spacing: 14) {
                        Image(systemName: item.isContainer ? "tv" : "film").font(.largeTitle).foregroundStyle(accent.opacity(0.7))
                        Text(item.title).font(.headline).multilineTextAlignment(.center).padding(.horizontal)
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped().clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .task(id: "\(server.id)-\(item.artwork ?? "")") {
            image = nil
            guard let path = item.artwork, let url = try? PlexAPI.url(path, server: server) else { return }
            if let (data, response) = try? await URLSession.shared.data(for: PlexAPI.request(url, token: server.token)), (response as? HTTPURLResponse)?.statusCode == 200, !Task.isCancelled { image = UIImage(data: data) }
        }
        .accessibilityHidden(true)
    }
}

struct DetailView: View {
    @ObservedObject var history = PlaybackHistory.shared
    var item: MediaItem
    var server: ServerSession
    @ObservedObject var downloads = Downloads.shared
    @State private var detail: MediaItem?
    @State private var children: [MediaItem] = []
    @State private var version = 0
    @State private var loading = true
    @State private var preparing = false
    @State private var error: String?
    @State private var selections: [DownloadSelection] = []
    @State private var showConfirmation = false
    @State private var queued = false
    private var current: MediaItem { detail ?? item }
    private var versions: [MediaVersion] { current.Media ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 20) {
                    PosterView(item: current, server: server).frame(width: 125, height: 188)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(current.type.uppercased()).font(.caption.weight(.bold)).tracking(2).foregroundStyle(accent)
                        Text(current.title).font(.title2.bold())
                        Text(current.subtitle).font(.subheadline).foregroundStyle(.secondary)
                        if let show = current.grandparentTitle { Text(show).font(.subheadline).foregroundStyle(.secondary) }
                    }.padding(.top, 6)
                }
                if !current.isContainer {
                    let saved = history.record(for: current, server: server)
                    let watched = saved?.watched ?? ((current.viewCount ?? 0) > 0)
                    HStack {
                        Label(saved?.label ?? ((current.viewOffset ?? 0) > 0 ? "Resume at \(playbackTime(current.viewOffset ?? 0))" : watched ? "Watched" : "Unwatched"), systemImage: watched ? "checkmark.circle" : "clock")
                        Spacer()
                        Button(watched ? "Mark unwatched" : "Mark watched") { history.mark(current, server: server, watched: !watched) }
                    }.font(.caption).foregroundStyle(accent)
                }
                if let summary = current.summary, !summary.isEmpty { Text(summary).font(.subheadline).foregroundStyle(.secondary) }
                if let error { ErrorCard(message: error) { Task { await load() } } }
                if loading { ProgressView("Loading from Plex…").frame(maxWidth: .infinity).padding() }
                if current.type != "show" && !loading {
                    if versions.count > 1 {
                        Picker("File version", selection: $version) {
                            ForEach(versions.indices, id: \.self) { index in Text(versions[index].label).tag(index) }
                        }.pickerStyle(.menu).tint(accent)
                    } else if let media = versions.first, !media.label.isEmpty {
                        Label(media.label, systemImage: "doc.zipper").font(.caption).foregroundStyle(.secondary)
                    }
                    Button { Task { await prepare() } } label: {
                        HStack {
                            if preparing { ProgressView().tint(.black) } else { Image(systemName: "arrow.down.circle.fill") }
                            Text(preparing ? "Preparing selection…" : current.type == "season" ? "Download season" : "Download \(current.type == "movie" ? "movie" : "episode")")
                        }.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(preparing || (current.type == "season" ? children.isEmpty : versions.isEmpty))
                        .accessibilityIdentifier("download-selection")
                    Text("Original quality. Files stay on this device until you remove them.").font(.caption).foregroundStyle(.secondary)
                    if queued { Label("Added to Downloads", systemImage: "checkmark.circle.fill").foregroundStyle(accent).font(.subheadline).accessibilityIdentifier("queued-notice") }
                }
                if !children.isEmpty {
                    HStack {
                        Text(current.type == "show" ? "Seasons" : "Episodes").font(.title2.bold())
                        Spacer()
                        Text("\(children.count)").foregroundStyle(.secondary)
                    }
                    ForEach(children) { child in
                        NavigationLink { DetailView(item: child, server: server) } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12).fill(panel)
                                    Text(String(format: "%02d", child.index ?? 0)).font(.title3.weight(.bold)).foregroundStyle(accent)
                                }.frame(width: 54, height: 58)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(child.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                    Text(child.subtitle).font(.caption).foregroundStyle(.secondary)
                                    WatchBadge(item: child, server: server)
                                }
                                Spacer()
                                if downloads.jobs.contains(where: { $0.serverID == server.id && $0.mediaID == child.id && $0.state == .complete }) { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("media-\(child.id)")
                    }
                }
            }.padding(20)
        }.background(canvas).navigationTitle(item.type == "show" ? "Show" : item.type.capitalized).navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .sheet(isPresented: $showConfirmation) {
                DownloadConfirmation(selections: selections, server: server) { queued = true }
            }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            detail = try await PlexAPI.metadata(item, server: server)
            history.ingest(current, server: server)
            if current.isContainer { children = try await PlexAPI.items("/library/metadata/\(item.id)/children", server: server).sorted { ($0.index ?? 0) < ($1.index ?? 0) } }
        } catch { self.error = error.localizedDescription }
    }
    private func prepare() async {
        preparing = true; error = nil
        defer { preparing = false }
        do {
            var values: [DownloadSelection] = []
            if current.type == "season" {
                for child in children where child.type == "episode" {
                    let full = child.Media?.isEmpty == false ? child : try await PlexAPI.metadata(child, server: server)
                    guard let media = full.Media?.first, media.Part?.isEmpty == false else { throw PlexError.message("\(child.title) has no downloadable file.") }
                    values.append(DownloadSelection(item: full, version: media))
                }
            } else if versions.indices.contains(version) { values = [DownloadSelection(item: current, version: versions[version])] }
            guard !values.isEmpty else { throw PlexError.message("No files are available to download.") }
            selections = values; showConfirmation = true
        } catch { self.error = error.localizedDescription }
    }
}

struct DownloadConfirmation: View {
    var selections: [DownloadSelection]
    var server: ServerSession
    var onQueued: () -> Void
    @Environment(\.dismiss) var dismiss
    @ObservedObject var downloads = Downloads.shared
    @State private var excluded: Set<UUID> = []
    @State private var error: String?
    var chosen: [DownloadSelection] { selections.filter { !excluded.contains($0.id) } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Make room for a good watch.").font(.title2.bold())
                        Text("\(chosen.count) \(chosen.count == 1 ? "title" : "titles") · \(byteString(chosen.reduce(0) { $0 + $1.version.bytes }))").foregroundStyle(accent)
                        Text("Original files from \(server.name). Existing downloads are skipped. When an episode has multiple versions, a season download uses its first version; open the episode to choose another.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                Section("Your selection") {
                    ForEach(selections) { selection in
                        Toggle(isOn: Binding(get: { !excluded.contains(selection.id) }, set: { if $0 { excluded.remove(selection.id) } else { excluded.insert(selection.id) } })) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(selection.item.title).font(.subheadline.weight(.semibold))
                                Text(selection.item.subtitle + " · " + selection.version.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }.tint(accent)
                    }
                }
                Section {
                    Label(downloads.allowCellular ? "Wi-Fi and cellular enabled" : "Wi-Fi only", systemImage: downloads.allowCellular ? "antenna.radiowaves.left.and.right" : "wifi")
                    Text("Downloads continue in the background when iOS allows. Force-quitting the app interrupts transfers.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Download").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download \(chosen.count)") {
                        do { try downloads.enqueue(chosen, server: server); onQueued(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(chosen.isEmpty).accessibilityIdentifier("confirm-download")
                }
            }
        }
    }
}

struct DownloadsView: View {
    @ObservedObject var history = PlaybackHistory.shared
    @ObservedObject var downloads = Downloads.shared
    @State private var filter = 0
    @State private var play: DownloadJob?
    @State private var share: DownloadJob?
    @State private var delete: DownloadJob?
    private var visible: [DownloadJob] { downloads.jobs.filter { filter == 0 || (filter == 1 ? $0.state == .complete : $0.state != .complete) } }
    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "arrow.down.to.line.circle.fill").font(.system(size: 44)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ready when you are.").font(.title3.bold())
                        Text("\(downloads.jobs.filter { $0.state == .complete }.count) saved · \(byteString(downloads.completedBytes)) on device").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 10)
                Picker("Show downloads", selection: $filter) {
                    Text("All").tag(0); Text("Saved").tag(1); Text("In progress").tag(2)
                }.pickerStyle(.segmented)
            }.listRowBackground(panel)
            if visible.isEmpty {
                ContentUnavailableView("\(filter == 1 ? "Nothing saved yet" : "No downloads yet")", systemImage: "arrow.down.circle", description: Text("Choose a movie, episode, or season in Library. Your files will appear here."))
                    .listRowBackground(Color.clear)
            }
            ForEach(visible) { job in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: job.state == .complete ? "checkmark.circle.fill" : job.state == .failed ? "exclamationmark.circle" : "film")
                            .font(.title2).foregroundStyle(job.state == .failed ? .red : accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.title).font(.subheadline.weight(.semibold))
                            Text(status(job)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("status-\(job.mediaID)")
                            if let record = history.record(for: job) {
                                Text(record.label + (record.pending == nil ? "" : " · Sync pending")).font(.caption).foregroundStyle(accent).accessibilityIdentifier("history-\(job.mediaID)")
                            }
                        }
                        Spacer(minLength: 0)
                        Menu {
                            if job.state == .complete {
                                Button("Save to Files / Open in…", systemImage: "square.and.arrow.up") { share = job }
                                let watched = history.record(for: job)?.watched ?? false
                                Button(watched ? "Mark unwatched" : "Mark watched", systemImage: "checkmark.circle") { history.mark(job, watched: !watched) }
                            }
                            Button(job.state == .complete ? "Remove download" : "Cancel download", systemImage: "trash", role: .destructive) { delete = job }
                        } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }.accessibilityLabel("Options for \(job.title)")
                    }
                    if job.state == .downloading { ProgressView(value: job.progress).tint(accent) }
                    if let error = job.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        switch job.state {
                        case .complete:
                            Button((history.record(for: job)?.offset ?? 0) > 0 ? "Resume" : "Play", systemImage: "play.fill") { startPlayback(job) }.accessibilityIdentifier("play-\(job.mediaID)")
                            Spacer()
                            Button("Save / Open", systemImage: "square.and.arrow.up") { share = job }
                        case .queued, .downloading:
                            Button("Pause", systemImage: "pause.fill") { downloads.pause(job.id) }.accessibilityIdentifier("pause-\(job.mediaID)")
                        case .paused, .failed:
                            Button(job.state == .failed ? "Retry" : "Resume", systemImage: "arrow.clockwise") { downloads.resume(job.id) }.accessibilityIdentifier("resume-\(job.mediaID)")
                        }
                    }.font(.subheadline.weight(.semibold)).buttonStyle(.borderless)
                }.padding(.vertical, 8).listRowBackground(panel)
            }
        }
        .scrollContentBackground(.hidden).background(canvas).navigationTitle("Downloads")
        .toolbar { if downloads.activeCount > 0 { Button("Pause all") { downloads.pauseAll() } } }
        .sheet(item: $share) { ShareSheet(url: downloads.file($0)) }
        .fullScreenCover(item: $play) { OfflinePlayer(job: $0, url: downloads.file($0)) }
        .alert("Remove this download?", isPresented: Binding(get: { delete != nil }, set: { if !$0 { delete = nil } })) {
            Button("Keep", role: .cancel) { delete = nil }
            Button("Remove", role: .destructive) { if let delete { downloads.remove(delete.id) }; delete = nil }
        } message: { Text("Only the copy on this device is removed. The original stays in Plex.") }
    }
    private func startPlayback(_ value: DownloadJob) {
        var bound = value
        if bound.historyOwner == nil {
            bound.historyOwner = history.owner(for: value)
            downloads.bindHistoryOwner(value.id, owner: bound.historyOwner!)
        }
        play = bound
    }
    private func status(_ job: DownloadJob) -> String {
        switch job.state {
        case .complete: return "Saved · \(byteString(job.received)) · \(URL(fileURLWithPath: job.filename).pathExtension.uppercased())"
        case .downloading: return "\(Int(job.progress * 100))% · \(byteString(job.received)) of \(byteString(job.expected))"
        case .queued: return "Queued"
        case .paused: return "Paused · \(byteString(job.received))"
        case .failed: return "Download failed"
        }
    }
}

struct AccountView: View {
    @ObservedObject var history = PlaybackHistory.shared
    @EnvironmentObject var library: LibraryStore
    @ObservedObject var downloads = Downloads.shared
    @State private var address = ""
    @State private var token = ""
    @State private var disconnect = false
    var body: some View {
        Form {
            if let server = library.server {
                Section("Connected server") {
                    Label(server.name, systemImage: "externaldrive.fill").foregroundStyle(accent)
                    Text(server.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                    Button("Disconnect", role: .destructive) { disconnect = true }
                }
            }
            Section {
                if library.signingIn {
                    ProgressView("Waiting for browser sign-in…")
                    Text("Finish signing in with Google or Plex in your browser, then return to better-plex.").font(.subheadline).foregroundStyle(.secondary)
                    if library.authURL != nil {
                        Button("Open sign-in browser") { Task { await library.openSignInBrowser() } }.accessibilityIdentifier("reopen-sign-in")
                        Button("Check sign-in") { library.resumeSignIn() }.accessibilityIdentifier("check-sign-in")
                    }
                    Button("Cancel sign-in") { library.cancelSignIn() }
                } else {
                    Button { library.startSignIn() } label: { Label("Sign in with Plex", systemImage: "person.crop.circle.badge.checkmark") }
                        .accessibilityIdentifier("plex-sign-in")
                }
                if library.accountToken != nil { Button("Refresh servers") { Task { await library.discover() } }.disabled(library.busy) }
            } footer: { Text("Sign-in opens in your default browser. When finished, return here to choose your server. Your password is never stored in better-plex.") }
            if !library.resources.isEmpty {
                Section("Your servers") {
                    ForEach(library.resources) { resource in
                        Button { Task { await library.connect(resource) } } label: {
                            HStack { Label(resource.name, systemImage: "externaldrive"); Spacer(); if library.server?.id == resource.id { Image(systemName: "checkmark") } }
                        }.disabled(library.busy)
                    }
                }
            }
            if library.busy { ProgressView("Connecting…") }
            if let error = library.error { Section { Text(error).foregroundStyle(.orange).font(.subheadline) } }
            Section {
                DisclosureGroup("Connect manually") {
                    TextField("Server URL, including port", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("server-url")
                    SecureField("X-Plex-Token", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("server-token")
                    Button("Connect") { Task { await library.connectManually(address: address, token: token); if library.connected { token = "" } } }.disabled(library.busy || address.isEmpty || token.isEmpty)
                    Text("Example: http://192.168.1.10:32400. Use HTTPS when available. Credentials are stored in this device’s Keychain.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Downloads") {
                Toggle("Allow cellular downloads", isOn: $downloads.allowCellular)
                Text("Wi-Fi only by default. This setting applies to new transfers. A resumed transfer keeps its original network setting.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Playback history") {
                Label(history.syncing ? "Syncing with Plex…" : history.pendingCount == 0 ? "Playback sync is up to date" : "\(history.pendingCount) updates waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                Button("Sync playback history now") { history.sync() }.disabled(history.syncing)
                if let message = history.lastError { Text(message).font(.caption).foregroundStyle(.orange) }
                Text("Progress syncs with your Plex account. Offline viewing syncs when you reconnect and open the app. Playback in other apps cannot be tracked; use Mark watched after viewing there.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Simple by design") {
                Label("Direct from your Plex server", systemImage: "point.3.connected.trianglepath.dotted")
                Label("Only the downloads you choose", systemImage: "hand.tap")
                Text("Original files, with no conversion. Some formats, including MKV, need another player. Use Save / Open in Downloads to export a file. Server download permissions still apply.").font(.caption).foregroundStyle(.secondary)
                Text("better-plex · 1.1\nIndependent app. Not affiliated with Plex.").font(.caption2).foregroundStyle(.tertiary)
            }
        }.navigationTitle("Account").scrollContentBackground(.hidden).background(canvas)
            .task { if library.resources.isEmpty { await library.discover() } }
            .alert("Disconnect from Plex?", isPresented: $disconnect) {
                Button("Cancel", role: .cancel) { }
                Button("Disconnect", role: .destructive) { library.disconnect() }
            } message: { Text("Active downloads will pause. Saved files stay available offline.") }
    }
}

struct ErrorCard: View {
    var message: String
    var retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.circle").font(.subheadline)
            Button("Try again", action: retry).font(.subheadline.weight(.semibold))
        }.padding().frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 16))
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    var url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
struct OfflinePlayer: View {
    var job: DownloadJob
    var url: URL
    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) var scenePhase
    @StateObject private var playback = OfflinePlayback()
    @State private var share = false
    var body: some View {
        NavigationStack {
            Group {
                if let error = playback.error {
                    ContentUnavailableView {
                        Label("Open in another player", systemImage: "play.slash")
                    } description: { Text(error) } actions: { Button("Save / Open") { share = true } }
                } else if let player = playback.player {
                    VideoPlayer(player: player).accessibilityIdentifier("offline-player")
                } else { ProgressView("Opening…") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                .navigationTitle(job.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { playback.stop(); dismiss() } }
                    if let label = playback.resumeLabel { ToolbarItem(placement: .bottomBar) { Text(label).font(.caption).accessibilityIdentifier("player-resume-position") } }
                }
                .task { await playback.open(job: job, url: url) }
                .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                    if let item = notification.object as? AVPlayerItem, item === playback.player?.currentItem { playback.ended() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
                    if let item = notification.object as? AVPlayerItem, item === playback.player?.currentItem { playback.error = "This file could not be played. Try opening it in another player."; playback.stop() }
                }
                .onChange(of: scenePhase) { _, phase in if phase != .active { playback.checkpoint() } }
                .onDisappear { playback.stop() }
                .sheet(isPresented: $share) { ShareSheet(url: url) }
        }
    }
}
