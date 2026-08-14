// C ABI over the tree-sitter grammars Alas bundles.
//
// Language and query ids are listed in ../src/lib.rs. Both lookups return
// NULL for an unknown id rather than trapping, so a caller asking for a
// language Alas does not ship degrades to unhighlighted text.

#ifndef ALAS_TREESITTER_PACK_H
#define ALAS_TREESITTER_PACK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns the `TSLanguage *` for `id`, or NULL when `id` is unknown.
const void *alas_ts_language(const char *id);

// Returns the highlight query for `id` and writes its byte length to
// `out_len`, or NULL when `id` has no query. The bytes are static UTF-8 and
// are NOT NUL-terminated — read exactly `out_len` of them.
const uint8_t *alas_ts_query(const char *id, size_t *out_len);

#ifdef __cplusplus
}
#endif

#endif  // ALAS_TREESITTER_PACK_H
