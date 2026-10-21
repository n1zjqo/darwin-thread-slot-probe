#ifndef S2I_NSO_H
#define S2I_NSO_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Inspection/decode only. No guest code execution, relocation or executable mapping. */
#define S2I_NSO_MAX_FILE (128u * 1024u * 1024u)
#define S2I_NSO_MAX_SEGMENT (128u * 1024u * 1024u)
#define S2I_NSO_MAX_DECODED (256u * 1024u * 1024u)
typedef enum {
 S2I_NSO_OK = 0, S2I_NSO_INVALID_ARGUMENT, S2I_NSO_TRUNCATED,
 S2I_NSO_UNSUPPORTED_FORMAT, S2I_NSO_RESOURCE_LIMIT, S2I_NSO_INVALID_RANGE,
 S2I_NSO_OVERLAP, S2I_NSO_INVALID_LZ4, S2I_NSO_HASH_MISMATCH,
 S2I_NSO_BUFFER_TOO_SMALL, S2I_NSO_UNSUPPORTED_DYNAMIC_METADATA
} s2i_nso_status;
typedef struct {
 uint32_t file_offset, memory_offset, stored_size, memory_size;
 uint32_t compressed, hash_required;
} s2i_nso_segment;
typedef struct {
 uint32_t version, flags;
 uint64_t image_size;
 s2i_nso_segment segments[3];
 uint32_t bss_size;
 uint64_t decoded_size;
} s2i_nso_plan;
/* Header only: file_size is trusted ONLY as a reported length, not payload proof.
 * Success does not verify hashes, compressed blocks, dynamic metadata, or identity.
 * out is cleared on failure. Input and output must not alias. */
s2i_nso_status s2i_nso_inspect_header(const uint8_t *, size_t, uint64_t, s2i_nso_plan *);
s2i_nso_status s2i_nso_inspect(const uint8_t *, size_t, s2i_nso_plan *);
/* Revalidates header, decodes exactly one segment, verifies requested SHA-256.
 * Destination must not alias input. Destination is cleared on decode/hash failure.
 * Zero-sized segment allows NULL destination. No allocation or executable memory. */
s2i_nso_status s2i_nso_decode_segment(const uint8_t *, size_t, uint32_t, uint8_t *, size_t);
/* Raw LZ4 block, not frame or size-prefixed format. Exact expected output size.
 * Caller owns separate input/output buffers. Output unspecified on failure. */
s2i_nso_status s2i_lz4_decode(const uint8_t *, size_t, uint8_t *, size_t);
/* Reject any MOD0 pointer: relocation/dynamic linking is not implemented.
 * Only call with successfully decoded text. OK is NOT execution readiness. */
s2i_nso_status s2i_nso_check_static_text(const uint8_t *, size_t);
const char *s2i_nso_status_string(s2i_nso_status);
#ifdef __cplusplus
}
#endif
#endif
