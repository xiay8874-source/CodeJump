#!/usr/bin/env python3
"""Build against an installed IDEA SDK without downloading another IDE or Gradle."""
import os, pathlib, shutil, subprocess, zipfile
root = pathlib.Path(__file__).resolve().parent
idea = pathlib.Path(os.environ.get('CODEJUMP_IDEA_APP', '/Applications/IntelliJ IDEA.app')) / 'Contents'
jdk = idea / 'jbr/Contents/Home/bin'
classes = root / 'build/classes'
classes.mkdir(parents=True, exist_ok=True)
cp = os.pathsep.join(str(p) for folder in [idea/'lib', idea/'plugins/java/lib'] for p in folder.rglob('*.jar'))
subprocess.run([str(jdk/'javac'), '--release', '21', '-cp', cp, '-d', str(classes), *map(str, (root/'src/main/java').rglob('*.java'))], check=True)
shutil.copytree(root/'src/main/resources', classes, dirs_exist_ok=True)
bundle = root/'build/CodeJumpCompanion/lib'
bundle.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(bundle/'codejump-companion.jar', 'w', zipfile.ZIP_DEFLATED) as jar:
    for p in classes.rglob('*'):
        if p.is_file(): jar.write(p, p.relative_to(classes))
archive = root.parent/'dist/CodeJumpCompanion-0.2.0.zip'
archive.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as z:
    for p in bundle.rglob('*'):
        if p.is_file(): z.write(p, p.relative_to(root/'build'))
print(archive)
