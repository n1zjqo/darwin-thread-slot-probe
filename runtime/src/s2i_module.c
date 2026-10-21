#include "s2i_module.h"
#include <stdlib.h>
#include <string.h>

struct s2i_module {
    s2i_module_allocator allocator;
    s2i_nso_plan plan;
    uint8_t *storage[3];
    s2i_dynamic_report dynamic;
    s2i_dynamic_name *dependencies;
    s2i_dynamic_symbol *symbols;
    size_t owned_bytes, load_peak_bytes;
};

struct budget {
    s2i_module_options options;
    size_t input_size, owned;
};

static void *default_allocate(void *context, size_t size) {
    (void)context;
    return malloc(size);
}

static void default_deallocate(void *context, void *allocation) {
    (void)context;
    free(allocation);
}

s2i_module_options s2i_module_default_options(void) {
    s2i_module_options options;
    memset(&options, 0, sizeof(options));
    options.max_file_bytes = S2I_NSO_MAX_FILE;
    options.max_owned_bytes = (size_t)272 * 1024 * 1024;
    options.max_peak_bytes = (size_t)400 * 1024 * 1024;
    options.max_dependencies = S2I_DYNAMIC_MAX_ENTRIES;
    options.max_symbols = S2I_DYNAMIC_MAX_SYMBOLS;
    return options;
}

static void error_at(s2i_module_error *error, s2i_module_stage stage,
                     s2i_nso_status nso, s2i_dynamic_status dynamic,
                     uint32_t segment) {
    if (error) {
        error->stage = stage;
        error->nso_status = nso;
        error->dynamic_status = dynamic;
        error->segment_index = segment;
    }
}

static int can_reserve(const struct budget *budget, size_t bytes) {
    size_t total;
    if (bytes > SIZE_MAX - budget->owned)
        return 0;
    total = budget->owned + bytes;
    if (total > budget->options.max_owned_bytes ||
        budget->input_size > budget->options.max_peak_bytes ||
        total > budget->options.max_peak_bytes - budget->input_size)
        return 0;
    return 1;
}

static s2i_module_status allocate_owned(struct budget *budget, size_t bytes,
                                        void **out) {
    void *value;
    *out = NULL;
    if (!can_reserve(budget, bytes))
        return S2I_MODULE_RESOURCE_LIMIT;
    if (!bytes)
        return S2I_MODULE_OK;
    value = budget->options.allocator.allocate(
        budget->options.allocator.context, bytes);
    if (!value)
        return S2I_MODULE_NO_MEMORY;
    memset(value, 0, bytes);
    budget->owned += bytes;
    *out = value;
    return S2I_MODULE_OK;
}

void s2i_module_destroy(s2i_module **owner) {
    s2i_module *module;
    s2i_module_allocator allocator;
    unsigned index;
    if (!owner || !*owner)
        return;
    module = *owner;
    allocator = module->allocator;
    *owner = NULL;
    if (module->symbols)
        allocator.deallocate(allocator.context, module->symbols);
    if (module->dependencies)
        allocator.deallocate(allocator.context, module->dependencies);
    for (index = 0; index < 3; ++index) {
        if (module->storage[index])
            allocator.deallocate(allocator.context, module->storage[index]);
    }
    allocator.deallocate(allocator.context, module);
}

