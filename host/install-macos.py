#!/usr/bin/env python3
"""Install a per-user LaunchAgent. Starts at login, including after a restart.
Use the same macOS user as the original OpenCode sessions.
"""
import getpass
import os
import pathlib
import plistlib
import shutil
import subprocess

def main():
    if os.geteuid() == 0:
        raise SystemExit('Execute como usuário normal, sem sudo.')
    binary = shutil.which('opencode')
    if not binary:
        raise SystemExit('Instale opencode e configure o PATH primeiro.')
    home = pathlib.Path.home()
    target = home / 'Library/LaunchAgents/io.github.remoteopencode.server.plist'
    if target.exists():
        raise SystemExit('LaunchAgent já existe; preservado.')
    password = getpass.getpass('Senha do servidor (ao menos 12 caracteres): ')
    if len(password) < 12:
        raise SystemExit('Senha muito curta.')
    logs = home / 'Library/Logs/RemoteDev'
    logs.mkdir(parents=True, exist_ok=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    data = {
        'Label': 'io.github.remoteopencode.server',
        'ProgramArguments': [binary, 'serve', '--hostname', '127.0.0.1', '--port', '4096'],
        'WorkingDirectory': str(home),
        'EnvironmentVariables': {'HOME': str(home), 'PATH': os.environ['PATH'],
            'OPENCODE_SERVER_USERNAME': 'opencode', 'OPENCODE_SERVER_PASSWORD': password},
        'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 5,
        'StandardOutPath': str(logs / 'server.log'), 'StandardErrorPath': str(logs / 'error.log'),
    }
    descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        plistlib.dump(data, stream)
    subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(target)], check=True)
    print('Habilitado para iniciar ao fazer login. Após reboot com FileVault, desbloqueie o Mac.')
    print('Execute: tailscale serve --bg http://127.0.0.1:4096')
    print('Cadastre a URL HTTPS retornada no app.')

if __name__ == '__main__':
    main()
