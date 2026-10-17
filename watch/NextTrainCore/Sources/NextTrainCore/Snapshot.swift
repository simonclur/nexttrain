import Foundation

public struct CommuteConfig: Sendable {
    public var home: String
    public var work: String
    public var fallback: (lat: Double, lon: Double)
    public var candidateStations = 3
    public var pastMinutes = 180
    public var maxFuture = 400
    public var futureHours = 24

    public init(home: String, work: String, fallback: (lat: Double, lon: Double),
                candidateStations: Int = 3, pastMinutes: Int = 180, maxFuture: Int = 400, futureHours: Int = 24) {
        self.home = home; self.work = work; self.fallback = fallback
        self.candidateStations = candidateStations; self.pastMinutes = pastMinutes
        self.maxFuture = maxFuture; self.futureHours = futureHours
    }
}

public enum Direction: String, Codable, Sendable { case home, work
    public var other: Direction { self == .home ? .work : .home }
}

public struct Route: Sendable {
    public let destination: String
    public let origin: String
    public let distanceKm: Double?
    public let trains: [Departure]
    public let assumed: Bool    // origin is assumed (return leg) rather than based on location
}

public struct Snapshot: Sendable {
    public let primary: Direction
    public var source: DirectionSource? = nil
    public let routes: [Direction: Route]
}

extension Timetable {
    /// Port of core.snapshot. `location` nil -> config fallback. `selected` is the direction of a train the user picked.
    public func snapshot(config cfg: CommuteConfig, location: (lat: Double, lon: Double)? = nil,
                         selected: Direction? = nil, where manual: Direction? = nil,
                         resolution: DirectionResolution? = nil,
                         now: Date = Date(), rt: [String: TripRealtime] = [:]) throws -> Snapshot {
        let dests: [Direction: Station] = [.home: try findStation(cfg.home), .work: try findStation(cfg.work)]
        let loc: (lat: Double, lon: Double)
        if let r = resolution {
            // without a trustworthy position, start from the station on the other side of the journey
            if r.usesLocation, let l = location { loc = l } else { let o = dests[r.direction.other]!; loc = (o.lat, o.lon) }
        } else if let m = manual, let d = dests[m] { loc = (d.lat, d.lon) } else { loc = location ?? cfg.fallback }

        let stations = try nearestStations(lat: loc.lat, lon: loc.lon, count: cfg.candidateStations)
        let far = dests.mapValues { haversineKm(loc.lat, loc.lon, $0.lat, $0.lon) }
        // the destination further away is the direction about to be travelled
        var primary: Direction = far[.home]! >= far[.work]! ? .home : .work
        if let s = selected, far[s]! > 1.0 { primary = s }
        if let r = resolution { primary = r.direction }

        let q = Query(limit: cfg.maxFuture, windowHours: cfg.futureHours, pastMinutes: cfg.pastMinutes)
        let dest = dests[primary]!
        var best: (key: Date, name: String, dist: Double, trains: [Departure])?
        for (stn, dist) in stations where stn.id != dest.id {
            let trains = try journeys(from: stn.id, to: dest.id, now: now, rt: rt, query: q)
            let upcoming = trains.filter { !$0.departed }
            if upcoming.isEmpty { continue }
            let walkMin = dist / 0.08   // ~4.8 km/h
            let usable = upcoming.filter { $0.time.timeIntervalSince(now) / 60 >= walkMin * 0.6 }
            let key = (usable.first ?? upcoming[0]).time.addingTimeInterval(walkMin * 60)
            if best == nil || key < best!.key { best = (key, stn.name, dist, trains) }
        }
        var routes: [Direction: Route] = [:]
        routes[primary] = Route(destination: dest.name, origin: best?.name ?? stations[0].0.name,
                                distanceKm: best?.dist ?? stations[0].1, trains: best?.trains ?? [], assumed: false)

        // return leg starts where the primary leg ends
        let other = primary.other
        routes[other] = Route(destination: dests[other]!.name, origin: dest.name, distanceKm: nil,
                              trains: try journeys(from: dest.id, to: dests[other]!.id, now: now, rt: rt, query: q),
                              assumed: true)
        return Snapshot(primary: primary, source: resolution?.source, routes: routes)
    }
}

extension Timetable {
    /// What every surface should call: records a fresh fix, resolves the direction with the shared rule, then builds the snapshot.
    public func resolvedSnapshot(config cfg: CommuteConfig, store: DirectionStore = DirectionStore(),
                                 location: (lat: Double, lon: Double)? = nil, selected: Direction? = nil,
                                 now: Date = Date(), rt: [String: TripRealtime] = [:]) throws -> Snapshot {
        if let l = location { store.recordFix(lat: l.lat, lon: l.lon, now: now) }
        let home = try findStation(cfg.home), work = try findStation(cfg.work)
        let res = store.resolve(home: (home.lat, home.lon), work: (work.lat, work.lon), now: now, selected: selected)
        return try snapshot(config: cfg, location: location ?? store.fix.map { ($0.lat, $0.lon) },
                            resolution: res, now: now, rt: rt)
    }
}
