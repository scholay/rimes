#ifndef CRIMEBRIDGE_H
#define CRIMEBRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Max candidates we surface per page. Rime pages are small (this user: 5);
// 32 is a safe ceiling. Candidates beyond this on a page are ignored.
#define BB_MAX_CANDIDATES 32

// A single candidate on the CURRENT page. The string pointers are owned by the
// bridge and remain valid only until the next BBRimeGetContext call — the Swift
// side must copy them (String(cString:)) immediately.
typedef struct {
    const char* text;
    const char* comment;
    const char* label;   // selection label, e.g. "1".."5"
} BBRimeCandidate;

// Snapshot of the CURRENT-PAGE Rime context. Pointers are bridge-owned and live
// until the next BBRimeGetContext call; copy immediately.
typedef struct {
    bool active;                // raw input non-empty OR preedit OR candidates>0
    const char* preedit;        // composition preedit (may be empty)
    const char* input;          // raw input buffer
    int cursorPos;
    int selStart;
    int selEnd;
    int pageSize;
    int pageNo;
    bool isLastPage;
    int highlightedIndex;       // index within the current page
    int numCandidates;          // count on the current page (<= BB_MAX_CANDIDATES)
    BBRimeCandidate candidates[BB_MAX_CANDIDATES];
} BBRimeContext;

// Engine status. String pointers are bridge-owned, valid until the next
// BBRimeGetStatus call.
typedef struct {
    const char* schemaId;       // load-bearing: drives chord gating (my_combo)
    const char* schemaName;
    bool disabled;
    bool composing;
    bool asciiMode;
    bool fullShape;
    bool simplified;
    bool traditional;
    bool asciiPunct;
} BBRimeStatus;

// Lifecycle. BBRimeStart dlopens librime (preferring the app's own bundled copy
// under `frameworksDir`, falling back to a system Squirrel install), runs
// setup()+initialize(), deploys on first run, and only reports success if a
// smoke create_session() also succeeds. Pass frameworksDir="" to force the
// legacy Squirrel-only behaviour.
bool BBRimeStart(const char* sharedDataDir,
                 const char* userDataDir,
                 const char* logDir,
                 const char* frameworksDir);
bool BBRimeIsHealthy(void);

uint64_t BBRimeCreateSession(void);
void BBRimeDestroySession(uint64_t session);

bool BBRimeProcessKey(uint64_t session, int32_t keycode, int32_t mask);
bool BBRimeCommitComposition(uint64_t session);
void BBRimeClearComposition(uint64_t session);
bool BBRimeSelectCandidateOnCurrentPage(uint64_t session, uint64_t index);

bool BBRimeGetOption(uint64_t session, const char* option);
void BBRimeSetOption(uint64_t session, const char* option, bool value);
bool BBRimeSelectSchema(uint64_t session, const char* schemaId);
bool BBRimeDeploy(void);

// Read a double from a DEPLOYED config (e.g. configId="squirrel",
// key="chord_duration"). Returns false when missing/engine down.
bool BBRimeConfigGetDouble(const char* configId, const char* key, double* out);

// A deployed schema. Pointers are bridge-owned, valid until the next
// BBRimeGetSchemaList call; copy immediately.
typedef struct {
    const char* id;
    const char* name;
} BBRimeSchema;

// Fill `out` (caller-provided, capacity maxCount) with the schemas Rime has
// actually deployed, returning the count. Lets the UI offer real schemas
// instead of hard-coded ones, and lets us reject a stale/unavailable preference.
int BBRimeGetSchemaList(BBRimeSchema* out, int maxCount);

// Fill caller-provided structs. Return false when unavailable (engine down /
// no context). See ownership note on the struct typedefs.
bool BBRimeGetContext(uint64_t session, BBRimeContext* out);
bool BBRimeGetStatus(uint64_t session, BBRimeStatus* out);

char* BBRimeCopyCommit(uint64_t session);
char* BBRimeCopySchema(uint64_t session);
char* BBRimeCopyLastError(void);
void BBRimeFreeString(char* value);

// User-dictionary maintenance through librime's official `levers` module.
// Export/import closes every live Rime session before touching the LevelDB;
// the Swift caller MUST first settle composition and invalidate its cached
// per-controller session ids. The operations are synchronous and return an
// entry count, or -1 on failure. `dictName` is the translator's user_dict
// name (currently `rime_ice` for pinyin, `wubi86` for Wubi 86, and `english`
// for English).
int BBRimeExportUserDictionary(const char* dictName, const char* textFile);
int BBRimeImportUserDictionary(const char* dictName, const char* textFile);
bool BBRimeRestoreUserDictionarySnapshot(const char* snapshotFile);
bool BBRimeHasUserDictionary(const char* dictName);

// Lets a controller distinguish a live session from a nonzero id invalidated
// by dictionary maintenance.
bool BBRimeSessionExists(uint64_t session);

#ifdef __cplusplus
}
#endif

#endif
