#!/usr/bin/env python3
"""Loopback-only Claude Code adapter for the CodeRelay mobile client."""
import argparse
import asyncio
import base64
import binascii
import dataclasses
import hashlib
import hmac
import json
import os
import pathlib
import re
import sqlite3
import uuid

from aiohttp import web
from claude_agent_sdk import PermissionResultAllow, PermissionResultDeny

from sdk_adapter import OfficialClaude
from storage import Storage

MODELS = ('sonnet', 'opus', 'haiku')


class RelayError(Exception):
    def __init__(self, status, code, message):
        self.status, self.code, self.message = status, code, message


def invalid(field):
    error = RelayError(422, 'INVALID_PARAMS', 'Parâmetros inválidos.')
    error.field = field
    raise error


def identifier(value):
    try:
        if str(uuid.UUID(value)) != value:
            invalid('id')
    except (ValueError, TypeError, AttributeError):
        invalid('id')
    return value


def text_field(body, key, maximum):
    value = body.get(key)
    if not isinstance(value, str) or not value.strip() or len(value.encode()) > maximum:
        invalid(key)
    return value


def prompt_identifier(value):
    if not isinstance(value, str) or re.fullmatch(r'[A-Za-z0-9_-]{1,128}', value) is None:
        invalid('id')
    return value


def public_session(session):
    return {key: session[key] for key in ('id', 'title', 'directory', 'updated')} | {
        'external': session.get('external', False)}


@dataclasses.dataclass(frozen=True)
class Config:
    roots: tuple[pathlib.Path, ...]
    state_directory: pathlib.Path
    password: str = dataclasses.field(repr=False)
    username: str = 'coderelay'
    max_active: int = 2
    turn_timeout: float = 900
    approval_timeout: float = 180

    def __post_init__(self):
        if len(self.password) < 24 or not self.username or ':' in self.username:
            raise ValueError('A dedicated password of at least 24 characters is required')
        if not self.roots or len(self.roots) > 16 or not 1 <= self.max_active <= 4:
            raise ValueError('Configure 1–16 trusted roots and 1–4 active turns')
        for root in self.roots:
            if not root.is_absolute() or not root.is_dir() or root.is_symlink() or root == pathlib.Path('/'):
                raise ValueError('Trusted roots must be existing absolute non-symlink project directories')


