//! C ABI over [`pbn_to_pdf`], for Swift.
//!
//! The same surface as the wasm bindings in pbn-to-pdf's `wasm/` crate:
//! PBN text and a layout name in, PDF bytes out. The renderer is already a
//! pure `&[Board] -> Vec<u8>` function with its fonts and card art compiled
//! in, so nothing crosses this boundary but strings and bytes.
//!
//! [`ptp_render_embedded`] is the one the app renders with. Its PDF carries
//! Contract 5's `pbn` profile (lesson-stage's `docs/contracts/
//! pdf-attachments.md`), so a saved or shared PDF opens in lesson-stage with
//! tappable boards, and it hands the click map back as JSON so the app can
//! build its board index without reading attachments out of the PDF.
//!
//! Ownership: every buffer or string this library returns is allocated here
//! and must come back through [`ptp_buffer_free`] or [`ptp_string_free`].
//! Panics are caught at the boundary and reported as errors -- unwinding into
//! Swift is undefined behaviour.
//!
//! The declarations Swift sees are hand-written in `include/PbnToPdfFFI.h`;
//! keep the two in step.

use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;
use std::str::FromStr;
use std::sync::Mutex;

use bridge_solver::annotate::{
    annotate_pbn, AnnotateError, AnnotateOptions, Progress, Report, Stage,
};

use pbn_to_pdf::cli::parse_board_range;
use pbn_to_pdf::{
    parse_pbn, render_boards, render_boards_embedded, Board, EmbedSource, Layout, RenderOptions,
};

/// Bytes owned by this library. Free with [`ptp_buffer_free`].
#[repr(C)]
pub struct PtpBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}

impl PtpBuffer {
    const EMPTY: Self = Self {
        ptr: ptr::null_mut(),
        len: 0,
    };

    fn from_vec(bytes: Vec<u8>) -> Self {
        let mut boxed = bytes.into_boxed_slice();
        let buffer = Self {
            ptr: boxed.as_mut_ptr(),
            len: boxed.len(),
        };
        std::mem::forget(boxed);
        buffer
    }
}

/// Render options. Mirrors the wasm `RenderOptions`; every field may be
/// left zeroed. `boards` is the CLI's `--boards` syntax, or null for all.
#[repr(C)]
pub struct PtpOptions {
    pub boards: *const c_char,
    pub circle_sure_winners: bool,
    pub circle_promotable_winners: bool,
    pub circle_length_winners: bool,
    pub omit_page_furniture: bool,
    pub all_play_records: bool,
    pub play_by_seat: bool,
}

/// Status codes. Anything but `PTP_OK` comes with an error string.
pub const PTP_OK: i32 = 0;
pub const PTP_ERROR: i32 = 1;
pub const PTP_PANIC: i32 = 2;

/// Render PBN text to a PDF.
///
/// On `PTP_OK`, `*out_pdf` holds the document. Otherwise `*out_error` holds a
/// message. Either way, free what you were given.
///
/// # Safety
/// `pbn` and `layout` must be valid NUL-terminated UTF-8. `options` may be
/// null. `out_pdf` and `out_error` must be valid for writes.
#[no_mangle]
pub unsafe extern "C" fn ptp_render(
    pbn: *const c_char,
    layout: *const c_char,
    options: *const PtpOptions,
    out_pdf: *mut PtpBuffer,
    out_error: *mut *mut c_char,
) -> i32 {
    boundary(out_pdf, out_error, || {
        let (pbn, layout, options) = (str_arg(pbn)?, str_arg(layout)?, read_options(options)?);
        render_selected(pbn, layout, &options, None, |boards| {
            select_boards(boards, options.boards.as_deref())
        })
        .map(|(pdf, _)| pdf)
    })
}

