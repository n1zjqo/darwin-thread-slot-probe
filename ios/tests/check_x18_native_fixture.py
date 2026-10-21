"""Owned stdlib-only static/word checks. Never assembles or executes ARM code."""
import ast
import argparse
import struct
import hashlib
import json
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
IOS = Path(__file__).resolve().parents[1]
STAGE = IOS.parent
TEST = IOS/'Switch2IOSTests'
asm = (TEST/'X18NativeFixture.S').read_text()
header = (TEST/'X18NativeFixture.h').read_text()
c = (TEST/'X18NativeFixture.c').read_text()
tests = (TEST/'X18NativeTests.m').read_text()
# Frozen expected body words independently reviewed against the owned emitter.
# Ordinary C ABI setup uses 12 instructions (48 bytes) before each literal body.
EXPECTED = {
    '_s2i_x18_w_add_write': (0x0b0b0152, (0xf9000789, 0xf9400389, 0x0b0b0149, 0xf9000389, 0xf9400789)),
    '_s2i_x18_w_add_read': (0x0b0b024a, (0xf9000789, 0xf9400389, 0x0b0b012a, 0xf9400789)),
    '_s2i_x18_w_add_repeated': (0x0b120252, (0xf9000789, 0xf9400389, 0x0b090129, 0xf9000389, 0xf9400789)),
    '_s2i_x18_w_sub_write': (0x4b0b0152, (0xf9000789, 0xf9400389, 0x4b0b0149, 0xf9000389, 0xf9400789)),
    '_s2i_x18_w_sub_read': (0x4b0b024a, (0xf9000789, 0xf9400389, 0x4b0b012a, 0xf9400789)),
    '_s2i_x18_w_sub_repeated': (0x4b120252, (0xf9000789, 0xf9400389, 0x4b090129, 0xf9000389, 0xf9400789)),
    '_s2i_x18_x_add_write': (0x8b0b0152, (0xf9000789, 0xf9400389, 0x8b0b0149, 0xf9000389, 0xf9400789)),
    '_s2i_x18_x_add_read': (0x8b0b024a, (0xf9000789, 0xf9400389, 0x8b0b012a, 0xf9400789)),
    '_s2i_x18_x_add_repeated': (0x8b120252, (0xf9000789, 0xf9400389, 0x8b090129, 0xf9000389, 0xf9400789)),
    '_s2i_x18_x_sub_write': (0xcb0b0152, (0xf9000789, 0xf9400389, 0xcb0b0149, 0xf9000389, 0xf9400789)),
    '_s2i_x18_x_sub_read': (0xcb0b024a, (0xf9000789, 0xf9400389, 0xcb0b012a, 0xf9400789)),
    '_s2i_x18_x_sub_repeated': (0xcb120252, (0xf9000789, 0xf9400389, 0xcb090129, 0xf9000389, 0xf9400789)),
}
bodies=re.findall(r'// BODY_BEGIN (\S+) input=(0x[0-9a-f]+)\n(.*?)// BODY_END',asm,re.S)
assert len(bodies)==12
assert len({name for name,_,_ in bodies}) == 12
assert {name for name,_,_ in bodies} == set(EXPECTED)
word_checks=0
for name,input_word,body in bodies:
    assert asm.count(name+':') == 1
    assert f'.globl {name}' in asm
    words=tuple(int(x,16) for x in re.findall(r'\.long (0x[0-9a-f]+)',body))
    word=int(input_word,16)
    assert ((word&31),(word>>5&31),(word>>16&31)) in ((18,10,11),(10,18,11),(18,18,18))
    assert (word,words)==EXPECTED[name]
    assert len(body.strip().splitlines()) == len(words)
    assert len(words)==(4 if word&31==10 else 5)
    word_checks+=len(words)
    function=asm.split(name+':',1)[1].split('.cfi_endproc',1)[0]
    prefix=function.split('// BODY_BEGIN',1)[0]
    assert len([line for line in prefix.splitlines() if line.strip() and not line.lstrip().startswith('.')]) == 12
    assert 'stp x29, x30, [sp, #-32]!' in function
    assert 'str x28, [sp, #16]' in function
    assert 'ldr x28, [sp, #16]' in function
    assert 'ldp x29, x30, [sp], #32' in function
    assert not re.search(r'\b[wx](?:19|2[0-7])\b',function)
    assert re.search(r'msr NZCV, x12\n// BODY_BEGIN',function)
    assert '// BODY_END\n    mrs x12, NZCV' in function
