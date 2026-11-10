"""Guarded upstream compatibility patches: no downloads or native build required."""
from pathlib import Path
import tempfile
import unittest
from native.build_catpaw_node import patch_libuv_android_barriers


GUARD = '#if defined(_AIX) || \\\n    defined(__OpenBSD__) || \\\n    !defined(PTHREAD_BARRIER_SERIAL_THREAD)'
PATHS = ('deps/uv/include/uv/unix.h', 'deps/uv/src/unix/thread.c')


class LibuvPatchTests(unittest.TestCase):
    def test_type_and_implementation_select_the_same_pre24_fallback(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for relative in PATHS:
                path = root / relative
                path.parent.mkdir(parents=True)
                path.write_text(GUARD + '\nfallback\n#else\nnative\n#endif\n')
            patch_libuv_android_barriers(root)
            texts = [(root / relative).read_text() for relative in PATHS]
            self.assertEqual(texts[0], texts[1])
            self.assertIn('(defined(__ANDROID__) && __ANDROID_API__ < 24) ||', texts[0])
            self.assertIn('fallback\n#else\nnative', texts[0])
            with self.assertRaises(ValueError): patch_libuv_android_barriers(root)

    def test_changed_upstream_implementation_leaves_header_unmodified(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for index, relative in enumerate(PATHS):
                path = root / relative
                path.parent.mkdir(parents=True)
                path.write_text(GUARD if index == 0 else 'upstream changed')
            with self.assertRaises(ValueError): patch_libuv_android_barriers(root)
            self.assertEqual((root / PATHS[0]).read_text(), GUARD)


if __name__ == '__main__': unittest.main()
