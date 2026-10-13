#!/usr/bin/env python3
"""Generate native projects using the developer's own Flutter SDK, then configure them.
Never overwrites lib/, pubspec.yaml or an existing native project.
"""
import argparse
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
ANDROID = 'http://schemas.android.com/apk/res/android'
ET.register_namespace('android', ANDROID)

def configure_android(path: pathlib.Path, allow_http: bool):
    manifest = path / 'app/src/main/AndroidManifest.xml'
    tree = ET.parse(manifest)
    root = tree.getroot()
    if not any(p.get(f'{{{ANDROID}}}name') == 'android.permission.INTERNET'
               for p in root.findall('uses-permission')):
        ET.SubElement(root, 'uses-permission', {f'{{{ANDROID}}}name': 'android.permission.INTERNET'})
    app = root.find('application')
    app.set(f'{{{ANDROID}}}label', 'Remoto')
    app.set(f'{{{ANDROID}}}allowBackup', 'false')
    app.set(f'{{{ANDROID}}}usesCleartextTraffic', 'true' if allow_http else 'false')
    tree.write(manifest, encoding='utf-8', xml_declaration=True)
    gradle = path / 'app/build.gradle.kts'
    if gradle.exists():
        text = gradle.read_text()
        text = re.sub(r'minSdk\s*=\s*flutter.minSdkVersion', 'minSdk = 23', text)
        gradle.write_text(text)
    else:
        gradle = path / 'app/build.gradle'
        text = gradle.read_text()
        text = re.sub(r'minSdk(?:Version)?\s+flutter.minSdkVersion', 'minSdkVersion 23', text)
        gradle.write_text(text)

def configure_ios(path: pathlib.Path, allow_http: bool):
    info = path / 'Runner/Info.plist'
    with info.open('rb') as stream:
        data = plistlib.load(stream)
    data['CFBundleDisplayName'] = 'Remoto'
    data['NSLocalNetworkUsageDescription'] = 'Conectar aos teus servidores OpenCode pela rede privada Tailscale.'
    # HTTPS is default. Direct tailnet HTTP is a developer opt-in.
    data['NSAppTransportSecurity'] = {'NSAllowsArbitraryLoads': allow_http}
    with info.open('wb') as stream:
        plistlib.dump(data, stream)
    entitlement = path / 'Runner/Runner.entitlements'
    existing = {}
    if entitlement.exists():
        with entitlement.open('rb') as stream:
            existing = plistlib.load(stream)
    existing.setdefault('keychain-access-groups', [])
    with entitlement.open('wb') as stream:
        plistlib.dump(existing, stream)
    project = path / 'Runner.xcodeproj/project.pbxproj'
    if project.exists():
        text = project.read_text()
        if 'CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;' not in text:
            text = text.replace('INFOPLIST_FILE = Runner/Info.plist;',
                'INFOPLIST_FILE = Runner/Info.plist;\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;')
        project.write_text(text)
    debug_config = path / 'Flutter/Debug.xcconfig'
    if debug_config.exists():
        text = debug_config.read_text()
        debug_condition = 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG $(inherited)'
        if debug_condition not in text.splitlines():
            debug_config.write_text(f'{text.rstrip()}\n{debug_condition}\n')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-http', action='store_true', help='Opt-in HTTP direto na tailnet; build exige ALLOW_TAILNET_HTTP=true.')
    args = parser.parse_args()
    if not shutil.which('flutter'):
        parser.error('Instale o SDK Flutter e adicione flutter ao PATH primeiro.')
    with tempfile.TemporaryDirectory(prefix='remote-dev-native-') as folder:
        target = pathlib.Path(folder) / 'remote_dev'
        subprocess.run(['flutter', 'create', '--platforms=android,ios', '--org',
                        'io.github.remoteopencode.app', '--project-name', 'remote_dev', '--no-pub', str(target)], check=True)
        for name in ('android', 'ios'):
            dest = ROOT / name
            if not dest.exists():
                shutil.copytree(target / name, dest)
                print(f'Criado {name}/')
            else:
                print(f'Preservado {name}/ existente; aplicando apenas configurações de rede/nome.')
        metadata = target / '.metadata'
        if metadata.exists() and not (ROOT / '.metadata').exists():
            shutil.copy2(metadata, ROOT / '.metadata')
    configure_android(ROOT / 'android', args.allow_http)
    configure_ios(ROOT / 'ios', args.allow_http)
    subprocess.run(['flutter', 'pub', 'get'], cwd=ROOT, check=True)
    print('Pronto. Execute flutter analyze && flutter test && flutter run.')
    if args.allow_http:
        print('Para HTTP: acrescente --dart-define=ALLOW_TAILNET_HTTP=true a run/build.')

if __name__ == '__main__':
    main()
