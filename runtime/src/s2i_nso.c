#include "s2i_nso.h"
#include <string.h>

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}

static int overlaps(uint64_t a, uint64_t n, uint64_t b, uint64_t m) {
    return n && m && a < b+m && b < a+n;
}

static int invalid_buffers(const void *src, size_t n, const void *dst, size_t cap) {
    uintptr_t a = (uintptr_t)src, b = (uintptr_t)dst;
    if ((!src && n) || (!dst && cap) || a > UINTPTR_MAX - n || b > UINTPTR_MAX - cap) return 1;
    return n && cap && a < b + cap && b < a + n;
}

static int within(uint64_t o, uint64_t n, uint64_t size) {
    return o <= size && n <= size-o;
}

s2i_nso_status s2i_nso_inspect_header(const uint8_t *h, size_t n, uint64_t file_size, s2i_nso_plan *out) {
    s2i_nso_plan p;
    unsigned i,j;
    uint32_t mo,ms;
    uint64_t end;
    if (!out) return S2I_NSO_INVALID_ARGUMENT;
    memset(out,0,sizeof(*out));
    memset(&p,0,sizeof(p));
    if (!h) return S2I_NSO_INVALID_ARGUMENT;
    if (n < 256 || file_size < 256) return S2I_NSO_TRUNCATED;
    if (file_size > S2I_NSO_MAX_FILE) return S2I_NSO_RESOURCE_LIMIT;
    if (memcmp(h,"NSO0",4)) return S2I_NSO_UNSUPPORTED_FORMAT;
    p.version=le32(h+4);
    p.flags=le32(h+12);
    if (p.version || le32(h+8) || (p.flags & ~0x7fu)) return S2I_NSO_UNSUPPORTED_FORMAT;
    for (i=0; i<3; i++) {
        s2i_nso_segment *s=&p.segments[i];
        const uint8_t *q=h+16+i*16;
        s->file_offset=le32(q);
        s->memory_offset=le32(q+4);
        s->memory_size=le32(q+8);
        s->compressed=(p.flags>>i)&1u;
        s->hash_required=(p.flags>>(i+3))&1u;
        s->stored_size=s->compressed ? le32(h+96+i*4) : s->memory_size;
        if(s->memory_size>S2I_NSO_MAX_SEGMENT) return S2I_NSO_RESOURCE_LIMIT;
        if((s->stored_size &&
            s->file_offset<256) ||
            (s->memory_size &&
            !s->stored_size) ||
            (s->compressed &&
            s->stored_size>s->memory_size) ||
            s->memory_offset%4096 ||
            (uint64_t)s->memory_offset+s->memory_size>UINT64_C(0x100000000)) return S2I_NSO_INVALID_RANGE;
        if(!within(s->file_offset,s->stored_size,file_size)) return S2I_NSO_TRUNCATED;
        p.decoded_size+=s->memory_size;
    }
    if(p.decoded_size>S2I_NSO_MAX_DECODED) return S2I_NSO_RESOURCE_LIMIT;
    if(p.segments[0].memory_offset) return S2I_NSO_INVALID_RANGE;
    for(i=0; i<3; i++) for(j=i+1; j<3; j++) {
        if(overlaps(p.segments[i].file_offset,p.segments[i].stored_size,p.segments[j].file_offset,p.segments[j].stored_size)) return S2I_NSO_OVERLAP;
        if((uint64_t)p.segments[i].memory_offset+p.segments[i].memory_size>p.segments[j].memory_offset) return S2I_NSO_OVERLAP;
    }
    p.bss_size=le32(h+60);
    end=(uint64_t)p.segments[2].memory_offset+p.segments[2].memory_size;
    p.image_size=end+p.bss_size;
    if(p.image_size>UINT64_C(0x100000000)) return S2I_NSO_INVALID_RANGE;
    mo=le32(h+28);
    ms=le32(h+44);
    if(ms && !(mo==1 && ms==1)) {
        if(mo<256 || !within(mo,ms,file_size)) return S2I_NSO_INVALID_RANGE;
        for(i=0; i<3; i++) if(overlaps(mo,ms,p.segments[i].file_offset,p.segments[i].stored_size)) return S2I_NSO_OVERLAP;
    }
    for(i=0; i<3; i++) {
        uint32_t o=le32(h+136+i*8), z=le32(h+140+i*8);
        if(z && !within(o,z,p.segments[1].memory_size)) return S2I_NSO_INVALID_RANGE;
    }
    if(overlaps(le32(h+144),le32(h+148),le32(h+152),le32(h+156))) return S2I_NSO_OVERLAP;
    *out=p;
    return S2I_NSO_OK;
}

