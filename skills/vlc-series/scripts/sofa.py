#!/usr/bin/env python3
"""Locate the repository whether the skill is used from Git or installed separately."""
import json
import os
from pathlib import Path
import sys


def locate():
    candidates=[]
    if os.environ.get('SOFA_REMOTE_REPO'):
        candidates.append(Path(os.environ['SOFA_REMOTE_REPO']).expanduser())
    candidates.append(Path(__file__).resolve().parents[3])
    profile=Path.home()/'Library/Application Support/org.videolan.vlc/sofa-remote'
    if '--profile' in sys.argv:
        i=sys.argv.index('--profile')
        if i+1<len(sys.argv):profile=Path(sys.argv[i+1]).expanduser()
    try:
        candidates.append(Path(json.loads((profile/'source.json').read_text())['path']))
    except (OSError,ValueError,KeyError):
        pass
    for folder in candidates:
        if (folder/'sofa.py').is_file() and (folder/'library.lua').is_file():
            return folder/'sofa.py'
    raise SystemExit('Не найден репозиторий Sofa Remote. Клонируйте https://github.com/Waksim/vlc-series и задайте SOFA_REMOTE_REPO или выполните его установку.')


if __name__=='__main__':
    entry=locate()
    os.execv(sys.executable,[sys.executable,str(entry),*sys.argv[1:]])
