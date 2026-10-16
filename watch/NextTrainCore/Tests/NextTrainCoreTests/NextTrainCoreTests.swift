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

    // The tests below need a timetable DB with a weekday service on 2026-10-19:
    //   NEXTTRAIN_DB=/path/watch.db NEXTTRAIN_HOME="<station>" NEXTTRAIN_WORK="<station>" swift test
    private func fixture() throws -> (Timetable, Station, Station, Date) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NEXTTRAIN_DB"], let home = env["NEXTTRAIN_HOME"], let work = env["NEXTTRAIN_WORK"] else {
            throw XCTSkip("NEXTTRAIN_DB / NEXTTRAIN_HOME / NEXTTRAIN_WORK not set")
        }
        let tt = try Timetable(path: path)
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 19; c.hour = 7; c.minute = 30
        c.timeZone = Brisbane.tz
        return (tt, try tt.findStation(home), try tt.findStation(work), Brisbane.calendar.date(from: c)!)
    }

    func testScheduledDeparturesAreOrderedAndFuture() throws {
        let (tt, home, work, now) = try fixture()
        let deps = try tt.nextTrains(from: home.id, to: work.id, now: now, query: Query(limit: 3, windowHours: 2))
        XCTAssertEqual(deps.count, 3)
        XCTAssertEqual(deps, deps.sorted { $0.time < $1.time })
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
}