/// Render PBN text to a PDF carrying Contract 5's payload: the source file
/// embedded as `source_name`, the rendered boards, a click map, and a
/// `lesson-block:` link over each board.
///
/// On `PTP_OK`, `*out_pdf` holds the document and `*out_click_map` the click
/// map (`lesson-blocks.json`) as JSON. Otherwise `*out_error` holds a message.
/// Either way, free what you were given.
///
/// # Safety
/// As [`ptp_render`]; `source_name` must be valid NUL-terminated UTF-8, and
/// `out_click_map` valid for writes.
#[no_mangle]
pub unsafe extern "C" fn ptp_render_embedded(
    pbn: *const c_char,
    layout: *const c_char,
    options: *const PtpOptions,
    source_name: *const c_char,
    out_pdf: *mut PtpBuffer,
    out_click_map: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    out_click_map.write(ptr::null_mut());
    let mut click_map = None;
    let status = boundary(out_pdf, out_error, || {
        let (pbn, layout, options) = (str_arg(pbn)?, str_arg(layout)?, read_options(options)?);
        let name = str_arg(source_name)?;
        let (pdf, map) = render_selected(pbn, layout, &options, Some(name), |boards| {
            select_boards(boards, options.boards.as_deref())
        })?;
        click_map = map;
        Ok(pdf)
    });
    if status == PTP_OK {
        if let Some(map) = click_map {
            out_click_map.write(into_c_string(map));
        }
    }
    status
}

/// Render a preview of `layout`: its own representative number of boards,
/// taken positionally from the start of the file. Show the first page.
///
/// # Safety
/// As [`ptp_render`].
#[no_mangle]
pub unsafe extern "C" fn ptp_render_preview(
    pbn: *const c_char,
    layout: *const c_char,
    options: *const PtpOptions,
    out_pdf: *mut PtpBuffer,
    out_error: *mut *mut c_char,
) -> i32 {
    boundary(out_pdf, out_error, || {
        let (pbn, layout, options) = (str_arg(pbn)?, str_arg(layout)?, read_options(options)?);
        let count = Layout::from_str(layout)?.preview_boards() as usize;
        render_selected(pbn, layout, &options, None, |mut boards| {
            boards.truncate(count);
            Ok(boards)
        })
        .map(|(pdf, _)| pdf)
    })
}

/// The layout names `ptp_render` accepts, in CLI order, one per line.
/// Free with [`ptp_string_free`].
#[no_mangle]
pub extern "C" fn ptp_layouts() -> *mut c_char {
    let names: Vec<&str> = Layout::ALL.iter().map(Layout::as_str).collect();
    into_c_string(names.join("\n"))
}

/// Number of boards in a PBN document, or -1 if it cannot be read.
///
/// # Safety
/// `pbn` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn ptp_board_count(pbn: *const c_char) -> i64 {
    catch_unwind(|| {
        let pbn = str_arg(pbn).ok()?;
        Some(parse_pbn(pbn).ok()?.boards.len() as i64)
    })
    .ok()
    .flatten()
    .unwrap_or(-1)
}

/// A LIN file as PBN text: each record as the board Bridge Composer opens
/// it as (`bridge_encodings::lin::LinData::to_board`), written as PBN. The
/// app renders LIN through this, and saves the result as the file's PBN.
///
/// # Safety
/// `lin` must be valid NUL-terminated UTF-8. `out_pbn` and `out_error` must
/// be writable; whichever is set must be freed by the caller.
#[no_mangle]
pub unsafe extern "C" fn ptp_lin_to_pbn(
    lin: *const c_char,
    out_pbn: *mut PtpBuffer,
    out_error: *mut *mut c_char,
) -> i32 {
    boundary(out_pbn, out_error, || {
        let lin = str_arg(lin)?;
        let records = bridge_encodings::lin::parse_lin_file(lin).map_err(|e| e.to_string())?;
        let boards: Vec<_> = records.iter().map(|r| r.to_board()).collect();
        if boards.is_empty() {
            return Err("no boards in the LIN".into());
        }
        Ok(bridge_encodings::pbn::write_pbn(&boards).into_bytes())
    })
}

/// Where each board's record sits in a source file, as JSON
/// `[[start, end], ...]` byte offsets: PBN records as
/// `bridge_encodings::pbn::PbnDocument` divides them (record `i` is board `i`
/// of the parsed file, and of the click map), LIN records as
/// `parse_lin_file` divides them (record `i` is board `i` of the PBN that
/// [`ptp_lin_to_pbn`] makes). For View Source. Null if the text won't read.
///
/// # Safety
/// `text` must be valid NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn ptp_source_records(text: *const c_char, lin: bool) -> *mut c_char {
    catch_unwind(|| {
        let text = str_arg(text).ok()?;
        let spans = if lin {
            lin_records(text)
        } else {
            pbn_records(text)?
        };
        let json: Vec<String> = spans.iter().map(|(a, b)| format!("[{a},{b}]")).collect();
        Some(into_c_string(format!("[{}]", json.join(","))))
    })
    .ok()
    .flatten()
    .unwrap_or(ptr::null_mut())
}