s2i_nso_status s2i_nso_inspect(const uint8_t *d,size_t n,s2i_nso_plan *p) {
    return s2i_nso_inspect_header(d,n,n,p);
}

s2i_nso_status s2i_lz4_decode(const uint8_t *src,size_t n,uint8_t *dst,size_t cap) {
    size_t ip=0,op=0,last_match=0;
    int matched=0;
    if(invalid_buffers(src,n,dst,cap)) return S2I_NSO_INVALID_ARGUMENT;
    if(n>S2I_NSO_MAX_SEGMENT || cap>S2I_NSO_MAX_SEGMENT) return S2I_NSO_RESOURCE_LIMIT;
    while(ip<n) {
        uint8_t token=src[ip++];
        size_t lit=token>>4,match=(token&15u)+4,off,k;
        unsigned x;
        if(lit==15) {
            do {
                if(ip==n) return S2I_NSO_INVALID_LZ4;
                x=src[ip++];
                if(lit>cap || x>cap-lit) return S2I_NSO_INVALID_LZ4;
                lit+=x;
            }
            while(x==255);
        }
        if(lit>n-ip || lit>cap-op) return S2I_NSO_INVALID_LZ4;
        if(lit) memcpy(dst+op,src+ip,lit);
        ip+=lit;
        op+=lit;
        if(ip==n) return op==cap && (!matched || (lit>=5 && cap-last_match>=12)) ? S2I_NSO_OK:S2I_NSO_INVALID_LZ4;
        if(n-ip<2) return S2I_NSO_INVALID_LZ4;
        off=(size_t)src[ip]|(size_t)src[ip+1]<<8;
        ip+=2;
        if(!off || off>op) return S2I_NSO_INVALID_LZ4;
        if((token&15u)==15) {
            do {
                if(ip==n) return S2I_NSO_INVALID_LZ4;
                x=src[ip++];
                if(match>cap || x>cap-match) return S2I_NSO_INVALID_LZ4;
                match+=x;
            }
            while(x==255);
        }
        if(match>cap-op) return S2I_NSO_INVALID_LZ4;
        matched=1;
        last_match=op;
        for(k=0; k<match; k++) {
            dst[op]=dst[op-off];
            op++;
        }
    }
    return S2I_NSO_INVALID_LZ4;
}
/* FIPS 180-4 SHA-256, local bounded implementation. Not used as authentication. */
static uint32_t rr(uint32_t x,unsigned n) {
    return (x>>n)|(x<<(32-n));
}

static void sha_block(uint32_t s[8],const uint8_t b[64]) {
    static const uint32_t K[64]= {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
         0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
         0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
         0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
         0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
         0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
         0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
         0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    };
    uint32_t w[64],a=s[0],c=s[2],d=s[3],e=s[4],f=s[5],g=s[6],h=s[7],v=s[1];
    unsigned i;
    for(i=0; i<16; i++) w[i]=(uint32_t)b[i*4]<<24|(uint32_t)b[i*4+1]<<16|(uint32_t)b[i*4+2]<<8|b[i*4+3];
    for(i=16; i<64; i++) w[i]=w[i-16]+(rr(w[i-15],7)^rr(w[i-15],18)^(w[i-15]>>3))+w[i-7]+(rr(w[i-2],17)^rr(w[i-2],19)^(w[i-2]>>10));
    for(i=0; i<64; i++) {
        uint32_t t=h+(rr(e,6)^rr(e,11)^rr(e,25))+((e&f)^(~e&g))+K[i]+w[i];
        uint32_t u=(rr(a,2)^rr(a,13)^rr(a,22))+((a&v)^(a&c)^(v&c));
        h=g;
        g=f;
        f=e;
        e=d+t;
        d=c;
        c=v;
        v=a;
        a=t+u;
    }
    s[0]+=a;
    s[1]+=v;
    s[2]+=c;
    s[3]+=d;
    s[4]+=e;
    s[5]+=f;
    s[6]+=g;
    s[7]+=h;
}

