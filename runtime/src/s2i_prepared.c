#include "s2i_prepared.h"
#include <stdlib.h>
#include <string.h>

struct s2i_prepared {
    s2i_module_allocator allocator;
    s2i_prepared_summary summary;
    s2i_prepared_segment segments[3];
    uint8_t *storage[3];
};
struct pending_relocation { uint64_t offset, value; size_t input_index; };

static void *default_allocate(void *context, size_t size) {
    (void)context;
    return malloc(size);
}
static void default_free(void *context, void *pointer) {
    (void)context;
    free(pointer);
}
static uint64_t little64(const uint8_t *bytes) {
    uint64_t value = 0;
    unsigned i;
    for (i = 0; i < 8; ++i) value |= (uint64_t)bytes[i] << (i * 8);
    return value;
}
static void store64(uint8_t *bytes, uint64_t value) {
    unsigned i;
    for (i = 0; i < 8; ++i) bytes[i] = (uint8_t)(value >> (i * 8));
}
static int add64(uint64_t a, uint64_t b, uint64_t *out) {
    if (b > UINT64_MAX - a) return 0;
    *out = a + b;
    return 1;
}
static int add_size(size_t a, size_t b, size_t *out) {
    if (b > SIZE_MAX - a) return 0;
    *out = a + b;
    return 1;
}
/* Decode signed two's-complement addend without an out-of-range signed cast or
 * negating INT64_MIN. Relocation values never wrap modulo 2^64. */
static int signed_add(uint64_t value, uint64_t raw_addend, uint64_t *out) {
    if (raw_addend & (UINT64_C(1) << 63)) {
        uint64_t magnitude = (~raw_addend) + 1;
        if (value < magnitude) return 0;
        *out = value - magnitude;
        return 1;
    }
    return add64(value, raw_addend, out);
}
static void error_at(s2i_prepared_error *error, s2i_prepared_stage stage,
                     s2i_dynamic_status dynamic, size_t index) {
    if (error) {
        error->stage = stage;
        error->dynamic_status = dynamic;
        error->index = index;
    }
}
static int locate(const s2i_prepared_segment segments[3], uint64_t offset,
                  uint64_t size, unsigned *which, size_t *within) {
    unsigned i;
    if (!size) return 0;
    for (i = 0; i < 3; ++i) {
        uint64_t start = segments[i].module_offset;
        if (offset >= start && offset - start <= segments[i].memory_size &&
            size <= segments[i].memory_size - (offset - start)) {
            if (which) *which = i;
            if (within) *within = (size_t)(offset - start);
            return 1;
        }
    }
    return 0;
}
/* In-place heapsort: predictable O(n log n), no hidden qsort heap allocation. */
static void swap_items(uint8_t *a, uint8_t *b, size_t width) {
    size_t i;
    for (i = 0; i < width; ++i) { uint8_t t = a[i]; a[i] = b[i]; b[i] = t; }
}
static void sift(uint8_t *base, size_t root, size_t count, size_t width,
                 int (*compare)(const void *, const void *)) {
    while (root < count / 2) {
        size_t child = root * 2 + 1;
        if (child + 1 < count && compare(base + child * width,
                                        base + (child + 1) * width) < 0) ++child;
        if (compare(base + root * width, base + child * width) >= 0) return;
        swap_items(base + root * width, base + child * width, width);
        root = child;
    }
}
static void heap_sort(void *values, size_t count, size_t width,
                      int (*compare)(const void *, const void *)) {
    uint8_t *base = values;
    size_t i;
    if (count < 2) return;
    for (i = count / 2; i; --i) sift(base, i - 1, count, width, compare);
    for (i = count - 1; i; --i) {
        swap_items(base, base + i * width, width);
        sift(base, 0, i, width, compare);
    }
}
static int compare_offsets(const void *a, const void *b) {
    uint64_t x = ((const struct pending_relocation *)a)->offset;
    uint64_t y = ((const struct pending_relocation *)b)->offset;
    return x < y ? -1 : x > y ? 1 : 0;
}
static int compare_names(const void *a, const void *b) {
    const s2i_dynamic_name *x = a, *y = b;
    size_t count = x->size < y->size ? x->size : y->size;
    int order = memcmp(x->bytes, y->bytes, count);
    return order ? order : x->size < y->size ? -1 : x->size > y->size ? 1 : 0;
}
static void *allocate_zero(const s2i_module_allocator *allocator, size_t size) {
    void *value;
    if (!size) return NULL;
    value = allocator->allocate(allocator->context, size);
    if (value) memset(value, 0, size);
    return value;
}

