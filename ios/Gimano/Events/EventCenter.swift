import Foundation
import Observation
import SwiftUI

/// A verified pack waiting for the user's confirmation (§7.3–7.5).
struct PendingEventImport: Identifiable, Equatable {
    let id = UUID()
    let pack: OpenedEventPack
    let decision: EventImportDecision
    /// The version on this phone (for "older" / "fork" / "newer" warnings).
    let stored: ImportedEvent?
    /// The host opened their own invitation: nothing is imported, their event opens.
    var isOwn = false
    /// A newer revision: what changed against the version on this phone (board "5 · Pelan berubah").
    var changes: [EventChange] = []
    /// Opened from a short link (§5.6): kept with the event once it is on this phone, to fetch later revisions.
    var drop: EventDropRef?
}

/// The guest is previewing or driving a route to this event stop (set by "Navigate").
struct EventActiveTrip: Equatable, Sendable {
    var eventId: String
    var stopId: String
    var target: LatLng
}

enum EventNavRoute: Hashable {
    case confirm
    case secretCode
    case detail(String)
    /// The organizer's editor for a hosted event: the wizard opened on "Semak" (editing an existing event).
    case host(String)
    /// "Acara baharu": the wizard from its first step ("Jenis").
    case create(String)
    /// "Kongsi jemputan" for a hosted event (board "2").
    case share(String)
    /// "Laluan saya": personal routes (on this phone only).
    case myRoutes
}

/// Events (Acara): opening invitation links and `.manotu-event` files, the import decision, the on-device library.
@MainActor
@Observable
final class EventCenter {
    let store: EventStore
    /// The personal store (backed up to the user's own storage) that holds "Laluan saya".
    let personalStore: LocalStore
    let secrets: any EventSecretStore
    private(set) var events: [ImportedEvent] = []
    /// Events this phone organizes.
    private(set) var hosted: [HostedEvent] = []
    /// The last publication per hosted event, in memory only (links and codes are never stored).
    private(set) var invites: [String: PublishedInvite] = [:]
    /// "Laluan saya" (on this phone and in the user's own backup).
    private(set) var personalRoutes: [RouteDraft] = []
    /// Set by "Navigate" to an event stop; checked when a newer revision moves that stop.
    var activeTrip: EventActiveTrip?

    /// The Acara sheet and its navigation.
    var isPresented = false
    var path: [EventNavRoute] = []
    var detent: PresentationDetent = .large

    private(set) var pending: PendingEventImport?
    /// Bytes of a `.manotu-event` file waiting for its secret code.
    private(set) var pendingFile: [UInt8]?
    /// Argon2id is running for the pending file (suite 2, §5.2): the code screen shows progress.
    private(set) var isOpeningFile = false
    /// The hosted event being published (a suite-2 file runs Argon2id): the editor shows progress.
    private(set) var publishing: String?
    /// The suite-2 file ("Acara sensitif") being made for this hosted event (Argon2id).
    private(set) var makingCodeFile: String?
    var errorMessage: String?
    /// The stop a per-stop "Buka di Manotu" link asked for; the event screen highlights it.
    var focusStopId: String?
    /// The event whose stops-only copy was just replaced by the full event ("Laluan penuh ditambah", §7.4).
    var fullRouteAdded: String?

    @ObservationIgnored var now: () -> Date = { .now }

    // MARK: short links (§5.6)

    /// The relay for short links (the encrypted blob only); nil in demo mode, where the long link is used.
    @ObservationIgnored var dropTransport: @MainActor () -> (any EventDropTransport)? = { nil }
    /// The hosted event whose short link is being made or updated (the share screen shows progress).
    private(set) var preparingShortLink: String?
    /// A short link is being fetched (guest).
    private(set) var fetchingDrop = false
    /// Imported events whose short link has ended (404/410): updates no longer arrive through it.
    private(set) var endedDrops: Set<String> = []
    /// Bumped when an organizer's short link is made or ended (it lives in the Keychain, which isn't observable).
    private(set) var shortLinkRevision = 0
    /// "Tampal pautan jemputan" (deferred link after install): shown on the first launches only.
    var showDeferredLinkCard = false
    @ObservationIgnored private var dropUploads: [String: Task<EventDropRef, Error>] = [:]
    @ObservationIgnored private var lastDropCheck: [String: Date] = [:]
    @ObservationIgnored private var lastHandledLink: (link: String, at: Date)?

