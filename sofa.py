#!/usr/bin/env python3
"""Install and manage Sofa Remote without controlling an ongoing VLC playback."""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import math
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid

VERSION = '1.0.1'
SOURCE = Path(__file__).resolve().parent
DEFAULT_PROFILE = Path.home() / 'Library/Application Support/org.videolan.vlc/sofa-remote'
EXTENSIONS = {'.mkv', '.mp4', '.avi', '.mov', '.m4v', '.webm', '.ts'}
PICTURES = {'dragon': '🐉', 'moon': '🌙', 'popcorn': '🍿', 'cat': '🐈', 'sofa': '🛋️', 'crown': '👑'}
MODULES = ('library.lua', 'progress.lua', 'markers.lua', 'audio.lua', 'navigation.lua', 'tracker.lua', 'sofa.lua')


def read_json(path, default=None):
    if not Path(path).exists():
        return default
    try:
        return json.loads(Path(path).read_text())
    except (ValueError, OSError) as e:
        raise ValueError(f'Не удалось прочитать {path}: {e}') from e


def atomic_json(path, data, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=path.name + '.', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, ensure_ascii=False, indent=2, allow_nan=False)
            f.write('\n'); f.flush(); os.fsync(f.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def season_number(name):
    match = re.search(r'(?:season|сезон)[ ._-]*(\d+)', name, re.I) or re.fullmatch(r's(\d+)', name, re.I)
    return int(match[1]) if match else None


def episode_number(name, folder_season=None):
    match = re.search(r's(\d+)[ ._-]*e(\d+)', name, re.I) or re.search(r'(\d+)x(\d+)', name, re.I)
    if match:
        season, episode = map(int, match.groups())
    elif folder_season is not None:
        match = re.search(r'(?:episode|серия)[ ._-]*(\d+)', name, re.I) or re.match(r'e[ ._-]*(\d+)', name, re.I) or re.match(r'(\d+)[ ._-]', name)
        if not match:
            return None
        season, episode = folder_season, int(match[1])
    else:
        return None
    return (season, episode) if 0 <= season <= 999 and 1 <= episode <= 999 else None


def probe(path):
    ffprobe = shutil.which('ffprobe')
    if not ffprobe:
        return 0.0
    try:
        result = subprocess.run([ffprobe, '-v', 'error', '-show_entries', 'format=duration',
                                 '-of', 'default=nw=1:nk=1', str(path)], capture_output=True, text=True, timeout=20, check=True)
        value = float(result.stdout.strip())
        return value if math.isfinite(value) and value > 0 else 0.0
    except (ValueError, subprocess.SubprocessError):
        return 0.0


def scan(folder, durations=False):
    folder = Path(folder).expanduser().resolve()
    if not folder.is_dir():
        raise ValueError(f'Нет папки: {folder}')
    entries, ignored, seen, duplicates = [], [], {}, {}
    for path in sorted(folder.rglob('*')):
        rel = path.relative_to(folder)
        if len(rel.parts) > 4 or any(part.startswith('.') for part in rel.parts) or path.suffix.lower() not in EXTENSIONS:
            continue
        if path.is_symlink() or not path.is_file() or any(p.is_symlink() for p in path.parents if p != folder and folder in p.parents):
            continue
        inherited = season_number(folder.name)
        for part in rel.parts[:-1]:
            found = season_number(part)
            if found is not None:
                inherited = found
        parsed = episode_number(path.name, inherited)
        if not parsed:
            ignored.append(str(rel)); continue
        season, episode = parsed
        key = f's{season:02}e{episode:02}'
        stat = path.stat()
        entry = {'key': key, 'season': season, 'episode': episode, 'file': rel.as_posix(),
                 'size': stat.st_size, 'mtime': int(stat.st_mtime), 'duration': 0.0}
        if key in seen:
            duplicates.setdefault(key, [seen[key]['file']]).append(entry['file'])
        else:
            seen[key] = entry
        entries.append(entry)
    entries.sort(key=lambda e: (e['season'], e['episode'], e['file']))
    if durations:
        with ThreadPoolExecutor(max_workers=2) as pool:
            values = pool.map(probe, (folder / e['file'] for e in entries))
            for entry, value in zip(entries, values):
                entry['duration'] = value
    return {'root': str(folder), 'episodes': entries, 'ignored': ignored, 'duplicates': duplicates}


def registry(profile):
    doc = read_json(profile / 'libraries.json')
    if doc is not None:
        if not isinstance(doc, dict) or doc.get('version') != 1 or not isinstance(doc.get('libraries'), list):
            raise ValueError('Некорректный libraries.json; существующий файл сохранён')
        return doc
    settings = read_json(profile / 'settings.json', {})
    shows = []
    if settings.get('libraryRoot'):
        shows.append({'id': 'legacy', 'title': settings.get('libraryTitle', 'Мой сериал'),
                      'root': str(Path(settings['libraryRoot']).expanduser().resolve()), 'legacy': True})
    return {'version': 1, 'libraries': shows}


def add_series(profile, folders, title=None, series_id=None):
    doc = registry(profile)
    cache = read_json(profile / 'library-cache.json', {})
    cache.setdefault('libraries', {})
    reports = []
    for folder in folders:
        inventory = scan(folder, durations=True)
        if inventory['duplicates']:
            raise ValueError('Повторяются номера серий. Выберите отдельную папку сериала или --collection: ' + json.dumps(inventory['duplicates'], ensure_ascii=False))
        if not inventory['episodes']:
            raise ValueError(f'Не распознаны серии в {folder}. Запустите scan и проверьте названия.')
        show = next((s for s in doc['libraries'] if s['root'] == inventory['root']), None)
        if series_id and show and show['id'] != series_id:
            raise ValueError(f"Этот путь уже зарегистрирован как {show['id']}; ID сохраняет историю")
        if not show:
            identifier = series_id or 'show-' + uuid.uuid4().hex[:10]
            if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}', identifier) or identifier == 'legacy':
                raise ValueError('ID: 1–64 символа a-z, 0-9, _ и -; legacy зарезервирован')
            if any(s['id'] == identifier for s in doc['libraries']):
                raise ValueError(f'ID {identifier} уже занят')
            current_root = Path(inventory['root'])
            if any(Path(s['root']) in current_root.parents or current_root in Path(s['root']).parents for s in doc['libraries']):
                raise ValueError('Папки сериалов не должны быть вложены друг в друга')
            show = {'id': identifier, 'title': title or Path(inventory['root']).name, 'root': inventory['root']}
            doc['libraries'].append(show)
        elif title:
            show['title'] = title
        cache['libraries'][show['id']] = {
            'durations': {e['file']: e['duration'] for e in inventory['episodes']},
            'fingerprints': {e['file']: {'size': e['size'], 'mtime': e['mtime']} for e in inventory['episodes']}}
        reports.append({'id': show['id'], 'title': show['title'], 'episodes': len(inventory['episodes']),
                        'durationsReady': sum(e['duration'] > 0 for e in inventory['episodes']), 'ignored': inventory['ignored']})
    # Publish cache first, then the registry; running VLC sees a complete update.
    atomic_json(profile / 'library-cache.json', cache)
    doc['revision'] = uuid.uuid4().hex
    atomic_json(profile / 'libraries.json', doc)
    return reports


