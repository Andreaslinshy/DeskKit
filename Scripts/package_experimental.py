#!/usr/bin/env python3
"""Build and package an experimental macOS app; no install, launch, upload, or notarization."""
from pathlib import Path
from datetime import date
import argparse
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import tempfile
from package_examples import package_examples

ROOT = Path(__file__).resolve().parents[1]


def run(arguments, **kwargs):
    return subprocess.run([str(item) for item in arguments], check=True, **kwargs)


def xcode_environment():
    environment = os.environ.copy()
    lookup = subprocess.run(['/usr/bin/xcrun', '--find', 'xcodebuild'], env=environment,
                            capture_output=True, text=True)
    if lookup.returncode == 0:
        return environment
    developer = Path('/Applications/Xcode.app/Contents/Developer')
    if 'DEVELOPER_DIR' not in environment and (developer / 'usr/bin/xcodebuild').is_file():
        environment['DEVELOPER_DIR'] = str(developer)
        return environment
    raise SystemExit('Full Xcode is required. Set DEVELOPER_DIR to its Contents/Developer directory.')


def check_package(app):
    forbidden_suffixes = ('.p12', '.p8', '.key', '.pem', '.mobileprovision', '.provisionprofile')
    for path in app.rglob('*'):
        if not path.is_file():
            continue
        if path.name.endswith(forbidden_suffixes) or '.debug.dylib' in path.name or path.name == '__preview.dylib':
            raise SystemExit(f'Private/development artifact found: {path.relative_to(app)}')
        data = path.read_bytes()
        if re.search(rb'/Users/[^/\s\x00]+', data) or str(ROOT).encode() in data:
            raise SystemExit(f'Local build path found: {path.relative_to(app)}')
        if b'-----BEGIN PRIVATE KEY-----' in data or b'-----BEGIN RSA PRIVATE KEY-----' in data:
            raise SystemExit(f'Private key found: {path.relative_to(app)}')
    # The public certificate/email/Team ID embedded in a signed app are intentional.
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--derived-data', type=Path, default=ROOT / 'DerivedData/Experimental')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    parser.add_argument('--app', type=Path, help='Repackage an existing signed app without rebuilding it')
    args = parser.parse_args()
    try:
        from dmgbuild import build_dmg
    except ImportError:
        raise SystemExit('Install Scripts/requirements-packaging.txt in a Python virtual environment first.')
    output = args.output.expanduser().resolve()
    derived = args.derived_data.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    stamp = date.today().isoformat()
    app = args.app.expanduser().resolve() if args.app else derived / 'Build/Products/Release/DeskKit.app'
    if not args.app:
        log = output / 'build-experimental.log'
        swift_flags = '$(inherited) ' + shlex.join(['-debug-prefix-map', f'{ROOT}=/DeskKit', '-file-compilation-dir', '/DeskKit'])
        command = ['/usr/bin/xcrun', 'xcodebuild', '-project', ROOT / 'DeskKit.xcodeproj', '-scheme', 'DeskKit',
                   '-configuration', 'Release', '-derivedDataPath', derived, '-arch', 'arm64',
                   'ONLY_ACTIVE_ARCH=YES', 'ENABLE_DEBUG_DYLIB=NO', 'SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO',
                   'DEPLOYMENT_POSTPROCESSING=YES', 'STRIP_INSTALLED_PRODUCT=YES', 'COPY_PHASE_STRIP=YES',
                   'OTHER_SWIFT_FLAGS=' + swift_flags, 'build']
        with log.open('w') as handle:
            result = subprocess.run([str(item) for item in command], cwd=ROOT, env=xcode_environment(), stdout=handle, stderr=subprocess.STDOUT)
        if result.returncode:
            raise SystemExit(f'Build failed. Inspect the local log: {log}')
        print('Optimized arm64 build completed.', flush=True)
    check_package(app)
    examples = package_examples(output / 'DeskKit-examples.zip')
    dmg = output / f'DeskKit-experimental-{stamp}-arm64.dmg'
    with tempfile.TemporaryDirectory(prefix='DeskKit-package-') as directory:
        staging = Path(directory) / 'Disk'
        staging.mkdir()
        run(['/usr/bin/ditto', '--norsrc', '--noextattr', '--noqtn', app, staging / 'DeskKit.app'])
        extras = staging / '样例与说明'
        extras.mkdir()
        shutil.copyfile(examples, extras / examples.name)
        shutil.copyfile(ROOT / 'LICENSE', extras / 'LICENSE.txt')
        (extras / '请先阅读.txt').write_text(
            'DeskKit\n\n'
            '不保证稳定性、兼容性或长期维护，有需求者自行下载源码自定义构建。\n\n'
            '将 DeskKit.app 拖入 Applications，再从应用程序目录打开。\n'
            '这是 Apple Silicon 实验包，最低 macOS 14，不是正式版。\n'
            '使用开发签名，没有 Apple 公证，可能被 Gatekeeper 阻止，或无法加载桌面扩展。\n'
            '请根据 macOS 的提示自行判断是否信任；也可以从源码自行签名构建。\n'
            '不要为此关闭系统安全保护。签名证书身份和 Team ID 可被查看。\n\n'
            '三个样例默认停用，仅供参考，不保证安装后立即可用。\n'
            '需要自己编写或调整脚本和配置；可让大模型根据样例模仿构建，再自行检查。\n'
            'Codex 组件需要另行安装并登录兼容的 Codex；金价依赖第三方网站。\n'
            '应用首次启动会放入三个样例；ZIP 用于参考、恢复或手动导入，不要重复导入相同 ID。\n'
            '只启用可信组件，本地 command 数据源可以读取文件或联网。\n\n'
            '源码与说明：https://github.com/Andreaslinshy/DeskKit\n')
        check_package(staging / 'DeskKit.app')
        artwork = Path(directory) / 'Artwork'
        run(['/usr/bin/xcrun', 'swift', ROOT / 'Scripts/generate_installer_artwork.swift', artwork, extras],
            env=xcode_environment())
        build_dmg(str(dmg), 'DeskKit', settings_file=str(ROOT / 'Scripts/dmg_settings.py'),
                  defines={'staging': str(staging), 'artwork': str(artwork)})
    checksums = output / 'SHA256SUMS.txt'
    checksums.write_text(''.join(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n' for path in [dmg, examples]))
    # Xcode registers build products. Keep this packaging copy from competing with installed widgets.
    lsregister = Path('/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister')
    if not lsregister.exists():
        lsregister = Path('/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister')
    if not args.app and lsregister.exists():
        result = subprocess.run([str(lsregister), '-u', str(app)], capture_output=True, text=True)
        if result.returncode and '-10814' not in result.stdout + result.stderr:
            print('Note: the temporary build registration could not be removed.')
    print(f'Created {dmg}\nCreated {examples}\nCreated {checksums}', flush=True)


if __name__ == '__main__':
    main()