s2i_prepared_options s2i_prepared_default_options(void) {
    s2i_prepared_options options;
    memset(&options, 0, sizeof(options));
    options.max_image_bytes = S2I_PREPARED_MAX_IMAGE_BYTES;
    options.max_owned_bytes = (size_t)68 * 1024 * 1024;
    options.max_peak_bytes = (size_t)160 * 1024 * 1024;
    options.max_relocations = S2I_DYNAMIC_MAX_RELOCATIONS;
    return options;
}

void s2i_prepared_destroy(s2i_prepared **owner) {
    s2i_prepared *image;
    s2i_module_allocator allocator;
    unsigned i;
    if (!owner || !*owner) return;
    image = *owner;
    allocator = image->allocator;
    *owner = NULL;
    for (i = 0; i < 3; ++i)
        if (image->storage[i]) allocator.deallocate(allocator.context, image->storage[i]);
    allocator.deallocate(allocator.context, image);
}

s2i_prepared_status s2i_prepared_create(const s2i_module *module, uint64_t base,
    const s2i_prepared_options *requested, s2i_prepared **out,
    s2i_prepared_error *error) {
    s2i_prepared_options options = requested ? *requested : s2i_prepared_default_options();
    s2i_module_view source;
    s2i_dynamic_relocations metadata;
    s2i_dynamic_status dynamic;
    s2i_prepared_segment segments[3];
    s2i_prepared_summary summary;
    s2i_prepared *image = NULL;
    struct pending_relocation *pending = NULL;
    s2i_dynamic_name *names = NULL;
    s2i_prepared_status status = S2I_PREPARED_NO_MEMORY;
    size_t i, name_count, plan_bytes, name_bytes, total;
    uint64_t previous_page_end = 0;
    error_at(error, S2I_PREPARED_STAGE_MODULE, S2I_DYNAMIC_OK, SIZE_MAX);
    if (!out || *out || !module ||
        (!options.allocator.allocate != !options.allocator.deallocate))
        return S2I_PREPARED_INVALID_ARGUMENT;
    if (!options.allocator.allocate) {
        options.allocator.allocate = default_allocate;
        options.allocator.deallocate = default_free;
    }
    if (s2i_module_get_view(module, &source) != S2I_MODULE_OK)
        return S2I_PREPARED_INVALID_ARGUMENT;
    if ((source.plan.flags & 0x38u) != 0x38u ||
        !source.dynamic.imports_complete || !source.dynamic.dependencies_complete ||
        source.dynamic.warnings || source.dynamic.dependency_count)
        return S2I_PREPARED_UNSUPPORTED_METADATA;
    error_at(error, S2I_PREPARED_STAGE_METADATA, S2I_DYNAMIC_OK, SIZE_MAX);
    dynamic = s2i_dynamic_inspect_relocations(&source.plan, source.segments, &metadata);
    if (dynamic != S2I_DYNAMIC_OK) {
        error_at(error, S2I_PREPARED_STAGE_METADATA, dynamic, SIZE_MAX);
        return dynamic == S2I_DYNAMIC_RESOURCE_LIMIT ? S2I_PREPARED_RESOURCE_LIMIT :
                                                      S2I_PREPARED_UNSUPPORTED_METADATA;
    }
    memset(&summary, 0, sizeof(summary));
    memset(segments, 0, sizeof(segments));
    summary.guest_base = base;
    summary.source_module_bytes = source.owned_bytes;
    summary.other_live_bytes = options.other_live_bytes;
    summary.relocation_count = metadata.relocation_count;
    error_at(error, S2I_PREPARED_STAGE_LAYOUT, S2I_DYNAMIC_OK, SIZE_MAX);
    if (base % 4096) return S2I_PREPARED_INVALID_LAYOUT;
    for (i = 0; i < 3; ++i) {
        uint64_t size = source.segments[i].size;
        uint64_t start, end, rounded;
        error_at(error, S2I_PREPARED_STAGE_LAYOUT, S2I_DYNAMIC_OK, i);
        if (i == 2) size += source.plan.bss_size;
        if (!size) return S2I_PREPARED_INVALID_LAYOUT;
        if (size > SIZE_MAX || size > UINT64_MAX - 4095)
            return S2I_PREPARED_ARITHMETIC_OVERFLOW;
        rounded = (size + 4095) & ~UINT64_C(4095);
        if (!add64(base, source.plan.segments[i].memory_offset, &start) ||
            !add64(start, size, &end) || !add64(start, rounded, &end))
            return S2I_PREPARED_ARITHMETIC_OVERFLOW;
        if (i && start < previous_page_end) return S2I_PREPARED_INVALID_LAYOUT;
        previous_page_end = end;
        segments[i].guest_address = start;
        segments[i].module_offset = source.plan.segments[i].memory_offset;
        segments[i].initialized_size = source.segments[i].size;
        segments[i].memory_size = (size_t)size;
        segments[i].model_permissions = (s2i_prepared_permissions)i;
        if (!add_size(summary.image_bytes, (size_t)size, &summary.image_bytes))
            return S2I_PREPARED_ARITHMETIC_OVERFLOW;
    }
    if (metadata.has_init) {
        unsigned which;
        if (metadata.init_offset % 4 ||
            !locate(segments, metadata.init_offset, 4, &which, NULL) || which != 0)
            return S2I_PREPARED_INVALID_LAYOUT;
        if (!add64(base, metadata.init_offset, &summary.initializer_guest_address))
            return S2I_PREPARED_ARITHMETIC_OVERFLOW;
        summary.has_initializer = 1;
    }
    error_at(error, S2I_PREPARED_STAGE_BUDGET, S2I_DYNAMIC_OK, SIZE_MAX);
    name_count = source.dynamic.symbol_count ? source.dynamic.symbol_count - 1 : 0;
    if (summary.image_bytes > options.max_image_bytes ||
        summary.image_bytes > S2I_PREPARED_MAX_IMAGE_BYTES ||
        metadata.relocation_count > options.max_relocations ||
        metadata.relocation_count > S2I_DYNAMIC_MAX_RELOCATIONS ||
        metadata.relocation_count > SIZE_MAX / sizeof(*pending) ||
        name_count > SIZE_MAX / sizeof(*names))
        return S2I_PREPARED_RESOURCE_LIMIT;
    plan_bytes = metadata.relocation_count * sizeof(*pending);
    name_bytes = name_count * sizeof(*names);
    if (!add_size(plan_bytes, name_bytes, &summary.temporary_bytes) ||
        !add_size(sizeof(*image), summary.image_bytes, &summary.owned_bytes) ||
        !add_size(source.owned_bytes, options.other_live_bytes, &total) ||
        !add_size(total, summary.owned_bytes, &total) ||
        !add_size(total, summary.temporary_bytes, &summary.creation_peak_bytes) ||
        summary.owned_bytes > options.max_owned_bytes ||
        summary.creation_peak_bytes > options.max_peak_bytes)
        return S2I_PREPARED_RESOURCE_LIMIT;
    error_at(error, S2I_PREPARED_STAGE_ALLOCATION, S2I_DYNAMIC_OK, SIZE_MAX);
    if (plan_bytes && !(pending = allocate_zero(&options.allocator, plan_bytes))) goto fail;
    if (name_bytes && !(names = allocate_zero(&options.allocator, name_bytes))) goto fail;
    for (i = 1; i < source.dynamic.symbol_count; ++i) {
        const s2i_dynamic_symbol *symbol = &source.symbols[i];
        unsigned which;
        uint64_t address;
        error_at(error, S2I_PREPARED_STAGE_SYMBOL, S2I_DYNAMIC_OK, i);
        if (!symbol->section) { status = S2I_PREPARED_UNRESOLVED_SYMBOL; goto fail; }
        if (!symbol->name.size || symbol->binding != 1 || symbol->visibility != 0 ||
            (symbol->type != 1 && symbol->type != 2) || symbol->section >= 0xff00 ||
            !locate(segments, symbol->value, symbol->size ? symbol->size : 1,
                    &which, NULL) ||
            (symbol->type == 2 && (symbol->value % 4 ||
                !locate(segments, symbol->value, 4, &which, NULL) || which != 0))) {
            status = S2I_PREPARED_UNSUPPORTED_SYMBOL;
            goto fail;
        }
        if (!add64(base, symbol->value, &address)) {
            status = S2I_PREPARED_ARITHMETIC_OVERFLOW;
            goto fail;
        }
        names[i - 1] = symbol->name;
    }
    heap_sort(names, name_count, sizeof(*names), compare_names);
    for (i = 1; i < name_count; ++i) if (!compare_names(&names[i - 1], &names[i])) {
        error_at(error, S2I_PREPARED_STAGE_SYMBOL, S2I_DYNAMIC_OK, SIZE_MAX);
        status = S2I_PREPARED_UNSUPPORTED_SYMBOL;
        goto fail;
    }
    for (i = 0; i < metadata.relocation_count; ++i) {
        const uint8_t *entry = metadata.rela.bytes + i * 24;
        uint64_t offset = little64(entry), info = little64(entry + 8);
        uint64_t addend = little64(entry + 16), value;
        uint32_t type = (uint32_t)info, symbol = (uint32_t)(info >> 32);
        unsigned which;
        error_at(error, S2I_PREPARED_STAGE_RELOCATION, S2I_DYNAMIC_OK, i);
        if (type != 1027 && type != 257) {
            status = S2I_PREPARED_UNSUPPORTED_RELOCATION;
            goto fail;
        }
        if (offset % 8 || !locate(segments, offset, 8, &which, NULL) || which != 2 ||
            (type == 1027 && symbol)) {
            status = S2I_PREPARED_INVALID_RELOCATION;
            goto fail;
        }
        if (type == 257) {
            if (!symbol || symbol >= source.dynamic.symbol_count) {
                status = S2I_PREPARED_UNRESOLVED_SYMBOL;
                goto fail;
            }
            if (!add64(base, source.symbols[symbol].value, &value)) {
                status = S2I_PREPARED_ARITHMETIC_OVERFLOW;
                goto fail;
            }
        } else value = base;
        if (!signed_add(value, addend, &value)) {
            status = S2I_PREPARED_ARITHMETIC_OVERFLOW;
            goto fail;
        }
        pending[i] = (struct pending_relocation){offset, value, i};
        if (type == 1027) ++summary.relative_count;
        else ++summary.absolute_count;
    }
    heap_sort(pending, metadata.relocation_count, sizeof(*pending), compare_offsets);
    for (i = 1; i < metadata.relocation_count; ++i)
        if (pending[i - 1].offset == pending[i].offset) {
            error_at(error, S2I_PREPARED_STAGE_RELOCATION, S2I_DYNAMIC_OK,
                     pending[i].input_index);
            status = S2I_PREPARED_INVALID_RELOCATION;
            goto fail;
        }
    error_at(error, S2I_PREPARED_STAGE_ALLOCATION, S2I_DYNAMIC_OK, SIZE_MAX);
    image = allocate_zero(&options.allocator, sizeof(*image));
    if (!image) { status = S2I_PREPARED_NO_MEMORY; goto fail; }
    image->allocator = options.allocator;
    image->summary = summary;
    for (i = 0; i < 3; ++i) {
        image->storage[i] = allocate_zero(&options.allocator, segments[i].memory_size);
        if (!image->storage[i]) { status = S2I_PREPARED_NO_MEMORY; goto fail; }
        image->segments[i] = segments[i];
        image->segments[i].bytes = image->storage[i];
        if (source.segments[i].size)
            memcpy(image->storage[i], source.segments[i].bytes, source.segments[i].size);
    }
    /* No validation can fail from this point: every target/value is in the plan.
     * The immutable source is never patched, even if RELA itself lives in data. */
    for (i = 0; i < metadata.relocation_count; ++i)
        store64(image->storage[2] + (size_t)(pending[i].offset - segments[2].module_offset),
                pending[i].value);
    if (names) options.allocator.deallocate(options.allocator.context, names);
    if (pending) options.allocator.deallocate(options.allocator.context, pending);
    error_at(error, S2I_PREPARED_STAGE_NONE, S2I_DYNAMIC_OK, SIZE_MAX);
    *out = image;
    return S2I_PREPARED_OK;
fail:
    s2i_prepared_destroy(&image);
    if (names) options.allocator.deallocate(options.allocator.context, names);
    if (pending) options.allocator.deallocate(options.allocator.context, pending);
    return status;
}