def get_series(profile, identifier):
    for show in registry(profile)['libraries']:
        if show['id'] == identifier:
            return show
    raise ValueError(f'Не найден сериал {identifier}; используйте list')


def valid_marker(value, entry):
    if not isinstance(value, dict) or value.get('verified') is not True:
        return False
    if any(value.get(k) != entry[k] for k in ('file', 'size', 'mtime')):
        return False
    finite = lambda n: isinstance(n, (int, float)) and not isinstance(n, bool) and math.isfinite(n) and abs(n) < 1e12
    duration = value.get('duration')
    if not finite(duration) or duration <= 0 or (entry['duration'] > 0 and abs(duration-entry['duration']) > 2):
        return False
    intro, credits = value.get('intro'), value.get('credits')
    if intro is not None:
        if not isinstance(intro, dict) or not all(finite(intro.get(k)) for k in ('start', 'skipTo', 'finish')):
            return False
        a, b, c = (intro[k] for k in ('start', 'skipTo', 'finish'))
        if not (0 <= a < b < c < duration and c-b <= 5):
            return False
    if credits is not None:
        if not isinstance(credits, dict) or not all(finite(credits.get(k)) for k in ('start', 'nextAt')):
            return False
        a, b = (credits[k] for k in ('start', 'nextAt'))
        if not (0 <= a <= b < duration and b-a <= 5) or (intro is not None and intro['finish'] >= a):
            return False
    return True


