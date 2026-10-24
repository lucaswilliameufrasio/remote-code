#!/usr/bin/env python3
"""Test the plugin in an isolated OpenCode server without models or real credentials."""
import base64
import json
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('opencode'), 'OpenCode v2 is required for runtime integration')
class FileBrowserRuntimeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.base = pathlib.Path(cls.temporary.name).resolve()
        cls.allowed = cls.base / 'project'
        cls.allowed.mkdir()
        (cls.allowed / 'file.txt').write_text('safe fixture')
        cls.outside = cls.base / 'outside'
        cls.outside.mkdir()
        (cls.outside / 'private.txt').write_text('outside fixture')
        (cls.allowed / 'escape').symlink_to(cls.outside, target_is_directory=True)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        cls.url = f'http://127.0.0.1:{port}'
        cls.authorization = 'Basic ' + base64.b64encode(b'opencode:synthetic-local-test-password').decode()
        configuration = cls.base / 'config/opencode/opencode.json'
        configuration.parent.mkdir(parents=True)
        configuration.write_text(json.dumps({'plugins': ['*', {
            'package': str(ROOT / 'host/file-browser'),
            'options': {'roots': [str(cls.allowed)]},
        }]}))
        environment = {
            'PATH': os.environ['PATH'], 'HOME': str(cls.base),
            'XDG_CONFIG_HOME': str(cls.base / 'config'),
            'XDG_DATA_HOME': str(cls.base / 'data'),
            'XDG_CACHE_HOME': str(cls.base / 'cache'),
            'OPENCODE_SERVER_USERNAME': 'opencode',
            'OPENCODE_SERVER_PASSWORD': 'synthetic-local-test-password',
            'OPENCODE_LOG_LEVEL': 'DEBUG',
        }
        cls.log = (cls.base / 'server.log').open('wb')
        cls.process = subprocess.Popen([shutil.which('opencode'), 'serve', '--log-level', 'debug', '--print-logs', '--hostname', '127.0.0.1', '--port', str(port)],
            cwd=cls.allowed, env=environment, stdout=cls.log, stderr=subprocess.STDOUT,
            start_new_session=True)
        cls.addClassCleanup(cls.stop)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                request = urllib.request.Request(cls.url + '/api/info', headers={'authorization': cls.authorization})
                with urllib.request.urlopen(request, timeout=2) as response:
                    if json.load(response)['version'].startswith('2.'):
                        try:
                            cls().call('capabilities', {})
                            return
                        except urllib.error.HTTPError as exception:
                            exception.close()
            except (OSError, ValueError, KeyError) as exception:
                if isinstance(exception, urllib.error.HTTPError):
                    exception.close()
                if cls.process.poll() is not None:
                    break
            time.sleep(.2)
        cls.log.flush()
        diagnostic = '\n'.join(line for line in (cls.base / 'server.log').read_text(errors='replace').splitlines()
                               if 'failed to load plugin' in line or 'configured plugin' in line)[-2000:]
        diagnostic = diagnostic.replace('synthetic-local-test-password', '[test credential]')
        raise RuntimeError('Isolated plugin did not become ready: ' + diagnostic)

    @classmethod
    def stop(cls):
        if cls.process.poll() is None:
            os.killpg(cls.process.pid, signal.SIGTERM)
            try:
                cls.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(cls.process.pid, signal.SIGKILL)
                cls.process.wait(timeout=5)
        cls.log.close()
        cls.temporary.cleanup()

    def call(self, method, value, directory=None, authenticated=True):
        query = urllib.parse.urlencode({'location[directory]': str(directory or self.allowed)})
        headers = {'content-type': 'application/json'}
        if authenticated:
            headers['authorization'] = self.authorization
        request = urllib.request.Request(f'{self.url}/api/rpc/remote-code-files-v1/{method}?{query}',
            data=json.dumps({'input': value}).encode(), headers=headers, method='POST')
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)['output']

    def test_real_plugin_registration_and_read(self):
        self.assertEqual(self.call('read', {'path': 'file.txt'})['text'], 'safe fixture')
        self.assertTrue(self.call('capabilities', {})['restricted'])
        self.assertEqual(self.call('roots', {}, directory=self.outside)['data'], [str(self.allowed)])

    def test_authentication_is_enforced_by_the_real_router(self):
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.call('list', {}, authenticated=False)
        self.assertEqual(raised.exception.code, 401)
        raised.exception.close()

    def test_symlink_and_outside_location_are_rejected_by_the_real_router(self):
        for directory, path in [(self.allowed, 'escape/private.txt'), (self.outside, 'private.txt')]:
            with self.assertRaises(urllib.error.HTTPError) as raised:
                self.call('read', {'path': path}, directory=directory)
            error = json.load(raised.exception)
            self.assertEqual(error['type'], 'rejected')
            self.assertEqual(error['data']['code'], 'FILES_DENIED')
            raised.exception.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
