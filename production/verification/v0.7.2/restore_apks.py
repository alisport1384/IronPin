#!/usr/bin/env python3
"""Restore signed IronPin 0.7.2 APKs with standard Python only.
Keep this file, IronPin-0.7.2-apks.lossless.zip and ../IronPin-0.7.1/*.apk.
Run: python RESTORE-APK-0.7.2.py [--output DIRECTORY]
No network, installation or private key is needed. Historical files never change.
Raw DEFLATE must match the recorded checksum (tested with zlib 1.2.13).
Refuses incompatible zlib output or overwriting a different existing file.
"""
from pathlib import Path
import argparse, bz2, hashlib, io, json, os, struct, zipfile, zlib
def sha(data): return hashlib.sha256(data).hexdigest()
def offset(data):
    n = int.from_bytes(data, 'little')
    return -(n & ((1 << 63) - 1)) if n >> 63 else n

def patch(old, data):
    if data[:8] != b'BSDIFF40': raise ValueError('Not BSDIFF40')
    a, b, size = (offset(data[p:p+8]) for p in (8, 16, 24))
    if min(a, b, size) < 0 or size > 32*1024*1024: raise ValueError('Unsafe patch')
    control = bz2.decompress(data[32:32+a])
    diff = bz2.decompress(data[32+a:32+a+b])
    extra = bz2.decompress(data[32+a+b:])
    result = bytearray(size)
    cp = dp = ep = pos = op = 0
    while pos < size:
        x, y, z = (offset(control[p:p+8]) for p in (cp, cp+8, cp+16))
        cp += 24
        if min(x,y) < 0 or pos+x+y > size or dp+x > len(diff) or ep+y > len(extra):
            raise ValueError('Invalid patch lengths')
        for i in range(x): result[pos+i] = (diff[dp+i] + (old[op+i] if 0 <= op+i < len(old) else 0)) & 255
        pos += x; op += x; dp += x
        result[pos:pos+y] = extra[ep:ep+y]
        pos += y; ep += y; op += z
    return bytes(result)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parent
    out=args.output or root
    with zipfile.ZipFile(root/'IronPin-0.7.2-apks.lossless.zip') as z:
        m=json.loads(z.read('manifest.json'))
        assert m['format']=='zip-aware-bsdiff40-v1'
        for a in m['files']:
            relative=Path(a['base'])
            assert len(relative.parts)==3 and relative.parts[:2]==('..','IronPin-0.7.1')
            old=(root/relative).read_bytes()
            assert sha(old)==a['baseSha256'], 'Wrong base APK'
            with zipfile.ZipFile(io.BytesIO(old)) as base:
                info=base.getinfo(a['member'])
                start=info.header_offset+30+sum(struct.unpack_from('<HH',old,info.header_offset+26))
                assert start==a['baseOffset'] and info.compress_size==a['baseCompressedBytes']
                rawold=base.read(a['member'])
            rp=z.read(a['rawPatch']); op=z.read(a['outerPatch'])
            assert sha(rp)==a['rawPatchSha256'] and sha(op)==a['outerPatchSha256']
            rawnew=patch(rawold,rp)
            assert sha(rawnew)==a['rawSha256'] and len(rawnew)==a['rawBytes']
            c=zlib.compressobj(6,zlib.DEFLATED,-15,8,zlib.Z_DEFAULT_STRATEGY)
            packed=c.compress(rawnew)+c.flush()
            assert sha(packed)==a['compressedSha256'] and len(packed)==a['compressedBytes'], 'Incompatible zlib: exact raw-DEFLATE checksum failed; use recorded version '+m['zlibRuntimeVersion']
            synthetic=old[:start]+packed+old[start+info.compress_size:]
            assert sha(synthetic)==a['syntheticSha256']
            result=patch(synthetic,op)
            assert len(result)==a['bytes'] and sha(result)==a['sha256'], 'Final signed APK checksum'
            name=Path(a['file'])
            assert len(name.parts)==1 and name.suffix=='.apk'
            dest=out/name
            if dest.exists():
                assert dest.read_bytes()==result, 'Refusing overwrite of different existing file'
            else:
                dest.parent.mkdir(parents=True,exist_ok=True)
                temporary=dest.with_suffix('.apk.restoring')
                temporary.write_bytes(result)
                os.replace(temporary,dest)
            print(dest,sha(result))
if __name__=='__main__':main()
