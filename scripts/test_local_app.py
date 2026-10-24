#!/usr/bin/env python3
"""Run the real mobile client against isolated OpenCode and verified local HTTPS."""
import argparse
import base64
import http.client
import http.server
import json
import os
import pathlib
import shutil
import signal
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEST_PASSWORD = 'synthetic-local-test-password'


class State:
    def __init__(self, project):
        self.project = project
        self.backend_port = 0
        self.prompt_posts = 0
        self.dropped_acks = 0
        self.model_requests = 0
        self.changed_file = False


def model_handler(state):
    class ModelHandler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *arguments):
            pass

        def do_POST(self):
            length = int(self.headers.get('content-length', '0'))
            if length > 2 * 1024 * 1024:
                self.send_error(413)
                return
            body = json.loads(self.rfile.read(length))
            state.model_requests += 1
            messages = json.dumps(body.get('messages', []))
            tool_call = None
            if body.get('tools') and 'LOCAL_CHANGE_FIXTURE' in messages and not state.changed_file:
                tool_call = {'index': 0, 'id': 'call_local_write', 'type': 'function',
                             'function': {'name': 'write', 'arguments': json.dumps({
                                 'path': str(state.project / 'src/fixture.txt'), 'content': 'new fixture line\n'})}}
                state.changed_file = True
            response = 'LOCAL_RESPONSE_OK'
            common = {'id': 'chatcmpl_local_fixture', 'created': int(time.time()),
                      'model': body.get('model', 'fixture')}
            self.send_response(200)
            if body.get('stream'):
                self.send_header('content-type', 'text/event-stream')
                self.end_headers()
                chunks = [
                    {**common, 'object': 'chat.completion.chunk', 'choices': [
                        {'index': 0, 'delta': ({'role': 'assistant', 'tool_calls': [tool_call]} if tool_call else
                                             {'role': 'assistant', 'content': response}), 'finish_reason': None}]},
                    {**common, 'object': 'chat.completion.chunk', 'choices': [
                        {'index': 0, 'delta': {}, 'finish_reason': 'tool_calls' if tool_call else 'stop'}],
                     'usage': {'prompt_tokens': 10, 'completion_tokens': 5, 'total_tokens': 15}},
                ]
                for chunk in chunks:
                    self.wfile.write(('data: ' + json.dumps(chunk) + '\n\n').encode())
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
            else:
                self.send_header('content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({**common, 'object': 'chat.completion', 'choices': [
                    {'index': 0, 'message': {'role': 'assistant', 'content': response}, 'finish_reason': 'stop'}],
                    'usage': {'prompt_tokens': 10, 'completion_tokens': 5, 'total_tokens': 15}}).encode())
    return ModelHandler


def proxy_handler(state):
    class ProxyHandler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *arguments):
            pass

        def do_GET(self):
            self.forward()

        def do_POST(self):
            self.forward()

        def do_PATCH(self):
            self.forward()

        def do_DELETE(self):
            self.forward()

        def forward(self):
            if self.path == '/__test__/state':
                result = json.dumps({'prompt_posts': state.prompt_posts, 'dropped_acks': state.dropped_acks,
                                     'model_requests': state.model_requests, 'changed_file': state.changed_file}).encode()
                self.send_response(200)
                self.send_header('content-type', 'application/json')
                self.send_header('content-length', str(len(result)))
                self.end_headers()
                self.wfile.write(result)
                return
            length = int(self.headers.get('content-length', '0'))
            if length > 8 * 1024 * 1024:
                self.send_error(413)
                return
            content = self.rfile.read(length)
            drop_ack = False
            if self.command == 'POST' and self.path.split('?')[0].endswith('/prompt'):
                state.prompt_posts += 1
                drop_ack = 'LOCAL_DROP_ACK' in content.decode(errors='replace') and state.dropped_acks == 0
            connection = http.client.HTTPConnection('127.0.0.1', state.backend_port, timeout=25)
            try:
                headers = {key: value for key, value in self.headers.items()
                           if key.lower() not in ('host', 'connection', 'transfer-encoding')}
                connection.request(self.command, self.path, body=content, headers=headers)
                response = connection.getresponse()
                result = response.read(8 * 1024 * 1024 + 1)
                if len(result) > 8 * 1024 * 1024:
                    self.send_error(502)
                    return
                if drop_ack and response.status == 200:
                    state.dropped_acks += 1
                    self.send_response(503)
                    self.send_header('content-length', '0')
                    self.end_headers()
                    return
                self.send_response(response.status)
                for key, value in response.getheaders():
                    if key.lower() not in ('transfer-encoding', 'connection', 'content-length'):
                        self.send_header(key, value)
                self.send_header('content-length', str(len(result)))
                self.end_headers()
                self.wfile.write(result)
            except (OSError, http.client.HTTPException):
                self.send_error(502)
            finally:
                connection.close()
    return ProxyHandler


