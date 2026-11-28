import PbnToPdfKit
import SwiftUI
import UniformTypeIdentifiers

/// A strip under the layout bar while a solve runs, and after it: progress
/// with Cancel, then what was done, with Save PBN while the analysis is only
/// in the app.
struct SolveBanner: View {
    @Environment(DocumentModel.self) private var model
    @State private var showingSkipped = false

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    @ViewBuilder private var content: some View {
        if model.isSolving {
            ProgressView(value: fraction)
                .frame(maxWidth: 160)
            Text(progressText)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Cancel") { model.cancelSolve() }
        } else if let outcome = model.solveOutcome {
            switch outcome {
            case .done(let report):
                Image(systemName: report.changedAnything ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(report.changedAnything ? .green : .secondary)
                Text(summary(report))
                if !report.skipped.isEmpty {
                    Button("\(report.skipped.count) skipped") { showingSkipped = true }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showingSkipped) { SkippedList(skipped: report.skipped) }
                }
                Spacer()
                if !report.changedAnything {
                    Button("Solve Again") { model.solve(recalculate: true) }
                        .help("Work every board out afresh, replacing the analysis it has")
                }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't solve: \(message)")
                Spacer()
            }
            if model.hasUnsavedAnalysis {
                Button("Save PBN…") { model.isExportingPBN = true }
                    .help("Save the file with its analysis")
            }
            Button("Dismiss", systemImage: "xmark") { model.dismissSolveOutcome() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }

    /// Tables are counted in strains, five to a board; the play in boards.
    private var fraction: Double {
        guard let p = model.solveProgress, p.total > 0 else { return 0 }
        return Double(p.done) / Double(p.total)
    }

    private var progressText: String {
        guard let p = model.solveProgress else { return "Starting…" }
        switch p.stage {
        case .tables:
            return "Solving board \(min(p.done / 5 + 1, max(p.total / 5, 1))) of \(p.total / 5)…"
        case .play:
            return "Analysing the play: \(p.done) of \(p.total) boards…"
        }
    }

    private func summary(_ report: SolveReport) -> String {
        func boards(_ n: Int) -> String { n == 1 ? "1 board" : "\(n) boards" }
        switch (report.tables, report.plays) {
        case (0, 0): return "Every board already has its analysis."
        case (let t, 0): return "Solved \(boards(t)) double dummy."
        case (0, let p): return "Analysed the play of \(boards(p))."
        case (let t, let p): return "Solved \(boards(t)) and analysed the play of \(p)."
        }
    }
}

/// The boards a solve left alone, and why.
private struct SkippedList: View {
    let skipped: [SolveReport.Skip]

    var body: some View {
        List(Array(skipped.enumerated()), id: \.offset) { _, skip in
            VStack(alignment: .leading, spacing: 2) {
                Text("Board \(skip.board)").font(.headline)
                Text(skip.reason).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 320, idealHeight: 240)
        .presentationDetents([.medium])
    }
}

/// PBN text, for `fileExporter`.
struct PBNTextFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pbn]
    let text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