/// Each PBN board's record, found in order: records are the file's own
/// text, one after another.
fn pbn_records(text: &str) -> Option<Vec<(usize, usize)>> {
    let doc = bridge_encodings::pbn::PbnDocument::parse(text).ok()?;
    let mut spans = Vec::with_capacity(doc.boards().len());
    let mut cursor = 0;
    for board in 0..doc.boards().len() {
        let record = doc.record(board)?;
        // Two boards sharing a block both return all of it
        let start = match text[cursor..].find(record) {
            Some(at) => cursor + at,
            None => text.find(record)?,
        };
        let end = start + record.len();
        spans.push((start, end));
        cursor = end.min(text.len());
    }
    Some(spans)
}

/// Each LIN board's tokens, split as `parse_lin_file` splits them: at each
/// `qx` (with the `mn`/`pn` before it) when the file has any, keeping those
/// with a deal, else one board per non-empty line.
fn lin_records(text: &str) -> Vec<(usize, usize)> {
    let doc = bridge_encodings::lin::LinDocument::parse(text);
    if !doc.tokens.iter().any(|t| t.is("qx")) {
        let mut spans = Vec::new();
        let mut at = 0;
        for line in text.split_inclusive('\n') {
            if !line.trim().is_empty() {
                spans.push((at, at + line.len()));
            }
            at += line.len();
        }
        return spans;
    }
    // Byte offset of each token, as `command|value|`
    let mut offsets = Vec::with_capacity(doc.tokens.len() + 1);
    let mut at = 0;
    for token in &doc.tokens {
        offsets.push(at);
        at += token.raw_command.len() + token.value.len() + 2;
    }
    offsets.push(at);
    let tokens = &doc.tokens;
    let mut starts = vec![0];
    for (i, token) in tokens.iter().enumerate() {
        if !token.is("qx") {
            continue;
        }
        let mut start = i;
        while start > 0 && (tokens[start - 1].is("mn") || tokens[start - 1].is("pn")) {
            start -= 1;
        }
        if start > starts.last().copied().unwrap_or(0) {
            starts.push(start);
        }
    }
    let mut spans = Vec::new();
    for (n, &start) in starts.iter().enumerate() {
        let end = starts.get(n + 1).copied().unwrap_or(tokens.len());
        if tokens[start..end].iter().any(|t| t.is("md")) {
            // A token's command carries the line break before it; start the
            // span at the command itself.
            let lead =
                tokens[start].raw_command.len() - tokens[start].raw_command.trim_start().len();
            spans.push((offsets[start] + lead, offsets[end]));
        }
    }
    spans
}

/// What Solve analyses. Every field may be left zeroed.
#[repr(C)]
pub struct PtpSolveOptions {
    /// Also analyse each recorded play card by card, into `[DoubleDummyPlay]`.
    pub play: bool,
    /// Redo boards that already carry analysis, rather than only filling in
    /// what is missing.
    pub recalculate: bool,
}

/// Progress for [`ptp_solve`]: `stage` is [`PTP_STAGE_TABLES`] (counted in
/// strains, five per board) or [`PTP_STAGE_PLAY`] (counted in boards), and
/// `done` of `total` are finished. Called as each stage starts and as each
/// item finishes, from the solver's worker threads but never two at once.
/// Return false to cancel.
pub type PtpProgress = Option<
    unsafe extern "C" fn(context: *mut c_void, stage: u32, done: usize, total: usize) -> bool,
>;

pub const PTP_CANCELLED: i32 = 3;
pub const PTP_STAGE_TABLES: u32 = 0;
pub const PTP_STAGE_PLAY: u32 = 1;

/// The progress callback and its context, shared with the worker threads.
/// The lock keeps calls into Swift one at a time.
struct ProgressSink {
    callback: PtpProgress,
    context: *mut c_void,
    lock: Mutex<()>,
}

// SAFETY: the context is only ever handed back to the caller's callback, one
// call at a time under `lock`; the caller promises it may be used from any
// thread (see `ptp_solve`).
unsafe impl Sync for ProgressSink {}

