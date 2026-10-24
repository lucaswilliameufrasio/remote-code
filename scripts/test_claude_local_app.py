#!/usr/bin/env python3
"""Test the mobile Claude client over trusted local TLS with the real SDK/CLI."""
import argparse
import asyncio
import base64
import json
import os
import pathlib
import shutil
import ssl
import subprocess
import sys

from aiohttp import web

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'host/claude-code'))
from test_sdk_runtime import OfficialRuntimeTests


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    arguments = parser.parse_args()
    flutter = shutil.which('flutter')
    if flutter is None:
        raise SystemExit('Flutter is required')
    # Build tools keep their normal HOME; no provider credentials enter this process.
    build_environment = {key: value for key, value in os.environ.items() if key in (
        'PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'DEVELOPER_DIR',
        'JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT', 'FLUTTER_ROOT', 'PUB_CACHE')}
    fixture = OfficialRuntimeTests()
    await fixture.asyncSetUp()
    process = None
    try:
        base = fixture.root
        root_certificate, root_key = base / 'root.pem', base / 'root-key.pem'
        certificate, private_key = base / 'server.pem', base / 'server-key.pem'
        request_file, extensions = base / 'server.csr', base / 'server.ext'
        extensions.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n')
        commands = [
            ['openssl', 'req', '-x509', '-nodes', '-newkey', 'rsa:2048', '-days', '1',
             '-keyout', str(root_key), '-out', str(root_certificate), '-subj', '/CN=CodeRelay Local Test',
             '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign'],
            ['openssl', 'req', '-new', '-nodes', '-newkey', 'rsa:2048', '-keyout', str(private_key),
             '-out', str(request_file), '-subj', '/CN=localhost'],
            ['openssl', 'x509', '-req', '-in', str(request_file), '-CA', str(root_certificate),
             '-CAkey', str(root_key), '-CAcreateserial', '-out', str(certificate),
             '-days', '1', '-extfile', str(extensions)],
        ]
        for command in commands:
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        root_key.chmod(0o600)
        private_key.chmod(0o600)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(certificate, private_key)
        site = web.TCPSite(fixture.runner, '127.0.0.1', 0, ssl_context=tls)
        await site.start()
        port = site._server.sockets[0].getsockname()[1]
        session = await fixture.call('POST', '/sessions', 201,
                                     json={'title': 'External fixture seed', 'directory': str(fixture.project)})
        await fixture.call('POST', f"/sessions/{session['id']}/prompts", 202,
                           json={'id': 'msg_seed', 'text': 'Seed local history'})
        await fixture.wait_idle()
        native = fixture.engine.catalog()[0]
        external_id = fixture.engine.fork(native['id'], str(fixture.project))
        definitions = base / 'mobile-test.json'
        definitions.write_text(json.dumps({
            'CLAUDE_E2E_URL': f'https://127.0.0.1:{port}',
            'CLAUDE_E2E_PROJECT': str(fixture.project),
            'CLAUDE_E2E_CA': base64.b64encode(root_certificate.read_bytes()).decode(),
            'CLAUDE_E2E_EXTERNAL': external_id,
        }))
        definitions.chmod(0o600)
        process = await asyncio.create_subprocess_exec(
            flutter, 'drive', '--no-pub', '--driver=test_driver/integration_test.dart',
            '--target=integration_test/claude_real_server_test.dart', '-d', arguments.device,
            f'--dart-define-from-file={definitions}', cwd=ROOT, env=build_environment)
        result = await asyncio.wait_for(process.wait(), 600)
        if result != 0:
            raise SystemExit(result)
        if (fixture.project / 'approval-fixture.txt').exists():
            raise SystemExit('The denied tool unexpectedly wrote a file')
        print(json.dumps({'claude_mobile_tls_validation': 'passed',
                          'local_model_requests': fixture.calls,
                          'provider_credentials_used': False}))
    finally:
        if process is not None and process.returncode is None:
            process.terminate()
            await process.wait()
        await fixture.asyncTearDown()


if __name__ == '__main__':
    asyncio.run(main())
