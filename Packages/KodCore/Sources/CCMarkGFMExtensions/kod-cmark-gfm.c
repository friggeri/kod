#include "kod-cmark-gfm.h"

#include "cmark-gfm-core-extensions.h"
#include "cmark-gfm-extension_api.h"
#include "strikethrough.h"
#include "table.h"

#include <pthread.h>
#include <string.h>

static pthread_once_t extensions_once = PTHREAD_ONCE_INIT;

static void register_extensions(void) {
  cmark_gfm_core_extensions_ensure_registered();
}

cmark_node *kod_cmark_parse_gfm(const char *source, size_t length) {
  static const char *extension_names[] = {
      "table", "tasklist", "strikethrough", "autolink", "tagfilter"};
  if (pthread_once(&extensions_once, register_extensions) != 0) {
    return NULL;
  }

  cmark_parser *parser = cmark_parser_new(CMARK_OPT_VALIDATE_UTF8);
  if (!parser) {
    return NULL;
  }

  for (size_t index = 0;
       index < sizeof(extension_names) / sizeof(extension_names[0]); index++) {
    cmark_syntax_extension *extension =
        cmark_find_syntax_extension(extension_names[index]);
    if (!extension ||
        !cmark_parser_attach_syntax_extension(parser, extension)) {
      cmark_parser_free(parser);
      return NULL;
    }
  }

  cmark_parser_feed(parser, source, length);
  cmark_node *document = cmark_parser_finish(parser);
  cmark_parser_free(parser);
  return document;
}

kod_cmark_node_kind kod_cmark_node_get_kind(cmark_node *node) {
  if (!node) {
    return KOD_CMARK_UNKNOWN;
  }
  cmark_node_type type = cmark_node_get_type(node);
  if (type == CMARK_NODE_DOCUMENT) return KOD_CMARK_DOCUMENT;
  if (type == CMARK_NODE_BLOCK_QUOTE) return KOD_CMARK_BLOCK_QUOTE;
  if (type == CMARK_NODE_LIST) return KOD_CMARK_LIST;
  if (type == CMARK_NODE_ITEM) return KOD_CMARK_ITEM;
  if (type == CMARK_NODE_CODE_BLOCK) return KOD_CMARK_CODE_BLOCK;
  if (type == CMARK_NODE_HTML_BLOCK) return KOD_CMARK_HTML_BLOCK;
  if (type == CMARK_NODE_PARAGRAPH) return KOD_CMARK_PARAGRAPH;
  if (type == CMARK_NODE_HEADING) return KOD_CMARK_HEADING;
  if (type == CMARK_NODE_THEMATIC_BREAK) return KOD_CMARK_THEMATIC_BREAK;
  if (type == CMARK_NODE_TEXT) return KOD_CMARK_TEXT;
  if (type == CMARK_NODE_SOFTBREAK) return KOD_CMARK_SOFTBREAK;
  if (type == CMARK_NODE_LINEBREAK) return KOD_CMARK_LINEBREAK;
  if (type == CMARK_NODE_CODE) return KOD_CMARK_CODE;
  if (type == CMARK_NODE_HTML_INLINE) return KOD_CMARK_HTML_INLINE;
  if (type == CMARK_NODE_EMPH) return KOD_CMARK_EMPH;
  if (type == CMARK_NODE_STRONG) return KOD_CMARK_STRONG;
  if (type == CMARK_NODE_LINK) return KOD_CMARK_LINK;
  if (type == CMARK_NODE_IMAGE) return KOD_CMARK_IMAGE;
  if (type == CMARK_NODE_STRIKETHROUGH) return KOD_CMARK_STRIKETHROUGH;
  if (type == CMARK_NODE_TABLE) return KOD_CMARK_TABLE;
  if (type == CMARK_NODE_TABLE_ROW) return KOD_CMARK_TABLE_ROW;
  if (type == CMARK_NODE_TABLE_CELL) return KOD_CMARK_TABLE_CELL;
  return KOD_CMARK_UNKNOWN;
}

int kod_cmark_task_state(cmark_node *node) {
  if (!node || strcmp(cmark_node_get_type_string(node), "tasklist") != 0) {
    return -1;
  }
  return cmark_gfm_extensions_get_tasklist_item_checked(node) ? 1 : 0;
}

char kod_cmark_table_alignment(cmark_node *table, int column) {
  uint16_t count = cmark_gfm_extensions_get_table_columns(table);
  uint8_t *alignments = cmark_gfm_extensions_get_table_alignments(table);
  if (!alignments || column < 0 || column >= count) {
    return '\0';
  }
  return (char)alignments[column];
}
