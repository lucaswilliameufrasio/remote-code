import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPECIFICATION = importlib.util.spec_from_file_location('build_release', ROOT / 'scripts/build_release.py')
MODULE = importlib.util.module_from_spec(SPECIFICATION)
SPECIFICATION.loader.exec_module(MODULE)


class ReleaseBuildTest(unittest.TestCase):
    def test_should_refuse_unmanaged_native_projects(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            self.assertFalse(MODULE.managed_signing_ready(root))
            gradle = root / 'android/app/build.gradle.kts'
            gradle.parent.mkdir(parents=True)
            gradle.write_text('android { /* Default debug release signing */ }')
            self.assertFalse(MODULE.managed_signing_ready(root))

    def test_should_build_with_signing_references_only_in_the_environment(self):
        with tempfile.TemporaryDirectory() as folder:
            fixture = pathlib.Path(folder) / 'synthetic-keystore'
            fixture.write_text('not-a-real-keystore')
            environment = {name: 'synthetic-fixture' for name in MODULE.SIGNING_NAMES}
            environment[MODULE.SIGNING_NAMES[0]] = str(fixture)
            with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['build_release.py', 'apk']), patch.object(MODULE.subprocess, 'run') as run:
                MODULE.main()
                run.assert_called_once_with(['flutter', 'build', 'apk', '--release'], cwd=ROOT, check=True)

    def test_should_remove_signing_inputs_from_unsigned_builds(self):
        environment = {name: 'synthetic-fixture' for name in MODULE.SIGNING_NAMES}
        with patch.dict(os.environ, environment), patch.object(sys, 'argv', ['build_release.py', 'appbundle', '--unsigned']), patch.object(MODULE.subprocess, 'run') as run:
            MODULE.main()
            supplied = run.call_args.kwargs['env']
            self.assertTrue(all(name not in supplied for name in MODULE.SIGNING_NAMES))
            self.assertEqual(run.call_args.args[0], ['flutter', 'build', 'appbundle', '--release'])

    def test_should_require_all_signing_inputs(self):
        self.assertFalse(MODULE.signing_ready({}))
        values = {name: 'synthetic-fixture' for name in MODULE.SIGNING_NAMES}
        self.assertTrue(MODULE.signing_ready(values))
        for name in MODULE.SIGNING_NAMES:
            self.assertFalse(MODULE.signing_ready({**values, name: ''}))

    def test_should_fail_without_printing_partial_secrets(self):
        environment = {key: value for key, value in os.environ.items() if key not in MODULE.SIGNING_NAMES}
        environment[MODULE.SIGNING_NAMES[1]] = 'synthetic-do-not-print'
        result = subprocess.run([sys.executable, str(ROOT / 'scripts/build_release.py'), 'apk'],
                                env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('synthetic-do-not-print', result.stderr + result.stdout)


if __name__ == '__main__':
    unittest.main()
