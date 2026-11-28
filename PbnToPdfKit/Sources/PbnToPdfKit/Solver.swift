import Foundation
import PbnToPdfFFI
import Synchronization

/// What a solve analyses.
public struct SolveOptions: Sendable, Equatable {
    /// Also analyse each recorded play card by card, into `[DoubleDummyPlay]`.
    public var play = true
    /// Redo boards that already carry analysis, rather than only filling in
    /// what is missing.
    public var recalculate = false

    public init() {}
}

/// How far a solve has got. Tables come first, counted in strains (five per
/// board), then the play, counted in boards.
public struct SolveProgress: Sendable, Equatable {
    public enum Stage: Sendable { case tables, play }
    public let stage: Stage
    public let done: Int
    public let total: Int

    public init(stage: Stage, done: Int, total: Int) {
        self.stage = stage
        self.done = done
        self.total = total
    }
}

/// What a solve did.
public struct SolveReport: Sendable, Equatable, Decodable {
    /// A board that needed analysis and was left alone, and why.
    public struct Skip: Sendable, Equatable, Decodable {
        /// The board's `[Board]` value.
        public let board: String
        public let reason: String
    }
    /// Boards given a double-dummy table.
    public let tables: Int
    /// Boards given a `[DoubleDummyPlay]` section.
    public let plays: Int
    public let skipped: [Skip]

    /// Whether the file came back changed.
    public var changedAnything: Bool { tables > 0 || plays > 0 }
}

public enum SolveError: LocalizedError, Sendable {
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Cancelled."
        case .failed(let message): message
        }
    }
}

/// Double-dummy analysis written into a PBN file: bridge-solver's
/// `annotate`, as its CLI runs it. The rest of the file is kept byte for byte.
public enum Solver {
    /// Solve `pbn`, returning the annotated text and what was done.
    ///
    /// Runs on its own threads; `progress` is called from them, one call at a
    /// time. Cancelling the task stops the solve as soon as the work in hand
    /// is done, and throws `SolveError.cancelled`.
    public static func solve(
        _ pbn: String,
        options: SolveOptions = .init(),
        progress: @escaping @Sendable (SolveProgress) -> Void = { _ in }
    ) async throws(SolveError) -> (pbn: String, report: SolveReport) {
        let context = Context(progress: progress)
        let result: Result<(String, SolveReport), SolveError> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // The solve blocks for as long as it takes, so it gets a thread
                // of its own rather than one of the cooperative pool's.
                Thread.detachNewThread {
                    continuation.resume(returning: run(pbn, options, context))
                }
            }
        } onCancel: {
            context.cancelled.store(true, ordering: .relaxed)
        }
        return try result.get()
    }

    /// The callback's state: where progress goes, and whether to stop.
    private final class Context: Sendable {
        let progress: @Sendable (SolveProgress) -> Void
        let cancelled = Atomic<Bool>(false)
        init(progress: @escaping @Sendable (SolveProgress) -> Void) { self.progress = progress }
    }

    private static func run(
        _ pbn: String, _ options: SolveOptions, _ context: Context
    ) -> Result<(String, SolveReport), SolveError> {
        var raw = PtpSolveOptions(play: options.play, recalculate: options.recalculate)
        var out = PtpBuffer(ptr: nil, len: 0)
        var report: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let opaque = Unmanaged.passRetained(context).toOpaque()
        defer { Unmanaged<Context>.fromOpaque(opaque).release() }
        let status = ptp_solve(pbn, &raw, { context, stage, done, total in
            guard let context else { return true }
            let me = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
            if me.cancelled.load(ordering: .relaxed) { return false }
            me.progress(SolveProgress(
                stage: stage == UInt32(PTP_STAGE_PLAY) ? .play : .tables, done: done, total: total))
            return true
        }, opaque, &out, &report, &error)
        let json = take(report)
        let message = take(error)
        if status == PTP_CANCELLED { return .failure(.cancelled) }
        guard status == PTP_OK, let ptr = out.ptr else {
            return .failure(.failed(message.isEmpty ? "Solving failed." : message))
        }
        let text = String(decoding: UnsafeBufferPointer(start: ptr, count: out.len), as: UTF8.self)
        ptp_buffer_free(out)
        guard let decoded = try? JSONDecoder().decode(SolveReport.self, from: Data(json.utf8)) else {
            return .failure(.failed("The solver's report didn't read."))
        }
        return .success((text, decoded))
    }

    private static func take(_ s: UnsafeMutablePointer<CChar>?) -> String {
        guard let s else { return "" }
        defer { ptp_string_free(s) }
        return String(cString: s)
    }
}