    /// `personalStore` nil: a throwaway in-memory store (tests). The app passes `LocalStore.shared`.
    init(store: EventStore, personalStore: LocalStore? = nil, secrets: any EventSecretStore = KeychainEventSecretStore()) {
        self.store = store
        self.personalStore = personalStore ?? (try! LocalStore(path: nil, photosDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("manotu-test-photos-\(UUID().uuidString)", isDirectory: true)))
        self.secrets = secrets
    }

    // MARK: library

    /// Purges expired events (§7.5) and reloads. Called on launch, when the app comes to the foreground and when listing.
    func refresh() {
        events = (try? store.events(now: now())) ?? []
        for id in (try? store.expiredHostedIds(now: now())) ?? [] {
            try? store.deleteHosted(eventId: id)
            secrets.delete(eventId: id)
            // The server purges the expired drop by itself.
            secrets.deleteDrop(eventId: id)
            invites[id] = nil
        }
        hosted = (try? store.hostedEvents()) ?? []
        reloadPersonalRoutes()
        Self.cleanShareFiles(olderThan: now().addingTimeInterval(-24 * 3600))
    }

    func reloadPersonalRoutes() {
        personalRoutes = (try? personalStore.personalRoutes()) ?? []
    }

    // MARK: organizer

    func hostedEvent(_ id: String) -> HostedEvent? { hosted.first { $0.id == id } }

    /// "Acara baharu": a new draft with its own id (its keys are created on first publish).
    @discardableResult
    func newEvent() -> String {
        let d = HostedEventDraft.new(now: now())
        try? store.saveDraft(d)
        refresh()
        path.append(.create(d.id))
        return d.id
    }

    func saveDraft(_ d: HostedEventDraft) {
        var d = d
        d.updatedAt = now()
        try? store.saveDraft(d)
        hosted = (try? store.hostedEvents()) ?? hosted
    }

    /// Removes the draft, its published revisions and its keys from this phone. Copies already sent stay
    /// readable until their access ends.
    func deleteHosted(_ id: String) {
        // The short link goes too (§5.6): best effort, the server purges it at its expiry anyway.
        if let drop = secrets.loadDrop(eventId: id), let transport = dropTransport() {
            Task.detached { try? await transport.deleteDrop(id: drop.dropId, writeToken: drop.writeToken) }
        }
        secrets.deleteDrop(eventId: id)
        dropUploads[id]?.cancel()
        dropUploads[id] = nil
        shortLinkRevision += 1
        try? store.deleteHosted(eventId: id)
        secrets.delete(eventId: id)
        invites[id] = nil
        path.removeAll { $0 == .host(id) || $0 == .create(id) || $0 == .share(id) }
        refresh()
    }

    /// Publishes (a new revision when something changed) and opens "Kongsi jemputan". Returns an error message.
    /// Sealing the file runs Argon2id, so the work happens off the main actor.
    func publish(_ id: String) async -> String? {
        guard publishing == nil else { return nil }
        publishing = id
        defer { publishing = nil }
        let (store, secrets, at) = (store, secrets, now())
        let result = await Task.detached(priority: .userInitiated) {
            EventPublisher.publish(eventId: id, store: store, secrets: secrets, now: at)
        }.value
        switch result {
        case .success(let invite):
            invites[id] = invite
            hosted = (try? store.hostedEvents()) ?? hosted
            if path.last != .share(id) { path.append(.share(id)) }
            return nil
        case .failure(let e):
            return e.message
        }
    }

    /// "Acara sensitif" switched on after publishing: makes the suite-2 file for the published bytes (Argon2id, off the
    /// main actor). Returns an error message.
    func makeCodeFile(_ id: String) async -> String? {
        guard let invite = invites[id] else { return nil }
        if invite.codeFileBytes != nil { return nil }
        guard makingCodeFile == nil else { return nil }
        makingCodeFile = id
        defer { makingCodeFile = nil }
        let (secrets, bytes) = (secrets, invite.eventBytes)
        let result = await Task.detached(priority: .userInitiated) {
            EventPublisher.codeFile(eventId: id, eventBytes: bytes, secrets: secrets)
        }.value
        switch result {
        case .success(let file):
            if invites[id]?.eventBytes == bytes { invites[id]?.codeFileBytes = file }
            return nil
        case .failure(let e):
            return e.message
        }
    }

