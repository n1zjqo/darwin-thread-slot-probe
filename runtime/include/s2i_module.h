#ifndef S2I_MODULE_H
#define S2I_MODULE_H
#include "s2i_dynamic.h"
#ifdef __cplusplus
extern "C" {
#endif

/* Owned decoded data and read-only inventory, NEVER execution readiness. */
typedef struct s2i_module s2i_module;
typedef enum {
    S2I_MODULE_OK = 0, S2I_MODULE_INVALID_ARGUMENT,
    S2I_MODULE_RESOURCE_LIMIT, S2I_MODULE_NO_MEMORY,
    S2I_MODULE_NSO_ERROR, S2I_MODULE_DYNAMIC_ERROR,
    S2I_MODULE_BUFFER_TOO_SMALL, S2I_MODULE_INVALID_INDEX
} s2i_module_status;
typedef enum {
    S2I_MODULE_STAGE_NONE = 0, S2I_MODULE_STAGE_OPTIONS,
    S2I_MODULE_STAGE_INSPECT, S2I_MODULE_STAGE_ALLOCATION,
    S2I_MODULE_STAGE_DECODE, S2I_MODULE_STAGE_DYNAMIC_SIZING,
    S2I_MODULE_STAGE_DYNAMIC_INVENTORY
} s2i_module_stage;
typedef struct {
    s2i_module_stage stage;
    s2i_nso_status nso_status;
    s2i_dynamic_status dynamic_status;
    uint32_t segment_index; /* UINT32_MAX when not segment-specific. */
} s2i_module_error;
typedef struct {
    void *context;
    void *(*allocate)(void *context, size_t size);
    void (*deallocate)(void *context, void *allocation);
} s2i_module_allocator;
typedef struct {
    size_t max_file_bytes;
    size_t max_owned_bytes;
    size_t max_peak_bytes; /* Input length + all live requested owned bytes. */
    size_t max_dependencies;
    size_t max_symbols;
    s2i_module_allocator allocator; /* Both callbacks NULL selects malloc/free. */
} s2i_module_options;

typedef struct {
    s2i_nso_plan plan;
    uint64_t dynamic_address;
    size_t dynamic_entries, dependency_count, symbol_count, import_count, export_count;
    uint32_t warnings;
    int dependencies_complete, imports_complete;
    size_t soname_size, owned_bytes, load_peak_bytes;
} s2i_module_summary;
typedef struct {
    s2i_nso_plan plan;
    s2i_dynamic_bytes segments[3];
    s2i_dynamic_report dynamic;
    const s2i_dynamic_name *dependencies;
    const s2i_dynamic_symbol *symbols;
    size_t owned_bytes, load_peak_bytes;
} s2i_module_view;
typedef enum {
    S2I_MODULE_NAME_SONAME = 0,
    S2I_MODULE_NAME_DEPENDENCY,
    S2I_MODULE_NAME_SYMBOL
} s2i_module_name_kind;

s2i_module_options s2i_module_default_options(void);
/*
 * Synchronously borrows immutable input only until return. *out must be NULL;
 * failure leaves an initially NULL output NULL and releases all new allocations.
 * An occupied output is rejected without changing or freeing it. No BSS/gap allocation,
 * relocation, executable mapping, guest execution, or thread-context binding.
 * Successful inventory can be incomplete: preserve warning/completeness flags.
 * Budgets cover requested object + segment + inventory bytes, not malloc private
 * overhead/RSS. max_peak_bytes also includes input_size. Options are copied.
 * Custom allocator must return fresh aligned nonoverlapping memory or NULL;
 * callbacks/context must outlive the object and not reenter/throw/longjmp or
 * deliver pthread cancellation. Async cancellation/signal handlers unsupported.
 * A Swift Task cancellation does not interrupt this synchronous C transaction.
 * Inputs/options/out/error and custom allocations must not alias each other.
 */
s2i_module_status s2i_module_load(const uint8_t *input, size_t input_size,
    const s2i_module_options *options, s2i_module **out, s2i_module_error *error);
/* NULL-safe, idempotent for the same owner variable; no concurrent users allowed.
 * Destroy invalidates borrowed views. No reference counting or implicit ownership
 * transfer. The object has no OS-thread affinity: externally synchronized serial
 * calls may use different threads if the allocator also permits it. */
void s2i_module_destroy(s2i_module **owner);
/* Summary contains no borrowed pointers; it remains valid after destroy. */
s2i_module_status s2i_module_get_summary(const s2i_module *, s2i_module_summary *out);
/* All pointers borrow immutable module storage until destroy. Never retain a view
 * across close/cancellation or hand it to another thread without owning lifetime.
 * This is API constness, NOT OS-enforced memory protection. */
s2i_module_status s2i_module_get_view(const s2i_module *, s2i_module_view *out);
/* Raw name bytes, no terminator added and no UTF-8 assumption. SONAME index must
 * be zero. *required returns byte length. Too-small buffers are not written;
 * NULL destination is allowed at capacity zero for sizing. destination/required
 * must not overlap each other or any module-owned storage. */
s2i_module_status s2i_module_copy_name(const s2i_module *, s2i_module_name_kind,
    size_t index, uint8_t *destination, size_t capacity, size_t *required);
const char *s2i_module_status_string(s2i_module_status);

#ifdef __cplusplus
}
#endif
#endif