assert not re.search(r'\b[wx]18\b',asm), 'No physical reserved-register references allowed'
assert asm.count('.cfi_startproc')==asm.count('.cfi_endproc')==13
assert asm.count('    blr x16')==1
assert not re.search(r'\b(?:mmap|mprotect|syscall|svc|brk|hlt|jit)\b',asm,re.I)
probe=asm.split('_s2i_x18_caller_probe:',1)[1]
assert 'sub sp, sp, #128' in probe and 'add sp, sp, #128' in probe
assert 'add x29, sp, #80' in probe
assert 'TARGET_OS_SIMULATOR && TARGET_OS_IOS' in header and 'TARGET_OS_SIMULATOR && TARGET_OS_IOS' in asm
assert '!defined(__arm64e__)' in header and '!defined(__arm64e__)' in asm
assert 'stp x0, x1, [sp, #96]' in probe and 'ldr x0, [sp, #96]' in probe
for i in range(6):
    r=19+2*i
    assert f'stp x{r}, x{r+1}, [sp, #{16*i}]' in probe
    assert f'ldp x{r}, x{r+1}, [sp, #{16*i}]' in probe
for r in range(19,29):
    assert f'mov x{r}, #0x{0x1900+r:04x}' in probe
    assert f'movk x{r}, #0xa5a5, lsl #48' in probe
fields=['context','initial9','initial10','initial11','initial_nzcv','after9','after10','after11','after_nzcv','helper_sp_before','helper_sp_after','base_before','base_after','callee_before','callee_after','probe_sp_before','probe_sp_after','canary_before','canary_after','fp_before','fp_after','expected_link','observed_link']
offsets=[0,32,40,48,56,64,72,80,88,96,104,112,120,128,208,288,296,304,312,320,328,336,344]
for field,offset in zip(fields,offsets):assert f'S2I_OFFSET({field}, {offset})' in header
assert 'sizeof(S2IX18Packet) == 352' in header
assert 'uint32_t a = (uint32_t)left' in c and 'const uint64_t left' in c
assert 'selector >= S2IX18Count' in c
assert 'XCTFail(@"Owned native fixture requires iOS Simulator ARM64, not device/arm64e; no successful fallback.")' in tests
assert 'flags < 16' in tests and 'index < 9' in tests
assert 'memcmp((const unsigned char *)p + 32' in tests

swift_tests=sum(len(re.findall(r'\bfunc test\w+\s*\(',p.read_text())) for p in TEST.glob('*.swift'))
assert swift_tests==73
for path in (IOS/'tests').glob('*.py'):ast.parse(path.read_text())
report={'passed':True,'fixed_helpers':len(bodies),'literal_instruction_words':word_checks,
        'existing_swift_test_methods_counted_not_run':swift_tests,
        'native_matrix_cases_planned':12*16*9,'native_tests_added':3,
        'physical_reserved_register_references':0,'apple_build_run':False,'native_execution_run':False,
        'scope':'Static source and frozen expected words only; optional object bytes are not execution'}


