#ifndef KOD_TREE_SITTER_TSX_H
#define KOD_TREE_SITTER_TSX_H

#include <tree_sitter/api.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns the compiled, pinned Tree-sitter TSX grammar.
/// The returned language pointer is owned by the grammar's static tables.
const TSLanguage *tree_sitter_tsx(void);

#ifdef __cplusplus
}
#endif

#endif