impl ProgressSink {
    fn report(&self, progress: Progress) -> bool {
        let Some(callback) = self.callback else {
            return true;
        };
        let stage = match progress.stage {
            Stage::Tables => PTP_STAGE_TABLES,
            Stage::Play => PTP_STAGE_PLAY,
        };
        let _one_at_a_time = self.lock.lock().unwrap_or_else(|e| e.into_inner());
        // SAFETY: the caller supplied the callback and context together and
        // keeps both alive for the duration of `ptp_solve`.
        unsafe { callback(self.context, stage, progress.done, progress.total) }
    }
}

/// Solve a PBN file double dummy, as bridge-solver's CLI does: each board
/// with a complete deal and no analysis yet gets `[DoubleDummyTricks]`, par
/// and `[OptimumResultTable]`, and with `options.play` each recorded play a
/// `[DoubleDummyPlay]` section. The rest of the file is kept byte for byte.
///
/// Runs on the calling thread, spreading the work over worker threads, and
/// returns when done: call it off the main thread. On `PTP_OK`, `*out_pbn`
/// holds the new text (UTF-8) and `*out_report` JSON
/// `{"tables": n, "plays": n, "skipped": [{"board": "4", "reason": "..."}]}`.
/// `PTP_CANCELLED` when `progress` returned false, with `*out_error` saying so.
/// Otherwise `*out_error` holds a message.
///
/// # Safety
/// `pbn` must be valid NUL-terminated UTF-8. `options` may be null.
/// `progress` may be null; if not, it and `context` must stay valid until
/// this returns and be callable from any thread. The out-parameters must be
/// valid for writes.
#[no_mangle]
pub unsafe extern "C" fn ptp_solve(
    pbn: *const c_char,
    options: *const PtpSolveOptions,
    progress: PtpProgress,
    context: *mut c_void,
    out_pbn: *mut PtpBuffer,
    out_report: *mut *mut c_char,
    out_error: *mut *mut c_char,
) -> i32 {
    out_report.write(ptr::null_mut());
    let mut report = None;
    let mut cancelled = false;
    let status = boundary(out_pbn, out_error, || {
        let pbn = str_arg(pbn)?;
        let solve = options.as_ref();
        let options = AnnotateOptions {
            play: solve.is_some_and(|o| o.play),
            recalculate: solve.is_some_and(|o| o.recalculate),
            ..AnnotateOptions::default()
        };
        let sink = ProgressSink {
            callback: progress,
            context,
            lock: Mutex::new(()),
        };
        match annotate_pbn(pbn, &options, &|p| sink.report(p)) {
            Ok((text, done)) => {
                report = Some(report_json(&done));
                Ok(text.into_bytes())
            }
            Err(AnnotateError::Cancelled) => {
                cancelled = true;
                Err("Cancelled.".into())
            }
            Err(e) => Err(e.to_string()),
        }
    });
    if cancelled {
        return PTP_CANCELLED;
    }
    if let Some(json) = report {
        out_report.write(into_c_string(json));
    }
    status
}

/// [`ptp_solve`]'s report as JSON.
fn report_json(report: &Report) -> String {
    let skipped: Vec<String> = report
        .skipped
        .iter()
        .map(|s| {
            format!(
                "{{\"board\":{},\"reason\":{}}}",
                json_string(&s.label),
                json_string(&s.reason)
            )
        })
        .collect();
    format!(
        "{{\"tables\":{},\"plays\":{},\"skipped\":[{}]}}",
        report.tables,
        report.plays,
        skipped.join(",")
    )
}

fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// # Safety
/// `buffer` must have come from this library, and be freed only once.
#[no_mangle]
pub unsafe extern "C" fn ptp_buffer_free(buffer: PtpBuffer) {
    if !buffer.ptr.is_null() {
        drop(Box::from_raw(ptr::slice_from_raw_parts_mut(
            buffer.ptr, buffer.len,
        )));
    }
}

/// # Safety
/// `s` must have come from this library, and be freed only once.
#[no_mangle]
pub unsafe extern "C" fn ptp_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

struct Options {
    boards: Option<String>,
    render: RenderOptions,
}

type Result<T> = std::result::Result<T, String>;

/// Run `body`, writing its result or error to the out-parameters, and never
/// letting a panic cross into Swift.
unsafe fn boundary(
    out_pdf: *mut PtpBuffer,
    out_error: *mut *mut c_char,
    body: impl FnOnce() -> Result<Vec<u8>>,
) -> i32 {
    out_pdf.write(PtpBuffer::EMPTY);
    out_error.write(ptr::null_mut());
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(bytes)) => {
            out_pdf.write(PtpBuffer::from_vec(bytes));
            PTP_OK
        }
        Ok(Err(message)) => {
            out_error.write(into_c_string(message));
            PTP_ERROR
        }
        Err(panic) => {
            let message = panic
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown panic".into());
            out_error.write(into_c_string(format!("Renderer panicked: {message}")));
            PTP_PANIC
        }
    }
}

