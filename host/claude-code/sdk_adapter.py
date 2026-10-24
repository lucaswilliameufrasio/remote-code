"""Official SDK boundary. Never parses the operator's private transcript format."""
import uuid

import claude_agent_sdk as sdk


def blocks(content):
    result = []
    if isinstance(content, str):
        return [{'type': 'text', 'text': content[:262144]}]
    for block in (content if isinstance(content, list) else [])[:100]:
        kind = block.get('type') if isinstance(block, dict) else None
        if kind == 'text' and isinstance(block.get('text'), str):
            result.append({'type': 'text', 'text': block['text'][:262144]})
        elif kind in ('tool_use', 'tool_result'):
            result.append({'type': 'tool', 'tool': block.get('name', 'Tool'),
                           'state': {'status': 'completed'}})
    return result


class OfficialClaude:
    def catalog(self):
        return [{'id': item.session_id, 'title': (item.summary or 'Claude Code')[:256],
                 'directory': item.cwd or '', 'updated': item.last_modified,
                 'external': True}
                for item in sdk.list_sessions(limit=5000)]

    def info(self, identifier):
        item = sdk.get_session_info(identifier)
        if item is None:
            return None
        return {'id': item.session_id, 'title': (item.summary or 'Claude Code')[:256],
                'directory': item.cwd or '', 'updated': item.last_modified, 'external': True}

    def history(self, identifier, directory):
        info = sdk.get_session_info(identifier, directory=directory)
        if info is None or info.file_size is None or info.file_size > 8 * 1024 * 1024:
            raise ValueError('Local transcript exceeds the bounded read/import limit')
        messages = sdk.get_session_messages(identifier, directory=directory, limit=5001)
        if len(messages) > 5000:
            raise ValueError('Transcript exceeds import limit')
        result = []
        for message in messages:
            if message.parent_tool_use_id:
                continue
            content = message.message
            if isinstance(content, dict):
                content = content.get('content', [])
            result.append({'id': message.uuid, 'role': message.type, 'parts': blocks(content)})
        return result

    def fork(self, identifier, directory):
        return sdk.fork_session(identifier, directory=directory,
                                title='CodeRelay continuation').session_id

    def options(self, session, model, approve):
        return sdk.ClaudeAgentOptions(
            cwd=session['directory'], resume=session.get('native_id'),
            session_id=None if session.get('native_id') else session['id'],
            system_prompt={'type': 'preset', 'preset': 'claude_code'},
            permission_mode='default', setting_sources=[], strict_mcp_config=True,
            mcp_servers={}, allowed_tools=[], can_use_tool=approve,
            max_turns=40, max_buffer_size=1024 * 1024, model=model,
            env={'CLAUDE_AGENT_SDK_CLIENT_APP': 'coderelay',
                 'CLAUDE_CODE_MAX_RETRIES': '2', 'API_TIMEOUT_MS': '120000',
                 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS': '1'},
        )

    async def run(self, session, text, model, approve, emit, connected):
        options = self.options(session, model, approve)
        async with sdk.ClaudeSDKClient(options=options) as client:
            connected(client)
            await client.query(text)
            finished = False
            tool_messages = {}
            async for message in client.receive_response():
                if isinstance(message, sdk.SystemMessage) and message.subtype == 'init':
                    native_id = message.data.get('session_id')
                    if isinstance(native_id, str):
                        emit({'native_id': native_id})
                elif isinstance(message, sdk.AssistantMessage) and not message.parent_tool_use_id:
                    parts = []
                    for block in message.content:
                        if isinstance(block, sdk.TextBlock):
                            parts.append({'type': 'text', 'text': block.text[:262144]})
                        elif isinstance(block, sdk.ToolUseBlock):
                            parts.append({'type': 'tool', 'tool': block.name,
                                          'tool_use_id': block.id,
                                          'state': {'status': 'running'}})
                    if parts:
                        displayed = {'id': message.uuid or str(uuid.uuid4()),
                                     'role': 'assistant', 'parts': parts}
                        for block in message.content:
                            if isinstance(block, sdk.ToolUseBlock):
                                tool_messages[block.id] = displayed
                        emit({'message': displayed})
                elif isinstance(message, sdk.UserMessage) and not message.parent_tool_use_id:
                    for block in (message.content if isinstance(message.content, list) else []):
                        if isinstance(block, sdk.ToolResultBlock):
                            displayed = tool_messages.pop(block.tool_use_id, None)
                            if displayed is not None:
                                for part in displayed['parts']:
                                    if part.get('tool_use_id') == block.tool_use_id:
                                        part['state'] = {'status': 'error' if block.is_error else 'completed'}
                                emit({'message': displayed})
                elif isinstance(message, sdk.ResultMessage):
                    finished = True
                    emit({'native_id': message.session_id})
                    if message.is_error:
                        raise RuntimeError('Claude turn failed')
            if not finished:
                raise RuntimeError('Claude stopped without a result')