def marker_command(args):
    show = get_series(args.profile, args.series)
    inventory = scan(show['root'], durations=True)
    if inventory['duplicates']:
        raise ValueError('Сначала устраните повторяющиеся номера серий')
    path = Path(show['root']) / 'markers.json'
    doc = read_json(path, {'version': 1, 'episodes': {}})
    if doc.get('version') != 1 or not isinstance(doc.get('episodes'), dict):
        raise ValueError('Некорректный markers.json; файл не перезаписан')
    if args.marker_action == 'init':
        for e in inventory['episodes']:
            if e['key'] not in doc['episodes']:
                doc['episodes'][e['key']] = {k: e[k] for k in ('file', 'size', 'mtime', 'duration')}
                doc['episodes'][e['key']].update(verified=False, intro=None, credits=None)
        atomic_json(path, doc, 0o644)
    elif args.marker_action == 'set':
        e = next((e for e in inventory['episodes'] if e['key'] == args.episode.lower()), None)
        if not e:
            raise ValueError('Не найдена серия')
        value = {k: e[k] for k in ('file', 'size', 'mtime', 'duration')}
        value.update(verified=True, intro=dict(zip(('start','skipTo','finish'), args.intro)) if args.intro else None,
                     credits=dict(zip(('start','nextAt'), args.credits)) if args.credits else None,
                     review={'method': 'frames', 'notes': args.notes})
        if not valid_marker(value, e):
            raise ValueError('Недопустимые границы или не определена длительность; файл не изменён')
        doc['episodes'][e['key']] = value
        atomic_json(path, doc, 0o644)
    verified = [e['key'] for e in inventory['episodes'] if valid_marker(doc['episodes'].get(e['key']), e)]
    pending = [e['key'] for e in inventory['episodes'] if e['key'] not in verified]
    result = {'file': str(path), 'verified': len(verified), 'total': len(inventory['episodes']), 'pending': pending}
    if args.marker_action == 'validate' and pending:
        result['complete'] = False
    else:
        result['complete'] = not pending
    return result


def vlc_pids():
    result = subprocess.run(['pgrep', '-x', 'VLC'], capture_output=True, text=True)
    return result.stdout.strip().splitlines() if result.returncode == 0 else []


