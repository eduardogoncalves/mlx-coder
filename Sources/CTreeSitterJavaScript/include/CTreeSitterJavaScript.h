// Sources/CTreeSitterJavaScript/include/CTreeSitterJavaScript.h
// Hand-authored bridging header (not upstream) — see CTreeSitterSwift.h for
// the rationale (shared `TSLanguage` type via the `CTreeSitter` dependency).
#ifndef CTREESITTERJAVASCRIPT_H
#define CTREESITTERJAVASCRIPT_H

#include <tree_sitter/api.h>

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_javascript(void);

#ifdef __cplusplus
}
#endif

#endif // CTREESITTERJAVASCRIPT_H