    /// The short link of the last publication (§5.6): uploads the encrypted blob the first time, PUTs it after a
    /// republish (the same link then shows the new revision), or reuses it when nothing changed. Gives up waiting after
    /// `timeout` seconds; the upload itself carries on and keeps its link for the next tap. On failure the caller falls
    /// back to the full link (§5.2.1).
    func shortLink(_ id: String, timeout: Double = 5) async -> Result<String, EventDropError> {
        guard let invite = invites[id] else { return .failure(.malformed) }
        guard let transport = dropTransport() else { return .failure(.network) }
        preparingShortLink = id
        defer { if preparingShortLink == id { preparingShortLink = nil } }
        let task: Task<EventDropRef, Error>
        if let running = dropUploads[id] {
            task = running
        } else {
            let (secrets, bytes, expires) = (secrets, invite.eventBytes, EventDrop.expiresAt(invite.doc))
            task = Task.detached(priority: .userInitiated) {
                try await EventDropPublisher.upload(eventId: id, eventBytes: bytes, expiresAt: expires, secrets: secrets, transport: transport)
            }
            dropUploads[id] = task
            Task { [weak self] in
                _ = try? await task.value
                if self?.dropUploads[id] == task { self?.dropUploads[id] = nil }
                self?.shortLinkRevision += 1
            }
        }
        do {
            let ref = try await withDropTimeout(seconds: timeout) { try await task.value }
            return .success(ref.link())
        } catch {
            return .failure(EventDropHTTP.classify(error))
        }
    }

    /// The short link already made for a hosted event, if any (no network).
    func existingShortLink(_ id: String) -> String? {
        _ = shortLinkRevision
        return secrets.loadDrop(eventId: id)?.ref?.link()
    }

    /// "Tamatkan pautan": deletes the drop on the server (guests who already imported keep their copy). Returns an
    /// error message, or nil when the link has ended.
    func endShortLink(_ id: String) async -> String? {
        guard let drop = secrets.loadDrop(eventId: id) else { return nil }
        guard let transport = dropTransport() else { return EventDropError.network.userMessage }
        dropUploads[id]?.cancel()
        dropUploads[id] = nil
        do {
            try await transport.deleteDrop(id: drop.dropId, writeToken: drop.writeToken)
        } catch {
            // Already gone on the server: nothing left to end.
            if EventDropHTTP.classify(error) != .gone { return String(localized: "Couldn't end the link. Check your connection and try again.") }
        }
        secrets.deleteDrop(eventId: id)
        shortLinkRevision += 1
        return nil
    }

    /// The safety code guests will see for a hosted event (§7.3), creating its organizer key if it has none yet.
    func hostSafetyCode(_ id: String) -> String? {
        if let pub = hostedEvent(id)?.organizerPub { return EventCodes.safetyCode(pub) }
        guard let pub = EventPublisher.ensureOrganizerKey(eventId: id, store: store, secrets: secrets) else { return nil }
        hosted = (try? store.hostedEvents()) ?? hosted
        return EventCodes.safetyCode(pub)
    }

    /// Whether the draft differs from what was last published (or was never published).
    func hasUnpublishedChanges(_ h: HostedEvent) -> Bool {
        guard let latest = try? store.latestHostedRevision(eventId: h.id) else { return true }
        if case .success(let p) = EventPublisher.prepare(h.draft, previousBytes: latest.eventBytes, now: now()) { return !p.reused }
        return true
    }