unsafe fn str_arg<'a>(s: *const c_char) -> Result<&'a str> {
    if s.is_null() {
        return Err("null string argument".into());
    }
    CStr::from_ptr(s)
        .to_str()
        .map_err(|_| "argument is not UTF-8".into())
}

unsafe fn read_options(options: *const PtpOptions) -> Result<Options> {
    let Some(o) = options.as_ref() else {
        return Ok(Options {
            boards: None,
            render: RenderOptions::default(),
        });
    };
    let boards = if o.boards.is_null() {
        None
    } else {
        Some(str_arg(o.boards)?.to_string())
    };
    Ok(Options {
        boards,
        render: render_options(
            o.circle_sure_winners,
            o.circle_promotable_winners,
            o.circle_length_winners,
            o.omit_page_furniture,
            o.all_play_records,
            o.play_by_seat,
        ),
    })
}

fn render_options(
    sure: bool,
    promotable: bool,
    length: bool,
    omit: bool,
    all_play_records: bool,
    play_by_seat: bool,
) -> RenderOptions {
    RenderOptions {
        circle_sure_winners: sure,
        circle_promotable_winners: promotable,
        circle_length_winners: length,
        omit_page_furniture: omit,
        all_play_records,
        play_by_seat,
        // In-section commentary is section data, which BridgeComposer leaves
        // out; the app takes the matching default, as the browser does. Any
        // option the renderer adds later takes its default too, so a new
        // field there doesn't break this build.
        ..RenderOptions::default()
    }
}

fn into_c_string(s: String) -> *mut c_char {
    // A NUL inside a message would truncate it; replace rather than fail.
    CString::new(s.replace('\0', "\u{FFFD}"))
        .unwrap_or_default()
        .into_raw()
}

/// A board and its index in the file, which the embedded payload needs to copy
/// the board's record from the source as written.
type Numbered = (usize, Board);

/// Apply a `boards` spec the way the CLI's `--boards` does: select by
/// `[Board]` number, and drop boards that carry no number.
fn select_boards(boards: Vec<Numbered>, spec: Option<&str>) -> Result<Vec<Numbered>> {
    let Some(spec) = spec.map(str::trim).filter(|s| !s.is_empty()) else {
        return Ok(boards);
    };
    let wanted = parse_board_range(spec).map_err(|e| format!("Invalid board range: {e}"))?;
    let selected: Vec<Numbered> = boards
        .into_iter()
        .filter(|(_, b)| b.number.is_some_and(|n| wanted.contains(&n)))
        .collect();
    if selected.is_empty() {
        return Err(format!(
            "No boards matched '{spec}'. Boards are selected by their [Board] number, \
             which need not start at 1."
        ));
    }
    Ok(selected)
}