def verify_owned_object(path):
    """Read only the specifically named owned Mach-O object; never load/execute it."""
    path=Path(path)
    if path.name != 'X18NativeFixture.o':
        raise ValueError('Expected the owned X18NativeFixture.o object name')
    if not path.is_file() or not 32 <= path.stat().st_size <= 16*1024*1024:
        raise ValueError('Missing or oversized owned object')
    data=path.read_bytes()
    def bounded(offset,size):
        if offset < 0 or size < 0 or offset+size > len(data):
            raise ValueError('Object range outside file')
        return data[offset:offset+size]
    magic,cpu,subtype,kind,ncmds,sizeofcmds,flags,reserved=struct.unpack('<8I',bounded(0,32))
    if magic != 0xfeedfacf or cpu != 0x0100000c or subtype != 0 or kind != 1:
        raise ValueError('Require thin little-endian ARM64_ALL Mach-O MH_OBJECT')
    if not 1 <= ncmds <= 128 or sizeofcmds > 1024*1024 or reserved != 0:
        raise ValueError('Invalid object header limits')
    bounded(32,sizeofcmds)
    cursor=32
    sections=[]
    symtab=None
    for _ in range(ncmds):
        cmd,size=struct.unpack('<2I',bounded(cursor,8))
        if size < 8 or size % 8 or cursor+size > 32+sizeofcmds:
            raise ValueError('Invalid load-command bounds')
        if cmd == 0x19:  # LC_SEGMENT_64; section addresses are not file offsets.
            if size < 72:
                raise ValueError('Short segment command')
            values=struct.unpack('<II16sQQQQIIII',bounded(cursor,72))
            nsects=values[-2]
            if nsects > 128 or size != 72+nsects*80:
                raise ValueError('Invalid section table')
            for i in range(nsects):
                sec=struct.unpack('<16s16sQQ8I',bounded(cursor+72+i*80,80))
                sections.append(dict(name=sec[0].rstrip(b'\0'),segment=sec[1].rstrip(b'\0'),
                                     address=sec[2],size=sec[3],offset=sec[4],relocation_offset=sec[6],relocation_count=sec[7],flags=sec[8],
                                     ordinal=len(sections)+1))
        elif cmd == 2:  # LC_SYMTAB
            if size != 24 or symtab is not None:
                raise ValueError('Ambiguous symbol table')
            symtab=struct.unpack('<6I',bounded(cursor,24))[2:]
        cursor+=size
    if cursor != 32+sizeofcmds or symtab is None:
        raise ValueError('Missing or malformed commands/symbols')
    text_sections=[s for s in sections if s['name']==b'__text' and s['segment']==b'__TEXT']
    if len(text_sections) != 1:
        raise ValueError('Require one unambiguous text section')
    section=text_sections[0]
    if section['flags'] & 0xff or section['address']+section['size'] > 2**64:
        raise ValueError('Unsupported text section type/range')
    bounded(section['offset'],section['size'])
    if section['relocation_count'] > 4096:
        raise ValueError('Too many text relocations')
    if section['relocation_count']:
        bounded(section['relocation_offset'],section['relocation_count']*8)
        raise ValueError('Owned fixture requires relocation-free text; raw bytes alone are insufficient')
    symoff,nsyms,stroff,strsize=symtab
    if not 1 <= nsyms <= 4096 or not 1 <= strsize <= 1024*1024:
        raise ValueError('Invalid symbol limits')
    bounded(symoff,nsyms*16)
    strings=bounded(stroff,strsize)
    symbols={}
    text_values=[]
    for i in range(nsyms):
        strx,ntype,nsect,desc,value=struct.unpack('<IBBHQ',bounded(symoff+i*16,16))
        if strx >= strsize:
            raise ValueError('Invalid symbol string index')
        end=strings.find(b'\0',strx)
        if end == -1:
            raise ValueError('Unterminated symbol')
        raw=strings[strx:end]
        if ntype & 0xe0 or (ntype & 0x0e) != 0x0e or nsect != section['ordinal']:
            continue
        if not section['address'] <= value < section['address']+section['size']:
            raise ValueError('Text symbol outside section')
        text_values.append(value)
        if raw.startswith(b'_s2i_x18_'):
            name=raw.decode('ascii')
            if name in symbols or not ntype & 1:
                raise ValueError('Duplicate or nonexternal fixture symbol')
            symbols[name]=value
    if set(symbols) != set(EXPECTED)|{'_s2i_x18_caller_probe'}:
        raise ValueError('Missing or unexpected fixture functions')
    checked=0
    for name,(_,words) in EXPECTED.items():
        start=symbols[name]
        end=min((v for v in text_values if v>start),default=section['address']+section['size'])
        body=start+48
        if start%4 or body+len(words)*4>end:
            raise ValueError('Body crosses function boundary')
        file_offset=section['offset']+(body-section['address'])
        expected=b''.join(word.to_bytes(4,'little') for word in words)
        if bounded(file_offset,len(expected)) != expected:
            raise ValueError('Object literal-body bytes differ: '+name)
        checked+=1
    return {'object_sha256':hashlib.sha256(data).hexdigest(),'object_bodies_checked':checked,
            'object_executed':False,
            'object_bytes_scope':'Raw relocation-free body bytes only, not linked/prologue/ABI verification'}


parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--object',type=Path,help='Optional owned X18NativeFixture.o for read-only Mach-O byte checks')
args=parser.parse_args()
if args.object is not None:
    report.update(verify_owned_object(args.object))
else:
    report['object_verification']='NOT_RUN: no owned object supplied'
(STAGE/'static_check_result.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
