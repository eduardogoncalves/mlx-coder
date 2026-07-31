// Sources/CTreeSitterTypeScript/include/CTreeSitterTypeScript.h
// Hand-authored bridging header (not upstream) — see CTreeSitterSwift.h for
// the rationale (shared `TSLanguage` type via the `CTreeSitter` dependency).
// This target vendors the "typescript" sub-grammar only (tier-1 scope is
// `.ts`; `.tsx`/JSX is not covered in M5 tier-1 — see the sync-grammars
// table if that's added later).
#ifndef CTREESITTERTYPESCRIPT_H
#define CTREESITTERTYPESCRIPT_H

#include <tree_sitter/api.h>

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_typescript(void);

#ifdef __cplusplus
}
#endif

#endif // CTREESITTERTYPESCRIPT_H
