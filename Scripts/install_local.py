#!/usr/bin/env python3
"""Install the local build and refresh only DeskKit's app/extension registrations."""
from pathlib import Path
import argparse
import os
import plistlib
import signal
import subprocess
import time

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=root / 'DerivedData/Build/Products/Debug/DeskKit.app')
parser.add_argument('--destination', type=Path, default=root / 'Build/DeskKit.app')
args = parser.parse_args()
source = args.source.expanduser().resolve()
app = args.destination.expanduser().resolve()
if source == app:
    raise SystemExit('Source and destination must be different.')
executable = app / 'Contents/MacOS/DeskKit'
extension_suffix = Path('Contents/PlugIns/DeskKitWidgets.appex')
lsregister = '/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister'
if not Path(lsregister).exists():
    lsregister = '/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister'


def matching_processes(paths):
    expected = {str(path.resolve()) for path in paths}
    output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,comm='], text=True)
    return [int(parts[0]) for line in output.splitlines()
            if len(parts := line.strip().split(None, 1)) == 2 and str(Path(parts[1]).resolve()) in expected]


def wait_for_exit(paths, seconds=3):
    deadline = time.monotonic() + seconds
    while matching_processes(paths) and time.monotonic() < deadline:
        time.sleep(0.2)
    return not matching_processes(paths)


with (source / 'Contents/Info.plist').open('rb') as file:
    info = plistlib.load(file)
if info.get('CFBundleName') != 'DeskKit' or not (source / 'Contents/MacOS/DeskKit').is_file():
    raise SystemExit('Source is not a built DeskKit app.')

if matching_processes([executable]):
    request = f'with timeout of 5 seconds\n tell application "{app}" to quit\nend timeout'
    result = subprocess.run(['/usr/bin/osascript', '-e', request], text=True, capture_output=True, timeout=8)
    if result.returncode:
        print(result.stderr.strip())
    if not wait_for_exit([executable]):
        raise SystemExit('DeskKit 仍在运行，未替换应用。请先处理未保存编辑的退出提示。')

# Xcode registers its DerivedData copy after building. Keep only the installed copy discoverable.
unregister = subprocess.run([lsregister, '-u', str(source)], text=True, capture_output=True)
if unregister.returncode and '-10814' not in unregister.stdout + unregister.stderr:
    raise SystemExit(unregister.stdout + unregister.stderr)
subprocess.run(['/usr/bin/rsync', '-a', '--delete', str(source) + '/', str(app) + '/'], check=True)
subprocess.run([lsregister, '-f', '-R', '-trusted', str(app)], check=True)
subprocess.run(['/usr/bin/pluginkit', '-a', str(app / extension_suffix)], check=True)

# Old extension processes keep the previous executable/intent metadata mapped after file replacement.
# Restart only our exact extension executables; other widgets and system hosts remain running.
extensions = [base / extension_suffix / 'Contents/MacOS/DeskKitWidgets' for base in [source, app]]
for pid in matching_processes(extensions):
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass

with open('/private/tmp/deskkit-installed-launch.log', 'ab') as log:
    process = subprocess.Popen([str(executable), '--show-manager'], stdin=subprocess.DEVNULL,
                               stdout=log, stderr=log, start_new_session=True)
print(f'DeskKit build {info["CFBundleVersion"]} 已更新并启动（PID {process.pid}），小组件扩展注册已刷新。')