    /// `<title>.manotu-event` with only letters, digits, spaces, `-` and `&` kept (no path separators, dots or control
    /// characters), at most 60 characters; "acara" when nothing is left.
    nonisolated static func shareFileName(_ title: String) -> String {
        let kept = String(String.UnicodeScalarView(title.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "&"
        }))
        let safe = kept.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let name = safe.isEmpty ? "acara" : String(safe.prefix(60)).trimmingCharacters(in: .whitespaces)
        return "\(name).\(EventPack.fileExtension)"
    }

    /// The `.manotu-event` file for sharing, in a temporary folder (removed after a day): the open suite-3 file, or the
    /// suite-2 file when `codeFile` (it must have been made, see `makeCodeFile`).
    func inviteFileURL(_ id: String, codeFile: Bool = false) -> URL? {
        guard let invite = invites[id], let bytes = codeFile ? invite.codeFileBytes : invite.fileBytes else { return nil }
        let dir = Self.shareDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = dir.appendingPathComponent(Self.shareFileName(invite.doc.title))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(bytes).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }

    private static var shareDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("manotu-event-share", isDirectory: true)
    }

    private static func cleanShareFiles(olderThan cutoff: Date) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: shareDirectory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for u in items where ((try? u.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < cutoff {
            try? fm.removeItem(at: u)
        }
    }

    func event(_ id: String) -> ImportedEvent? {
        if let e = events.first(where: { $0.eventId == id }), !EventImport.isExpired(e.doc.expiresAt.date, now: now()) { return e }
        return nil
    }

    func delete(_ id: String) {
        try? store.delete(eventId: id)
        path.removeAll { $0 == .detail(id) }
        refresh()
    }

    func forkAlternatives(_ id: String) -> [ImportedEvent] {
        (try? store.forkAlternatives(eventId: id)) ?? []
    }

    func chooseFork(_ e: ImportedEvent) {
        try? store.choose(eventId: e.eventId, hash: e.hash)
        refresh()
    }

    func open() {
        refresh()
        path = []
        isPresented = true
    }

    // MARK: incoming

    /// `manotu://event#1.<key>.<ct>`, `gimano://event#…`, a pasted `https://…/a/#1.…`, or a `.manotu-event` file URL.
    /// Returns false when the URL isn't an event invitation.
    @discardableResult
    func handle(url: URL) -> Bool {
        if url.isFileURL {
            // Security-scoped when it comes from Files / another app's container ("Open in place" or the file picker).
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Some apps rename attachments: a file that starts with the "MNTE" magic is ours whatever its extension.
            guard url.pathExtension.lowercased() == EventPack.fileExtension || Self.hasFileMagic(url) else { return false }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let data = size <= EventLimits.maxFileBytes ? try? Data(contentsOf: url) : nil
            // Opened from another app: iOS copied it into our Inbox. Don't keep the encrypted copy around.
            if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
            present()
            if size > EventLimits.maxFileBytes {
                fail(.fileTooLarge)
            } else if let data {
                receiveFile([UInt8](data))
            } else {
                fail(.malformedFile)
            }
            return true
        }
        let raw = url.absoluteString
        // Short links (§5.6): https://manotu.app/j/#<dropId>.<secret>, manotu://event?drop=<dropId>#<secret>.
        if let ref = EventDrop.parse(raw) {
            present()
            focusStopId = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "stop" }?.value
            Task { await openDrop(ref) }
            return true
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let isAppLink = ["manotu", "gimano"].contains(scheme) && url.host?.lowercased() == "event"
        let path = url.path(percentEncoded: false)
        let isWebLink = ["https", "http"].contains(scheme) && (path.hasSuffix("/a/") || path.hasSuffix("/a"))
            && (url.fragment?.hasPrefix("1.") ?? false)
        guard isAppLink || isWebLink else { return false }
        present()
        // §5.3: `manotu://event?stop=<stopId>#…` selects that stop after import (ignored if unknown).
        focusStopId = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "stop" }?.value
        openLink(url.absoluteString)
        return true
    }

    /// The app's entry for URLs (`onOpenURL`) and Universal Links (`onContinueUserActivity`): the same link arriving
    /// through both within two seconds is handled once.
    @discardableResult
    func handleIncoming(url: URL) -> Bool {
        let raw = url.absoluteString
        if !url.isFileURL, let last = lastHandledLink, last.link == raw, Date().timeIntervalSince(last.at) < 2 { return true }
        let handled = handle(url: url)
        if handled, !url.isFileURL { lastHandledLink = (raw, Date()) }
        return handled
    }

    nonisolated private static func hasFileMagic(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 4)).map { [UInt8]($0) == EventPack.fileMagic } ?? false
    }

    private func present() {
        if !isPresented { path = [] }
        isPresented = true
        detent = .large
    }

    /// From the "Import invitation" field: a link, a bare fragment, or a whole message containing a link.
    func importPasted(_ text: String) {
        focusStopId = nil
        if let ref = EventDrop.find(inText: text) {
            Task { await openDrop(ref) }
            return
        }
        openLink(EventPack.extractLink(fromPasted: text))
    }

    // MARK: short links, guest (§5.6)

    /// Fetches, decrypts and verifies a short link's blob, then runs the normal import decision (§7).
    func openDrop(_ ref: EventDropRef) async {
        guard let transport = dropTransport() else {
            errorMessage = EventDropError.network.userMessage
            return
        }
        fetchingDrop = true
        defer { fetchingDrop = false }
        switch await Self.fetch(ref, transport: transport) {
        case .success(let pack):
            do {
                try decide(pack, drop: ref)
            } catch {
                fail(error)
            }
        case .failure(let e):
            errorMessage = e.userMessage
        }
    }

    /// Re-fetches the short link an imported event came from (when it is opened, and on pull to refresh) and offers a
    /// newer revision through the usual rules (§7.4). Without `force`, at most once a minute per event. Network errors
    /// are silent; an ended link (404/410) is remembered in `endedDrops`.
    func refreshDrop(_ id: String, force: Bool = false) async {
        guard let ref = try? store.drop(eventId: id), let transport = dropTransport() else { return }
        if !force, let last = lastDropCheck[id], now().timeIntervalSince(last) < 60 { return }
        lastDropCheck[id] = now()
        switch await Self.fetch(ref, transport: transport) {
        case .success(let pack):
            endedDrops.remove(id)
            guard pack.event.id == id, pending == nil, !path.contains(.confirm) else { return }
            let decision = EventImport.decide(EventImportCandidate(pack), stored: try? store.record(eventId: id), now: now())
            switch decision {
            case .newer, .fork, .upgradeToFull: try? decide(pack, drop: ref)
            default: break
            }
        case .failure(.gone):
            endedDrops.insert(id)
        case .failure:
            break
        }
    }

    /// Pull to refresh on the list: every event opened from a short link.
    func refreshAllDrops() async {
        for id in (try? store.dropEventIds()) ?? [] { await refreshDrop(id, force: true) }
    }

    func isDropEvent(_ id: String) -> Bool { (try? store.drop(eventId: id)) != nil }

    nonisolated private static func fetch(_ ref: EventDropRef, transport: any EventDropTransport) async -> Result<OpenedEventPack, EventDropError> {
        let blob: [UInt8]
        do {
            blob = try await transport.getDrop(id: ref.dropId)
        } catch {
            return .failure(EventDropHTTP.classify(error))
        }
        // Decrypt and inflate off the main actor.
        return await Task.detached(priority: .userInitiated) { () -> Result<OpenedEventPack, EventDropError> in
            do throws(EventDropError) { return .success(try EventDrop.open(blob: blob, secret: ref.secret)) } catch { return .failure(error) }
        }.value
    }

    // MARK: deferred link (§5.6, after install)

    /// Once per launch, on the first launches: shows "Tampal pautan jemputan" when the clipboard *looks like* it holds a
    /// web link. Only the pattern is checked (no paste prompt, nothing is read); the user pastes with the system control.
    func checkDeferredLink(defaults: UserDefaults = .standard) {
        let eligible = EventDeferredLink.isEligible(defaults: defaults, now: now(), hasEvents: !events.isEmpty || !hosted.isEmpty)
        guard eligible, UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs else { return }
        // UIKit calls this back on a background queue: as a plain closure it inherited the main actor and crashed
        // (dispatch_assert_queue) whenever the clipboard held a link.
        UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { @Sendable [weak self] result in
            guard case .success(let found) = result, found.contains(.probableWebURL) else { return }
            Task { @MainActor in self?.showDeferredLinkCard = true }
        }
    }

    /// The text the user pasted with the system paste control: opens a short or full invitation link (never imports by
    /// itself: the usual confirmation follows).
    func openDeferredPaste(_ text: String) {
        showDeferredLinkCard = false
        present()
        if let ref = EventDrop.find(inText: text) {
            focusStopId = nil
            Task { await openDrop(ref) }
        } else if text.contains("#1.") {
            importPasted(text)
        } else {
            errorMessage = String(localized: "That isn't a Manotu invitation link.")
        }
    }

    func openLink(_ link: String) {
        do {
            try decide(EventPack.openLink(link))
        } catch {
            fail(error)
        }
    }

    /// A `.manotu-event` file: suite 3 (the default share) opens at once, like a link; only suites 2 and 1 ask for the
    /// code the organizer sent separately. The suite is checked first.
    func receiveFile(_ bytes: [UInt8]) {
        let needsCode: Bool
        do {
            needsCode = try EventPack.fileNeedsCode(bytes)
        } catch {
            fail(error)
            return
        }
        guard needsCode else {
            pendingFile = nil
            path.removeAll { $0 == .secretCode }
            do {
                try decide(EventPack.openFileWithoutCode(bytes))
            } catch {
                fail(error)
            }
            return
        }
        pendingFile = bytes
        errorMessage = nil
        path.append(.secretCode)
    }

    /// Returns an error message for the secret-code screen, or nil when the file opened. Suite-2 files run Argon2id
    /// (64 MiB, a fraction of a second) off the main actor while `isOpeningFile` is set.
    func openPendingFile(secretCode: String) async -> String? {
        guard let bytes = pendingFile, !isOpeningFile else { return nil }
        isOpeningFile = true
        defer { isOpeningFile = false }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<OpenedEventPack, EventPackError> in
            do throws(EventPackError) { return .success(try EventPack.openFile(bytes, secretCode: secretCode)) } catch { return .failure(error) }
        }.value
        do {
            let pack = try result.get()
            guard pendingFile == bytes else { return nil }   // the file changed while deriving
            pendingFile = nil
            path.removeAll { $0 == .secretCode }
            try decide(pack)
            return nil
        } catch {
            return error.userMessage
        }
    }

    private func decide(_ pack: OpenedEventPack, drop: EventDropRef? = nil) throws(EventPackError) {
        // The organizer opening their own invitation: their event, not someone else's import.
        if EventPublisher.isOwn(pack, store: store) {
            pending = PendingEventImport(pack: pack, decision: .alreadyImported, stored: nil, isOwn: true)
            errorMessage = nil
            path.removeAll { $0 == .confirm }
            path.append(.confirm)
            return
        }
        let stored = try? store.record(eventId: pack.event.id)
        let decision = EventImport.decide(EventImportCandidate(pack), stored: stored, now: now())
        // §7.4: the full event of a stored stops-only link replaces it silently ("Laluan penuh ditambah").
        if case .upgradeToFull = decision {
            let id = pack.event.id
            if (try? store.save(pack, decision: decision, now: now())) == true { fullRouteAdded = id }
            if let drop { keepDrop(drop, eventId: id) }
            pending = nil
            errorMessage = nil
            refresh()
            path.removeAll { $0 == .confirm || $0 == .detail(id) }
            if event(id) != nil { path.append(.detail(id)) }
            return
        }
        let current = (try? store.events(now: now()))?.first { $0.eventId == pack.event.id }
        var changes: [EventChange] = []
        if case .newer = decision, let current { changes = EventChange.between(current.doc, pack.event) }
        pending = PendingEventImport(pack: pack, decision: decision, stored: current, changes: changes, drop: drop)
        errorMessage = nil
        path.removeAll { $0 == .confirm }
        path.append(.confirm)
    }

    private func fail(_ error: EventPackError) {
        errorMessage = error.userMessage
    }

    /// The user confirmed the pending import. Returns the event id when something was stored.
    @discardableResult
    func confirmPending() -> String? {
        guard let p = pending else { return nil }
        pending = nil
        let id = p.pack.event.id
        if p.isOwn {
            refresh()
            path = hostedEvent(id) != nil ? [.host(id)] : []
            return nil
        }
        let stored = (try? store.save(p.pack, decision: p.decision, now: now())) ?? false
        // The short link it came from stays with the event (also when it was already here), for later revisions.
        if let drop = p.drop { keepDrop(drop, eventId: id) }
        if stored { EventDeferredLink.markImported() }
        refresh()
        let opensStored = stored || p.decision == .alreadyImported || p.decision.code == "older"
        path = opensStored && event(id) != nil ? [.detail(id)] : []
        return stored ? id : nil
    }

    private func keepDrop(_ drop: EventDropRef, eventId: String) {
        try? store.saveDrop(drop, eventId: eventId)
        endedDrops.remove(eventId)
        lastDropCheck[eventId] = now()
    }

    func cancelPending() {
        pending = nil
        pendingFile = nil
        path.removeAll { $0 == .confirm || $0 == .secretCode }
    }

    /// The active trip's stop moved or was removed in the pending update (the destination never changes silently).
    func pendingAffectsTrip(_ p: PendingEventImport, trip: EventActiveTrip?) -> EventChange? {
        guard let t = trip, t.eventId == p.pack.event.id else { return nil }
        return EventChange.affectsTrip(p.changes, stopId: t.stopId)
    }

    // MARK: schedule

    /// "Seterusnya": the first stop whose arrival window (or the event) hasn't ended, in plan order.
    nonisolated static func nextStop(_ doc: EventDoc, now: Date) -> EventStop? {
        guard !doc.stops.isEmpty else { return nil }
        if doc.end.date <= now { return nil }
        return doc.stops.first { ($0.arrive?.to.date ?? doc.end.date) > now }
    }

    /// Travel mode for a stop: the first route that visits it, else nil (the user's own mode).
    nonisolated static func vehicle(for stop: EventStop, in doc: EventDoc) -> Vehicle? {
        guard let r = doc.routes.first(where: { $0.stopIds.contains(stop.id) }) else { return nil }
        return Vehicle(rawValue: r.mode.rawValue)
    }
}

