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

void ptp_buffer_free(PtpBuffer buffer);
void ptp_string_free(char *s);

#endif
