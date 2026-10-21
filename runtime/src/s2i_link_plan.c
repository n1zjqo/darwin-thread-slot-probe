#include "s2i_link_plan.h"
#include <stdlib.h>
#include <string.h>

/* This parser deliberately does not extend the frozen inventory/preparation ABI. */
struct extent { uint64_t address, size; };
struct metadata {
 struct extent ranges[12]; size_t range_count;
 const uint8_t *rela, *jmprel;
 uint64_t rela_count_hint;
 int has_hint;
 s2i_link_module_report report;
};
struct reference { s2i_dynamic_name name; uint32_t module, symbol; };
struct span { uint32_t start, count; };
struct module_ref {
 const s2i_module *module;
 s2i_module_view view;
 s2i_link_module_report report;
 size_t symbol_start;
};
struct s2i_link_plan {
 s2i_module_allocator allocator;
 s2i_link_summary summary;
 size_t max_name_work;
 struct module_ref *modules;
 s2i_link_relocation *relocations;
 struct reference *candidates;
 struct span *spans;
};
static void *allocate_default(void *context, size_t size) { (void)context; return malloc(size); }
static void free_default(void *context, void *value) { (void)context; free(value); }
static uint32_t le32(const uint8_t *p) {
 return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
static uint64_t le64(const uint8_t *p) { return le32(p) | (uint64_t)le32(p+4)<<32; }
static int sum(size_t a, size_t b, size_t *out) {
 if (b > SIZE_MAX-a) return 0;
 *out = a+b; return 1;
}
static int product(size_t a, size_t b, size_t *out) {
 if (a && b > SIZE_MAX/a) return 0;
 *out = a*b; return 1;
}
static void error_at(s2i_link_error *e, s2i_link_stage stage, size_t m, size_t r) {
 if (e) { e->stage=stage; e->module_index=m; e->record_index=r; }
}
static const uint8_t *range(const s2i_module_view *v, uint64_t a, uint64_t n) {
 unsigned i;
 for (i=0; i<3; ++i) {
  uint64_t start=v->plan.segments[i].memory_offset;
  if (a>=start && a-start<=v->segments[i].size && n<=v->segments[i].size-(a-start))
   return v->segments[i].bytes ? v->segments[i].bytes+(size_t)(a-start) : NULL;
 }
 return NULL;
}
static int overlap(struct extent a, struct extent b) {
 return a.size && b.size && a.address < b.address+b.size && b.address < a.address+a.size;
}
static int add_extent(struct metadata *m, const s2i_module_view *v, uint64_t a, uint64_t n) {
 struct extent e; size_t i;
 if (!range(v,a,n) || n>UINT64_MAX-a || m->range_count>=12) return 0;
 e.address=a; e.size=n;
 for (i=0; i<m->range_count; ++i) if (overlap(e,m->ranges[i])) return 0;
 m->ranges[m->range_count++]=e; return 1;
}
static int charge_work(size_t *work, size_t limit, size_t n) {
 if (*work>limit || n>limit-*work) return 0;
 *work+=n; return 1;
}
static int hash_name(s2i_dynamic_name name, size_t *work, size_t limit, uint32_t *out) {
 uint32_t h=5381; size_t i;
 if (!charge_work(work,limit,name.size)) return 0;
 for (i=0;i<name.size;++i) h=h*33u+name.bytes[i];
 *out=h; return 1;
}
/* Bounded complete suffix checks, with a separate legacy empty-table state.
 * No guessed walk is used to derive N: it comes only from validated SysV HASH. */
static s2i_link_status gnu_hash(const s2i_module_view *v, struct metadata *m,
 uint64_t a, int has_sysv, size_t *work, size_t work_limit) {
 const uint8_t *header=range(v,a,16), *bloom, *buckets, *chains;
 uint32_t nb, first, words, shift, h=0, next=0;
 uint64_t prefix, total; size_t i, bucket_cursor=0, n=v->dynamic.symbol_count;
 int all_empty=1;
 if (!header || a%8) return S2I_LINK_INVALID_METADATA;
 nb=le32(header); first=le32(header+4); words=le32(header+8); shift=le32(header+12);
 if (!nb || !words || (words & (words-1)) || shift>=32) return S2I_LINK_INVALID_METADATA;
 if (nb>S2I_DYNAMIC_MAX_SYMBOLS || words>S2I_DYNAMIC_MAX_SYMBOLS) return S2I_LINK_RESOURCE_LIMIT;
 prefix=16+(uint64_t)words*8+(uint64_t)nb*4;
 if (!range(v,a,prefix)) return S2I_LINK_INVALID_METADATA;
 bloom=header+16; buckets=bloom+(size_t)words*8;
 for (i=0;i<nb;++i) if (le32(buckets+i*4)) all_empty=0;
 if (!has_sysv) {
  if (!add_extent(m,v,a,prefix)) return S2I_LINK_INVALID_METADATA;
  m->report.gnu_hash=S2I_LINK_GNU_UNBOUNDED;
  m->report.format=m->report.inventory=S2I_LINK_INCOMPLETE;
  return S2I_LINK_OK;
 }
 if (!first || first>n) return S2I_LINK_INVALID_METADATA;
 /* GNU ld can emit this no-chain shape even when undefined symbols follow
  * symbol zero. Record it conservatively as incomplete rather than inventing
  * chain storage or incorrectly rejecting a historical valid encoding. */
 if (all_empty && first<n) {
  if (!add_extent(m,v,a,prefix)) return S2I_LINK_INVALID_METADATA;
  m->report.gnu_hash=S2I_LINK_GNU_INCOMPLETE;
  m->report.format=S2I_LINK_INCOMPLETE;
  return S2I_LINK_OK;
 }
 total=prefix+(uint64_t)(n-first)*4;
 if (!add_extent(m,v,a,total)) return S2I_LINK_INVALID_METADATA;
 chains=buckets+(size_t)nb*4;
 if (first<n && !hash_name(v->symbols[first].name,work,work_limit,&h)) return S2I_LINK_RESOURCE_LIMIT;
 for (i=first;i<n;++i) {
  uint32_t bucket=h%nb, raw=le32(chains+(i-first)*4), end=1;
  uint64_t mask=(UINT64_C(1)<<(h%64)) | (UINT64_C(1)<<((h>>shift)%64));
  if (i==first || !(le32(chains+(i-first-1)*4)&1)) {
   /* Continuation must still be inside the current bucket. */
   if (i!=first && bucket+1!=bucket_cursor) return S2I_LINK_INVALID_METADATA;
  }
  if (i==first || (le32(chains+(i-first-1)*4)&1)) {
   if (bucket<bucket_cursor) return S2I_LINK_INVALID_METADATA;
   while (bucket_cursor<bucket) {
    if (le32(buckets+bucket_cursor*4)) return S2I_LINK_INVALID_METADATA;
    ++bucket_cursor;
   }
   if (le32(buckets+(size_t)bucket*4)!=i) return S2I_LINK_INVALID_METADATA;
   bucket_cursor=(size_t)bucket+1;
  }
  if (i+1<n) {
   if (!hash_name(v->symbols[i+1].name,work,work_limit,&next)) return S2I_LINK_RESOURCE_LIMIT;
   if (next%nb<bucket) return S2I_LINK_INVALID_METADATA;
   end=next%nb!=bucket;
  }
  if (raw!=((h&~1u)|end) || (le64(bloom+((h/64)%words)*8)&mask)!=mask)
   return S2I_LINK_INVALID_METADATA;
  h=next;
 }
 while (bucket_cursor<nb) {
  if (le32(buckets+bucket_cursor*4)) return S2I_LINK_INVALID_METADATA;
  ++bucket_cursor;
 }
 m->report.gnu_hash=S2I_LINK_GNU_VALIDATED;
 return S2I_LINK_OK;
}

static s2i_link_status metadata(const s2i_module_view *v, struct metadata *m,
 size_t *work, size_t limit, size_t per_module, s2i_link_stage *stage) {
 uint64_t ra=0,rs=0,re=0,ja=0,js=0,jt=0,sa=0,ss=0,sy=0,ha=0,ga=0;
 unsigned rp=0,jp=0,ip=0,fp=0; int has_sysv=0,has_gnu=0;
 size_t i; const uint8_t *q;
 memset(m,0,sizeof(*m));
 m->report.format=m->report.targets=m->report.inventory=S2I_LINK_VALIDATED;
 m->report.policy=S2I_LINK_POLICY_DEFERRED;
 m->report.original_warnings=v->dynamic.warnings;
 m->report.symbol_count=v->dynamic.symbol_count;
 m->report.dependency_count=v->dynamic.dependency_count;
 if (!v->dynamic.imports_complete || !v->dynamic.dependencies_complete)
  m->report.inventory=S2I_LINK_INCOMPLETE;
 if (v->dynamic.warnings & ~S2I_DYNAMIC_GNU_HASH_UNSUPPORTED)
  m->report.format=S2I_LINK_INCOMPLETE;
 if (v->dynamic.warnings & S2I_DYNAMIC_NO_MOD0) return S2I_LINK_OK;
 if (!add_extent(m,v,le32(v->segments[0].bytes+4),28) ||
     !add_extent(m,v,v->dynamic.dynamic_address,(v->dynamic.dynamic_entries+1)*16))
  return S2I_LINK_INVALID_METADATA;
 for (i=0;i<v->dynamic.dynamic_entries;++i) {
  uint64_t tag,value;
  q=range(v,v->dynamic.dynamic_address+i*16,16);
  if (!q) return S2I_LINK_INVALID_METADATA;
  tag=le64(q);value=le64(q+8);
  switch(tag) {
   case 1: case 11: case 14: case 39: break;
   case 4: ha=value;has_sysv=1;break;
   case 5: sa=value;break;
   case 6: sy=value;break;
   case 10:ss=value;break;
   case 7:ra=value;rp|=1;break;
   case 8:rs=value;rp|=2;break;
   case 9:re=value;rp|=4;break;
   case 23:ja=value;jp|=1;break;
   case 2:js=value;jp|=2;break;
   case 20:jt=value;jp|=4;break;
   case 12:m->report.init_offset=value;m->report.present|=1;break;
   case 13:m->report.fini_offset=value;m->report.present|=2;break;
   case 25:m->report.init_array_offset=value;ip|=1;break;
   case 27:m->report.init_array_size=value;ip|=2;break;
   case 26:m->report.fini_array_offset=value;fp|=1;break;
   case 28:m->report.fini_array_size=value;fp|=2;break;
   case 3:m->report.pltgot_offset=value;m->report.present|=16;break;
   case 21:m->report.present|=64;break; /* No dereference. */
   case UINT64_C(0x6ffffef5):ga=value;has_gnu=1;break;
   case UINT64_C(0x6ffffff9):m->rela_count_hint=value;m->has_hint=1;break;
   case UINT64_C(0x6ffffffb):m->report.flags1=value;m->report.present|=32;break;
   default:++m->report.unknown_tag_count;m->report.format=S2I_LINK_INCOMPLETE;break;
  }
 }
 if (ss && !add_extent(m,v,sa,ss)) return S2I_LINK_INVALID_METADATA;
 if (v->dynamic.symbol_count && !add_extent(m,v,sy,(uint64_t)v->dynamic.symbol_count*24))
  return S2I_LINK_INVALID_METADATA;
 if (has_sysv) {
  q=range(v,ha,8);
  if (!q || le32(q+4)!=v->dynamic.symbol_count ||
      !add_extent(m,v,ha,8+((uint64_t)le32(q)+le32(q+4))*4)) return S2I_LINK_INVALID_METADATA;
 }
 if (has_gnu) {
  s2i_link_status status;
  *stage=S2I_LINK_STAGE_GNU_HASH;
  status=gnu_hash(v,m,ga,has_sysv,work,limit);
  if (status!=S2I_LINK_OK) return status;
  *stage=S2I_LINK_STAGE_METADATA;
 }
 if (rp) {
  if (rp!=7 || re!=24 || rs%24 || ra%8) return S2I_LINK_INVALID_METADATA;
  if (rs/24>per_module) return S2I_LINK_RESOURCE_LIMIT;
  if (!add_extent(m,v,ra,rs)) return S2I_LINK_INVALID_METADATA;
  m->rela=range(v,ra,rs);m->report.rela_count=(size_t)(rs/24);
 }
 if (jp) {
  if (jp!=7 || jt!=7 || js%24 || ja%8) return S2I_LINK_INVALID_METADATA;
  if (js/24>per_module) return S2I_LINK_RESOURCE_LIMIT;
  if (!add_extent(m,v,ja,js)) return S2I_LINK_INVALID_METADATA;
  m->jmprel=range(v,ja,js);m->report.jmprel_count=(size_t)(js/24);
 }
 if (m->report.rela_count>per_module-m->report.jmprel_count) return S2I_LINK_RESOURCE_LIMIT;
 if (m->has_hint && (!rp || m->rela_count_hint>m->report.rela_count)) return S2I_LINK_INVALID_METADATA;
 /* Arrays are validated initialized storage, not protected relocation metadata:
  * relocation of their slots is permitted, but values/calls remain deferred. */
 if (ip) {
  if (ip!=3 || m->report.init_array_size%8 || m->report.init_array_offset%8 ||
      !range(v,m->report.init_array_offset,m->report.init_array_size)) return S2I_LINK_INVALID_METADATA;
  m->report.present|=4;
 }
 if (fp) {
  if (fp!=3 || m->report.fini_array_size%8 || m->report.fini_array_offset%8 ||
      !range(v,m->report.fini_array_offset,m->report.fini_array_size)) return S2I_LINK_INVALID_METADATA;
  m->report.present|=8;
 }
 return S2I_LINK_OK;
}
static int compare_name(s2i_link_plan *p,s2i_dynamic_name a,s2i_dynamic_name b,int *order) {
 size_t n=a.size<b.size?a.size:b.size; int c;
 if (!charge_work(&p->summary.name_work,p->max_name_work,n)) return 0;
 c=n?memcmp(a.bytes,b.bytes,n):0;
 *order=c?c:a.size<b.size?-1:a.size>b.size?1:0;
 return 1;
}
/* Bounded in-place heapsorts, no opaque qsort allocation or quadratic search. */
static int sift_refs(s2i_link_plan *p,size_t root,size_t count) {
 while(root<count/2) {
  size_t child=root*2+1; int order; struct reference temp;
  if(child+1<count) {
   if(!compare_name(p,p->candidates[child].name,p->candidates[child+1].name,&order)) return 0;
   if(order<0) ++child;
  }
  if(!compare_name(p,p->candidates[root].name,p->candidates[child].name,&order)) return 0;
  if(order>=0) return 1;
  temp=p->candidates[root];p->candidates[root]=p->candidates[child];p->candidates[child]=temp;
  root=child;
 }
 return 1;
}
static int sort_refs(s2i_link_plan *p) {
 size_t n=p->summary.candidate_count,i;
 if(n<2) return 1;
 for(i=n/2;i;--i) if(!sift_refs(p,i-1,n)) return 0;
 for(i=n-1;i;--i) {
  struct reference temp=p->candidates[0];p->candidates[0]=p->candidates[i];p->candidates[i]=temp;
  if(!sift_refs(p,0,i)) return 0;
 }
 return 1;
}
static void sift_keys(uint64_t *keys,size_t root,size_t count) {
 while(root<count/2) {
  size_t child=root*2+1;uint64_t temp;
  if(child+1<count && keys[child]<keys[child+1]) ++child;
  if(keys[root]>=keys[child]) return;
  temp=keys[root];keys[root]=keys[child];keys[child]=temp;root=child;
 }
}
static void sort_keys(uint64_t *keys,size_t n) {
 size_t i; if(n<2) return;
 for(i=n/2;i;--i) sift_keys(keys,i-1,n);
 for(i=n-1;i;--i) {uint64_t temp=keys[0];keys[0]=keys[i];keys[i]=temp;sift_keys(keys,0,i);}
}
static int find_span(s2i_link_plan *p,s2i_dynamic_name name,struct span *out) {
 size_t lo=0,hi=p->summary.candidate_count,first;int order;
 out->start=out->count=0;
 if(!name.size) return 1;
 while(lo<hi) {
  size_t mid=lo+(hi-lo)/2;
  if(!compare_name(p,p->candidates[mid].name,name,&order)) return 0;
  if(order<0) lo=mid+1;else hi=mid;
 }
 first=lo;hi=p->summary.candidate_count;
 while(lo<hi) {
  size_t mid=lo+(hi-lo)/2;
  if(!compare_name(p,p->candidates[mid].name,name,&order)) return 0;
  if(order<=0) lo=mid+1;else hi=mid;
 }
 out->start=(uint32_t)first;out->count=(uint32_t)(lo-first);return 1;
}
static void *allocate_zero(s2i_link_plan *p,size_t n) {
 void *v;if(!n) return NULL;
 v=p->allocator.allocate(p->allocator.context,n);if(v) memset(v,0,n);return v;
}
s2i_link_options s2i_link_default_options(void) {
 s2i_link_options o;memset(&o,0,sizeof(o));
 o.max_peak_bytes=S2I_LINK_MAX_PEAK_BYTES;
 o.max_relocations_per_module=S2I_LINK_MAX_RELOCATIONS_PER_MODULE;
 o.max_relocations=S2I_LINK_MAX_RELOCATIONS;
 o.max_symbols=S2I_LINK_MAX_SYMBOLS;o.max_candidates=S2I_LINK_MAX_CANDIDATES;
 o.max_name_work=S2I_LINK_MAX_NAME_WORK;return o;
}
void s2i_link_plan_destroy(s2i_link_plan **owner) {
 s2i_link_plan *p;s2i_module_allocator a;
 if(!owner || !*owner) return;
 p=*owner;a=p->allocator;*owner=NULL;
 if(p->spans) a.deallocate(a.context,p->spans);
 if(p->candidates) a.deallocate(a.context,p->candidates);
 if(p->relocations) a.deallocate(a.context,p->relocations);
 if(p->modules) a.deallocate(a.context,p->modules);
 a.deallocate(a.context,p);
}
s2i_link_status s2i_link_plan_create(const s2i_module *const *modules,size_t count,
 const s2i_link_options *requested,s2i_link_plan **out,s2i_link_error *error) {
 s2i_link_options o=requested?*requested:s2i_link_default_options();
 struct metadata metas[S2I_LINK_MAX_MODULES];
 s2i_module_view views[S2I_LINK_MAX_MODULES];
 s2i_link_summary summary;s2i_link_plan *p=NULL;uint64_t *keys=NULL;
 s2i_link_status status=S2I_LINK_NO_MEMORY;s2i_link_stage stage;
 size_t i,j,k,r=0,c=0,s=0,mb,rb,cb,sb,tb,owned,peak;
 error_at(error,S2I_LINK_STAGE_OPTIONS,SIZE_MAX,SIZE_MAX);
 if(!out || *out || !modules || !count || count>S2I_LINK_MAX_MODULES ||
    (!o.allocator.allocate != !o.allocator.deallocate)) return S2I_LINK_INVALID_ARGUMENT;
 if(o.max_peak_bytes>S2I_LINK_MAX_PEAK_BYTES ||
    o.max_relocations_per_module>S2I_LINK_MAX_RELOCATIONS_PER_MODULE ||
    o.max_relocations>S2I_LINK_MAX_RELOCATIONS || o.max_symbols>S2I_LINK_MAX_SYMBOLS ||
    o.max_candidates>S2I_LINK_MAX_CANDIDATES || o.max_name_work>S2I_LINK_MAX_NAME_WORK)
  return S2I_LINK_RESOURCE_LIMIT;
 if(!o.allocator.allocate) {o.allocator.allocate=allocate_default;o.allocator.deallocate=free_default;}
 memset(&summary,0,sizeof(summary));
 summary.format=summary.targets=summary.inventory=S2I_LINK_VALIDATED;
 summary.policy=S2I_LINK_POLICY_DEFERRED;summary.module_count=count;
 summary.other_live_bytes=o.other_live_bytes;
 summary.report_bytes=(count+1)*S2I_LINK_REPORT_BYTES;
 for(i=0;i<count;++i) {
  error_at(error,S2I_LINK_STAGE_MODULE,i,SIZE_MAX);
  if(!modules[i] || s2i_module_get_view(modules[i],&views[i])!=S2I_MODULE_OK)
   return S2I_LINK_INVALID_ARGUMENT;
  for(j=0;j<i;++j) if(modules[j]==modules[i]) return S2I_LINK_INVALID_ARGUMENT;
  if(!sum(summary.source_module_bytes,views[i].owned_bytes,&summary.source_module_bytes))
   return S2I_LINK_RESOURCE_LIMIT;
  if(!sum(summary.source_module_bytes,o.other_live_bytes,&peak) ||
     !sum(peak,summary.report_bytes,&peak) || peak>o.max_peak_bytes) return S2I_LINK_RESOURCE_LIMIT;
  stage=S2I_LINK_STAGE_METADATA;
  status=metadata(&views[i],&metas[i],&summary.name_work,o.max_name_work,o.max_relocations_per_module,&stage);
  if(status!=S2I_LINK_OK) {error_at(error,stage,i,SIZE_MAX);return status;}
  if(!sum(r,metas[i].report.rela_count+metas[i].report.jmprel_count,&r) || r>o.max_relocations ||
     !sum(s,views[i].dynamic.symbol_count,&s) || s>o.max_symbols) return S2I_LINK_RESOURCE_LIMIT;
  for(j=0;j<views[i].dynamic.symbol_count;++j)
   if(views[i].symbols[j].name.size && views[i].symbols[j].section) {
    if(c==o.max_candidates) return S2I_LINK_RESOURCE_LIMIT;
    ++c;
   }
  if(metas[i].report.format==S2I_LINK_INCOMPLETE) summary.format=S2I_LINK_INCOMPLETE;
  if(metas[i].report.inventory==S2I_LINK_INCOMPLETE) summary.inventory=S2I_LINK_INCOMPLETE;
 }
 summary.relocation_count=r;summary.candidate_count=c;summary.symbol_count=s;
 error_at(error,S2I_LINK_STAGE_BUDGET,SIZE_MAX,SIZE_MAX);
 if(!product(count,sizeof(struct module_ref),&mb) || !product(r,sizeof(s2i_link_relocation),&rb) ||
    !product(c,sizeof(struct reference),&cb) || !product(s,sizeof(struct span),&sb) ||
    !product(r,sizeof(uint64_t),&tb) || !sum(sizeof(*p),mb,&owned) || !sum(owned,rb,&owned) ||
    !sum(owned,cb,&owned) || !sum(owned,sb,&owned) || !sum(owned,tb,&peak) ||
    !sum(peak,summary.source_module_bytes,&peak) || !sum(peak,o.other_live_bytes,&peak) ||
    !sum(peak,summary.report_bytes,&peak) || peak>o.max_peak_bytes) return S2I_LINK_RESOURCE_LIMIT;
 summary.owned_bytes=owned;summary.temporary_bytes=tb;summary.creation_peak_bytes=peak;
 error_at(error,S2I_LINK_STAGE_ALLOCATION,SIZE_MAX,SIZE_MAX);
 p=o.allocator.allocate(o.allocator.context,sizeof(*p));
 if(!p) return S2I_LINK_NO_MEMORY;
 memset(p,0,sizeof(*p));p->allocator=o.allocator;p->summary=summary;p->max_name_work=o.max_name_work;
 status=S2I_LINK_NO_MEMORY;
 p->modules=allocate_zero(p,mb);if(!p->modules) goto fail;
 if(rb && !(p->relocations=allocate_zero(p,rb))) goto fail;
 if(cb && !(p->candidates=allocate_zero(p,cb))) goto fail;
 if(sb && !(p->spans=allocate_zero(p,sb))) goto fail;
 if(tb && !(keys=allocate_zero(p,tb))) goto fail;
 c=s=0;
 for(i=0;i<count;++i) {
  p->modules[i].module=modules[i];p->modules[i].view=views[i];
  p->modules[i].report=metas[i].report;p->modules[i].symbol_start=s;
  s+=views[i].dynamic.symbol_count;
  for(j=0;j<views[i].dynamic.symbol_count;++j) if(views[i].symbols[j].name.size && views[i].symbols[j].section) {
   p->candidates[c].name=views[i].symbols[j].name;
   p->candidates[c].module=(uint32_t)i;p->candidates[c++].symbol=(uint32_t)j;
  }
 }
 error_at(error,S2I_LINK_STAGE_INVENTORY,SIZE_MAX,SIZE_MAX);
 status=S2I_LINK_RESOURCE_LIMIT;
 if(!sort_refs(p)) goto fail;
 for(i=0;i<count;++i) for(j=0;j<views[i].dynamic.symbol_count;++j)
  if(!find_span(p,views[i].symbols[j].name,&p->spans[p->modules[i].symbol_start+j])) goto fail;
 r=0;
 for(i=0;i<count;++i) {
  struct metadata *m=&metas[i];const s2i_module_view *v=&views[i];
  uint64_t data_start=v->plan.segments[2].memory_offset;
  uint64_t data_size=(uint64_t)v->segments[2].size+v->plan.bss_size;
  if(data_size>UINT64_C(0x100000000)-data_start) {status=S2I_LINK_INVALID_TARGET;goto fail;}
  for(j=0;j<m->report.rela_count+m->report.jmprel_count;++j) {
   int is_plt=j>=m->report.rela_count;
   size_t ti=is_plt?j-m->report.rela_count:j;
   const uint8_t *bytes=(is_plt?m->jmprel:m->rela)+ti*24;
   s2i_link_relocation *item=&p->relocations[r];struct extent target;
   uint64_t info=le64(bytes+8);
   error_at(error,S2I_LINK_STAGE_RELOCATION,i,j);
   item->target_offset=le64(bytes);item->addend_bits=le64(bytes+16);
   item->module_index=(uint32_t)i;item->table_index=(uint32_t)ti;
   item->table=is_plt?S2I_LINK_JMPREL:S2I_LINK_RELA;
   item->type=(uint32_t)info;item->symbol_index=(uint32_t)(info>>32);
   status=S2I_LINK_UNSUPPORTED_RELOCATION;
   if(item->type!=257 && item->type!=1025 && item->type!=1026 && item->type!=1027) goto fail;
   status=S2I_LINK_INVALID_SYMBOL;
   if(item->type==1027) {
    if(item->symbol_index) goto fail;
    item->expression=S2I_LINK_LOAD_BIAS_PLUS_ADDEND;
   } else {
    item->expression=item->type==1026?S2I_LINK_JUMP_SLOT_PLATFORM_EXPRESSION:S2I_LINK_SYMBOL_PLUS_ADDEND;
    if(v->dynamic.symbol_count) {
     struct span span;
     if(item->symbol_index>=v->dynamic.symbol_count) goto fail;
     span=p->spans[p->modules[i].symbol_start+item->symbol_index];
     item->candidate_start=span.start;item->candidate_count=span.count;
    }
   }
   status=S2I_LINK_INVALID_METADATA;
   if(!is_plt && m->has_hint && j<m->rela_count_hint && item->type!=1027) goto fail;
   status=S2I_LINK_INVALID_TARGET;
   if(item->target_offset%8 || item->target_offset<data_start ||
      item->target_offset-data_start>data_size || 8>data_size-(item->target_offset-data_start)) goto fail;
   target.address=item->target_offset;target.size=8;
   for(k=0;k<m->range_count;++k) if(overlap(target,m->ranges[k])) goto fail;
   keys[r]=((uint64_t)i<<32)|item->target_offset;++r;
  }
 }
 sort_keys(keys,r);
 for(i=1;i<r;++i) if(keys[i]==keys[i-1]) {
  error_at(error,S2I_LINK_STAGE_RELOCATION,(size_t)(keys[i]>>32),SIZE_MAX);
  status=S2I_LINK_INVALID_TARGET;goto fail;
 }
 if(keys) p->allocator.deallocate(p->allocator.context,keys);
 error_at(error,S2I_LINK_STAGE_NONE,SIZE_MAX,SIZE_MAX);*out=p;return S2I_LINK_OK;
fail:
 if(keys) p->allocator.deallocate(p->allocator.context,keys);
 s2i_link_plan_destroy(&p);return status;
}
s2i_link_status s2i_link_plan_get_summary(const s2i_link_plan *p,s2i_link_summary *out) {
 if(!p||!out) return S2I_LINK_INVALID_ARGUMENT;
 *out=p->summary;return S2I_LINK_OK;
}
s2i_link_status s2i_link_plan_get_module(const s2i_link_plan *p,size_t i,s2i_link_module_report *out) {
 if(!p||!out) return S2I_LINK_INVALID_ARGUMENT;
 if(i>=p->summary.module_count) return S2I_LINK_INVALID_INDEX;
 *out=p->modules[i].report;return S2I_LINK_OK;
}
s2i_link_status s2i_link_plan_get_relocation(const s2i_link_plan *p,size_t i,s2i_link_relocation *out) {
 if(!p||!out) return S2I_LINK_INVALID_ARGUMENT;
 if(i>=p->summary.relocation_count) return S2I_LINK_INVALID_INDEX;
 *out=p->relocations[i];return S2I_LINK_OK;
}
s2i_link_status s2i_link_plan_get_candidate(const s2i_link_plan *p,size_t i,s2i_link_candidate *out) {
 const struct reference *r;const s2i_dynamic_symbol *s;
 if(!p||!out) return S2I_LINK_INVALID_ARGUMENT;
 if(i>=p->summary.candidate_count) return S2I_LINK_INVALID_INDEX;
 r=&p->candidates[i];s=&p->modules[r->module].view.symbols[r->symbol];
 memset(out,0,sizeof(*out));out->module_index=r->module;out->symbol_index=r->symbol;
 out->value=s->value;out->size=s->size;out->section=s->section;
 out->binding=s->binding;out->type=s->type;out->visibility=s->visibility;return S2I_LINK_OK;
}
s2i_link_status s2i_link_plan_candidates(const s2i_link_plan *p,size_t m,size_t s,size_t *start,size_t *count) {
 struct span span;
 if(!p||!start||!count) return S2I_LINK_INVALID_ARGUMENT;
 if(m>=p->summary.module_count || s>=p->modules[m].view.dynamic.symbol_count) return S2I_LINK_INVALID_INDEX;
 span=p->spans[p->modules[m].symbol_start+s];*start=span.start;*count=span.count;return S2I_LINK_OK;
}
s2i_link_status s2i_link_plan_copy_name(const s2i_link_plan *p,size_t m,s2i_module_name_kind kind,
 size_t i,uint8_t *dst,size_t capacity,size_t *required) {
 s2i_module_status status;
 if(!p) return S2I_LINK_INVALID_ARGUMENT;
 if(m>=p->summary.module_count) return S2I_LINK_INVALID_INDEX;
 status=s2i_module_copy_name(p->modules[m].module,kind,i,dst,capacity,required);
 switch(status) {
 case S2I_MODULE_OK:return S2I_LINK_OK;
 case S2I_MODULE_INVALID_INDEX:return S2I_LINK_INVALID_INDEX;
 case S2I_MODULE_BUFFER_TOO_SMALL:return S2I_LINK_BUFFER_TOO_SMALL;
 default:return S2I_LINK_INVALID_ARGUMENT;
 }
}
const char *s2i_link_status_string(s2i_link_status s) {
 switch(s) {
 case S2I_LINK_OK:return "read-only plan (policy deferred, not ready)";
 case S2I_LINK_INVALID_ARGUMENT:return "invalid argument";
 case S2I_LINK_RESOURCE_LIMIT:return "link inventory resource limit";
 case S2I_LINK_NO_MEMORY:return "allocation failure";
 case S2I_LINK_INVALID_METADATA:return "invalid metadata";
 case S2I_LINK_INVALID_TARGET:return "invalid or duplicate target";
 case S2I_LINK_UNSUPPORTED_RELOCATION:return "unsupported relocation expression";
 case S2I_LINK_INVALID_SYMBOL:return "invalid symbol reference";
 case S2I_LINK_INVALID_INDEX:return "invalid index";
 case S2I_LINK_BUFFER_TOO_SMALL:return "name buffer too small";
 default:return "unknown link plan status";
 }
}
