import XCTest
@testable import NextTrainCore

final class NextTrainCoreTests: XCTestCase {
    // Generated with the Python gtfs_realtime_pb2 bindings: trip T1 (delay -120s at seq 3, +300s arrival at seq 5), T2 cancelled.
    let feedHex = "0a050a03322e30122b0a01311a260a040a025431121208031a0b0888ffffffffffffffff01220141120a0805120308ac02220142120d0a01321a080a060a0254322003"

    func data(_ hex: String) -> Data {
        var d = Data(), i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            d.append(UInt8(hex[i..<j], radix: 16)!); i = j
        }
        return d
    }

    func testParsesFeedAndDelays() {
        let rt = GTFSRealtime.parse(data(feedHex))
        XCTAssertEqual(rt["T1"]?.cancelled, false)
        XCTAssertEqual(rt["T2"]?.cancelled, true)
        let t1 = rt["T1"]!
        XCTAssertEqual(t1.delay(seq: 3, stopId: "A"), -120)
        XCTAssertEqual(t1.delay(seq: 4, stopId: "X"), -120)   // carries the last earlier delay
        XCTAssertEqual(t1.delay(seq: 5, stopId: "B"), 300)
    }

    // The tests below need a timetable DB with weekday service in the coming days; `now` is the next weekday 07:30:
    //   NEXTTRAIN_DB=/path/watch.db NEXTTRAIN_HOME="<station>" NEXTTRAIN_WORK="<station>" swift test
    private func fixture() throws -> (Timetable, Station, Station, Date) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NEXTTRAIN_DB"], let home = env["NEXTTRAIN_HOME"], let work = env["NEXTTRAIN_WORK"] else {
            throw XCTSkip("NEXTTRAIN_DB / NEXTTRAIN_HOME / NEXTTRAIN_WORK not set")
        }
        let tt = try Timetable(path: path)
        let cal = Brisbane.calendar
        var day = cal.date(byAdding: .day, value: 2, to: Date())!
        while cal.isDateInWeekend(day) { day = cal.date(byAdding: .day, value: 1, to: day)! }
        let now = cal.date(bySettingHour: 7, minute: 30, second: 0, of: day)!
        return (tt, try tt.findStation(home), try tt.findStation(work), now)
    }

    func testScheduledDeparturesAreOrderedAndFuture() throws {
        let (tt, home, work, now) = try fixture()
        let all = try tt.nextTrains(from: home.id, to: work.id, now: now, query: Query(limit: 3, windowHours: 2))
        XCTAssertEqual(all, all.sorted { $0.time < $1.time })
        // a train that left within the last minute may also be listed (marked departed)
        let deps = all.filter { !$0.departed }
        XCTAssertEqual(deps.count, 3)
        for d in deps {
            XCTAssertGreaterThanOrEqual(d.time, now)
            XCTAssertGreaterThan(d.arrive, d.time)
            XCTAssertFalse(d.live)
            XCTAssertFalse(d.headsign.isEmpty)
        }
    }

    func testSnapshotBuildsBothLegs() throws {
        let (tt, home, work, now) = try fixture()
        let cfg = CommuteConfig(home: home.name, work: work.name, fallback: (-27.4766, 153.0197))
        // standing at the home station -> travelling to work, and the return leg starts at work
        let snap = try tt.snapshot(config: cfg, where: .home, now: now)
        XCTAssertEqual(snap.primary, .work)
        XCTAssertEqual(snap.routes[.work]?.assumed, false)
        XCTAssertEqual(snap.routes[.home]?.assumed, true)
        XCTAssertEqual(snap.routes[.home]?.origin, work.name)
        XCTAssertFalse(snap.routes[.work]!.trains.isEmpty)
    }

    func testTripStopsRunFromBoardingToDestination() throws {
        let (tt, home, work, now) = try fixture()
        let d = try tt.nextTrains(from: home.id, to: work.id, now: now, query: Query(limit: 1, windowHours: 2))[0]
        let stops = try tt.tripStops(for: d)
        XCTAssertEqual(stops.first?.name, home.name)
        XCTAssertEqual(stops.last?.name, work.name)
        XCTAssertEqual(stops.first?.time, d.time)
        XCTAssertEqual(stops.last?.time, d.arrive)
        let rt = [d.tripId: TripRealtime(cancelled: false, updates: [StopUpdate(seq: d.seq, stopId: "", delay: 120)])]
        XCTAssertEqual(try tt.tripStops(for: d, rt: rt).last?.time, d.arrive.addingTimeInterval(120))
    }

    /// NEXTTRAIN_ARCHIVE = rail.db.z from publish_timetable.py; checks inflate + slimming end to end.
    func testInflateAndSlimPublishedArchive() throws {
        let (_, home, work, now) = try fixture()
        guard let archive = ProcessInfo.processInfo.environment["NEXTTRAIN_ARCHIVE"] else {
            throw XCTSkip("NEXTTRAIN_ARCHIVE not set")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let full = dir.appendingPathComponent("rail.db"), slim = dir.appendingPathComponent("watch.db")
        try TimetableSlimmer.inflate(URL(fileURLWithPath: archive), to: full)
        try TimetableSlimmer.slim(full: full, stationNames: [home.name, work.name], to: slim)
        let a = try Timetable(path: slim.path).nextTrains(from: home.id, to: work.id, now: now, query: Query(limit: 3, windowHours: 2))
        let b = try Timetable(path: full.path).nextTrains(from: home.id, to: work.id, now: now, query: Query(limit: 3, windowHours: 2))
        XCTAssertEqual(a.map(\.time), b.map(\.time))
        XCTAssertEqual(a.filter { !$0.departed }.count, 3)
        let size = { (u: URL) in try FileManager.default.attributesOfItem(atPath: u.path)[.size] as! Int }
        XCTAssertLessThan(try size(slim), try size(full))
    }

    func testTransferJourneysAreConsistent() throws {
        let (tt, home, work, now) = try fixture()
        let js = try tt.transferJourneys(from: home.id, to: work.id, now: now, query: Query(limit: 5, windowHours: 2))
        for j in js {
            XCTAssertNotNil(j.via)
            XCTAssertNotNil(j.leg2)
            XCTAssertGreaterThan(j.arrive, j.time)
            XCTAssertTrue(j.headsign.hasPrefix("change at \(j.via!)"))
        }
        XCTAssertEqual(js, js.sorted { $0.time < $1.time })
    }

    /// Needs the Oct 2026 timetable snapshot (Saturday trackwork: railbus + train). Matches Python core.journeys.
    func testTrackworkSaturdayNeedsAChange() throws {
        guard ProcessInfo.processInfo.environment["NEXTTRAIN_CHANGE_PARITY"] != nil else {
            throw XCTSkip("NEXTTRAIN_CHANGE_PARITY not set")
        }
        let (tt, home, work, _) = try fixture()
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 17; c.hour = 13; c.minute = 30
        c.timeZone = Brisbane.tz
        let now = Brisbane.calendar.date(from: c)!
        let js = try tt.journeys(from: home.id, to: work.id, now: now, query: Query(limit: 3, windowHours: 4))
        XCTAssertEqual(js.map { Format.clock($0.time) }, ["13:48", "14:18", "14:48"])
        XCTAssertEqual(js.map { Format.clock($0.arrive) }, ["14:59", "15:29", "15:59"])
        XCTAssertEqual(js.first?.via, "Northgate")
    }

    // MARK: direction rule (no data needed)

    private func at(_ hour: Int, minute: Int = 0) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 21; c.hour = hour; c.minute = minute
        c.timeZone = Brisbane.tz
        return Brisbane.calendar.date(from: c)!
    }
    private let homePos = (lat: -27.33, lon: 153.07), workPos = (lat: -27.47, lon: 153.02)

    func testDirectionFallsBackToTimeOfDay() {
        let r1 = DirectionResolver.resolve(now: at(7), home: homePos, work: workPos)
        XCTAssertEqual(r1, DirectionResolution(direction: .work, source: .timeOfDay))
        let r2 = DirectionResolver.resolve(now: at(17), home: homePos, work: workPos)
        XCTAssertEqual(r2, DirectionResolution(direction: .home, source: .timeOfDay))
    }

    func testFreshLocationBeatsTimeOfDayButStaleDoesNot() {
        let now = at(17)   // evening would say home
        let nearHome = LastFix(lat: homePos.lat, lon: homePos.lon, time: now.addingTimeInterval(-60))
        XCTAssertEqual(DirectionResolver.resolve(now: now, home: homePos, work: workPos, fix: nearHome).direction, .work)
        let stale = LastFix(lat: homePos.lat, lon: homePos.lon, time: now.addingTimeInterval(-3600))
        XCTAssertEqual(DirectionResolver.resolve(now: now, home: homePos, work: workPos, fix: stale),
                       DirectionResolution(direction: .home, source: .timeOfDay))
    }

    func testManualOverrideWinsUntilItExpires() {
        let now = at(7)
        let o = DirectionOverride(direction: .home, expires: now.addingTimeInterval(600))
        let nearHome = LastFix(lat: homePos.lat, lon: homePos.lon, time: now)
        XCTAssertEqual(DirectionResolver.resolve(now: now, home: homePos, work: workPos, fix: nearHome, override: o),
                       DirectionResolution(direction: .home, source: .manual))
        XCTAssertEqual(DirectionResolver.resolve(now: now.addingTimeInterval(700), home: homePos, work: workPos,
                                                 override: o).source, .timeOfDay)
    }

    func testSelectedTrainDecidesUnlessArrived() {
        let now = at(7)
        XCTAssertEqual(DirectionResolver.resolve(now: now, home: homePos, work: workPos, selected: .home).source, .selected)
        let atHome = LastFix(lat: homePos.lat, lon: homePos.lon, time: now)
        // standing at the selected train's destination: fall through to location (travel away from home = work)
        let r = DirectionResolver.resolve(now: now, home: homePos, work: workPos, fix: atHome, selected: .home)
        XCTAssertEqual(r, DirectionResolution(direction: .work, source: .location))
    }

    func testOverrideExpiresAtFourAmOrThreeHours() {
        XCTAssertEqual(DirectionResolver.overrideExpiry(from: at(7)), at(10))
        XCTAssertEqual(DirectionResolver.overrideExpiry(from: at(2)), at(4))
        XCTAssertEqual(DirectionResolver.overrideExpiry(from: at(23)), at(2).addingTimeInterval(86400))
    }

    func testStoreRoundTripsFixAndOverride() {
        let d = UserDefaults(suiteName: "nt.test.\(UUID().uuidString)")!
        let store = DirectionStore(defaults: d)
        let now = at(7)
        store.recordFix(lat: 1, lon: 2, now: now)
        store.setOverride(.home, now: now)
        XCTAssertEqual(store.fix, LastFix(lat: 1, lon: 2, time: now))
        XCTAssertEqual(store.override?.direction, .home)
        store.setOverride(nil)
        XCTAssertNil(store.override)
    }

    /// Widget (no location) and app (fresh location) must agree when the user is where time of day says they are.
    func testResolvedSnapshotAgreesBetweenAppAndWidget() throws {
        let (tt, home, work, now) = try fixture()
        let cfg = CommuteConfig(home: home.name, work: work.name, fallback: (-27.4766, 153.0197))
        let mk = { UserDefaults(suiteName: "nt.test.\(UUID().uuidString)")! }
        // morning at the home station
        let app = try tt.resolvedSnapshot(config: cfg, store: DirectionStore(defaults: mk()),
                                          location: (home.lat, home.lon), now: now)
        let widget = try tt.resolvedSnapshot(config: cfg, store: DirectionStore(defaults: mk()), now: now)
        XCTAssertEqual(app.primary, .work)
        XCTAssertEqual(widget.primary, app.primary)
        XCTAssertEqual(widget.routes[.work]?.origin, app.routes[.work]?.origin)
    }

    /// Away from both commute stations, the boarding station follows you, whatever decided the direction.
    func testBoardingStationFollowsLocationWhenAwayFromHomeAndWork() throws {
        let (tt, home, work, now) = try fixture()
        let cfg = CommuteConfig(home: home.name, work: work.name, fallback: (-27.4766, 153.0197))
        guard let other = try tt.stations().first(where: { $0.id != home.id && $0.id != work.id }) else { throw XCTSkip("one station") }
        let store = DirectionStore(defaults: UserDefaults(suiteName: "nt.test.\(UUID().uuidString)")!)
        store.setOverride(.work, now: now)
        let snap = try tt.resolvedSnapshot(config: cfg, store: store, location: (other.lat, other.lon), now: now)
        let near = try tt.nearestStations(lat: other.lat, lon: other.lon, count: cfg.candidateStations).map(\.0.name)
        let origin = try XCTUnwrap(snap.routes[snap.primary]?.origin)
        XCTAssertTrue(near.contains(origin), "\(origin) not near \(other.name)")
    }

    func testTimelineHasOneEntryPerDepartureAndAdvances() throws {
        let (tt, home, work, now) = try fixture()
        let cfg = CommuteConfig(home: home.name, work: work.name, fallback: (-27.4766, 153.0197))
        let snap = try tt.snapshot(config: cfg, where: .home, now: now)
        let entries = TimelineBuilder.entries(from: snap, now: now)
        XCTAssertGreaterThan(entries.count, 1)
        XCTAssertEqual(entries.first?.date, now)
        XCTAssertEqual(entries.map(\.date), entries.map(\.date).sorted())
        for e in entries {
            XCTAssertLessThanOrEqual(e.trains.count, 3)
            XCTAssertTrue(e.trains.allSatisfy { $0.time >= e.date })
            XCTAssertEqual(e.direction, snap.primary)
        }
        XCTAssertEqual(TimelineBuilder.failure("x", now: now).note, "x")
    }

    func testTrackedTrainAlertsRunFifteenToTenThenArrival() throws {
        let (tt, home, work, now) = try fixture()
        let cfg = CommuteConfig(home: home.name, work: work.name, fallback: (-27.4766, 153.0197))
        let snap = try tt.snapshot(config: cfg, where: .home, now: now)
        let r = snap.routes[.work]!
        let d = r.trains.first { $0.time > now.addingTimeInterval(3600) }!
        let t = TrackedTrain(d, direction: .work, origin: r.origin, destination: r.destination)
        let plan = AlertPlanner.tracked(t, now: d.time.addingTimeInterval(-3600))
        XCTAssertEqual(plan.count, 7)                       // 15,14,13,12,11,10 min + arrival
        XCTAssertEqual(plan.first?.fire, d.time.addingTimeInterval(-15 * 60))
        XCTAssertEqual(plan[5].fire, d.time.addingTimeInterval(-10 * 60))
        XCTAssertTrue(plan.last!.title.hasPrefix("🚆 Arriving"))
        // after the 12-minute mark only 11, 10 and the arrival alert remain
        XCTAssertEqual(AlertPlanner.tracked(t, now: d.time.addingTimeInterval(-12 * 60 + 5)).count, 3)
        XCTAssertTrue(t.isFinished(now: d.arrive.addingTimeInterval(61)))
        XCTAssertFalse(t.isFinished(now: d.arrive))
    }

    func testTrackStoreSelectsTogglesAndDropsFinished() throws {
        let (tt, home, work, now) = try fixture()
        let cfg = CommuteConfig(home: home.name, work: work.name, fallback: (-27.4766, 153.0197))
        let snap = try tt.snapshot(config: cfg, where: .home, now: now)
        let r = snap.routes[.work]!
        let d = r.trains.first { $0.time > now }!
        let store = TrackStore(defaults: UserDefaults(suiteName: "nt.test.\(UUID().uuidString)")!)
        let t = TrackedTrain(d, direction: .work, origin: r.origin, destination: r.destination)
        store.toggle(t)
        XCTAssertEqual(store.selectedDirection, .work)
        XCTAssertEqual(store.update(from: snap, now: now).count, 1)
        XCTAssertTrue(store.update(from: snap, now: d.arrive.addingTimeInterval(3600)).isEmpty)
        store.toggle(t); store.toggle(t)
        XCTAssertTrue(store.tracked.isEmpty)
    }

    func testCommuteAlertsFollowWindowAndWeekdays() {
        // Saturday 17 Oct 2026 10:00 Brisbane: nothing; the next weekday window is Monday 19th
        let cal = Brisbane.calendar
        let sat = cal.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 10))!
        let plan = AlertPlanner.commute(now: sat, days: 2) { _, d in ("t \(d.rawValue)", "b") }
        XCTAssertFalse(plan.isEmpty)
        let comps = plan.map { cal.dateComponents([.weekday, .hour, .minute], from: $0.fire) }
        XCTAssertTrue(comps.allSatisfy { (2...6).contains($0.weekday!) })
        XCTAssertEqual(plan.filter { $0.title == "t work" }.count, 5 * 1)   // 06:30..07:10 on Monday only
        XCTAssertEqual(plan.first?.fire, cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 6, minute: 30)))
    }
}
