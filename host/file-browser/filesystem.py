#!/usr/bin/env python3
"""Read-only POSIX filesystem policy, invoked over stdin by the OpenCode plugin."""
import errno
import json
import os
import stat
import sys
import time

MAX_BYTES = 256 * 1024
MAX_ENTRIES = 500
MAX_VISITED = 5000
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class PolicyError(Exception):
    def __init__(self, code, message):
        self.code = code
        self.message = message


def segments(path, absolute=False):
    if not isinstance(path, str) or len(path) > 4096 or '\\' in path or '%' in path:
        raise PolicyError('FILES_DENIED', 'Caminho não permitido pelo explorador.')
    if any(ord(character) < 32 for character in path):
        raise PolicyError('FILES_DENIED', 'Caminho não permitido pelo explorador.')
    if absolute != path.startswith('/'):
        raise PolicyError('FILES_DENIED', 'Caminho fora do escopo configurado.')
    parts = path[1:].split('/') if absolute else path.split('/')
    if path in ('', '/'):
        return []
    if any(part in ('', '.', '..') for part in parts):
        raise PolicyError('FILES_DENIED', 'Caminho não permitido pelo explorador.')
    return parts


def open_directory(path):
    parts = segments(path, absolute=True)
    descriptor = os.open('/', DIRECTORY_FLAGS)
    try:
        for part in parts:
            child = os.open(part, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def open_child(directory, path, is_directory):
    parts = segments(path)
    descriptor = os.dup(directory)
    try:
        for index, part in enumerate(parts):
            flags = DIRECTORY_FLAGS if is_directory or index < len(parts) - 1 else (
                os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def execute(roots, directory, method, value):
    if not isinstance(value, dict):
        raise PolicyError('FILES_INVALID', 'Solicitação inválida para o explorador.')
    if not isinstance(roots, list) or len(roots) > 16 or not roots:
        raise PolicyError('FILES_DENIED', 'Nenhuma raiz foi autorizada no host.')
    for root in roots:
        segments(root, absolute=True)
    if method == 'roots':
        return {'data': roots}
    directory_parts = segments(directory, absolute=True)
    authorized = False
    for root in roots:
        root_parts = segments(root, absolute=True)
        if directory_parts[:len(root_parts)] == root_parts:
            authorized = True
    if not authorized:
        raise PolicyError('FILES_DENIED', 'Projeto fora das raízes autorizadas no host.')
    base = open_directory(directory)
    try:
        path = value.get('path', '')
        segments(path)
        if method == 'capabilities':
            return {'version': 1, 'restricted': True, 'max_bytes': MAX_BYTES}
        if method == 'read':
            if not path:
                raise PolicyError('FILES_DENIED', 'Escolha um arquivo regular.')
            descriptor = open_child(base, path, False)
            try:
                if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                    raise PolicyError('FILES_DENIED', 'Somente arquivos regulares podem ser lidos.')
                with os.fdopen(descriptor, 'rb', closefd=False) as stream:
                    content = stream.read(MAX_BYTES + 1)
                truncated = len(content) > MAX_BYTES
                content = content[:MAX_BYTES]
                text = None
                for trim in range(4 if truncated else 1):
                    try:
                        text = content[:len(content) - trim].decode('utf-8-sig')
                        break
                    except UnicodeDecodeError:
                        continue
                if text is None or any(ord(character) < 9 or 13 < ord(character) < 32 for character in text):
                    raise PolicyError('FILES_BINARY', 'Visualização disponível somente para texto UTF-8.')
                return {'text': text, 'truncated': truncated}
            finally:
                os.close(descriptor)
        if method == 'list':
            descriptor = open_child(base, path, True)
            try:
                entries = []
                with os.scandir(descriptor) as children:
                    for child in children:
                        if len(entries) >= MAX_ENTRIES:
                            raise PolicyError('FILES_LIMIT', 'Pasta muito grande. Use a busca limitada do projeto.')
                        if child.is_symlink():
                            continue
                        if child.is_dir(follow_symlinks=False) or child.is_file(follow_symlinks=False):
                            entries.append({'path': '/'.join(filter(None, (path, child.name))),
                                            'type': 'directory' if child.is_dir(follow_symlinks=False) else 'file'})
                return {'data': entries}
            finally:
                os.close(descriptor)
        if method == 'find':
            query = value.get('query')
            if not isinstance(query, str) or not 1 <= len(query) <= 256:
                raise PolicyError('FILES_INVALID', 'Informe uma busca com até 256 caracteres.')
            entries = []
            pending = ['']
            visited = 0
            deadline = time.monotonic() + 2
            while pending and len(entries) < 100 and visited < MAX_VISITED and time.monotonic() < deadline:
                current = pending.pop()
                descriptor = open_child(base, current, True)
                try:
                    with os.scandir(descriptor) as children:
                        for child in children:
                            visited += 1
                            if visited >= MAX_VISITED or time.monotonic() >= deadline:
                                break
                            if child.is_symlink():
                                continue
                            child_path = '/'.join(filter(None, (current, child.name)))
                            is_directory = child.is_dir(follow_symlinks=False)
                            if is_directory and len(pending) < 256:
                                pending.append(child_path)
                            if not is_directory and not child.is_file(follow_symlinks=False):
                                continue
                            if value.get('directories_only') is True and not is_directory:
                                continue
                            if query.casefold() in child_path.casefold():
                                entries.append({'path': child_path, 'type': 'directory' if is_directory else 'file'})
                                if len(entries) == 100:
                                    break
                finally:
                    os.close(descriptor)
            return {'data': entries}
        raise PolicyError('FILES_INVALID', 'Operação do explorador não suportada.')
    finally:
        os.close(base)


def main():
    try:
        raw = sys.stdin.buffer.read(65537)
        if len(raw) > 65536:
            raise PolicyError('FILES_LIMIT', 'Solicitação muito grande.')
        request = json.loads(raw)
        output = execute(request['roots'], request['directory'], request['method'], request['input'])
        result = {'output': output}
    except PolicyError as exception:
        result = {'error': {'code': exception.code, 'message': exception.message}}
    except OSError as exception:
        code = 'FILES_NOT_FOUND' if exception.errno == errno.ENOENT else 'FILES_DENIED'
        result = {'error': {'code': code, 'message': 'Arquivo indisponível ou acesso recusado pelo host.'}}
    except (ValueError, KeyError, TypeError):
        result = {'error': {'code': 'FILES_INVALID', 'message': 'Solicitação inválida para o explorador.'}}
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