def install(profile, stage=False, port=8080):
    if sys.platform != 'darwin':
        raise ValueError('Установка поддерживается на macOS; тесты и индексатор работают и на других ОС')
    if not 1024 <= port <= 65535:
        raise ValueError('Порт должен быть от 1024 до 65535')
    from build_audio import build
    support = Path.home() / 'Library/Application Support/org.videolan.vlc'
    prefs = Path.home() / 'Library/Preferences/org.videolan.vlc/vlcrc'
    original = prefs.read_text() if prefs.exists() else ''
    active = lambda key: (re.search(r'^'+re.escape(key)+r'=(.*)$', original, re.M) or ['', ''])[1]
    running = vlc_pids()
    loader = support / 'lua/intf/sofa.lua'
    configured = 'luaintf{intf=sofa}' in active('extraintf') and str(profile) in active('lua-config') and loader.exists()
    if running and (not stage or not configured):
        raise ValueError('VLC открыт. Первую установку выполните после выхода из VLC; обновление настроенного пульта: install --stage. Воспроизведение не изменено.')
    if active('lua-intf') not in ('', 'dummy', 'sofa') or (active('lua-config') and not active('lua-config').startswith('sofa=')):
        raise ValueError('Обнаружена другая Lua-конфигурация; сохраните её перед установкой')
    profile.mkdir(parents=True, exist_ok=True, mode=0o700); profile.chmod(0o700)
    if original and not (profile/'vlcrc.before-sofa').exists():
        (profile/'vlcrc.before-sofa').write_text(original); (profile/'vlcrc.before-sofa').chmod(0o600)
    build(profile/'sofa-audio')
    files = [SOURCE/name for name in MODULES] + list((SOURCE/'web').iterdir())
    for src in files:
        if not src.is_file():
            continue
        dest = profile/src.relative_to(SOURCE); dest.parent.mkdir(parents=True, exist_ok=True)
        temp = dest.with_name(dest.name+'.install-tmp'); shutil.copy2(src,temp); os.replace(temp,dest)
    settings = read_json(profile/'settings.json')
    fresh = settings is None
    if fresh:
        hostname = subprocess.check_output(['scutil','--get','LocalHostName'], text=True).strip()+'.local'
        settings = {'port':port, 'hostname':hostname, 'pattern':'-'.join(secrets.SystemRandom().sample(list(PICTURES),3))}
        atomic_json(profile/'settings.json',settings)
    if not (profile/'sessions.json').exists():
        atomic_json(profile/'sessions.json',{})
    atomic_json(profile/'source.json', {'path':str(SOURCE), 'version':VERSION})
    if not running:
        loader.parent.mkdir(parents=True,exist_ok=True)
        loader.write_text('assert(config.root)\ndofile(config.root .. "/sofa.lua")\n')
        loader.with_name('sofa_tracker.lua').write_text('assert(config.root)\ndofile(config.root .. "/tracker.lua")\n')
        extra = [s for s in active('extraintf').split(':') if s and s not in ('luaintf','luaintf{intf=sofa}','luaintf{intf=sofa_tracker}')]
        extra.extend(['luaintf{intf=sofa}','luaintf{intf=sofa_tracker}'])
        updates = {'extraintf':':'.join(extra),'lua-intf':'sofa',
                   'lua-config':','.join(name+'={root='+json.dumps(str(profile))+'}' for name in ('sofa','sofa_tracker'))}
        text=original
        for key,value in updates.items():
            pattern=r'^#?'+re.escape(key)+r'=.*$'
            text=re.sub(pattern,lambda _:key+'='+value,text,flags=re.M) if re.search(pattern,text,re.M) else text+'\n'+key+'='+value+'\n'
        prefs.parent.mkdir(parents=True,exist_ok=True)
        temp=prefs.with_suffix('.sofa-tmp');temp.write_text(text);temp.chmod(0o600);os.replace(temp,prefs)
    result={'installed':str(profile),'version':VERSION,'restartRequired':bool(running)}
    if fresh:
        result['login']=' → '.join(PICTURES[p] for p in settings['pattern'].split('-'))
    return result


