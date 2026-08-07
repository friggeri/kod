#ifndef KOD_TREE_SITTER_JAVASCRIPT_H
#define KOD_TREE_SITTER_JAVASCRIPT_H

#include <tree_sitter/api.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns the compiled, pinned Tree-sitter grammar for this language.
/// The returned language pointer is owned by the grammar's static tables
/// and must not be freed.
const TSLanguage *tree_sitter_javascript(void);

#ifdef __cplusplus
}
#endif

#endif
