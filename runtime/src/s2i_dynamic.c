#include "s2i_dynamic.h"
#include <string.h>
static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}

static uint64_t u64(const uint8_t *p) {
    return u32(p)|((uint64_t)u32(p+4)<<32);
}

static const uint8_t *range(const s2i_nso_plan *p, const s2i_dynamic_bytes b[3], uint64_t a, uint64_t n) {
    unsigned i;
    for (i = 0; i < 3; i++) {
        uint64_t start = p->segments[i].memory_offset;
        if (a >= start && a-start <= b[i].size && n <= b[i].size-(a-start))
            return b[i].bytes ? b[i].bytes+(size_t)(a-start) : NULL;
    }
    return NULL;
}

static int add_delta(uint64_t base, uint32_t raw, uint64_t *out) {
    int64_t d = raw <= 0x7fffffffu?(int64_t)raw:(int64_t)raw-INT64_C(4294967296);
    if (d < 0 && base < (uint64_t)(-d))
        return 0;
    *out = d < 0?base-(uint64_t)(-d):base+(uint64_t)d;
    return 1;
}

static int name_at(const uint8_t *str, uint64_t size, uint64_t off, s2i_dynamic_name *out) {
    const uint8_t *end;
    uint64_t scan_size;
    if (!str || off >= size)
        return 0;
    scan_size = size - off;
    if (scan_size > S2I_DYNAMIC_MAX_NAME_LENGTH + 1u)
        scan_size = S2I_DYNAMIC_MAX_NAME_LENGTH + 1u;
    end = memchr(str + (size_t)off, 0, (size_t)scan_size);
    if (!end)
        return 0;
    out->bytes = str+(size_t)off;
    out->size = (size_t)(end-out->bytes);
    return 1;
}
s2i_dynamic_status s2i_dynamic_inspect(
    const s2i_nso_plan *p, const s2i_dynamic_bytes b[3],
    s2i_dynamic_name *deps, size_t dc, s2i_dynamic_symbol *syms,
    size_t sc, s2i_dynamic_report *out) {
    uint64_t tags[S2I_DYNAMIC_MAX_ENTRIES], vals[S2I_DYNAMIC_MAX_ENTRIES];
    uint64_t mod, da, st = 0, ss = 0, sy = 0, se = 0, sz = 0, hash = 0, son = 0, count = 0;
    uint32_t have = 0;
    size_t i, j, nt = 0, nd = 0, name_bytes = 0;
    int terminated = 0;
    const uint8_t *q, *str = NULL, *table = NULL;
    s2i_dynamic_report r;
    s2i_dynamic_status status = S2I_DYNAMIC_INVALID_FORMAT;
    if (!out)
        return S2I_DYNAMIC_INVALID_ARGUMENT;
    memset(out, 0, sizeof(*out));
    memset(&r, 0, sizeof(r));
    if (!p || !b || (!deps && dc) || (!syms && sc))
        return S2I_DYNAMIC_INVALID_ARGUMENT;
    for (i = 0; i < 3; i++) {
        uint64_t start = p->segments[i].memory_offset, end = start+b[i].size;
        if (b[i].size != p->segments[i].memory_size || (!b[i].bytes && b[i].size))
            return S2I_DYNAMIC_INVALID_ARGUMENT;
        if (b[i].size > S2I_NSO_MAX_SEGMENT || end > UINT64_C(0x100000000))
            return S2I_DYNAMIC_INVALID_RANGE;
        for (j = 0; j < i; j++) {
            if (b[i].size && b[j].size &&
                start < (uint64_t)p->segments[j].memory_offset + b[j].size &&
                p->segments[j].memory_offset < end)
                return S2I_DYNAMIC_INVALID_RANGE;
        }
    }
    if (p->segments[0].memory_offset || b[0].size < 8) {
        r.warnings = S2I_DYNAMIC_NO_MOD0;
        *out = r;
        return S2I_DYNAMIC_OK;
    }
    mod = u32(b[0].bytes+4);
    if (!mod) {
        r.warnings = S2I_DYNAMIC_NO_MOD0;
        *out = r;
        return S2I_DYNAMIC_OK;
    }
    q = range(p, b, mod, 28);
    if (!q)
        return S2I_DYNAMIC_INVALID_RANGE;
    if (memcmp(q, "MOD0", 4))
        return S2I_DYNAMIC_INVALID_FORMAT;
    if (u32(q+8) || u32(q+12)) {
        uint64_t bs, be, dataend = (uint64_t)p->segments[2].memory_offset+b[2].size;
        if (!add_delta(mod, u32(q+8), &bs) || !add_delta(mod, u32(q+12), &be) || bs < dataend || be < bs || be > dataend+p->bss_size)
            return S2I_DYNAMIC_INVALID_RANGE;
    }
    if (!add_delta(mod, u32(q+4), &da) || da%8)
        return S2I_DYNAMIC_INVALID_FORMAT;
    r.dynamic_address = da;
    for (i = 0; i < S2I_DYNAMIC_MAX_ENTRIES; i++) {
        uint64_t tag, val;
        q = range(p, b, da+i*16, 16);
        if (!q)
            return S2I_DYNAMIC_INVALID_RANGE;
        tag = u64(q);
        val = u64(q+8);
        if (!tag) {
            terminated = 1;
            break;
        }
        if (tag > 0x7fffffffu)
            return S2I_DYNAMIC_INVALID_FORMAT;
        if (tag != 1 && tag != 0x7ffffffdu && tag != 0x7fffffffu) {
            for (j = 0; j < nt; j++) {
                if (tags[j] == tag)
                    return S2I_DYNAMIC_INVALID_FORMAT;
            }
        }
        tags[nt] = tag;
        vals[nt++] = val;
        if (tag == 1)
            nd++;
        if (tag == 0x7ffffffdu || tag == 0x7fffffffu)
            r.warnings |= S2I_DYNAMIC_UNSUPPORTED_DEPENDENCY;
        if (tag == 0x6ffffef5u)
            r.warnings |= S2I_DYNAMIC_GNU_HASH_UNSUPPORTED;
        switch (tag) {
            case 5:
                st = val;
                have |= 1;
                break;
            case 10:
                ss = val;
                have |= 2;
                break;
            case 6:
                sy = val;
                have |= 4;
                break;
            case 11:
                se = val;
                have |= 8;
                break;
            case 39:
                sz = val;
                have |= 16;
                break;
            case 4:
                hash = val;
                have |= 32;
                break;
            case 14:
                son = val;
                have |= 64;
                break;
            default:
                break;
        }
    }
    if (!terminated)
        return S2I_DYNAMIC_RESOURCE_LIMIT;
    r.dynamic_entries = nt;
    r.dependencies_complete = !(r.warnings & S2I_DYNAMIC_UNSUPPORTED_DEPENDENCY);
    if ((have&8) && se != 24)
        return S2I_DYNAMIC_INVALID_FORMAT;
    if (ss > S2I_DYNAMIC_MAX_STRINGS)
        return S2I_DYNAMIC_RESOURCE_LIMIT;
    if (ss) {
        str = range(p, b, st, ss);
        if (!str)
            return S2I_DYNAMIC_INVALID_RANGE;
        if (str[0] || str[ss-1])
            return S2I_DYNAMIC_INVALID_FORMAT;
    }
    if (nd || (have&64)) {
        if ((have&3) != 3)
            return S2I_DYNAMIC_INVALID_FORMAT;
        if (have&64) {
            if (!name_at(str, ss, son, &r.soname) || !r.soname.size)
                return S2I_DYNAMIC_INVALID_FORMAT;
            name_bytes = r.soname.size;
        }
        for (i = 0; i < nt; i++) if (tags[i] == 1) {
            s2i_dynamic_name n;
            if (!name_at(str, ss, vals[i], &n) || !n.size)
                return S2I_DYNAMIC_INVALID_FORMAT;
            name_bytes += n.size;
            if (name_bytes > S2I_DYNAMIC_MAX_NAME_BYTES)
                return S2I_DYNAMIC_RESOURCE_LIMIT;
            if (r.dependency_count < dc)
                deps[r.dependency_count] = n;
            r.dependency_count++;
        }
    }
    if (have&16) {
        if (sz%24)
            return S2I_DYNAMIC_INVALID_FORMAT;
        count = sz/24;
    }
    if (have&32) {
        uint64_t nb, nc;
        q = range(p, b, hash, 8);
        if (!q)
            return S2I_DYNAMIC_INVALID_RANGE;
        nb = u32(q);
        nc = u32(q+4);
        if (!nb || !nc)
            return S2I_DYNAMIC_INVALID_FORMAT;
        if (nb > S2I_DYNAMIC_MAX_SYMBOLS || nc > S2I_DYNAMIC_MAX_SYMBOLS)
            return S2I_DYNAMIC_RESOURCE_LIMIT;
        q = range(p, b, hash+8, (nb+nc)*4);
        if (!q)
            return S2I_DYNAMIC_INVALID_RANGE;
        for (i = 0; i < nb + nc; i++) {
            if (u32(q + i * 4) >= nc)
                return S2I_DYNAMIC_INVALID_FORMAT;
        }
        if ((have&16) && count != nc)
            return S2I_DYNAMIC_INVALID_FORMAT;
        count = nc;
    }
    if (count > S2I_DYNAMIC_MAX_SYMBOLS)
        return S2I_DYNAMIC_RESOURCE_LIMIT;
    if (!(have&48) || !count)
        r.warnings |= S2I_DYNAMIC_MISSING_SYMBOL_BOUND;
    if ((have&15) != 15 || !ss)
        r.warnings |= S2I_DYNAMIC_MISSING_SYMBOL_TAGS;
    r.imports_complete = !(r.warnings & (S2I_DYNAMIC_MISSING_SYMBOL_BOUND |
                                       S2I_DYNAMIC_MISSING_SYMBOL_TAGS));
    if (count && (have&15) == 15 && ss) {
        table = range(p, b, sy, count*24);
        if (!table)
            return S2I_DYNAMIC_INVALID_RANGE;
        if (sy < st+ss && st < sy+count*24)
            return S2I_DYNAMIC_INVALID_FORMAT;
        for (i = 0; i < 24; i++) {
            if (table[i])
                return S2I_DYNAMIC_INVALID_FORMAT;
        }
        for (i = 0; i < count; i++) {
            s2i_dynamic_symbol s;
            memset(&s, 0, sizeof(s));
            q = table+i*24;
            if (!name_at(str, ss, u32(q), &s.name))
                return S2I_DYNAMIC_INVALID_FORMAT;
            name_bytes += s.name.size;
            if (name_bytes > S2I_DYNAMIC_MAX_NAME_BYTES)
                return S2I_DYNAMIC_RESOURCE_LIMIT;
            s.index = (uint32_t)i;
            s.binding = q[4]>>4;
            s.type = q[4]&15;
            s.visibility = q[5]&3;
            s.section = (uint16_t)(q[6]|q[7]<<8);
            s.value = u64(q+8);
            s.size = u64(q+16);
            if (s.binding > 2) {
                r.imports_complete = 0;
                r.warnings |= S2I_DYNAMIC_UNSUPPORTED_SYMBOL;
            }
            if (s.name.size && (s.binding == 1 || s.binding == 2)) {
                if (!s.section) {
                    r.import_count++;
                    if (s.visibility) {
                        r.imports_complete = 0;
                        r.warnings |= S2I_DYNAMIC_UNSUPPORTED_SYMBOL;
                    }
                }
                else if (s.visibility == 0 || s.visibility == 3)
                    r.export_count++;
            }
            if (i < sc)
                syms[i] = s;
        }
        r.symbol_count = (size_t)count;
    }
    status = (r.dependency_count > dc || r.symbol_count > sc)
        ? S2I_DYNAMIC_BUFFER_TOO_SMALL : S2I_DYNAMIC_OK;
    *out = r;
    return status;
}