class Relay:
    def __init__(self, config, engine=None):
        self.config = config
        self.engine = engine or OfficialClaude()
        self.storage = Storage(config.state_directory)
        self.tasks = {}
        self.clients = {}
        self.requests = {}
        self.draining = False
        self.http_active = 0

    def directory(self, value):
        if not isinstance(value, str) or not value.startswith('/'):
            invalid('directory')
        path = pathlib.Path(value)
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError):
            raise RelayError(403, 'DIRECTORY_DENIED', 'Diretório não autorizado.') from None
        # Reject symlink components instead of silently following an alias.
        if resolved != path or not resolved.is_dir() or not any(
                resolved.is_relative_to(root) for root in self.config.roots):
            raise RelayError(403, 'DIRECTORY_DENIED', 'Diretório não autorizado.')
        return str(resolved)

    def allowed(self, directory):
        try:
            self.directory(directory)
            return True
        except RelayError:
            return False

    def session(self, value):
        identifier(value)
        session = self.storage.session(value) or self.engine.info(value)
        if session is None or not self.allowed(session['directory']):
            raise RelayError(404, 'SESSION_NOT_FOUND', 'Sessão não encontrada nas raízes autorizadas.')
        return session

    def history(self, session):
        if session.get('external'):
            return self.engine.history(session['id'], session['directory'])
        return None

    async def approve(self, session_id, tool, input_data, context):
        if self.draining or len(self.requests) >= 32 or len(json.dumps(input_data).encode()) > 32768:
            return PermissionResultDeny(message='Adapter unavailable or approval input too large')
        request_id = str(uuid.uuid4())
        future = asyncio.get_running_loop().create_future()
        request = {'id': request_id, 'session_id': session_id, 'tool': tool,
                   'input': input_data, 'future': future}
        self.requests[request_id] = request
        try:
            result = await asyncio.wait_for(future, self.config.approval_timeout)
            if tool == 'AskUserQuestion':
                if not isinstance(result, dict):
                    return PermissionResultDeny(message='Question was not answered')
                return PermissionResultAllow(updated_input={**input_data, 'answers': result})
            if result == 'once':
                return PermissionResultAllow(updated_input=input_data)
            return PermissionResultDeny(message='Denied from CodeRelay')
        except TimeoutError:
            return PermissionResultDeny(message='Approval expired')
        finally:
            self.requests.pop(request_id, None)

    def pending(self, session_id=None, directory=None, kind='permission'):
        result = []
        for request in self.requests.values():
            if request['future'].done():
                continue
            if session_id and request['session_id'] != session_id:
                continue
            session = self.session(request['session_id'])
            if directory and session['directory'] != directory:
                continue
            is_question = request['tool'] == 'AskUserQuestion'
            if (kind == 'question') != is_question:
                continue
            item = {'id': request['id'], 'session_id': session['id']}
            if is_question:
                fields = []
                questions = request['input'].get('questions', [])
                if not isinstance(questions, list) or not 1 <= len(questions) <= 10:
                    continue
                for index, question in enumerate(questions):
                    if not isinstance(question, dict) or not isinstance(question.get('question'), str):
                        continue
                    options = question.get('options', [])
                    fields.append({'key': str(index), 'title': question['question'], 'required': True,
                                   'type': 'multiselect' if question.get('multiSelect') else 'string',
                                   'options': [{'value': option['label'], 'label': option['label'],
                                                'description': str(option.get('description', ''))}
                                               for option in options[:20]
                                               if isinstance(option, dict) and isinstance(option.get('label'), str)]})
                item.update({'title': 'Claude Code precisa de uma resposta', 'fields': fields})
            else:
                item.update({'permission': request['tool'],
                             'patterns': [json.dumps(request['input'], ensure_ascii=False)],
                             'metadata': request['input'], 'persistent': False})
            result.append(item)
        return result

    def emit(self, session_id, event):
        native_id = event.get('native_id')
        if native_id:
            self.storage.set_native(session_id, identifier(native_id))
        if 'message' in event:
            if self.storage.message_count(session_id) >= 5000:
                raise ValueError('Session message capacity reached')
            self.storage.append(session_id, event['message'])

    async def execute(self, session, receipt_id, text, model):
        self.storage.state(receipt_id, 'running')
        try:
            async with asyncio.timeout(self.config.turn_timeout):
                await self.engine.run(
                    session, text, model,
                    lambda tool, values, context: self.approve(session['id'], tool, values, context),
                    lambda event: self.emit(session['id'], event),
                    lambda client: self.clients.update({session['id']: client}))
            self.storage.state(receipt_id, 'completed')
        except asyncio.CancelledError:
            self.storage.state(receipt_id, 'interrupted')
            self.storage.append(session['id'], {
                'id': 'interrupted_' + receipt_id, 'role': 'assistant',
                'parts': [{'type': 'text', 'text':
                           'Turno interrompido. Alterações já feitas no projeto podem permanecer; o prompt não foi repetido.'}],
            })
            raise
        except Exception:
            # Never expose SDK/provider exception text, prompts or credential values.
            self.storage.state(receipt_id, 'failed')
            self.storage.append(session['id'], {
                'id': str(uuid.uuid4()), 'role': 'assistant',
                'parts': [{'type': 'text', 'text':
                           'Claude Code não concluiu o turno. Confira autenticação e limites no host; o prompt não foi repetido.'}],
            })
        finally:
            for request in list(self.requests.values()):
                if request['session_id'] == session['id'] and not request['future'].done():
                    request['future'].set_result('reject')
            self.clients.pop(session['id'], None)
            self.tasks.pop(session['id'], None)

    async def interrupt(self, session_id):
        task = self.tasks.get(session_id)
        if task is None:
            return
        for request in list(self.requests.values()):
            if request['session_id'] == session_id and not request['future'].done():
                request['future'].set_result('reject')
        client = self.clients.get(session_id)
        if client is not None:
            try:
                await asyncio.wait_for(client.interrupt(), 3)
            except Exception:
                # A failed SDK interrupt is followed by cancellation/disconnect;
                # never claim the remote turn completed or repeat its prompt.
                self.storage.append(session_id, {
                    'id': str(uuid.uuid4()), 'role': 'assistant',
                    'parts': [{'type': 'text', 'text': 'Interrupção sem confirmação do SDK; encerrando a conexão.'}],
                })
        task.cancel()
        try:
            await asyncio.wait_for(task, 8)
        except (asyncio.CancelledError, TimeoutError):
            pass

    async def shutdown(self):
        self.draining = True
        await asyncio.gather(*(self.interrupt(identifier) for identifier in list(self.tasks)))


