#!/usr/bin/env python3
"""Copy the explicit-only skill into Codex; preserve an existing installation."""
from pathlib import Path
import argparse
import os
import shutil
import time


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--destination',type=Path,default=Path(os.environ.get('CODEX_HOME',str(Path.home()/'.codex')))/'skills')
    args=parser.parse_args()
    source=Path(__file__).resolve().parents[1]/'skills/sofa-series'
    dest=args.destination.expanduser()/'sofa-series'
    if dest.exists():
        if all((dest/p.relative_to(source)).is_file() and (dest/p.relative_to(source)).read_bytes()==p.read_bytes() for p in source.rglob('*') if p.is_file()):
            print(f'Уже установлен: {dest}');return
        backup=dest.parent.parent/'skill-backups'/f'sofa-series-{time.time_ns()}'
        backup.parent.mkdir(parents=True,exist_ok=True);shutil.move(str(dest),str(backup))
    shutil.copytree(source,dest)
    print(f'Установлен: {dest}\nВ новом чате вызовите $sofa-series.')


if __name__=='__main__':main()