s2i_module_status s2i_module_load(const uint8_t *input, size_t input_size,
    const s2i_module_options *options, s2i_module **out, s2i_module_error *error) {
    struct budget budget;
    s2i_module *module = NULL;
    s2i_nso_plan plan;
    s2i_nso_status nso;
    s2i_dynamic_status dynamic;
    s2i_dynamic_report sizing;
    s2i_dynamic_bytes decoded[3];
    s2i_module_status status;
    size_t dependencies_size, symbols_size;
    unsigned index;
    void *allocation;
    error_at(error, S2I_MODULE_STAGE_OPTIONS, S2I_NSO_OK,
             S2I_DYNAMIC_OK, UINT32_MAX);
    if (!out || *out || !input || (uintptr_t)input > UINTPTR_MAX - input_size)
        return S2I_MODULE_INVALID_ARGUMENT;
    budget.options = options ? *options : s2i_module_default_options();
    budget.input_size = input_size;
    budget.owned = 0;
    if ((!budget.options.allocator.allocate) !=
        (!budget.options.allocator.deallocate))
        return S2I_MODULE_INVALID_ARGUMENT;
    if (!budget.options.allocator.allocate) {
        budget.options.allocator.allocate = default_allocate;
        budget.options.allocator.deallocate = default_deallocate;
    }
    if (input_size > budget.options.max_file_bytes ||
        input_size > budget.options.max_peak_bytes)
        return S2I_MODULE_RESOURCE_LIMIT;
    nso = s2i_nso_inspect(input, input_size, &plan);
    error_at(error, S2I_MODULE_STAGE_INSPECT, nso, S2I_DYNAMIC_OK, UINT32_MAX);
    if (nso != S2I_NSO_OK)
        return S2I_MODULE_NSO_ERROR;
    /* Preflight all decoded segments, not the largest segment or image_size.
     * No BSS/gaps are allocated. The sum is checked before any heap allocation. */
    if (plan.decoded_size > SIZE_MAX ||
        (size_t)plan.decoded_size > SIZE_MAX - sizeof(*module) ||
        !can_reserve(&budget, sizeof(*module) + (size_t)plan.decoded_size))
        return S2I_MODULE_RESOURCE_LIMIT;
    error_at(error, S2I_MODULE_STAGE_ALLOCATION, S2I_NSO_OK,
             S2I_DYNAMIC_OK, UINT32_MAX);
    status = allocate_owned(&budget, sizeof(*module), &allocation);
    if (status != S2I_MODULE_OK)
        return status;
    module = allocation;
    module->allocator = budget.options.allocator;
    module->plan = plan;
    for (index = 0; index < 3; ++index) {
        error_at(error, S2I_MODULE_STAGE_ALLOCATION, S2I_NSO_OK,
                 S2I_DYNAMIC_OK, index);
        status = allocate_owned(&budget, plan.segments[index].memory_size,
                                &allocation);
        if (status != S2I_MODULE_OK)
            goto fail;
        module->storage[index] = allocation;
        nso = s2i_nso_decode_segment(input, input_size, index,
            module->storage[index], plan.segments[index].memory_size);
        if (nso != S2I_NSO_OK) {
            error_at(error, S2I_MODULE_STAGE_DECODE, nso, S2I_DYNAMIC_OK, index);
            status = S2I_MODULE_NSO_ERROR;
            goto fail;
        }
        decoded[index].bytes = module->storage[index];
        decoded[index].size = plan.segments[index].memory_size;
    }
    dynamic = s2i_dynamic_inspect(&module->plan, decoded, NULL, 0, NULL, 0, &sizing);
    error_at(error, S2I_MODULE_STAGE_DYNAMIC_SIZING, S2I_NSO_OK,
             dynamic, UINT32_MAX);
    if (dynamic != S2I_DYNAMIC_OK && dynamic != S2I_DYNAMIC_BUFFER_TOO_SMALL) {
        status = S2I_MODULE_DYNAMIC_ERROR;
        goto fail;
    }
    if (sizing.dependency_count > budget.options.max_dependencies ||
        sizing.symbol_count > budget.options.max_symbols ||
        sizing.dependency_count > SIZE_MAX / sizeof(*module->dependencies) ||
        sizing.symbol_count > SIZE_MAX / sizeof(*module->symbols)) {
        status = S2I_MODULE_RESOURCE_LIMIT;
        goto fail;
    }
    dependencies_size = sizing.dependency_count * sizeof(*module->dependencies);
    symbols_size = sizing.symbol_count * sizeof(*module->symbols);
    if (dependencies_size > SIZE_MAX - symbols_size ||
        !can_reserve(&budget, dependencies_size + symbols_size)) {
        status = S2I_MODULE_RESOURCE_LIMIT;
        goto fail;
    }
    error_at(error, S2I_MODULE_STAGE_ALLOCATION, S2I_NSO_OK,
             S2I_DYNAMIC_OK, UINT32_MAX);
    status = allocate_owned(&budget, dependencies_size, &allocation);
    if (status != S2I_MODULE_OK)
        goto fail;
    module->dependencies = allocation;
    status = allocate_owned(&budget, symbols_size, &allocation);
    if (status != S2I_MODULE_OK)
        goto fail;
    module->symbols = allocation;
    dynamic = s2i_dynamic_inspect(&module->plan, decoded,
        module->dependencies, sizing.dependency_count,
        module->symbols, sizing.symbol_count, &module->dynamic);
    if (dynamic != S2I_DYNAMIC_OK) {
        error_at(error, S2I_MODULE_STAGE_DYNAMIC_INVENTORY, S2I_NSO_OK,
                 dynamic, UINT32_MAX);
        status = S2I_MODULE_DYNAMIC_ERROR;
        goto fail;
    }
    module->owned_bytes = budget.owned;
    /* can_reserve already proved the sum is <= max_peak_bytes <= SIZE_MAX. */
    module->load_peak_bytes = input_size + budget.owned;
    error_at(error, S2I_MODULE_STAGE_NONE, S2I_NSO_OK,
             S2I_DYNAMIC_OK, UINT32_MAX);
    *out = module;
    return S2I_MODULE_OK;
fail:
    s2i_module_destroy(&module);
    return status;
}

