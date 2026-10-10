#!/usr/bin/env python3
"""Package an already-built CodeJump app and IDEA companion; no credentials are included."""
import hashlib
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parent.parent
app = root / 'dist/CodeJump.app'
if not app.exists():
    raise SystemExit('Build dist/CodeJump.app first: ./script/build_and_run.sh --build-only')
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
architectures = subprocess.check_output(['lipo', '-archs', str(app/'Contents/MacOS/CodeJump')], text=True).strip().split()
architecture = architectures[0] if len(architectures) == 1 else 'universal'
plugin_version = ET.parse(root/'idea-plugin/src/main/resources/META-INF/plugin.xml').findtext('version')
plugin = root / f'dist/CodeJumpCompanion-{plugin_version}.zip'
if not plugin.is_file():
    raise SystemExit('Build the IDEA companion first: python3 idea-plugin/build.py')
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
output = root / f'dist/CodeJump-{version}-{architecture}.dmg'
if output.exists():
    raise SystemExit(f'Refusing to replace an existing release artifact: {output}')
with tempfile.TemporaryDirectory(prefix='codejump-dmg-') as temporary:
    staging = pathlib.Path(temporary)/'contents'
    staging.mkdir()
    subprocess.run(['ditto', str(app), str(staging/'CodeJump.app')], check=True)
    (staging/'Applications').symlink_to('/Applications', target_is_directory=True)
    shutil.copy2(plugin, staging/plugin.name)
    (staging/'安装说明.txt').write_text(f'''CodeJump {version}

系统要求：macOS 14 或更新版本，{architecture}。
将 CodeJump.app 拖入 Applications，然后打开应用。
导入需要搜索的项目目录，在系统设置中授予 CodeJump 辅助功能权限。
⌥J：识别鼠标指向或选中的代码引用；⌥P：切换项目；⌥H：打开主页。

可选 IDEA 插件：{plugin.name}
在 IDEA 2026.1 的 设置 → 插件 → 从磁盘安装 中选择此 ZIP。
如 IDEA 提示重启，请重启后在 CodeJump 启用“使用可选 IDEA 插件”。
裸方法名查询需要目标项目已在 IDEA 中打开。

此版本使用专用本机代码签名证书签名，未使用 Apple Developer ID 签名或 Apple 公证。
另一台 Mac 首次运行可能需要通过系统的正常应用允许流程。
应用仅本地处理代码；包内不包含个人项目配置、授权信息或签名私钥。
源码与后续版本：https://github.com/xiay8874-source/CodeJump
''', encoding='utf-8')
    subprocess.run(['hdiutil', 'create', '-volname', f'CodeJump {version}', '-srcfolder', str(staging),
                    '-format', 'UDZO', '-fs', 'HFS+', str(output)], check=True)
subprocess.run(['hdiutil', 'verify', str(output)], check=True)
sha = hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix(output.suffix+'.sha256').write_text(f'{sha}  {output.name}\n')
print(output)