/// Parse, choose boards, render -- the body every entry point shares. With a
/// `source_name`, the PDF carries the Contract 5 payload and the click map
/// comes back too.
fn render_selected(
    pbn: &str,
    layout: &str,
    options: &Options,
    source_name: Option<&str>,
    choose: impl FnOnce(Vec<Numbered>) -> Result<Vec<Numbered>>,
) -> Result<(Vec<u8>, Option<String>)> {
    let layout = Layout::from_str(layout)?;
    let pbn_file = parse_pbn(pbn).map_err(|e| e.to_string())?;
    // parse_pbn yields an empty list for input with no boards, and rendering
    // that gives a blank PDF. Say so instead, as the CLI does.
    if pbn_file.boards.is_empty() {
        return Err("No boards found. Is this a PBN file?".into());
    }
    let (positions, boards): (Vec<usize>, Vec<Board>) =
        choose(pbn_file.boards.into_iter().enumerate().collect())?
            .into_iter()
            .unzip();
    // `%` header lines carry the Bridge Composer directives.
    let metadata_comments: Vec<String> = pbn
        .lines()
        .filter(|line| line.starts_with('%'))
        .map(String::from)
        .collect();
    let Some(name) = source_name else {
        return render_boards(&boards, &metadata_comments, layout, options.render)
            .map(|pdf| (pdf, None))
            .map_err(|e| e.to_string());
    };
    let source = EmbedSource { name, text: pbn };
    render_boards_embedded(
        &boards,
        &positions,
        &metadata_comments,
        layout,
        options.render,
        &source,
    )
    .map(|rendered| (rendered.pdf, Some(rendered.click_map)))
    .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const PBN: &str = "[Board \"1\"]\n[Dealer \"N\"]\n[Vulnerable \"None\"]\n\
        [Deal \"N:AKQ2.KQ2.AK2.432 JT98.JT9.QJT.QJT 7654.876.9876.98 3.A543.543.AK765\"]\n";

    unsafe fn call(
        f: unsafe extern "C" fn(
            *const c_char,
            *const c_char,
            *const PtpOptions,
            *mut PtpBuffer,
            *mut *mut c_char,
        ) -> i32,
        pbn: &str,
        layout: &str,
    ) -> std::result::Result<Vec<u8>, String> {
        let (pbn, layout) = (CString::new(pbn).unwrap(), CString::new(layout).unwrap());
        let mut out = PtpBuffer::EMPTY;
        let mut err = ptr::null_mut();
        let status = f(
            pbn.as_ptr(),
            layout.as_ptr(),
            ptr::null(),
            &mut out,
            &mut err,
        );
        if status == PTP_OK {
            let bytes = std::slice::from_raw_parts(out.ptr, out.len).to_vec();
            ptp_buffer_free(out);
            Ok(bytes)
        } else {
            let message = CStr::from_ptr(err).to_string_lossy().into_owned();
            ptp_string_free(err);
            Err(message)
        }
    }

    #[test]
    fn source_records_find_each_board() {
        let two = format!("{PBN}\n{}", PBN.replace("[Board \"1\"]", "[Board \"2\"]"));
        let spans = pbn_records(&two).unwrap();
        assert_eq!(spans.len(), 2);
        assert!(two[spans[0].0..spans[0].1].contains("[Board \"1\"]"));
        assert!(two[spans[1].0..spans[1].1].contains("[Board \"2\"]"));

        let lines = "pn|,,,|md|1S2,,,|mb|p|\npn|,,,|md|2S3,,,|\n";
        assert_eq!(lin_records(lines), vec![(0, 23), (23, lines.len())]);

        let qx = "qx|o1|md|1S2,,,|pc|S2|pg||\nqx|o2|md|1S3,,,|";
        let spans = lin_records(qx);
        assert_eq!(spans.len(), 2);
        assert!(qx[spans[0].0..spans[0].1].starts_with("qx|o1|"));
        assert!(qx[spans[1].0..spans[1].1].starts_with("qx|o2|"));
    }

    #[test]
    fn every_layout_renders_a_pdf() {
        for layout in Layout::ALL {
            let pdf = unsafe { call(ptp_render, PBN, layout.as_str()) }.unwrap();
            assert!(pdf.starts_with(b"%PDF-"), "{}", layout.as_str());
        }
    }

    #[test]
    fn errors_come_back_as_messages() {
        let err = unsafe { call(ptp_render, "not a pbn", "analysis") }.unwrap_err();
        assert!(err.contains("No boards"), "{err}");
        let err = unsafe { call(ptp_render, PBN, "no-such-layout") }.unwrap_err();
        assert!(!err.is_empty());
    }

    #[test]
    fn the_embedded_render_carries_the_payload_and_returns_its_click_map() {
        let (pbn, layout, name) = (
            CString::new(PBN).unwrap(),
            CString::new("hand-record").unwrap(),
            CString::new("Lesson.pbn").unwrap(),
        );
        let mut out = PtpBuffer::EMPTY;
        let mut map = ptr::null_mut();
        let mut err = ptr::null_mut();
        let status = unsafe {
            ptp_render_embedded(
                pbn.as_ptr(),
                layout.as_ptr(),
                ptr::null(),
                name.as_ptr(),
                &mut out,
                &mut map,
                &mut err,
            )
        };
        assert_eq!(status, PTP_OK);
        let pdf = unsafe { std::slice::from_raw_parts(out.ptr, out.len) }.to_vec();
        let json = unsafe { CStr::from_ptr(map) }.to_str().unwrap().to_owned();
        unsafe {
            ptp_buffer_free(out);
            ptp_string_free(map);
        }
        assert!(json.contains("\"version\":2"), "{json}");
        assert!(json.contains("\"kind\":\"board\""), "{json}");
        let text = String::from_utf8_lossy(&pdf);
        assert!(
            text.contains("(Lesson.pbn)"),
            "the source is embedded under its name"
        );
        assert!(text.contains("lesson-block:0"), "a link over the board");

        // The plain render stays plain.
        let plain = unsafe { call(ptp_render, PBN, "hand-record") }.unwrap();
        assert!(!String::from_utf8_lossy(&plain).contains("lesson-block:"));
    }

    #[test]
    fn layouts_are_listed_in_cli_order() {
        let s = ptp_layouts();
        let names = unsafe { CStr::from_ptr(s) }.to_str().unwrap().to_owned();
        unsafe { ptp_string_free(s) };
        let expected: Vec<&str> = Layout::ALL.iter().map(Layout::as_str).collect();
        assert_eq!(names.split('\n').collect::<Vec<_>>(), expected);
    }

    /// Calls to the progress callback, and whether to carry on.
    struct Seen {
        calls: Mutex<Vec<(u32, usize, usize)>>,
        carry_on: bool,
    }

    unsafe extern "C" fn record(
        context: *mut c_void,
        stage: u32,
        done: usize,
        total: usize,
    ) -> bool {
        let seen = &*(context as *const Seen);
        seen.calls.lock().unwrap().push((stage, done, total));
        seen.carry_on
    }

    unsafe fn solve(pbn: &str, carry_on: bool) -> (i32, String, String, Vec<(u32, usize, usize)>) {
        let pbn = CString::new(pbn).unwrap();
        let options = PtpSolveOptions {
            play: true,
            recalculate: false,
        };
        let seen = Seen {
            calls: Mutex::new(Vec::new()),
            carry_on,
        };
        let (mut out, mut report, mut err) = (PtpBuffer::EMPTY, ptr::null_mut(), ptr::null_mut());
        let status = ptp_solve(
            pbn.as_ptr(),
            &options,
            Some(record),
            &seen as *const Seen as *mut c_void,
            &mut out,
            &mut report,
            &mut err,
        );
        let text = if out.ptr.is_null() {
            String::new()
        } else {
            String::from_utf8(std::slice::from_raw_parts(out.ptr, out.len).to_vec()).unwrap()
        };
        ptp_buffer_free(out);
        let take = |s: *mut c_char| {
            if s.is_null() {
                return String::new();
            }
            let owned = CStr::from_ptr(s).to_string_lossy().into_owned();
            ptp_string_free(s);
            owned
        };
        let report = take(report);
        let err = take(err);
        (
            status,
            text,
            if status == PTP_OK { report } else { err },
            seen.calls.into_inner().unwrap(),
        )
    }

    #[test]
    fn solve_writes_the_analysis_and_reports_progress() {
        let (status, text, report, calls) = unsafe { solve(PBN, true) };
        assert_eq!(status, PTP_OK, "{report}");
        assert!(text.contains("[DoubleDummyTricks "), "{text}");
        assert!(text.starts_with(PBN), "the file is kept as written");
        assert_eq!(report, r#"{"tables":1,"plays":0,"skipped":[]}"#);
        assert_eq!(calls.first(), Some(&(PTP_STAGE_TABLES, 0, 5)));
        assert!(calls.contains(&(PTP_STAGE_TABLES, 5, 5)));
        // Solved already: nothing to do the second time
        let (status, again, report, _) = unsafe { solve(&text, true) };
        assert_eq!(status, PTP_OK);
        assert_eq!(again, text);
        assert_eq!(report, r#"{"tables":0,"plays":0,"skipped":[]}"#);
    }

    #[test]
    fn solve_stops_when_the_callback_says_so() {
        let (status, text, message, _) = unsafe { solve(PBN, false) };
        assert_eq!(status, PTP_CANCELLED);
        assert!(text.is_empty());
        assert_eq!(message, "Cancelled.");
    }

    #[test]
    fn the_report_escapes_its_strings() {
        let report = Report {
            tables: 1,
            plays: 0,
            skipped: vec![bridge_solver::annotate::Skipped {
                file: 0,
                board: 0,
                label: "4\"a".into(),
                reason: "line\nbreak".into(),
            }],
        };
        assert_eq!(
            report_json(&report),
            r#"{"tables":1,"plays":0,"skipped":[{"board":"4\"a","reason":"line\nbreak"}]}"#
        );
    }
}
