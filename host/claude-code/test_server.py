"""Real HTTP/SQLite integration tests with only the paid agent boundary replaced."""
import asyncio
import pathlib
import tempfile
import unittest
import uuid

from aiohttp import ClientSession, encode_basic_auth, web

from server import Config, make_app
from storage import Storage

PASSWORD = 'synthetic-adapter-password-for-local-tests'


class FixtureClaude:
    def __init__(self, directory, outside):
        self.directory = str(directory)
        self.external_id = str(uuid.uuid4())
        self.outside_id = str(uuid.uuid4())
        self.rows = [
            {'id': self.external_id, 'title': 'Previous terminal session',
             'directory': self.directory, 'updated': 1, 'external': True},
            {'id': self.outside_id, 'title': 'Private unrelated session',
             'directory': str(outside), 'updated': 2, 'external': True},
        ]
        self.calls = 0
        self.forks = 0
        self.decisions = []

    def catalog(self):
        return self.rows

    def info(self, identifier):
        return next((row for row in self.rows if row['id'] == identifier), None)

    def history(self, identifier, directory):
        return [{'id': 'historic-user', 'role': 'user',
                 'parts': [{'type': 'text', 'text': 'Keep my history'}]}]

    def fork(self, identifier, directory):
        self.forks += 1
        return str(uuid.uuid4())

    async def interrupt(self):
        return None

    async def run(self, session, text, model, approve, emit, connected):
        self.calls += 1
        connected(self)
        if text == 'slow':
            await asyncio.Event().wait()
        if text == 'failure':
            raise RuntimeError('Synthetic secret which must not reach the client')
        if text == 'permission':
            decision = await approve('Bash', {'command': 'echo example'}, None)
            self.decisions.append(decision)
        if text == 'question':
            decision = await approve('AskUserQuestion', {'questions': [
                {'question': 'Which color?', 'multiSelect': False,
                 'options': [{'label': 'Mint', 'description': 'Brand color'}]}]}, None)
            self.decisions.append(decision)
        emit({'message': {'id': str(uuid.uuid4()), 'role': 'assistant',
                          'parts': [{'type': 'text', 'text': 'Local response'}]}})


class RelayHTTPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='coderelay-tests-')
        root = pathlib.Path(self.temporary.name).resolve()
        self.project = root / 'project'
        self.project.mkdir()
        self.outside = root / 'outside'
        self.outside.mkdir()
        self.state_directory = root / 'state'
        self.engine = FixtureClaude(self.project, self.outside)
        self.config = Config((self.project,), self.state_directory, PASSWORD,
                             max_active=1, approval_timeout=0.5)
        await self.start()

    async def start(self):
        self.app = make_app(self.config, self.engine)
        self.runner = web.AppRunner(self.app, access_log=None)
        await self.runner.setup()
        site = web.TCPSite(self.runner, '127.0.0.1', 0)
        await site.start()
        port = site._server.sockets[0].getsockname()[1]
        self.client = ClientSession(base_url=f'http://127.0.0.1:{port}',
                                    headers={'Authorization': encode_basic_auth('coderelay', PASSWORD)})

    async def asyncTearDown(self):
        await self.client.close()
        await self.runner.cleanup()
        self.temporary.cleanup()

    async def call(self, method, path, expected=200, **arguments):
        async with self.client.request(method, '/relay/v1' + path, **arguments) as response:
            value = await response.json()
            self.assertEqual(response.status, expected, value)
            self.assertEqual(response.headers['Cache-Control'], 'no-store')
            return value

    async def create(self):
        return await self.call('POST', '/sessions', 201,
                               json={'title': 'Managed', 'directory': str(self.project)})

    async def send(self, session, text='hello', expected=202, identifier=None):
        identifier = identifier or str(uuid.uuid4())
        await self.call('POST', f"/sessions/{session['id']}/prompts", expected,
                        json={'id': identifier, 'text': text})
        return identifier

    async def wait_for(self, predicate):
        async with asyncio.timeout(5):
            while not await predicate():
                await asyncio.sleep(0.01)

    async def idle(self):
        return not (await self.call('GET', '/active'))['data']

    async def test_should_authenticate_every_route_and_reject_browser_requests(self):
        result = await self.call('GET', '/info')
        self.assertEqual(result['agent'], 'claude_code')
        self.assertEqual(result['protocol_version'], 1)
        async with self.client.get('/relay/v1/info', headers={'Authorization': encode_basic_auth('coderelay', 'wrong')}) as response:
            self.assertEqual(response.status, 401)
        await self.call('GET', '/info', 403, headers={'Origin': 'https://untrusted.example'})
        await self.call('GET', '/unavailable', 404)
        await self.call('POST', '/sessions', 400, data='not-json')

    async def test_should_filter_external_sessions_and_deny_unauthorized_roots_and_symlinks(self):
        catalog = await self.call('GET', '/sessions')
        self.assertEqual([row['id'] for row in catalog['data']], [self.engine.external_id])
        await self.call('GET', '/sessions/' + self.engine.outside_id, 404)
        for directory in (str(self.outside), str(self.project / '..' / 'outside')):
            await self.call('POST', '/sessions', 403, json={'title': 'Denied', 'directory': directory})
        alias = self.project / 'alias'
        alias.symlink_to(self.outside, target_is_directory=True)
        await self.call('POST', '/sessions', 403,
                        json={'title': 'Denied', 'directory': str(alias)})

    async def test_should_preserve_original_history_and_require_explicit_fork(self):
        external = await self.call('GET', '/sessions/' + self.engine.external_id)
        original = await self.call('GET', f"/sessions/{external['id']}/messages")
        await self.send(external, expected=412)
        await self.call('POST', f"/sessions/{external['id']}/fork", 422, json={})
        fork = await self.call('POST', f"/sessions/{external['id']}/fork", 201,
                               json={'confirm_shared_files': True})
        self.assertFalse(fork['external'])
        self.assertNotEqual(fork['id'], external['id'])
        self.assertEqual(fork['directory'], external['directory'])
        imported = await self.call('GET', f"/sessions/{fork['id']}/messages")
        self.assertEqual(imported, original)
        self.assertEqual(self.engine.calls, 0)
        self.assertEqual(self.engine.forks, 1)

    async def test_should_reconcile_a_receipt_without_replaying_and_reject_payload_conflicts(self):
        session = await self.create()
        receipt_id = await self.send(session, identifier='msg_rc_synthetic_123')
        await self.wait_for(self.idle)
        await self.send(session, expected=200, identifier=receipt_id)
        await self.send(session, text='different', expected=409, identifier=receipt_id)
        receipt = await self.call('GET', f"/sessions/{session['id']}/receipts/{receipt_id}")
        self.assertEqual(receipt['state'], 'completed')
        self.assertEqual(self.engine.calls, 1)
        messages = await self.call('GET', f"/sessions/{session['id']}/messages?limit=1")
        self.assertEqual(messages['data'][0]['role'], 'assistant')
        older = await self.call('GET', f"/sessions/{session['id']}/messages?cursor={messages['next_cursor']}")
        self.assertEqual(older['data'][0]['id'], receipt_id)

    async def test_should_bound_active_work_interrupt_and_release_capacity(self):
        session = await self.create()
        other = await self.create()
        receipt_id = await self.send(session, text='slow')
        await self.send(session, expected=409)
        await self.send(other, expected=429)
        await self.call('POST', f"/sessions/{session['id']}/interrupt")
        await self.wait_for(self.idle)
        receipt = await self.call('GET', f"/sessions/{session['id']}/receipts/{receipt_id}")
        self.assertEqual(receipt['state'], 'interrupted')
        await self.send(other)

    async def test_should_prompt_for_one_time_permission_and_reject_persistent_or_duplicate_replies(self):
        session = await self.create()
        await self.send(session, text='permission')
        async def has_request():
            return bool((await self.call('GET', '/requests'))['data'])
        await self.wait_for(has_request)
        permission = (await self.call('GET', '/requests'))['data'][0]
        self.assertFalse(permission['persistent'])
        path = f"/sessions/{session['id']}/requests/{permission['id']}/reply"
        await self.call('POST', path, 422, json={'reply': 'always'})
        await self.call('POST', path, json={'reply': 'once'})
        await self.call('POST', path, 409, json={'reply': 'once'})
        await self.wait_for(self.idle)
        self.assertEqual(self.engine.decisions[0].behavior, 'allow')

    async def test_should_deny_unanswered_permissions_after_the_deadline(self):
        session = await self.create()
        await self.send(session, text='permission')
        await self.wait_for(self.idle)
        self.assertEqual(self.engine.decisions[0].behavior, 'deny')
        self.assertEqual((await self.call('GET', '/requests'))['data'], [])

    async def test_should_translate_questions_and_answers_without_granting_other_tools(self):
        session = await self.create()
        await self.send(session, text='question')
        async def has_question():
            return bool((await self.call('GET', '/requests?kind=question'))['data'])
        await self.wait_for(has_question)
        question = (await self.call('GET', '/requests?kind=question'))['data'][0]
        self.assertEqual(question['fields'][0]['title'], 'Which color?')
        path = f"/sessions/{session['id']}/requests/{question['id']}/reply"
        await self.call('POST', path, json={'answers': {'0': 'Mint'}})
        await self.wait_for(self.idle)
        self.assertEqual(self.engine.decisions[0].updated_input['answers'], {'Which color?': 'Mint'})

    async def test_should_preserve_receipts_across_shutdown_without_replay(self):
        session = await self.create()
        receipt_id = await self.send(session, text='slow')
        await self.client.close()
        await self.runner.cleanup()
        await self.start()
        receipt = await self.call('GET', f"/sessions/{session['id']}/receipts/{receipt_id}")
        self.assertEqual(receipt['state'], 'interrupted')
        await self.send(session, text='slow', expected=200, identifier=receipt_id)
        self.assertLessEqual(self.engine.calls, 1)
        self.assertTrue(await self.idle())

    async def test_should_hide_provider_error_text_and_release_capacity(self):
        session = await self.create()
        receipt_id = await self.send(session, text='failure')
        await self.wait_for(self.idle)
        messages = await self.call('GET', f"/sessions/{session['id']}/messages")
        self.assertNotIn('Synthetic secret', str(messages))
        receipt = await self.call('GET', f"/sessions/{session['id']}/receipts/{receipt_id}")
        self.assertEqual(receipt['state'], 'failed')
        await self.send(session)

    async def test_should_validate_pagination_and_bound_request_size(self):
        await self.call('GET', '/sessions?cursor=bad', 422)
        await self.call('GET', '/sessions?limit=1000', 422)
        await self.call('POST', '/sessions', 413, json={'padding': 'x' * 140000})
        session = await self.create()
        await self.call('POST', f"/sessions/{session['id']}/prompts", 422,
                        json={'id': 'valid_id', 'text': 'x' * 65537})
        await self.call('POST', f"/sessions/{session['id']}/prompts", 422,
                        json={'id': 'valid_id', 'text': 'hello', 'permission_mode': 'bypassPermissions'})


class PersistenceTests(unittest.TestCase):
    def test_should_mark_unclean_receipts_interrupted_without_running_any_agent(self):
        with tempfile.TemporaryDirectory() as folder:
            state = pathlib.Path(folder) / 'state'
            storage = Storage(state)
            with self.assertRaises(ValueError):
                Storage(state)
            session = storage.create('Test', folder)
            storage.admit(session, 'receipt', 'fingerprint', 'hello')
            storage.close()
            restored = Storage(state)
            self.assertEqual(restored.receipt('receipt')['state'], 'interrupted')
            restored.close()
            self.assertEqual((state / 'relay.sqlite3').stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main(verbosity=2)
