#!/usr/bin/env python3
"""Build signed Android releases without accepting secrets in CLI arguments."""
import argparse
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
SIGNING_NAMES = (
    'CODERELAY_ANDROID_KEYSTORE_PATH',
    'CODERELAY_ANDROID_STORE_PASSWORD',
    'CODERELAY_ANDROID_KEY_ALIAS',
    'CODERELAY_ANDROID_KEY_PASSWORD',
)


def signing_ready(environment):
    return all(environment.get(name, '').strip() for name in SIGNING_NAMES)


def managed_signing_ready(root):
    gradle = root / 'android/app/build.gradle.kts'
    return gradle.is_file() and '// BEGIN CODERELAY RELEASE SIGNING' in gradle.read_text()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact', choices=['apk', 'appbundle'])
    parser.add_argument('--unsigned', action='store_true', help='Build verification artifacts without signing.')
    arguments = parser.parse_args()
    if not managed_signing_ready(ROOT):
        parser.exit(2, 'Managed Android release signing is missing. Run the bootstrap with a current Flutter SDK before building.\n')
    if arguments.unsigned:
        environment = {key: value for key, value in os.environ.items() if key not in SIGNING_NAMES}
        subprocess.run(['flutter', 'build', arguments.artifact, '--release'],
                       cwd=ROOT, env=environment, check=True)
        return
    if not signing_ready(os.environ):
        parser.exit(2, 'Release signing is required. Configure the four CODERELAY_ANDROID_* variables through your secret manager. See docs/distribution-and-diagnostics.md.\n')
    keystore = pathlib.Path(os.environ[SIGNING_NAMES[0]])
    if not keystore.is_absolute() or not keystore.is_file():
        parser.exit(2, 'The release keystore must be an existing absolute file path.\n')
    subprocess.run(['flutter', 'build', arguments.artifact, '--release'], cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