def serve(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return thread


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', help='Explicit Flutter simulator device ID')
    parser.add_argument('--preflight-only', action='store_true', help='Verify local backend/provider without launching Flutter')
    arguments = parser.parse_args()
    binary = shutil.which('opencode')
    if not binary:
        raise SystemExit('OpenCode v2 is required')
    with tempfile.TemporaryDirectory(prefix='remote-code-local-e2e-') as temporary:
        base = pathlib.Path(temporary).resolve()
        project = base / 'project'
        (project / 'src').mkdir(parents=True)
        (project / 'src/fixture.txt').write_text('old fixture line\n')
        (project / 'binary.bin').write_bytes(b'\x00\xff')
        outside = base / 'outside'
        outside.mkdir()
        (outside / 'private.txt').write_text('outside fixture')
        (project / 'escape').symlink_to(outside, target_is_directory=True)
        for command in (['git', 'init', '-q', str(project)],
                        ['git', '-C', str(project), 'add', 'src/fixture.txt'],
                        ['git', '-C', str(project), '-c', 'user.name=Local fixture', '-c', 'user.email=fixture@example.invalid',
                         'commit', '-qm', 'Initial local fixture']):
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           env={'PATH': os.environ['PATH'], 'HOME': str(base), 'GIT_CONFIG_NOSYSTEM': '1'})
        state = State(project)
        model = http.server.ThreadingHTTPServer(('127.0.0.1', 0), model_handler(state))
        model.daemon_threads = True
        serve(model)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            state.backend_port = listener.getsockname()[1]
        configuration = base / 'config/opencode/opencode.json'
        configuration.parent.mkdir(parents=True)
        configuration.write_text(json.dumps({
            'snapshots': True,
            'permissions': [{'action': 'edit', 'resource': str(project / 'src/fixture.txt'), 'effect': 'allow'}],
            'plugins': [{'package': str(ROOT / 'host/file-browser'), 'options': {'roots': [str(project)]}}],
            'model': 'local-fixture/fixture',
            'providers': {'local-fixture': {'name': 'Local fixture', 'env': ['LOCAL_FIXTURE_KEY'],
                'package': '@opencode/ai/providers/openai-compatible',
                'settings': {'baseURL': f'http://127.0.0.1:{model.server_port}/v1'},
                'models': {'fixture': {'name': 'Local fixture',
                    'capabilities': {'tools': True, 'input': ['text', 'image', 'pdf'], 'output': ['text']},
                    'limit': {'context': 32000, 'output': 2048}}}}},
            'policies': [{'action': 'provider.use', 'resource': '*', 'effect': 'deny'},
                         {'action': 'provider.use', 'resource': 'local-fixture', 'effect': 'allow'}],
        }))
        certificate = base / 'certificate.pem'
        private_key = base / 'private-key.pem'
        root_certificate = base / 'root.pem'
        root_key = base / 'root-key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-nodes', '-newkey', 'rsa:2048', '-days', '1',
                        '-keyout', str(root_key), '-out', str(root_certificate), '-subj', '/CN=Local Test Root',
                        '-addext', 'basicConstraints=critical,CA:TRUE',
                        '-addext', 'keyUsage=critical,keyCertSign,cRLSign'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        request_file = base / 'server.csr'
        extensions = base / 'server.ext'
        extensions.write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1,DNS:localhost\n')
        subprocess.run(['openssl', 'req', '-new', '-nodes', '-newkey', 'rsa:2048',
                        '-keyout', str(private_key), '-out', str(request_file), '-subj', '/CN=localhost'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['openssl', 'x509', '-req', '-in', str(request_file), '-CA', str(root_certificate),
                        '-CAkey', str(root_key), '-CAcreateserial', '-out', str(certificate),
                        '-days', '1', '-extfile', str(extensions)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        private_key.chmod(0o600)
        proxy = http.server.ThreadingHTTPServer(('127.0.0.1', 0), proxy_handler(state))
        proxy.daemon_threads = True
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(certificate, private_key)
        proxy.socket = tls.wrap_socket(proxy.socket, server_side=True)
        serve(proxy)
        environment = {'PATH': os.environ['PATH'], 'HOME': str(base),
            'XDG_CONFIG_HOME': str(base / 'config'), 'XDG_DATA_HOME': str(base / 'data'),
            'XDG_CACHE_HOME': str(base / 'cache'), 'OPENCODE_SERVER_USERNAME': 'opencode',
            'OPENCODE_SERVER_PASSWORD': TEST_PASSWORD, 'LOCAL_FIXTURE_KEY': 'synthetic-provider-key'}
        process = None
        try:
            with (base / 'server.log').open('wb') as log:
                process = subprocess.Popen([binary, 'serve', '--hostname', '127.0.0.1', '--port', str(state.backend_port), '--print-logs'],
                    cwd=project, env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                context = ssl.create_default_context(cafile=str(root_certificate))
                url = f'https://127.0.0.1:{proxy.server_port}'
                authorization = 'Basic ' + base64.b64encode(f'opencode:{TEST_PASSWORD}'.encode()).decode()
                deadline = time.monotonic() + 25
                ready = False
                while time.monotonic() < deadline:
                    try:
                        request = urllib.request.Request(url + '/api/info', headers={'authorization': authorization})
                        with urllib.request.urlopen(request, context=context, timeout=2) as response:
                            ready = json.load(response)['version'].startswith('2.')
                        if ready:
                            break
                    except (OSError, ValueError, KeyError) as exception:
                        if isinstance(exception, urllib.error.HTTPError):
                            exception.close()
                    if process.poll() is not None:
                        break
                    time.sleep(.2)
                if not ready:
                    raise SystemExit('Isolated OpenCode did not become ready')
                definitions = base / 'flutter-test.json'
                definitions.write_text(json.dumps({'LOCAL_E2E_URL': url,
                    'LOCAL_E2E_PROJECT': str(project), 'LOCAL_E2E_OUTSIDE': str(outside),
                    'LOCAL_E2E_CA': base64.b64encode(root_certificate.read_bytes()).decode()}))
                definitions.chmod(0o600)
                if arguments.preflight_only:
                    request = urllib.request.Request(url + '/api/model', headers={'authorization': authorization})
                    with urllib.request.urlopen(request, context=context, timeout=10) as response:
                        models = json.load(response)['data']
                    found = any(item.get('providerID') == 'local-fixture' and item.get('modelID') == 'fixture' for item in models)
                    print(json.dumps({'real_https_ready': True, 'local_model_available': found}))
                    if not found:
                        raise SystemExit('Local fixture model is not available')
                else:
                    command = ['flutter', 'drive', '--no-pub', '--driver=test_driver/integration_test.dart',
                        '--target=integration_test/local_real_server_test.dart', '--dart-define-from-file=' + str(definitions)]
                    if arguments.device:
                        command.extend(['-d', arguments.device])
                    result = subprocess.run(command, cwd=ROOT, timeout=360)
                    if result.returncode:
                        for line in (base / 'server.log').read_text(errors='replace').splitlines()[-30:]:
                            if 'ERROR' in line or 'WARN' in line:
                                print(line[:2000])
                        raise SystemExit(result.returncode)
                    print(json.dumps({'real_open_code_tls_validation': 'passed', 'prompt_posts': state.prompt_posts,
                        'dropped_acks': state.dropped_acks, 'local_model_requests': state.model_requests}))
        finally:
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            proxy.shutdown()
            proxy.server_close()
            model.shutdown()
            model.server_close()


if __name__ == '__main__':
    main()
