// Sources/CTreeSitterCSharp/include/CTreeSitterCSharp.h
// Hand-authored bridging header (not upstream) — see CTreeSitterSwift.h for
// the rationale (shared `TSLanguage` type via the `CTreeSitter` dependency).
#ifndef CTREESITTERCSHARP_H
#define CTREESITTERCSHARP_H

#include <tree_sitter/api.h>

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_c_sharp(void);

#ifdef __cplusplus
}
#endif

#endif // CTREESITTERCSHARP_H
