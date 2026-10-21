#ifndef S2I_DYNAMIC_H
#define S2I_DYNAMIC_H
#include "s2i_nso.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Read-only ELF64 inventory, never linking/execution readiness. Buffers must be
 * successful segment decodes from this plan; no BSS or gap bytes are readable.
 * Names borrow input storage, are byte strings (not necessarily UTF-8), and
 * remain valid only while all decoded buffers remain unchanged/alive. */
#define S2I_DYNAMIC_MAX_ENTRIES 1024u
#define S2I_DYNAMIC_MAX_SYMBOLS 65536u
#define S2I_DYNAMIC_MAX_NAME_LENGTH 4096u
#define S2I_DYNAMIC_MAX_NAME_BYTES (4u * 1024u * 1024u)
#define S2I_DYNAMIC_MAX_STRINGS (16u * 1024u * 1024u)
typedef struct { const uint8_t *bytes; size_t size; } s2i_dynamic_bytes;
typedef struct { const uint8_t *bytes; size_t size; } s2i_dynamic_name;
typedef struct {
 s2i_dynamic_name name;
 uint64_t value, size;
 uint32_t index;
 uint16_t section;
 uint8_t binding, type, visibility;
} s2i_dynamic_symbol;
typedef enum {
 S2I_DYNAMIC_OK = 0, S2I_DYNAMIC_INVALID_ARGUMENT,
 S2I_DYNAMIC_INVALID_RANGE, S2I_DYNAMIC_INVALID_FORMAT,
 S2I_DYNAMIC_RESOURCE_LIMIT, S2I_DYNAMIC_BUFFER_TOO_SMALL,
 S2I_DYNAMIC_UNSUPPORTED_METADATA
} s2i_dynamic_status;
enum {
 S2I_DYNAMIC_NO_MOD0 = 1u,
 S2I_DYNAMIC_MISSING_SYMBOL_BOUND = 2u,
 S2I_DYNAMIC_UNSUPPORTED_DEPENDENCY = 4u,
 S2I_DYNAMIC_UNSUPPORTED_SYMBOL = 8u,
 S2I_DYNAMIC_MISSING_SYMBOL_TAGS = 16u,
 S2I_DYNAMIC_GNU_HASH_UNSUPPORTED = 32u
};
typedef struct {
 uint64_t dynamic_address;
 size_t dynamic_entries, dependency_count, symbol_count, import_count, export_count;
 s2i_dynamic_name soname;
 uint32_t warnings;
 int dependencies_complete, imports_complete;
} s2i_dynamic_report;
/* Arrays may be NULL only at zero capacity. DT_NEEDED order/repetitions preserved.
 * All symbols are returned, including local/unsupported ones. Symbol
 * count includes ELF's null symbol, stored at index 0. Capacity 0 supports sizing.
 * BUFFER_TOO_SMALL returns validated counts/report; entries beyond capacity are
 * omitted. On any other error report is cleared; array contents are unspecified.
 * Inputs, report and output arrays must not alias. No allocation is performed.
 * Only DT_HASH/DT_SYMTABSZ bound symbols; GNU-hash-only is explicitly incomplete.
 * NSO optional header dynsym/dynstr extents are not part of this API/plan. */
s2i_dynamic_status s2i_dynamic_inspect(const s2i_nso_plan *plan,
 const s2i_dynamic_bytes decoded[3], s2i_dynamic_name *dependencies,
 size_t dependency_capacity, s2i_dynamic_symbol *symbols,
 size_t symbol_capacity, s2i_dynamic_report *report);
const char *s2i_dynamic_status_string(s2i_dynamic_status status);

/* Strict preparation metadata subset. Existing inventory API/ABI is unchanged.
 * Revalidates via the inventory parser, then accepts only baseline singleton tags
 * {4,5,6,7,8,9,10,11,12,14,39}; DT_NEEDED and every other tag are unsupported.
 * RELA requires all three tags even at zero length, entry size 24, 8-byte table
 * alignment, and a range within one ORIGINAL decoded segment (never BSS/gaps).
 * Output bytes borrow decoded storage. INIT is retained only, NEVER executed.
 * This inventories table bytes; it does not validate/apply relocation records.
 * Cleared output on failure; input/output must not alias. No allocation. */
#define S2I_DYNAMIC_MAX_RELOCATIONS 100000u
typedef struct {
 uint64_t rela_address, init_offset;
 s2i_dynamic_bytes rela;
 size_t relocation_count;
 int has_rela, has_init;
} s2i_dynamic_relocations;
s2i_dynamic_status s2i_dynamic_inspect_relocations(const s2i_nso_plan *,
 const s2i_dynamic_bytes decoded[3], s2i_dynamic_relocations *out);
#ifdef __cplusplus
}
#endif
#endif