def doctor(profile, check_auth=False):
    settings=read_json(profile/'settings.json',{})
    port=settings.get('port',8080)
    report={'version':VERSION, 'installed':(profile/'sofa.lua').exists(),
            'ffmpeg':bool(shutil.which('ffmpeg')),'ffprobe':bool(shutil.which('ffprobe')),
            'vlcInstalled':Path('/Applications/VLC.app').exists(), 'urls':[], 'service':None}
    if sys.platform=='darwin':
        for interface in ('en0','en1','en2','en3','en4'):
            r=subprocess.run(['/usr/sbin/ipconfig','getifaddr',interface],capture_output=True,text=True)
            ip=r.stdout.strip()
            if r.returncode==0 and re.fullmatch(r'\d+\.\d+\.\d+\.\d+',ip):report['urls'].append(f'http://{ip}:{port}/')
    if settings.get('hostname'):report['urls'].append(f"http://{settings['hostname']}:{port}/")
    base=f'http://127.0.0.1:{port}'
    try:
        with urllib.request.urlopen(base+'/health',timeout=3) as r: report['service']=json.load(r)
    except (OSError,ValueError):
        report['note']='Новая версия не отвечает: VLC закрыт, требуется первый перезапуск или порт занят.'
    if check_auth and report['service'] and report['service'].get('apiVersion')==2:
        def api(payload):
            req=urllib.request.Request(base+'/api',data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})
            with urllib.request.urlopen(req,timeout=4) as response:return json.load(response)
        token=None
        try:
            login=api({'action':'login','pattern':settings['pattern']});token=login['token']
            lib=api({'action':'library','token':token})
            report['authenticated']=True;report['series']=lib['series']
            report['state']=login['status']['state']
        finally:
            if token:api({'action':'logout','token':token})
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile',type=Path,default=DEFAULT_PROFILE,help='Папка приватных данных пульта')
    subs=parser.add_subparsers(dest='command',required=True)
    p=subs.add_parser('install');p.add_argument('--stage',action='store_true');p.add_argument('--port',type=int,default=8080)
    p=subs.add_parser('scan');p.add_argument('folder',type=Path);p.add_argument('--durations',action='store_true')
    p=subs.add_parser('add');p.add_argument('folder',type=Path);p.add_argument('--title');p.add_argument('--id');p.add_argument('--collection',action='store_true')
    subs.add_parser('list')
    p=subs.add_parser('doctor');p.add_argument('--check-auth',action='store_true')
    subs.add_parser('access')
    p=subs.add_parser('frames');p.add_argument('series');p.add_argument('episode');p.add_argument('--times',required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--width',type=int,default=256)
    p=subs.add_parser('markers');m=p.add_subparsers(dest='marker_action',required=True)
    for name in ('init','validate','set'):
        q=m.add_parser(name);q.add_argument('series')
        if name=='set':
            q.add_argument('episode');q.add_argument('--intro',type=float,nargs=3,metavar=('START','SKIP_TO','FINISH'))
            q.add_argument('--credits',type=float,nargs=2,metavar=('START','NEXT_AT'))
            q.add_argument('--notes',required=True,help='Какие кадры проверены; для отсутствующих сегментов укажите причину')
    args=parser.parse_args(argv);args.profile=args.profile.expanduser().resolve()
    try:
        if args.command=='install':result=install(args.profile,args.stage,args.port)
        elif args.command=='scan':result=scan(args.folder,args.durations)
        elif args.command=='add':
            folder=args.folder.expanduser().resolve()
            if args.collection:
                if args.title or args.id:raise ValueError('--title и --id доступны для одного сериала')
                if not folder.is_dir():raise ValueError('Нет папки коллекции')
                folders=[p for p in sorted(folder.iterdir()) if p.is_dir() and not p.is_symlink() and not p.name.startswith('.') and scan(p)['episodes']]
                if not folders:raise ValueError('В дочерних папках не найдены сериалы')
            else:folders=[folder]
            result=add_series(args.profile,folders,args.title,args.id)
        elif args.command=='list':result=registry(args.profile)
        elif args.command=='doctor':result=doctor(args.profile,args.check_auth)
        elif args.command=='access':
            settings=read_json(args.profile/'settings.json',{})
            result={'login':' → '.join(PICTURES[p] for p in settings.get('pattern','').split('-') if p in PICTURES),'urls':doctor(args.profile)['urls']}
        elif args.command=='frames':
            from tools.frames import make_sheet
            result=make_sheet(args)
        else:result=marker_command(args)
        print(json.dumps(result,ensure_ascii=False,indent=2,allow_nan=False))
        return 1 if args.command=='markers' and args.marker_action=='validate' and not result['complete'] else 0
    except (ValueError,OSError,subprocess.SubprocessError,KeyError) as e:
        parser.exit(1,f'Ошибка: {e}\n')


if __name__=='__main__':
    raise SystemExit(main())
