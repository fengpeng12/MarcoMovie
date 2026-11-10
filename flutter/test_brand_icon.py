import struct
import tempfile
import unittest
from pathlib import Path
from prepare_platform import _write_windows_ico, LOGO_MARK


class BrandIconChecks(unittest.TestCase):
    def test_native_sizes_and_transparent_png_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'app.ico'
            _write_windows_ico(target, LOGO_MARK)
            data = target.read_bytes()
            self.assertEqual(struct.unpack_from('<HHH', data), (0, 1, 9))
            sizes = []
            for n in range(9):
                w, h, _, _, planes, bits, length, offset = struct.unpack_from('<BBBBHHII', data, 6 + n * 16)
                sizes.append(w or 256)
                self.assertEqual(w, h)
                self.assertEqual((planes, bits), (1, 32))
                png = data[offset:offset + length]
                self.assertEqual(png[:8], b'\x89PNG\r\n\x1a\n')
                self.assertEqual(struct.unpack_from('>II', png, 16), (w or 256, h or 256))
                self.assertEqual(png[25], 6)  # RGBA, not an opaque RGB square.
            self.assertEqual(sizes, [16, 20, 24, 32, 40, 48, 64, 128, 256])


if __name__ == '__main__':
    unittest.main()