static void sha256(const uint8_t *data,size_t n,uint8_t out[32]) {
    uint32_t s[8]= {
        0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
    };
    uint8_t tail[128]= {
        0
    };
    size_t full=n/64,rem=n%64,i;
    uint64_t bits=(uint64_t)n*8;
    for(i=0; i<full; i++) sha_block(s,data+i*64);
    if(rem) memcpy(tail,data+full*64,rem);
    tail[rem]=128;
    for(i=0; i<8; i++) tail[(rem<56?64:128)-1-i]=(uint8_t)(bits>>(8*i));
    sha_block(s,tail);
    if(rem>=56) sha_block(s,tail+64);
    for(i=0; i<32; i++) out[i]=(uint8_t)(s[i/4]>>(24-8*(i%4)));
}

s2i_nso_status s2i_nso_decode_segment(const uint8_t *d,size_t n,uint32_t index,uint8_t *out,size_t cap) {
    s2i_nso_plan p;
    s2i_nso_segment *s;
    uint8_t digest[32];
    s2i_nso_status st;
    if(index>2) return S2I_NSO_INVALID_ARGUMENT;
    st=s2i_nso_inspect(d,n,&p);
    if(st!=S2I_NSO_OK) return st;
    s=&p.segments[index];
    if(cap<s->memory_size) return S2I_NSO_BUFFER_TOO_SMALL;
    if(!out && s->memory_size) return S2I_NSO_INVALID_ARGUMENT;
    /* Reject alias before any writes, including partially overlapping buffers. */
    if(invalid_buffers(d,n,out,s->memory_size)) return S2I_NSO_INVALID_ARGUMENT;
    if(s->compressed) st=s2i_lz4_decode(d+s->file_offset,s->stored_size,out,s->memory_size);
    else {
        if(s->memory_size) memcpy(out,d+s->file_offset,s->memory_size);
        st=S2I_NSO_OK;
    }
    if(st==S2I_NSO_OK && s->hash_required) {
        sha256(out,s->memory_size,digest);
        if(memcmp(digest,d+160+index*32,32)) st=S2I_NSO_HASH_MISMATCH;
    }
    if(st!=S2I_NSO_OK && s->memory_size) memset(out,0,s->memory_size);
    return st;
}

s2i_nso_status s2i_nso_check_static_text(const uint8_t *text,size_t n) {
    if(!text) return S2I_NSO_INVALID_ARGUMENT;
    if(n<8) return S2I_NSO_TRUNCATED;
    return le32(text+4) ? S2I_NSO_UNSUPPORTED_DYNAMIC_METADATA:S2I_NSO_OK;
}

const char *s2i_nso_status_string(s2i_nso_status s) {
    switch(s) {
        case S2I_NSO_OK:return "OK (inspection/decode only; execution unavailable)";
        case S2I_NSO_INVALID_ARGUMENT:return "Invalid argument or aliased destination";
        case S2I_NSO_TRUNCATED:return "Input truncated or range outside file";
        case S2I_NSO_UNSUPPORTED_FORMAT:return "Unsupported NSO format/version/flags (ZBIC unsupported)";
        case S2I_NSO_RESOURCE_LIMIT:return "Resource limit exceeded";
        case S2I_NSO_INVALID_RANGE:return "Invalid segment, module-name, or table range";
        case S2I_NSO_OVERLAP:return "Overlapping or unordered ranges";
        case S2I_NSO_INVALID_LZ4:return "Invalid LZ4 block or decoded length";
        case S2I_NSO_HASH_MISMATCH:return "Decoded segment SHA-256 mismatch";
        case S2I_NSO_BUFFER_TOO_SMALL:return "Destination buffer too small";
        case S2I_NSO_UNSUPPORTED_DYNAMIC_METADATA:return "MOD0 dynamic metadata/relocations require unimplemented linker";
        default:return "Unknown status";
    }
}
