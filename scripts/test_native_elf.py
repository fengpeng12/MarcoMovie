"""Binary fixtures catch alignment false positives without loading native code."""
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from native_elf import inspect_elf, inspect_apk

def elf(align=16384, address=0, extra=False):
    ident=b'\x7fELF\x02\x01\x01'+bytes(9)
    count=2 if extra else 1
    data=struct.pack('<16sHHIQQQIHHHHHH',ident,3,183,1,0,64,0,0,64,56,count,0,0,0)
    data+=struct.pack('<IIQQQQQQ',1,5,0,address,0,64+56*count,64+56*count,align)
    if extra: data+=struct.pack('<IIQQQQQQ',1,6,0,0,0,64,64,4096)
    return data

class ElfChecks(unittest.TestCase):
    def test_good_and_bad_load_segments(self):
        self.assertTrue(inspect_elf(elf())['compatible_16kb'])
        self.assertFalse(inspect_elf(elf(4096))['compatible_16kb'])
        self.assertFalse(inspect_elf(elf(address=4096))['compatible_16kb'])
        self.assertFalse(inspect_elf(elf(24576))['compatible_16kb'])
        self.assertFalse(inspect_elf(elf(extra=True))['compatible_16kb'])

    def test_truncated_binary(self):
        for data in (b'',elf()[:30],elf()[:-1]):
            with self.assertRaises(ValueError):inspect_elf(data)

    def test_apk_storage_alignment(self):
        with tempfile.TemporaryDirectory() as folder:
            for mode in (zipfile.ZIP_STORED,zipfile.ZIP_DEFLATED):
                p=Path(folder)/'sample.apk'
                with zipfile.ZipFile(p,'w',mode) as z:z.writestr('lib/arm64-v8a/libsample.so',elf())
                row=inspect_apk(p)[0]
                self.assertEqual(row['zip_16kb_aligned'],mode==zipfile.ZIP_DEFLATED)

    def test_empty_apk_cannot_pass_gate(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'sample.apk'
            with zipfile.ZipFile(p,'w') as z:z.writestr('assets/test','fixture')
            r=subprocess.run([sys.executable,str(Path(__file__).with_name('native_elf.py')),str(p),'--require-16kb'],capture_output=True)
            self.assertNotEqual(r.returncode,0)

if __name__=='__main__':unittest.main()
