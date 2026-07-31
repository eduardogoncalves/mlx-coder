// Sources/CTreeSitterSwift/include/CTreeSitterSwift.h
// Hand-authored bridging header (not upstream) exposing the grammar's
// exported TSLanguage getter to Swift. `TSLanguage` itself is defined by
// the `CTreeSitter` runtime target's public `tree_sitter/api.h` — this
// target depends on `CTreeSitter` (Package.swift) so both resolve to the
// exact same Clang-imported `TSLanguage` type in Swift.
#ifndef CTREESITTERSWIFT_H
#define CTREESITTERSWIFT_H

#include <tree_sitter/api.h>

#ifdef __cplusplus
extern "C" {
#endif

const TSLanguage *tree_sitter_swift(void);

#ifdef __cplusplus
}
#endif

#endif // CTREESITTERSWIFT_H
