#ifndef CMARK_CONFIG_H
#define CMARK_CONFIG_H

#include <stdbool.h>

#define HAVE_STDBOOL_H 1
#define HAVE___BUILTIN_EXPECT 1
#define HAVE___ATTRIBUTE__ 1
#define CMARK_ATTRIBUTE(list) __attribute__(list)
#define CMARK_INLINE inline

#endif
