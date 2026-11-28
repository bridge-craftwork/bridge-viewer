import Foundation
import Synchronization
import Testing
@testable import PbnToPdfKit

/// Board 1 of a Brill daily IMP export, its play on record: 3♦ by South.
private let played = """
    [Board "1"]
    [Dealer "N"]
    [Vulnerable "None"]
    [Deal "N:QJ7.8.T9752.J752 K542.T7.QJ6.Q943 A863.Q932.K84.K8 T9.AKJ654.A3.AT6"]
    [Declarer "S"]
    [Contract "3D"]
    [Result "8"]
    [Play "W"]
    HA H8 H7 H2
    ST SJ S5 S3
    DA D9 D6 D4
    S9 SQ SK SA
    H4 D2 HT H9
    D3 D5 DJ DK
    H5 D7 DQ H3
    HJ S7 S4 S8
    HK DT C4 HQ
    CA C2 C3 CK
    H6 C5 C9 D8
    C6 CJ CQ C8
    CT C7 S2 S6

    """

@Test func solvingWritesTheTableAndThePlay() async throws {
    let seen = Mutex<[SolveProgress]>([])
    let (pbn, report) = try await Solver.solve(played) { p in seen.withLock { $0.append(p) } }
    #expect(pbn.hasPrefix(played.prefix(40)))
    #expect(pbn.contains("[DoubleDummyTricks "))
    #expect(pbn.contains("[DoubleDummyPlay \"W\"]"))
    #expect(report == SolveReport(tables: 1, plays: 1, skipped: []))
    let progress = seen.withLock { $0 }
    #expect(progress.first == SolveProgress(stage: .tables, done: 0, total: 5))
    #expect(progress.contains(SolveProgress(stage: .play, done: 1, total: 1)))

    // Solved already: the same text back, nothing done
    let (again, nothing) = try await Solver.solve(pbn)
    #expect(again == pbn)
    #expect(!nothing.changedAnything)
}

@Test func cancellingStopsTheSolve() async {
    let task = Task { try await Solver.solve(played) }
    task.cancel()
    await #expect(throws: SolveError.self) { try await task.value }
}
