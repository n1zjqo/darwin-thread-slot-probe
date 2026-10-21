#ifndef S2I_PREPARED_H
#define S2I_PREPARED_H
#include "s2i_module.h"
#ifdef __cplusplus
extern "C" {
#endif

/* Sparse private data, not executable host memory and not a complete linker. */
#define S2I_PREPARED_MAX_IMAGE_BYTES (64u * 1024u * 1024u)
typedef struct s2i_prepared s2i_prepared;
typedef enum {
 S2I_PREPARED_OK = 0, S2I_PREPARED_INVALID_ARGUMENT,
 S2I_PREPARED_RESOURCE_LIMIT, S2I_PREPARED_NO_MEMORY,
 S2I_PREPARED_UNSUPPORTED_METADATA, S2I_PREPARED_INVALID_LAYOUT,
 S2I_PREPARED_UNSUPPORTED_SYMBOL, S2I_PREPARED_UNRESOLVED_SYMBOL,
 S2I_PREPARED_INVALID_RELOCATION, S2I_PREPARED_UNSUPPORTED_RELOCATION,
 S2I_PREPARED_ARITHMETIC_OVERFLOW, S2I_PREPARED_INVALID_ACCESS
} s2i_prepared_status;
typedef enum {
 S2I_PREPARED_STAGE_NONE = 0, S2I_PREPARED_STAGE_MODULE,
 S2I_PREPARED_STAGE_METADATA, S2I_PREPARED_STAGE_LAYOUT,
 S2I_PREPARED_STAGE_BUDGET, S2I_PREPARED_STAGE_ALLOCATION,
 S2I_PREPARED_STAGE_SYMBOL, S2I_PREPARED_STAGE_RELOCATION
} s2i_prepared_stage;
typedef struct {
 s2i_prepared_stage stage;
 s2i_dynamic_status dynamic_status;
 size_t index; /* SIZE_MAX when not a segment/symbol/relocation-specific error. */
} s2i_prepared_error;
typedef struct {
 size_t max_image_bytes; /* Hard ceiling remains 64 MiB. */
 size_t max_owned_bytes;
 size_t max_peak_bytes;
 size_t other_live_bytes; /* Caller-retained input/other objects, excluding module. */
 size_t max_relocations; /* Hard ceiling remains 100000. */
 s2i_module_allocator allocator;
} s2i_prepared_options;
typedef struct {
 uint64_t guest_base, initializer_guest_address;
 size_t image_bytes, owned_bytes, source_module_bytes, other_live_bytes;
 size_t temporary_bytes, creation_peak_bytes;
 size_t relocation_count, relative_count, absolute_count;
 int has_initializer; /* Validated integer only. Not called or executable. */
} s2i_prepared_summary;
typedef enum {
 S2I_PREPARED_TEXT_MODEL_RX = 0, S2I_PREPARED_RODATA_MODEL_R,
 S2I_PREPARED_DATA_MODEL_RW
} s2i_prepared_permissions;
typedef struct {
 uint64_t guest_address;
 uint32_t module_offset;
 size_t initialized_size, memory_size;
 s2i_prepared_permissions model_permissions;
 const uint8_t *bytes;
} s2i_prepared_segment;

s2i_prepared_options s2i_prepared_default_options(void);
/*
 * Borrows module only synchronously; requires no concurrent destroy/mutation.
 * Source module stays unchanged. Result has independent lifetime/storage.
 * Requires all three verified hashes, complete inventory, no DT_NEEDED/imports,
 * and strong default-visible named defined object/function symbols only.
 * Base and segment offsets use a 4096-byte MODEL page, not Apple VM permission.
 * Rounded page overlap, zero-sized mapped segments, and unrepresentable end
 * addresses are rejected conservatively. Only data receives zero-filled BSS.
 * RELATIVE(1027)/ABS64(257), 24-byte LE RELA, checked signed arithmetic, 8-byte
 * aligned unique data targets only. Every record is validated before any write.
 * No guest integer is cast to a pointer. No mapping/protection/call/INIT execution.
 * Peak = source module owned bytes + other_live_bytes + prepared owned bytes +
 * temporary plans; all component-requested allocations are counted. This excludes
 * allocator bookkeeping, stack, unrelated process memory and is NOT an RSS cap.
 * *out must initially be NULL; failure leaves it NULL and frees new allocations.
 * Occupied outputs are rejected unchanged. Allocator lifetime/nonalias/cancellation
 * requirements are the same as s2i_module. No implicit reference counting.
 */
s2i_prepared_status s2i_prepared_create(const s2i_module *, uint64_t guest_base,
 const s2i_prepared_options *, s2i_prepared **out, s2i_prepared_error *error);
/* NULL-safe/idempotent on one owner; requires no concurrent users. No OS-thread
 * affinity: externally synchronized serial calls may use different threads when
 * the allocator permits. Destruction invalidates all borrowed segment pointers. */
void s2i_prepared_destroy(s2i_prepared **owner);
/* Copied numeric data, no borrowed pointers. Temporary plans have been freed
 * before create returns; creation_peak_bytes is the checked transaction bound. */
s2i_prepared_status s2i_prepared_get_summary(const s2i_prepared *, s2i_prepared_summary *);
/* Borrowed immutable storage until destroy. No OS-enforced permissions. */
s2i_prepared_status s2i_prepared_get_segment(const s2i_prepared *, unsigned index,
 s2i_prepared_segment *);
/* Positive-size bounded copy from one segment; rejects gaps/cross-segment reads.
 * Outputs must not overlap any prepared storage or each other. */
s2i_prepared_status s2i_prepared_read(const s2i_prepared *, uint64_t guest_address,
 uint8_t *destination, size_t size);
const char *s2i_prepared_status_string(s2i_prepared_status);

#ifdef __cplusplus
}
#endif
#endif