s2i_module_status s2i_module_get_summary(const s2i_module *module,
                                          s2i_module_summary *out) {
    if (!out)
        return S2I_MODULE_INVALID_ARGUMENT;
    memset(out, 0, sizeof(*out));
    if (!module)
        return S2I_MODULE_INVALID_ARGUMENT;
    out->plan = module->plan;
    out->dynamic_address = module->dynamic.dynamic_address;
    out->dynamic_entries = module->dynamic.dynamic_entries;
    out->dependency_count = module->dynamic.dependency_count;
    out->symbol_count = module->dynamic.symbol_count;
    out->import_count = module->dynamic.import_count;
    out->export_count = module->dynamic.export_count;
    out->warnings = module->dynamic.warnings;
    out->dependencies_complete = module->dynamic.dependencies_complete;
    out->imports_complete = module->dynamic.imports_complete;
    out->soname_size = module->dynamic.soname.size;
    out->owned_bytes = module->owned_bytes;
    out->load_peak_bytes = module->load_peak_bytes;
    return S2I_MODULE_OK;
}

s2i_module_status s2i_module_get_view(const s2i_module *module,
                                     s2i_module_view *out) {
    unsigned index;
    if (!out)
        return S2I_MODULE_INVALID_ARGUMENT;
    memset(out, 0, sizeof(*out));
    if (!module)
        return S2I_MODULE_INVALID_ARGUMENT;
    out->plan = module->plan;
    for (index = 0; index < 3; ++index) {
        out->segments[index].bytes = module->storage[index];
        out->segments[index].size = module->plan.segments[index].memory_size;
    }
    out->dynamic = module->dynamic;
    out->dependencies = module->dependencies;
    out->symbols = module->symbols;
    out->owned_bytes = module->owned_bytes;
    out->load_peak_bytes = module->load_peak_bytes;
    return S2I_MODULE_OK;
}

s2i_module_status s2i_module_copy_name(const s2i_module *module,
    s2i_module_name_kind kind, size_t index, uint8_t *destination,
    size_t capacity, size_t *required) {
    s2i_dynamic_name name;
    if (!required)
        return S2I_MODULE_INVALID_ARGUMENT;
    *required = 0;
    if (!module || (!destination && capacity) ||
        (uintptr_t)destination > UINTPTR_MAX - capacity)
        return S2I_MODULE_INVALID_ARGUMENT;
    switch (kind) {
    case S2I_MODULE_NAME_SONAME:
        if (index)
            return S2I_MODULE_INVALID_INDEX;
        name = module->dynamic.soname;
        break;
    case S2I_MODULE_NAME_DEPENDENCY:
        if (index >= module->dynamic.dependency_count)
            return S2I_MODULE_INVALID_INDEX;
        name = module->dependencies[index];
        break;
    case S2I_MODULE_NAME_SYMBOL:
        if (index >= module->dynamic.symbol_count)
            return S2I_MODULE_INVALID_INDEX;
        name = module->symbols[index].name;
        break;
    default:
        return S2I_MODULE_INVALID_ARGUMENT;
    }
    *required = name.size;
    if (capacity < name.size)
        return S2I_MODULE_BUFFER_TOO_SMALL;
    if (name.size)
        memcpy(destination, name.bytes, name.size);
    return S2I_MODULE_OK;
}

const char *s2i_module_status_string(s2i_module_status status) {
    switch (status) {
    case S2I_MODULE_OK: return "ok";
    case S2I_MODULE_INVALID_ARGUMENT: return "invalid_argument";
    case S2I_MODULE_RESOURCE_LIMIT: return "resource_limit";
    case S2I_MODULE_NO_MEMORY: return "no_memory";
    case S2I_MODULE_NSO_ERROR: return "nso_error";
    case S2I_MODULE_DYNAMIC_ERROR: return "dynamic_error";
    case S2I_MODULE_BUFFER_TOO_SMALL: return "buffer_too_small";
    case S2I_MODULE_INVALID_INDEX: return "invalid_index";
    }
    return "unknown";
}