async def body(request):
    if request.content_type != 'application/json':
        raise RelayError(400, 'MALFORMED_REQUEST', 'Envie um objeto JSON.')
    try:
        value = await asyncio.wait_for(request.json(), 5)
    except TimeoutError:
        raise RelayError(408, 'BODY_TIMEOUT', 'Tempo de envio esgotado.') from None
    except (ValueError, UnicodeError):
        raise RelayError(400, 'MALFORMED_REQUEST', 'JSON inválido.') from None
    if not isinstance(value, dict):
        raise RelayError(400, 'MALFORMED_REQUEST', 'Envie um objeto JSON.')
    return value


def number(value, default, maximum):
    if value is None:
        return default
    try:
        parsed = int(value)
    except (ValueError, TypeError):
        invalid('pagination')
    if not 1 <= parsed <= maximum:
        invalid('pagination')
    return parsed


def error_response(error):
    payload = {'error_code': error.code, 'message': error.message}
    if error.status == 422:
        payload['extra'] = {'validation_errors': [
            {'field': getattr(error, 'field', 'request'), 'message': 'Valor inválido.'}]}
    return web.json_response(payload, status=error.status)


def make_app(config, engine=None):
    relay = Relay(config, engine)

    @web.middleware
    async def boundary(request, handler):
        reserved = False
        try:
            raw = request.headers.get('Authorization', '')
            expected = f'{config.username}:{config.password}'.encode()
            try:
                supplied = base64.b64decode(raw[6:], validate=True) if raw.startswith('Basic ') else b''
            except (binascii.Error, ValueError):
                supplied = b''
            if not hmac.compare_digest(hashlib.sha256(supplied).digest(), hashlib.sha256(expected).digest()):
                raise RelayError(401, 'UNAUTHORIZED', 'Autenticação necessária.')
            if request.headers.get('Origin') is not None:
                raise RelayError(403, 'BROWSER_DENIED', 'Este endpoint aceita apenas clientes nativos.')
            if relay.http_active >= 32:
                raise RelayError(429, 'REQUEST_LIMIT', 'Limite de requisições simultâneas atingido.')
            relay.http_active += 1
            reserved = True
            response = await handler(request)
        except RelayError as error:
            response = error_response(error)
        except web.HTTPRequestEntityTooLarge:
            response = error_response(RelayError(413, 'PAYLOAD_TOO_LARGE', 'Corpo muito grande.'))
        except web.HTTPException as error:
            response = error_response(RelayError(error.status, 'ROUTE_UNAVAILABLE', 'Operação indisponível.'))
        except (ValueError, sqlite3.Error):
            response = error_response(RelayError(503, 'CAPACITY_OR_STORAGE', 'Limite local ou armazenamento indisponível.'))
        except Exception:
            response = error_response(RelayError(500, 'UNEXPECTED_ERROR', 'Falha interna do adaptador.'))
        finally:
            if reserved:
                relay.http_active -= 1
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        return response

    app = web.Application(middlewares=[boundary], client_max_size=131072)
    app[web.AppKey('relay', Relay)] = relay

    async def info(request):
        return web.json_response({'agent': 'claude_code', 'protocol_version': 1,
                                  'healthy': not relay.draining, 'adapter_version': '1.0.0',
                                  'capabilities': ['sessions', 'text', 'questions', 'approval_once', 'interrupt', 'receipts']})

    async def projects(request):
        return web.json_response({'data': [{'id': str(index), 'directory': str(root)}
                                          for index, root in enumerate(config.roots)]})

    async def sessions(request):
        if request.method == 'POST':
            values = await body(request)
            directory = relay.directory(text_field(values, 'directory', 4096))
            title = text_field(values, 'title', 256)
            return web.json_response(public_session(relay.storage.create(title, directory)), status=201)
        limit = number(request.query.get('limit'), 30, 100)
        catalog = {item['id']: public_session(item) for item in relay.engine.catalog()
                   if relay.allowed(item['directory'])}
        for session in relay.storage.sessions():
            catalog.pop(session.get('native_id'), None)
            if relay.allowed(session['directory']):
                catalog[session['id']] = public_session(session)
        rows = list(catalog.values())
        directory = request.query.get('directory')
        if directory:
            directory = relay.directory(directory)
            rows = [item for item in rows if item['directory'] == directory]
        search = request.query.get('search', '').lower()
        if len(search) > 256:
            invalid('search')
        rows = [item for item in rows if search in item['title'].lower()]
        rows.sort(key=lambda item: (item['updated'], item['id']), reverse=True)
        cursor = request.query.get('cursor')
        if cursor:
            try:
                updated, last_id = cursor.split(':', 1)
                last_key = (int(updated), identifier(last_id))
            except (ValueError, TypeError):
                invalid('cursor')
            rows = [item for item in rows if (item['updated'], item['id']) < last_key]
        page = rows[:limit]
        result = {'data': page, 'has_more': len(rows) > limit,
                  'discovery_limit': 5000}
        if result['has_more']:
            result['next_cursor'] = f"{page[-1]['updated']}:{page[-1]['id']}"
        return web.json_response(result)

    async def session_info(request):
        return web.json_response(public_session(relay.session(request.match_info['session_id'])))

    async def fork(request):
        source = relay.session(request.match_info['session_id'])
        if not source.get('external'):
            raise RelayError(409, 'ALREADY_MANAGED', 'Esta sessão já pertence ao CodeRelay.')
        values = await body(request)
        if values != {'confirm_shared_files': True}:
            invalid('confirm_shared_files')
        history = relay.engine.history(source['id'], source['directory'])
        if not history:
            raise RelayError(412, 'EMPTY_HISTORY', 'Não há histórico para continuar.')
        # Validate bounded import before the SDK writes the fork.
        sizes = [len(json.dumps(item).encode()) for item in history]
        if len(history) > 5000 or max(sizes, default=0) > 1024 * 1024 or sum(sizes) > 8 * 1024 * 1024:
            raise RelayError(413, 'HISTORY_TOO_LARGE', 'Histórico muito grande para importar.')
        native_id = relay.engine.fork(source['id'], source['directory'])
        session = relay.storage.create(source['title'] + ' · CodeRelay', source['directory'], native_id, history)
        return web.json_response(public_session(session), status=201)

    async def messages(request):
        session = relay.session(request.match_info['session_id'])
        limit = number(request.query.get('limit'), 30, 100)
        cursor = request.query.get('cursor')
        before = number(cursor, None, 2**63 - 1) if cursor else None
        if session.get('external'):
            history = relay.history(session)
            end = min(before if before is not None else len(history), len(history))
            start = max(0, end - limit)
            selected, next_cursor = history[start:end], str(start) if start else None
        else:
            selected, next_cursor = relay.storage.messages(session['id'], limit, before)
        result = {'data': selected, 'has_more': next_cursor is not None}
        if next_cursor is not None:
            result['next_cursor'] = next_cursor
        return web.json_response(result)

    async def receipt(request):
        session = relay.session(request.match_info['session_id'])
        record = relay.storage.receipt(request.match_info['receipt_id'])
        if record is None or record['session_id'] != session['id']:
            raise RelayError(404, 'RECEIPT_NOT_FOUND', 'Recebimento não encontrado.')
        return web.json_response({'id': record['id'], 'state': record['state']})

    async def prompt(request):
        session = relay.session(request.match_info['session_id'])
        if session.get('external'):
            raise RelayError(412, 'FORK_REQUIRED', 'Crie uma continuação antes de enviar.')
        values = await body(request)
        if set(values) - {'id', 'text', 'model'}:
            invalid('request')
        receipt_id = prompt_identifier(values.get('id'))
        text = text_field(values, 'text', 65536)
        model = values.get('model')
        if model is not None and model not in MODELS:
            invalid('model')
        fingerprint = hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()
        existing = relay.storage.receipt(receipt_id)
        if existing:
            if existing['fingerprint'] != fingerprint or existing['session_id'] != session['id']:
                raise RelayError(409, 'RECEIPT_CONFLICT', 'Identificador já usado com outro conteúdo.')
            return web.json_response({'id': receipt_id, 'state': existing['state']})
        if relay.draining:
            raise RelayError(503, 'DRAINING', 'Adaptador encerrando; envio não aceito.')
        if session['id'] in relay.tasks:
            raise RelayError(409, 'SESSION_BUSY', 'Aguarde o turno atual; Claude não oferece fila neste adaptador.')
        if len(relay.tasks) >= config.max_active:
            raise RelayError(429, 'ACTIVE_LIMIT', 'Limite de execuções simultâneas atingido.')
        if relay.storage.message_count(session['id']) >= 4900:
            raise RelayError(409, 'HISTORY_LIMIT', 'Limite de histórico atingido.')
        relay.storage.admit(session, receipt_id, fingerprint, text)
        task = asyncio.create_task(relay.execute(session, receipt_id, text, model))
        relay.tasks[session['id']] = task
        def release(completed):
            if relay.tasks.get(session['id']) is completed:
                relay.tasks.pop(session['id'], None)
            record = relay.storage.receipt(receipt_id)
            if record and record['state'] in ('admitted', 'running'):
                relay.storage.state(receipt_id, 'interrupted')
                relay.storage.append(session['id'], {
                    'id': 'interrupted_' + receipt_id, 'role': 'assistant',
                    'parts': [{'type': 'text', 'text': 'Turno interrompido antes da conclusão; o prompt não foi repetido.'}],
                })
        task.add_done_callback(release)
        return web.json_response({'id': receipt_id, 'state': 'admitted'}, status=202)

    async def active(request):
        return web.json_response({'data': {key: 'running' for key in relay.tasks}})

    async def interrupt(request):
        session = relay.session(request.match_info['session_id'])
        await relay.interrupt(session['id'])
        return web.json_response({'interrupted': True})

    async def pending(request):
        session_id = request.match_info.get('session_id')
        if session_id:
            relay.session(session_id)
        directory = request.query.get('directory')
        if directory:
            directory = relay.directory(directory)
        kind = request.query.get('kind', 'permission')
        if kind not in ('permission', 'question'):
            invalid('kind')
        return web.json_response({'data': relay.pending(session_id, directory, kind)})

    async def reply(request):
        session = relay.session(request.match_info['session_id'])
        pending_request = relay.requests.get(request.match_info['request_id'])
        if pending_request is None or pending_request['session_id'] != session['id'] or pending_request['future'].done():
            raise RelayError(409, 'REQUEST_EXPIRED', 'Solicitação já respondida ou expirada.')
        values = await body(request)
        if pending_request['tool'] == 'AskUserQuestion':
            answers = values.get('answers')
            questions = pending_request['input'].get('questions', [])
            if not isinstance(answers, dict) or len(questions) > 10:
                invalid('answers')
            mapped = {}
            for index, question in enumerate(questions):
                answer = answers.get(str(index))
                if isinstance(answer, list) and all(isinstance(item, str) for item in answer):
                    answer = ', '.join(answer)
                if not isinstance(answer, str) or not answer.strip() or len(answer) > 4096:
                    invalid('answers')
                mapped[question['question']] = answer
            pending_request['future'].set_result(mapped)
        else:
            decision = values.get('reply')
            if decision not in ('once', 'reject'):
                invalid('reply')
            pending_request['future'].set_result(decision)
        return web.json_response({'answered': True})

    prefix = '/relay/v1'
    app.router.add_get(prefix + '/info', info)
    app.router.add_get(prefix + '/projects', projects)
    app.router.add_get(prefix + '/sessions', sessions)
    app.router.add_post(prefix + '/sessions', sessions)
    app.router.add_get(prefix + '/active', active)
    app.router.add_get(prefix + '/requests', pending)
    app.router.add_get(prefix + '/sessions/{session_id}', session_info)
    app.router.add_post(prefix + '/sessions/{session_id}/fork', fork)
    app.router.add_get(prefix + '/sessions/{session_id}/messages', messages)
    app.router.add_get(prefix + '/sessions/{session_id}/receipts/{receipt_id}', receipt)
    app.router.add_post(prefix + '/sessions/{session_id}/prompts', prompt)
    app.router.add_post(prefix + '/sessions/{session_id}/interrupt', interrupt)
    app.router.add_get(prefix + '/sessions/{session_id}/requests', pending)
    app.router.add_post(prefix + '/sessions/{session_id}/requests/{request_id}/reply', reply)

    async def shutdown(application):
        await relay.shutdown()

    async def cleanup(application):
        relay.storage.close()

    app.on_shutdown.append(shutdown)
    app.on_cleanup.append(cleanup)
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', action='append', required=True)
    parser.add_argument('--state-directory', type=pathlib.Path, required=True)
    parser.add_argument('--port', type=int, default=4097)
    arguments = parser.parse_args()
    os.umask(0o077)
    password = os.environ.pop('CODERELAY_ADAPTER_PASSWORD', '')
    config = Config(tuple(pathlib.Path(value) for value in arguments.root),
                    arguments.state_directory, password)
    if not 1 <= arguments.port <= 65535:
        parser.error('Port must be between 1 and 65535')
    web.run_app(make_app(config), host='127.0.0.1', port=arguments.port,
                access_log=None, shutdown_timeout=15)


if __name__ == '__main__':
    main()