const char *s2i_dynamic_status_string(s2i_dynamic_status s) {
    switch (s) {
        case S2I_DYNAMIC_OK:
            return "ok (inventory only)";
        case S2I_DYNAMIC_INVALID_ARGUMENT:
            return "invalid argument";
        case S2I_DYNAMIC_INVALID_RANGE:
            return "metadata outside decoded bytes";
        case S2I_DYNAMIC_INVALID_FORMAT:
            return "invalid or unsupported ELF64 metadata";
        case S2I_DYNAMIC_RESOURCE_LIMIT:
            return "metadata resource limit";
        case S2I_DYNAMIC_BUFFER_TOO_SMALL:
            return "inventory output capacity insufficient";
        case S2I_DYNAMIC_UNSUPPORTED_METADATA:
            return "metadata outside strict preparation subset";
        default:
            return "unknown dynamic status";
    }
}

s2i_dynamic_status s2i_dynamic_inspect_relocations(const s2i_nso_plan *plan,
    const s2i_dynamic_bytes decoded[3], s2i_dynamic_relocations *out) {
    s2i_dynamic_report inventory;
    s2i_dynamic_relocations result;
    s2i_dynamic_status status;
    uint64_t rela = 0, size = 0, entry = 0;
    unsigned present = 0;
    size_t i;
    if (!out)
        return S2I_DYNAMIC_INVALID_ARGUMENT;
    memset(out, 0, sizeof(*out));
    memset(&result, 0, sizeof(result));
    status = s2i_dynamic_inspect(plan, decoded, NULL, 0, NULL, 0, &inventory);
    if (status != S2I_DYNAMIC_OK && status != S2I_DYNAMIC_BUFFER_TOO_SMALL)
        return status;
    if (inventory.warnings & S2I_DYNAMIC_NO_MOD0)
        return S2I_DYNAMIC_UNSUPPORTED_METADATA;
    for (i = 0; i < inventory.dynamic_entries; ++i) {
        const uint8_t *item = range(plan, decoded,
            inventory.dynamic_address + (uint64_t)i * 16, 16);
        uint64_t tag, value;
        if (!item)
            return S2I_DYNAMIC_INVALID_RANGE;
        tag = u64(item);
        value = u64(item + 8);
        switch (tag) {
        case 4: case 5: case 6: case 10: case 11: case 14: case 39:
            break; /* Existing inspector already validates these metadata tags. */
        case 7: rela = value; present |= 1; break;
        case 8: size = value; present |= 2; break;
        case 9: entry = value; present |= 4; break;
        case 12: result.has_init = 1; result.init_offset = value; break;
        default: return S2I_DYNAMIC_UNSUPPORTED_METADATA;
        }
    }
    if (present) {
        if (present != 7 || entry != 24 || size % 24 || rela % 8)
            return S2I_DYNAMIC_INVALID_FORMAT;
        if (size / 24 > S2I_DYNAMIC_MAX_RELOCATIONS || size > SIZE_MAX)
            return S2I_DYNAMIC_RESOURCE_LIMIT;
        result.rela.bytes = range(plan, decoded, rela, size);
        if (!result.rela.bytes)
            return S2I_DYNAMIC_INVALID_RANGE;
        result.has_rela = 1;
        result.rela_address = rela;
        result.rela.size = (size_t)size;
        result.relocation_count = (size_t)(size / 24);
    }
    *out = result;
    return S2I_DYNAMIC_OK;
}
