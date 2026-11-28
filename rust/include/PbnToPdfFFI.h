// C ABI of rust/src/lib.rs. Hand-written: keep it in step with the Rust.
//
// Every buffer or string returned here is owned by the library and must be
// released with ptp_buffer_free / ptp_string_free.

#ifndef PBN_TO_PDF_FFI_H
#define PBN_TO_PDF_FFI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define PTP_OK 0
#define PTP_ERROR 1
#define PTP_PANIC 2
#define PTP_CANCELLED 3

#define PTP_STAGE_TABLES 0
#define PTP_STAGE_PLAY 1

typedef struct PtpBuffer {
    uint8_t *ptr;
    size_t len;
} PtpBuffer;

typedef struct PtpOptions {
    /// The CLI's --boards syntax ("1-8", "5,8,12"), or NULL for every board.
    const char *boards;
    bool circle_sure_winners;
    bool circle_promotable_winners;
    bool circle_length_winners;
    bool omit_page_furniture;
    /// Draw every board's play record (analysis), not only those BCFlags ask for.
    bool all_play_records;
    /// Lay the play record out by seat, with [DoubleDummyPlay] costs.
    bool play_by_seat;
} PtpOptions;

/// Render PBN text to a PDF. `options` may be NULL.
int32_t ptp_render(const char *pbn, const char *layout, const PtpOptions *options,
                   PtpBuffer *out_pdf, char **out_error);

/// Render to a PDF carrying Contract 5's payload: the source embedded as
/// `source_name`, a click map, and a lesson-block: link over each board. On
/// PTP_OK, *out_click_map holds the click map JSON (free with ptp_string_free).
int32_t ptp_render_embedded(const char *pbn, const char *layout, const PtpOptions *options,
                            const char *source_name, PtpBuffer *out_pdf,
                            char **out_click_map, char **out_error);

/// Render a preview: the layout's representative opening boards.
int32_t ptp_render_preview(const char *pbn, const char *layout, const PtpOptions *options,
                           PtpBuffer *out_pdf, char **out_error);

/// Layout names in CLI order, newline-separated.
char *ptp_layouts(void);

/// Number of boards in a PBN document, or -1 if it cannot be read.
int64_t ptp_board_count(const char *pbn);

/// A LIN file as PBN text (UTF-8, in `out_pbn`), each record read as Bridge
/// Composer reads it.
int32_t ptp_lin_to_pbn(const char *lin, PtpBuffer *out_pbn, char **out_error);

/// Each board's record in a PBN (`lin` false) or LIN source, as JSON
/// `[[start, end], ...]` byte offsets; NULL if the text won't read.
char *ptp_source_records(const char *text, bool lin);

typedef struct PtpSolveOptions {
    /// Also analyse each recorded play card by card, into [DoubleDummyPlay].
    bool play;
    /// Redo boards that already carry analysis.
    bool recalculate;
} PtpSolveOptions;

/// Solve progress: `stage` is PTP_STAGE_TABLES (counted in strains, five per
/// board) or PTP_STAGE_PLAY (counted in boards). Called from worker threads,
/// one call at a time. Return false to cancel.
typedef bool (*PtpProgress)(void *context, uint32_t stage, size_t done, size_t total);

/// Solve a PBN file double dummy, as bridge-solver's CLI does, keeping the rest
/// of the file byte for byte. Blocks until done: call it off the main thread.
/// On PTP_OK, *out_pbn holds the new text and *out_report JSON
/// {"tables": n, "plays": n, "skipped": [{"board": "4", "reason": "..."}]}.
/// PTP_CANCELLED when `progress` returned false. `options` and `progress` may
/// be NULL; `context` is passed back to `progress`.
int32_t ptp_solve(const char *pbn, const PtpSolveOptions *options, PtpProgress progress,
                  void *context, PtpBuffer *out_pbn, char **out_report, char **out_error);

void ptp_buffer_free(PtpBuffer buffer);
void ptp_string_free(char *s);

#endif