s2i_prepared_status s2i_prepared_get_summary(const s2i_prepared *image,
                                            s2i_prepared_summary *out) {
    if (!out) return S2I_PREPARED_INVALID_ARGUMENT;
    memset(out, 0, sizeof(*out));
    if (!image) return S2I_PREPARED_INVALID_ARGUMENT;
    *out = image->summary;
    return S2I_PREPARED_OK;
}
s2i_prepared_status s2i_prepared_get_segment(const s2i_prepared *image, unsigned index,
                                            s2i_prepared_segment *out) {
    if (!out) return S2I_PREPARED_INVALID_ARGUMENT;
    memset(out, 0, sizeof(*out));
    if (!image || index >= 3) return S2I_PREPARED_INVALID_ARGUMENT;
    *out = image->segments[index];
    return S2I_PREPARED_OK;
}
s2i_prepared_status s2i_prepared_read(const s2i_prepared *image, uint64_t address,
                                    uint8_t *destination, size_t size) {
    unsigned which;
    size_t within;
    if (!image || !destination || !size || (uintptr_t)destination > UINTPTR_MAX - size)
        return S2I_PREPARED_INVALID_ARGUMENT;
    if (address < image->summary.guest_base ||
        !locate(image->segments, address - image->summary.guest_base,
                size, &which, &within))
        return S2I_PREPARED_INVALID_ACCESS;
    memcpy(destination, image->storage[which] + within, size);
    return S2I_PREPARED_OK;
}
const char *s2i_prepared_status_string(s2i_prepared_status status) {
    switch (status) {
    case S2I_PREPARED_OK: return "prepared data only; not executable";
    case S2I_PREPARED_INVALID_ARGUMENT: return "invalid argument";
    case S2I_PREPARED_RESOURCE_LIMIT: return "resource budget exceeded";
    case S2I_PREPARED_NO_MEMORY: return "allocation failed";
    case S2I_PREPARED_UNSUPPORTED_METADATA: return "unsupported/incomplete metadata";
    case S2I_PREPARED_INVALID_LAYOUT: return "invalid model layout";
    case S2I_PREPARED_UNSUPPORTED_SYMBOL: return "unsupported defined symbol";
    case S2I_PREPARED_UNRESOLVED_SYMBOL: return "external/undefined symbol blocked";
    case S2I_PREPARED_INVALID_RELOCATION: return "invalid relocation target/symbol";
    case S2I_PREPARED_UNSUPPORTED_RELOCATION: return "unsupported relocation type";
    case S2I_PREPARED_ARITHMETIC_OVERFLOW: return "address/addend arithmetic overflow";
    case S2I_PREPARED_INVALID_ACCESS: return "read outside one prepared segment";
    }
    return "unknown";
}
