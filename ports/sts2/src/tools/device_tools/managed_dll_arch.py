# INPUT: managed DLL bytes from the selected Linux runtime baseline
# OUTPUT: AnyCPU pure-IL or Linux ARM64 ReadyToRun classification
# POS: fail-closed architecture gate; never loads or invokes an assembly
import struct


def classify_runtime_dll(data):
    if len(data)<64 or data[:2]!=b'MZ':raise ValueError('not a PE managed assembly')
    pe=struct.unpack_from('<I',data,0x3c)[0]
    if data[pe:pe+4]!=b'PE\0\0':raise ValueError('invalid PE signature')
    coff=pe+4;machine,sections=struct.unpack_from('<HH',data,coff)
    optional=coff+20;opt_size=struct.unpack_from('<H',data,coff+16)[0]
    magic=struct.unpack_from('<H',data,optional)[0]
    if (machine,magic) not in ((0x14c,0x10b),(0xaa64,0x20b),(0xd11d,0x20b)):
        raise ValueError('unsupported runtime architecture')
    cli_rva=struct.unpack_from('<I',data,optional+(112 if magic==0x20b else 96)+14*8)[0]
    def offset(rva,size):
        for index in range(sections):
            p=optional+opt_size+index*40
            vsize,va,rawsize,rawptr=struct.unpack_from('<4I',data,p+8)
            if va<=rva and rva+size<=va+rawsize and rawptr+(rva-va)+size<=len(data):
                return rawptr+rva-va
        raise ValueError('CLI directory outside PE sections')
    cli=offset(cli_rva,72);flags=struct.unpack_from('<I',data,cli+16)[0]
    native_rva,native_size=struct.unpack_from('<II',data,cli+64)
    if machine==0xd11d:
        if native_size<8:raise ValueError('missing ARM64 ReadyToRun header')
        r2r=offset(native_rva,native_size);signature,major,minor=struct.unpack_from('<IHH',data,r2r)
        if (signature,major,minor)!=(0x00525452,10,1):raise ValueError('unexpected ARM64 ReadyToRun version')
        return 'linux-arm64-r2r'
    if not flags&1 or flags&(2|0x10|0x20000) or native_rva or native_size:
        raise ValueError('unsupported non-pure managed assembly')
    return 'anycpu-il' if machine==0x14c else 'arm64-il'
