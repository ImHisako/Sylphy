"""Deterministic release metadata and per-user Linux installer packaging."""
import argparse
import hashlib
import io
import json
import pathlib
import re
import subprocess
import tarfile


def app_version(text):
    match = re.search(r"^version: (\d+\.\d+\.\d+)\+([1-9]\d*)\s*$", text, re.M)
    if not match or int(match[2]) > 2100000000:
        raise ValueError("pubspec.yaml requires major.minor.patch+increasingBuild")
    return match[1], int(match[2])


def validate(tag, root):
    version, build = app_version((root / "pubspec.yaml").read_text())
    if tag != "v" + version:
        raise ValueError("Release tag must match pubspec.yaml")
    tags = subprocess.check_output(["git", "tag", "--list", "v*"], cwd=root, text=True).splitlines()
    for previous in tags:
        if previous == tag or not re.fullmatch(r"v\d+\.\d+\.\d+", previous):
            continue
        previous_spec = subprocess.check_output(["git", "show", previous + ":pubspec.yaml"], cwd=root, text=True)
        old_version, old_build = app_version(previous_spec)
        if tuple(map(int, version.split('.'))) <= tuple(map(int, old_version.split('.'))) or build <= old_build:
            raise ValueError(f"Version and build must increase beyond {previous} ({old_build})")


def linux_installer(bundle, output, version, build):
    if not (bundle / "sylphy").is_file() or not (bundle / "lib/libsylphy_core.so").is_file():
        raise ValueError("Incomplete Linux bundle")
    payload = io.BytesIO()
    # upload-artifact strips executable bits. Restore the application explicitly.
    with tarfile.open(fileobj=payload, mode="w:gz", format=tarfile.PAX_FORMAT) as archive:
        for path in sorted(bundle.rglob('*')):
            if path.is_symlink():
                raise ValueError("Release bundles must not contain symlinks")
            if path.is_file():
                info = archive.gettarinfo(str(path), arcname=path.relative_to(bundle).as_posix())
                info.mode = 0o755 if path.name == "sylphy" else 0o644
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                with path.open('rb') as stream:
                    archive.addfile(info, stream)
    data = payload.getvalue()
    header = (pathlib.Path(__file__).parent / 'linux-installer.sh').read_text()
    header = header.replace('@VERSION@', version).replace('@BUILD@', str(build)).replace('@SHA256@', hashlib.sha256(data).hexdigest())
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(header.encode() + data)
    output.chmod(0o755)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['validate', 'metadata', 'linux'])
    parser.add_argument('--tag')
    parser.add_argument('--bundle', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent.parent
    version, build = app_version((root / 'pubspec.yaml').read_text())
    if args.command == 'validate':
        validate(args.tag, root)
    elif args.command == 'metadata':
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps({'schema': 1, 'version': version, 'build': build}) + '\n')
    else:
        linux_installer(args.bundle, args.output, version, build)


if __name__ == '__main__':
    main()
