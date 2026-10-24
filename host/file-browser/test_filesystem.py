"""Exercise the policy against real POSIX files, not mocked path comparisons."""
import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('filesystem', pathlib.Path(__file__).with_name('filesystem.py'))
filesystem = importlib.util.module_from_spec(spec)
spec.loader.exec_module(filesystem)


class FilePolicyTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = pathlib.Path(self.temporary.name).resolve()
        self.root = self.directory / 'allowed'
        self.root.mkdir()
        self.outside = self.directory / 'outside'
        self.outside.mkdir()
        (self.root / 'file.txt').write_text('safe content')
        (self.outside / 'file.txt').write_text('outside content')

    def tearDown(self):
        self.temporary.cleanup()

    def execute(self, method, value, directory=None, roots=None):
        return filesystem.execute([str(self.root)] if roots is None else roots,
                                  str(directory or self.root), method, value)

    def test_allowed_files_and_subdirectories(self):
        (self.root / 'src').mkdir()
        listing = self.execute('list', {})
        self.assertEqual({entry['path'] for entry in listing['data']}, {'src', 'file.txt'})
        self.assertEqual(self.execute('read', {'path': 'file.txt'})['text'], 'safe content')

    def test_empty_roots_and_outside_locations_are_denied(self):
        for roots, directory in [([], self.root), ([str(self.root)], self.outside)]:
            with self.assertRaises(filesystem.PolicyError):
                self.execute('list', {}, roots=roots, directory=directory)

    def test_traversal_and_absolute_read_paths_are_denied(self):
        for path in ['../outside/file.txt', '/etc/passwd', 'src/../file.txt', '%2e%2e/file', 'src\\file', 'a\x00b']:
            with self.assertRaises(filesystem.PolicyError):
                self.execute('read', {'path': path})

    def test_symlink_files_directories_and_locations_are_denied(self):
        (self.root / 'link.txt').symlink_to(self.outside / 'file.txt')
        (self.root / 'linkdir').symlink_to(self.outside, target_is_directory=True)
        self.assertEqual([entry['path'] for entry in self.execute('list', {})['data']], ['file.txt'])
        for method, value in [('read', {'path': 'link.txt'}), ('read', {'path': 'linkdir/file.txt'}), ('list', {'path': 'linkdir'})]:
            with self.assertRaises((filesystem.PolicyError, OSError)):
                self.execute(method, value)
        with self.assertRaises(OSError):
            self.execute('list', {}, directory=self.root / 'linkdir')

    def test_ancestor_swap_does_not_redirect_an_already_open_directory(self):
        subdirectory = self.root / 'sub'
        subdirectory.mkdir()
        (subdirectory / 'file.txt').write_text('original directory')
        original_open = os.open

        def swap_before_final_open(path, flags, *arguments, **keywords):
            if path == 'file.txt':
                subdirectory.rename(self.root / 'retained')
                subdirectory.symlink_to(self.outside, target_is_directory=True)
            return original_open(path, flags, *arguments, **keywords)

        with patch.object(filesystem.os, 'open', side_effect=swap_before_final_open):
            result = self.execute('read', {'path': 'sub/file.txt'})
        self.assertEqual(result['text'], 'original directory')

    def test_fifo_and_binary_files_are_not_previewed(self):
        os.mkfifo(self.root / 'pipe')
        (self.root / 'binary').write_bytes(b'\x00\xff')
        for path in ['pipe', 'binary']:
            with self.assertRaises(filesystem.PolicyError):
                self.execute('read', {'path': path})

    def test_text_preview_has_a_byte_limit_and_preserves_unicode(self):
        (self.root / 'large').write_text('é' * filesystem.MAX_BYTES)
        result = self.execute('read', {'path': 'large'})
        self.assertTrue(result['truncated'])
        self.assertLessEqual(len(result['text'].encode()), filesystem.MAX_BYTES)
        self.assertNotIn('\ufffd', result['text'])

    def test_search_is_bounded_and_never_follows_symlinks(self):
        (self.root / 'linked').symlink_to(self.outside, target_is_directory=True)
        for index in range(110):
            (self.root / f'match-{index}.txt').touch()
        result = self.execute('find', {'query': 'match'})
        self.assertEqual(len(result['data']), 100)
        self.assertFalse(any('linked' in entry['path'] for entry in result['data']))

    def test_large_listing_is_refused_instead_of_silently_truncated(self):
        for index in range(501):
            (self.root / str(index)).touch()
        with self.assertRaises(filesystem.PolicyError) as raised:
            self.execute('list', {})
        self.assertEqual(raised.exception.code, 'FILES_LIMIT')


if __name__ == '__main__':
    unittest.main()
