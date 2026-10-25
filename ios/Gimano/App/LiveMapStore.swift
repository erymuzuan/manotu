import Foundation
import Observation

/// Alerts, jams and nearby drivers for the visible area: polls `GET /live?bbox=` and applies
/// SignalR pushes from `/hubs/live`.
@MainActor
@Observable
final class LiveMapStore {
    private(set) var alerts: [String: Report] = [:]
    private(set) var jams: [String: Jam] = [:]
    private(set) var drivers: [Driver] = []
    private(set) var hubStatus: LiveHubClient.Status = .disconnected
    /// Bumped on every change; cheap to observe.
    private(set) var revision = 0

    @ObservationIgnored private var repo: (any GimanoRepository)?
    @ObservationIgnored private var hub: LiveHubClient?
    @ObservationIgnored private var lastBBox: BBox?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?

    func configure(repo: any GimanoRepository, hubURL: URL?, tokenProvider: @escaping @Sendable () async -> String?) {
        self.repo = repo
        Task { await hub?.stop() }
        hub = nil
        hubStatus = .disconnected
        if let hubURL {
            let client = LiveHubClient(
                hubURL: hubURL,
                tokenProvider: tokenProvider,
                onEvent: { [weak self] e in Task { @MainActor in self?.apply(e) } },
                onStatus: { [weak self] s in Task { @MainActor in self?.hubStatus = s } }
            )
            hub = client
            Task { await client.start() }
        }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.refresh()
            }
        }
        if lastBBox != nil { Task { await refresh() } }
    }

    func viewportChanged(_ bbox: BBox) {
        // Pad the viewport a little so small pans don't refetch.
        if let lastBBox, lastBBox.contains(LatLng(lat: bbox.minLat, lng: bbox.minLng)), lastBBox.contains(LatLng(lat: bbox.maxLat, lng: bbox.maxLng)) {
            return
        }
        let padLat = (bbox.maxLat - bbox.minLat) * 0.25, padLng = (bbox.maxLng - bbox.minLng) * 0.25
        let padded = BBox(minLng: bbox.minLng - padLng, minLat: bbox.minLat - padLat, maxLng: bbox.maxLng + padLng, maxLat: bbox.maxLat + padLat)
        lastBBox = padded
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.refresh()
            await self?.hub?.subscribe(bbox: padded)
        }
    }

    func refresh() async {
        guard let repo, let bbox = lastBBox else { return }
        guard let res = try? await repo.live(bbox: bbox) else { return }
        alerts = Dictionary(res.alerts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        jams = Dictionary(res.jams.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        drivers = res.drivers
        revision += 1
    }

    func upsert(_ r: Report) {
        alerts[r.id] = r
        revision += 1
    }

    /// A report withdrawn with Undo.
    func remove(reportId: String) {
        guard alerts.removeValue(forKey: reportId) != nil else { return }
        revision += 1
    }

    func apply(_ e: LiveEvent) {
        switch e {
        case .alertCreated(let r), .alertUpdated(let r): alerts[r.id] = r
        case .alertExpired(let id): alerts[id] = nil
        // level 0 = jam cleared.
        case .jamUpdated(let j): jams[j.id] = j.level <= 0 ? nil : j
        }
        revision += 1
    }
}