extension AppModel {
    /// Short links (§5.6): the live server, also in auto mode. Demo mode has none, so the full link is shared.
    var eventDropTransport: (any EventDropTransport)? { repo as? any EventDropTransport }

    /// "Pandu": route preview to the stop's vehicle entrance (else its pin). The request carries coordinates only:
    /// no waypoint name, no place id (§7.7). The stop label is shown on this phone only and is not kept in recents.
    func navigate(toEventStop stop: EventStop, in doc: EventDoc) {
        events.isPresented = false
        clearEventFromMap()
        let destination = Destination(name: stop.label, address: doc.title, location: stop.navigationTarget, placeId: nil)
        planRoute(to: destination, remember: false, vehicle: EventCenter.vehicle(for: stop, in: doc), eventTrip: true)
        events.activeTrip = EventActiveTrip(eventId: doc.id, stopId: stop.id, target: stop.navigationTarget)
    }

    /// The trip to an event stop that is being previewed or driven right now, if any.
    var currentEventTrip: EventActiveTrip? {
        guard let t = events.activeTrip, let p = planner, p.isEventTrip,
              Geo.distance(p.destination.location, t.target) < 1 else { return nil }
        return t
    }

    /// "Guna pelan baharu": imports the newer revision; when the trip's stop moved, ends the drive and opens the
    /// route preview to the new position (the user starts it). Never changes the destination without this tap.
    func acceptEventUpdate() {
        guard let p = events.pending else { return }
        let affected = currentEventTrip.flatMap { t in
            EventChange.affectsTrip(p.changes, stopId: t.stopId).map { _ in t }
        }
        guard let id = events.confirmPending() else { return }
        showToast(String(localized: "Plan updated"))
        guard let t = affected, let e = events.event(id) else { return }
        if navigation != nil { stopNavigation() }
        if let stop = e.doc.stop(t.stopId) {
            navigate(toEventStop: stop, in: e.doc)
        } else {
            events.activeTrip = nil
        }
    }

    /// Draws the event's routes (and the next stop's pin) on the home map behind the Acara sheet.
    func showEventOnMap(_ e: ImportedEvent, routeId: String? = nil) {
        guard screen == .home else { return }
        let routes = e.doc.routes.enumerated().map { (offset, r) in
            RouteLine(id: "event-\(r.id)", points: r.points, selected: routeId.map { $0 == r.id } ?? (offset == 0), traffic: [])
        }
        map.routes = routes
        map.destination = EventCenter.nextStop(e.doc, now: .now)?.pin
        map.bubbleAnchors = [:]
        let focused = routeId == nil ? [] : routes.filter(\.selected).flatMap(\.points)
        let pts = focused.isEmpty ? e.doc.stops.map(\.pin) + routes.flatMap(\.points) : focused
        if let b = BBox.around(pts) {
            map.overviewInsets = (top: 80, bottom: 460)
            map.setCamera(.overview(b))
        }
    }

    func clearEventFromMap() {
        guard screen == .home, map.routes.contains(where: { $0.id.hasPrefix("event-") }) || map.destination != nil else { return }
        map.routes = []
        map.destination = nil
    }
}
