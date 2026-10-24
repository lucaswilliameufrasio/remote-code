"""Run the bundled real Claude CLI/SDK against a loopback-only Anthropic fixture."""
import asyncio
import json
import os
import pathlib
import tempfile
import unittest
from unittest.mock import patch

from aiohttp import ClientSession, encode_basic_auth, web

from sdk_adapter import OfficialClaude
from server import Config, make_app


class LocalOfficialClaude(OfficialClaude):
    def __init__(self, environment):
        self.environment = environment

    def options(self, session, model, approve):
        options = super().options(session, model, approve)
        options.env.update(self.environment)
        options.max_turns = 3
        return options


class OfficialRuntimeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='coderelay-sdk-runtime-')
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.project = self.root / 'project'
        self.project.mkdir()
        self.calls = 0
        self.permission_calls = 0

        async def model(request):
            self.calls += 1
            values = await request.json()
            serialized = json.dumps(values.get('messages', []))
            tool = None
            if 'REQUEST_PERMISSION_FIXTURE' in serialized and 'tool_result' not in serialized:
                tool = {'name': 'Bash', 'input': {'command': 'printf coderelay-fixture > approval-fixture.txt'}}
                self.permission_calls += 1
            if 'REQUEST_QUESTION_FIXTURE' in serialized and 'tool_result' not in serialized:
                tool = {'name': 'AskUserQuestion', 'input': {'questions': [{
                    'question': 'Choose a local fixture color', 'header': 'Color',
                    'multiSelect': False, 'options': [
                        {'label': 'Mint', 'description': 'Brand color'},
                        {'label': 'Blue', 'description': 'Alternative'},
                    ]}]}}
            content = ({'type': 'tool_use', 'id': 'tool_fixture', 'name': tool['name'], 'input': {}}
                       if tool else {'type': 'text', 'text': ''})
            delta = ({'type': 'input_json_delta', 'partial_json': json.dumps(tool['input'])}
                     if tool else {'type': 'text_delta', 'text': 'CLAUDE_LOCAL_RESPONSE_OK'})
            response = web.StreamResponse(headers={'Content-Type': 'text/event-stream'})
            await response.prepare(request)
            events = [
                ('message_start', {'type': 'message_start', 'message': {
                    'id': 'msg_local_fixture', 'type': 'message', 'role': 'assistant',
                    'content': [], 'model': values.get('model', 'fixture'),
                    'usage': {'input_tokens': 10, 'output_tokens': 0}}}),
                ('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': content}),
                ('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': delta}),
                ('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
                ('message_delta', {'type': 'message_delta', 'delta': {
                    'stop_reason': 'tool_use' if tool else 'end_turn', 'stop_sequence': None},
                    'usage': {'output_tokens': 5}}),
                ('message_stop', {'type': 'message_stop'}),
            ]
            for event, data in events:
                await response.write(f'event: {event}\ndata: {json.dumps(data)}\n\n'.encode())
            await response.write_eof()
            return response

        fixture = web.Application()
        fixture.router.add_post('/v1/messages', model)
        async def tokens(request):
            return web.json_response({'input_tokens': 10})
        fixture.router.add_post('/v1/messages/count_tokens', tokens)
        self.fixture_runner = web.AppRunner(fixture, access_log=None)
        await self.fixture_runner.setup()
        site = web.TCPSite(self.fixture_runner, '127.0.0.1', 0)
        await site.start()
        port = site._server.sockets[0].getsockname()[1]
        environment = {
            'PATH': os.defpath, 'HOME': str(self.root),
            'CLAUDE_CONFIG_DIR': str(self.root / 'claude-config'),
            'ANTHROPIC_API_KEY': 'synthetic-loopback-fixture-key',
            'ANTHROPIC_BASE_URL': f'http://127.0.0.1:{port}',
            'DISABLE_NONESSENTIAL_TRAFFIC': '1', 'NO_PROXY': '127.0.0.1,localhost',
            'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
            'CLAUDE_CODE_MAX_RETRIES': '0',
        }
        self.environment = patch.dict(os.environ, environment, clear=True)
        self.environment.start()
        self.engine = LocalOfficialClaude(environment)
        password = 'synthetic-loopback-adapter-password'
        app = make_app(Config((self.project,), self.root / 'state', password,
                              turn_timeout=60, approval_timeout=20), self.engine)
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        site = web.TCPSite(self.runner, '127.0.0.1', 0)
        await site.start()
        adapter_port = site._server.sockets[0].getsockname()[1]
        self.client = ClientSession(base_url=f'http://127.0.0.1:{adapter_port}',
                                    headers={'Authorization': encode_basic_auth('coderelay', password)})

    async def asyncTearDown(self):
        await self.client.close()
        await self.runner.cleanup()
        await self.fixture_runner.cleanup()
        self.environment.stop()
        self.temporary.cleanup()

    async def call(self, method, path, expected=200, **arguments):
        async with self.client.request(method, '/relay/v1' + path, **arguments) as response:
            value = await response.json()
            self.assertEqual(response.status, expected, value)
            return value

    async def wait_idle(self):
        async with asyncio.timeout(75):
            while (await self.call('GET', '/active'))['data']:
                await asyncio.sleep(0.1)

    async def test_should_execute_resume_discover_and_fork_with_the_real_sdk_without_paid_requests(self):
        session = await self.call('POST', '/sessions', 201,
                                  json={'directory': str(self.project), 'title': 'Local SDK session'})
        for index in range(2):
            await self.call('POST', f"/sessions/{session['id']}/prompts", 202,
                            json={'id': f'msg_fixture_{index}', 'text': 'Respond locally'})
            await self.wait_idle()
            receipt = await self.call('GET', f"/sessions/{session['id']}/receipts/msg_fixture_{index}")
            self.assertEqual(receipt['state'], 'completed')
        history = await self.call('GET', f"/sessions/{session['id']}/messages")
        self.assertIn('CLAUDE_LOCAL_RESPONSE_OK', str(history))
        self.assertEqual(self.calls, 2)
        native = self.engine.catalog()
        self.assertEqual(len(native), 1)
        self.assertGreater(len(self.engine.history(native[0]['id'], str(self.project))), 0)
        external_id = self.engine.fork(native[0]['id'], str(self.project))
        forked = await self.call('POST', f"/sessions/{external_id}/fork", 201,
                                 json={'confirm_shared_files': True})
        self.assertFalse(forked['external'])
        self.assertEqual(len(self.engine.catalog()), 3)
        self.assertEqual(self.calls, 2, 'Forking must not make a model request')

    async def test_should_route_a_real_sdk_permission_callback_to_mobile_and_deny_it(self):
        session = await self.call('POST', '/sessions', 201,
                                  json={'directory': str(self.project), 'title': 'Approval SDK session'})
        await self.call('POST', f"/sessions/{session['id']}/prompts", 202,
                        json={'id': 'msg_permission', 'text': 'REQUEST_PERMISSION_FIXTURE'})
        async with asyncio.timeout(60):
            pending = []
            while not pending:
                pending = (await self.call('GET', '/requests'))['data']
                if not (await self.call('GET', '/active'))['data']:
                    self.fail('Real CLI ended before requesting permission')
                await asyncio.sleep(0.1)
        self.assertEqual(pending[0]['permission'], 'Bash')
        await self.call('POST', f"/sessions/{session['id']}/requests/{pending[0]['id']}/reply",
                        json={'reply': 'reject'})
        await self.wait_idle()
        receipt = await self.call('GET', f"/sessions/{session['id']}/receipts/msg_permission")
        self.assertEqual(receipt['state'], 'completed')
        self.assertEqual(self.permission_calls, 1)
        self.assertFalse((self.project / 'approval-fixture.txt').exists())

    async def test_should_answer_a_real_sdk_question_without_granting_tool_permissions(self):
        session = await self.call('POST', '/sessions', 201,
                                  json={'directory': str(self.project), 'title': 'Question SDK session'})
        await self.call('POST', f"/sessions/{session['id']}/prompts", 202,
                        json={'id': 'msg_question', 'text': 'REQUEST_QUESTION_FIXTURE'})
        async with asyncio.timeout(60):
            pending = []
            while not pending:
                pending = (await self.call('GET', '/requests?kind=question'))['data']
                if not (await self.call('GET', '/active'))['data']:
                    self.fail('Real CLI ended before requesting an answer')
                await asyncio.sleep(0.1)
        self.assertEqual(pending[0]['fields'][0]['title'], 'Choose a local fixture color')
        await self.call('POST', f"/sessions/{session['id']}/requests/{pending[0]['id']}/reply",
                        json={'answers': {'0': 'Mint'}})
        await self.wait_idle()
        receipt = await self.call('GET', f"/sessions/{session['id']}/receipts/msg_question")
        self.assertEqual(receipt['state'], 'completed')
        self.assertEqual(self.calls, 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
