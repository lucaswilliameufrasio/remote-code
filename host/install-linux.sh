#!/usr/bin/env bash
set -euo pipefail
# Must run as the same normal user who owns the existing OpenCode sessions.
if [[ $EUID -eq 0 ]]; then
  echo 'Execute como teu usuário normal, sem sudo.' >&2
  exit 1
fi
opencode_bin=$(command -v opencode) || { echo 'Instale opencode primeiro.' >&2; exit 1; }
case "$opencode_bin" in *$'\n'*|*'"'*|*'%'*) echo 'Caminho do executável não suportado.' >&2; exit 1;; esac
config_dir="$HOME/.config/remote-dev"
unit_dir="$HOME/.config/systemd/user"
mkdir -p "$config_dir" "$unit_dir"
chmod 700 "$config_dir"
if [[ ! -f "$config_dir/server.env" ]]; then
  read -r -s -p 'Senha para o servidor OpenCode (sem espaços/aspas): ' server_password
  printf '\n'
  [[ "$server_password" =~ ^[a-zA-Z0-9_.@+=:-]{12,}$ ]] || {
    echo 'Use ao menos 12 caracteres, letras/números ou _.@+=:-.' >&2; exit 1;
  }
  (umask 077; printf 'OPENCODE_SERVER_USERNAME=opencode\nOPENCODE_SERVER_PASSWORD=%s\n' "$server_password" > "$config_dir/server.env")
  unset server_password
fi
if [[ -e "$unit_dir/remote-dev-opencode.service" ]]; then
  echo 'Serviço já existe; preservado. Ajuste manualmente se necessário.' >&2
  exit 1
fi
# User service inherits the normal HOME and session database. PATH is captured
# here so Bun/node/package-manager installations remain available to tools.
python3 - "$opencode_bin" "$unit_dir/remote-dev-opencode.service" <<'PY'
import os, pathlib, sys
binary, output = sys.argv[1:]
def quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%') + '"'
text = f'''[Unit]
Description=OpenCode persistent remote development
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=%h
EnvironmentFile=%h/.config/remote-dev/server.env
Environment={quote('PATH=' + os.environ['PATH'])}
ExecStart={quote(binary)} serve --hostname 127.0.0.1 --port 4096
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=default.target
'''
pathlib.Path(output).write_text(text)
PY
systemctl --user daemon-reload
systemctl --user enable --now remote-dev-opencode.service
echo 'Serviço habilitado. Para iniciar antes do login após reboot:'
printf '  sudo loginctl enable-linger %q\n' "$USER"
echo 'Depois publique SOMENTE na tailnet:'
echo '  tailscale serve --bg http://127.0.0.1:4096'
echo '  tailscale serve status'
echo 'Cadastre no app a URL HTTPS e a senha definida acima.'
