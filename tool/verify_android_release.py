"""Reject APK releases that cannot update the preceding public GitHub APK."""
import hashlib
import json
import os
import pathlib
import re
import subprocess
import tempfile
import urllib.error
import urllib.request

from release import app_version


def apk_details(apk, build_tools):
    signed = subprocess.check_output([str(build_tools / 'apksigner'), 'verify', '--print-certs', str(apk)], text=True)
    certs = set(re.findall(r'Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)', signed))
    if not certs:
        raise ValueError('APK has no verified signing certificate')
    badging = subprocess.check_output([str(build_tools / 'aapt'), 'dump', 'badging', str(apk)], text=True)
    match = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
    if not match:
        raise ValueError('Cannot read APK identity/version')
    return match[1], int(match[2]), match[3], certs


def main():
    tools = pathlib.Path(os.environ['ANDROID_HOME']) / 'build-tools'
    build_tools = sorted((p for p in tools.iterdir() if re.fullmatch(r'\d+\.\d+\.\d+', p.name)),
                         key=lambda p: tuple(map(int, p.name.split('.'))))[-1]
    current = apk_details(pathlib.Path('build/app/outputs/flutter-apk/app-release.apk'), build_tools)
    version, build = app_version(pathlib.Path('pubspec.yaml').read_text())
    if current[:3] != ('com.example.sylphy', build, version):
        raise ValueError('APK identity/version differs from pubspec.yaml')
    repository = os.environ['GITHUB_REPOSITORY']
    request = urllib.request.Request(f'https://api.github.com/repos/{repository}/releases/latest',
        headers={'Authorization': 'Bearer ' + os.environ['GH_TOKEN'], 'User-Agent': 'Sylphy-release-check'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            release = json.load(response)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        print('First public release: keep this signing key for all future APKs.')
        return
    assets = [asset for asset in release['assets'] if asset['name'].endswith('-android.apk')]
    if len(assets) != 1:
        raise ValueError('Previous release APK missing or ambiguous; compatibility must be established before publication')
    asset = assets[0]
    if not 0 < asset['size'] <= 1024 * 1024 * 1024:
        raise ValueError('Previous APK size invalid')
    with tempfile.TemporaryDirectory() as folder:
        # gh handles authenticated GitHub downloads; never print signing keys/passwords.
        subprocess.run(['gh', 'release', 'download', release['tag_name'], '--repo', repository,
                        '--pattern', asset['name'], '--dir', folder], check=True)
        previous = pathlib.Path(folder) / asset['name']
        if asset.get('digest', '').startswith('sha256:'):
            with previous.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            if 'sha256:' + digest != asset['digest']:
                raise ValueError('Previous APK checksum mismatch')
        old = apk_details(previous, build_tools)
        if current[0] != old[0] or current[1] <= old[1] or current[3] != old[3]:
            raise ValueError('APK cannot update the previous release: preserve applicationId and signing key, and increase versionCode')
    print('APK signature, applicationId and increasing versionCode verified against previous release.')


if __name__ == '__main__':
    main()
