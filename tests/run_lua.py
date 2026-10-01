#!/usr/bin/env python3
"""Run pure Lua tests using Lua, or a separate VLC when Lua is not installed."""
from pathlib import Path
import json
import shutil
import subprocess
import tempfile
import uuid

root=Path(__file__).resolve().parents[1]
lua=shutil.which('lua') or shutil.which('lua5.4')
if lua:
    raise SystemExit(subprocess.run([lua,str(root/'tests/test_core.lua')],cwd=root).returncode)
vlc=Path('/Applications/VLC.app/Contents/MacOS/VLC')
if not vlc.exists():raise SystemExit('Install Lua 5.1+ or VLC 3.x on macOS')
name='sofa_unit_'+uuid.uuid4().hex[:10]
loader=Path.home()/'Library/Application Support/org.videolan.vlc/lua/intf'/(name+'.lua')
loader.parent.mkdir(parents=True,exist_ok=True)
loader.write_text('dofile(config.source .. "/tests/test_core.lua")\n')
try:
    with tempfile.TemporaryDirectory(prefix='sofa-unit-') as tmp:
        result=Path(tmp)/'result.txt'
        conf=name+'={source='+json.dumps(str(root))+',result='+json.dumps(str(result))+'}'
        process=subprocess.Popen([str(vlc),'--ignore-config','-I','dummy','--extraintf','luaintf{intf='+name+'}','--lua-config',conf,'--no-video','--aout','dummy','--no-metadata-network-access'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        try:output,_=process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            process.terminate();output,_=process.communicate(timeout=5)
        if not result.exists():raise SystemExit(output)
        print(result.read_text())
finally:loader.unlink(missing_ok=True)
