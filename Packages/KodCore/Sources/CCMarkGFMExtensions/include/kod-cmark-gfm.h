#ifndef KOD_CMARK_GFM_H
#define KOD_CMARK_GFM_H

#include "cmark-gfm.h"

typedef enum {
  KOD_CMARK_UNKNOWN = 0,
  KOD_CMARK_DOCUMENT,
  KOD_CMARK_BLOCK_QUOTE,
  KOD_CMARK_LIST,
  KOD_CMARK_ITEM,
  KOD_CMARK_CODE_BLOCK,
  KOD_CMARK_HTML_BLOCK,
  KOD_CMARK_PARAGRAPH,
  KOD_CMARK_HEADING,
  KOD_CMARK_THEMATIC_BREAK,
  KOD_CMARK_TEXT,
  KOD_CMARK_SOFTBREAK,
  KOD_CMARK_LINEBREAK,
  KOD_CMARK_CODE,
  KOD_CMARK_HTML_INLINE,
  KOD_CMARK_EMPH,
  KOD_CMARK_STRONG,
  KOD_CMARK_LINK,
  KOD_CMARK_IMAGE,
  KOD_CMARK_STRIKETHROUGH,
  KOD_CMARK_TABLE,
  KOD_CMARK_TABLE_ROW,
  KOD_CMARK_TABLE_CELL
} kod_cmark_node_kind;

cmark_node *kod_cmark_parse_gfm(const char *source, size_t length);
kod_cmark_node_kind kod_cmark_node_get_kind(cmark_node *node);
int kod_cmark_task_state(cmark_node *node);
char kod_cmark_table_alignment(cmark_node *table, int column);

#endif
