#include <sqlite3.h>

// SQLITE_TRANSIENT is a C macro (cast) that Swift cannot import directly.
// Re-export as a C constant for Swift bridging.
static const sqlite3_destructor_type _swift_sqlite_transient = (sqlite3_destructor_type)-1;
