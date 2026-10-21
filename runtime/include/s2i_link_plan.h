#ifndef S2I_LINK_PLAN_H
#define S2I_LINK_PLAN_H
#include "s2i_module.h"
#ifdef __cplusplus
extern "C" {
#endif

/* Read-only symbolic inventory, NEVER a bound/executable/ready image. */
#define S2I_LINK_MAX_MODULES 16u
#define S2I_LINK_MAX_RELOCATIONS_PER_MODULE 100000u
#define S2I_LINK_MAX_RELOCATIONS 300000u
#define S2I_LINK_MAX_SYMBOLS 196608u
#define S2I_LINK_MAX_CANDIDATES 196608u
#define S2I_LINK_MAX_PEAK_BYTES (96u * 1024u * 1024u)
#define S2I_LINK_MAX_NAME_WORK (256u * 1024u * 1024u)
#define S2I_LINK_REPORT_BYTES 4096u

typedef struct s2i_link_plan s2i_link_plan;
typedef enum {
 S2I_LINK_OK = 0, S2I_LINK_INVALID_ARGUMENT, S2I_LINK_RESOURCE_LIMIT,
 S2I_LINK_NO_MEMORY, S2I_LINK_INVALID_METADATA, S2I_LINK_INVALID_TARGET,
 S2I_LINK_UNSUPPORTED_RELOCATION, S2I_LINK_INVALID_SYMBOL,
 S2I_LINK_INVALID_INDEX, S2I_LINK_BUFFER_TOO_SMALL
} s2i_link_status;
typedef enum {
 S2I_LINK_STAGE_NONE = 0, S2I_LINK_STAGE_OPTIONS, S2I_LINK_STAGE_MODULE,
 S2I_LINK_STAGE_METADATA, S2I_LINK_STAGE_GNU_HASH, S2I_LINK_STAGE_BUDGET,
 S2I_LINK_STAGE_ALLOCATION, S2I_LINK_STAGE_RELOCATION, S2I_LINK_STAGE_INVENTORY
} s2i_link_stage;
typedef struct {
 s2i_link_stage stage;
 size_t module_index, record_index; /* SIZE_MAX when not specific. */
} s2i_link_error;
typedef enum { S2I_LINK_INCOMPLETE = 0, S2I_LINK_VALIDATED = 1 } s2i_link_state;
typedef enum { S2I_LINK_POLICY_DEFERRED = 0 } s2i_link_policy;
typedef enum { S2I_LINK_GNU_ABSENT = 0, S2I_LINK_GNU_UNBOUNDED,
               S2I_LINK_GNU_VALIDATED, S2I_LINK_GNU_INCOMPLETE } s2i_link_gnu_state;
typedef struct {
 size_t max_peak_bytes; /* At most 96 MiB, includes retained modules. */
 size_t other_live_bytes; /* Other retained inputs/reports, not modules or this plan. */
 size_t max_relocations_per_module, max_relocations, max_symbols, max_candidates;
 size_t max_name_work; /* Charged bytes hashed/compared, hard 256 MiB ceiling. */
 s2i_module_allocator allocator;
} s2i_link_options;
typedef struct {
 s2i_link_state format, targets, inventory;
 s2i_link_policy policy; /* Always DEFERRED, even with a sole candidate. */
 size_t module_count, relocation_count, candidate_count, symbol_count;
 size_t source_module_bytes, owned_bytes, temporary_bytes, report_bytes;
 size_t other_live_bytes, creation_peak_bytes, name_work;
} s2i_link_summary;
typedef struct {
 s2i_link_state format, targets, inventory;
 s2i_link_policy policy;
 s2i_link_gnu_state gnu_hash;
 uint32_t original_warnings; /* Frozen module warnings are never cleared. */
 size_t rela_count, jmprel_count, symbol_count, dependency_count;
 size_t unknown_tag_count;
 uint64_t init_offset, fini_offset, init_array_offset, fini_array_offset;
 uint64_t init_array_size, fini_array_size, pltgot_offset, flags1;
 uint32_t present; /* bits: INIT, FINI, INIT_ARRAY, FINI_ARRAY, PLTGOT, FLAGS_1, DEBUG */
} s2i_link_module_report;
typedef enum { S2I_LINK_RELA = 0, S2I_LINK_JMPREL = 1 } s2i_link_table;
/* LOAD_BIAS means ABI Delta, not an assumed runtime base. Neither Delta nor S
 * is supplied, computed or selected by this API. */
typedef enum { S2I_LINK_LOAD_BIAS_PLUS_ADDEND = 0,
 S2I_LINK_SYMBOL_PLUS_ADDEND, S2I_LINK_JUMP_SLOT_PLATFORM_EXPRESSION } s2i_link_expression;
typedef struct {
 uint64_t target_offset, addend_bits; /* Two's-complement 64-bit signed addend bits. */
 uint32_t module_index, table_index, type, symbol_index;
 uint32_t candidate_start, candidate_count;
 s2i_link_table table;
 s2i_link_expression expression; /* Unevaluated. JUMP_SLOT addend policy unresolved. */
} s2i_link_relocation;
typedef struct {
 uint32_t module_index, symbol_index;
 uint64_t value, size;
 uint16_t section;
 uint8_t binding, type, visibility;
} s2i_link_candidate;

s2i_link_options s2i_link_default_options(void);
/* Input handles must be distinct and remain immutable/alive until plan destroy.
 * NO retain API or ownership transfer exists. Destroy plan BEFORE every module.
 * No concurrent reads/destroy/mutation; serial externally synchronized use only.
 * References in public output are numeric module/symbol indices, never pointers.
 * Candidates are ALL named defined symbols with byte-identical names, including
 * local/hidden/weak/special definitions: neither eligibility nor provider choice.
 * Inventory completeness concerns enumerating known symbols, NOT link resolution.
 * Names are raw bytes. No NUL/UTF-8/canonicalization assumptions in matching.
 * GNU is strictly checked only with independent SysV nchain; GNU-only metadata
 * remains incomplete. Unknown tags stay incomplete and are never dereferenced.
 * RELA + JMPREL: 24-byte LE, unique aligned 8-byte data/BSS logical targets only.
 * No BSS allocation, byte writes, addresses/bases, symbol lookup, code calls,
 * mappings, initializer execution, dependencies policy, ABI or value evaluation.
 * All requested allocations are charged along with modules, other_live_bytes and
 * (module_count+1)*4096 reserved report bytes. Reports are budget reservations,
 * not heap allocations. Stack/allocator overhead/RSS are outside this contract.
 * *out must start NULL; failures leave it NULL and release every new allocation.
 * Occupied output rejected unchanged. Allocator/alias/cancellation requirements
 * match s2i_module. Output parameters must not alias source or plan storage.
 */
s2i_link_status s2i_link_plan_create(const s2i_module *const *modules, size_t count,
 const s2i_link_options *, s2i_link_plan **out, s2i_link_error *error);
void s2i_link_plan_destroy(s2i_link_plan **owner); /* NULL-safe/idempotent owner. */
s2i_link_status s2i_link_plan_get_summary(const s2i_link_plan *, s2i_link_summary *);
s2i_link_status s2i_link_plan_get_module(const s2i_link_plan *, size_t, s2i_link_module_report *);
s2i_link_status s2i_link_plan_get_relocation(const s2i_link_plan *, size_t, s2i_link_relocation *);
s2i_link_status s2i_link_plan_get_candidate(const s2i_link_plan *, size_t, s2i_link_candidate *);
/* Same-byte-name candidate span for any symbol, without selecting a provider. */
s2i_link_status s2i_link_plan_candidates(const s2i_link_plan *, size_t module_index,
 size_t symbol_index, size_t *start, size_t *count);
/* Bounded copy, no borrowed pointer escape. Same semantics as module_copy_name. */
s2i_link_status s2i_link_plan_copy_name(const s2i_link_plan *, size_t module_index,
 s2i_module_name_kind, size_t index, uint8_t *destination, size_t capacity, size_t *required);
const char *s2i_link_status_string(s2i_link_status);
#ifdef __cplusplus
}
#endif
#endif
