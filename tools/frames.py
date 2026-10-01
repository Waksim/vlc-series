"""Extract a contact sheet from files, without opening or seeking VLC."""
from pathlib import Path
import math
import shutil
import subprocess
import tempfile


def parse_times(spec, duration):
    times=[]
    for part in spec.split(','):
        values=[float(n) for n in part.split(':')]
        if not all(math.isfinite(n) for n in values):
            raise ValueError('Время должно быть конечным числом')
        if len(values)==1:
            times.extend(values)
        elif len(values)==3:
            start,stop,step=values
            if step<=0 or stop<start or (stop-start)/step>100:
                raise ValueError('Неверный диапазон времени или слишком много кадров')
            times.extend(start+i*step for i in range(math.ceil((stop-start)/step)))
        else:
            raise ValueError('Время: секунды через запятую или начало:конец:шаг')
    if not times or len(times)>100 or any(t<0 or t>=duration for t in times):
        raise ValueError('Нужно 1–100 кадров внутри длительности файла')
    return times


def make_sheet(args):
    from sofa import get_series, scan
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError as e:
        raise ValueError('Для контактного листа нужен Pillow: python3 -m pip install -r requirements-frames.txt') from e
    ffmpeg=shutil.which('ffmpeg')
    if not ffmpeg:
        raise ValueError('Не найден ffmpeg; установите FFmpeg')
    show=get_series(args.profile,args.series)
    inventory=scan(show['root'],durations=True)
    if inventory['duplicates']:
        raise ValueError('Неоднозначные номера серий; сначала исправьте каталог')
    entry=next((e for e in inventory['episodes'] if e['key']==args.episode.lower()),None)
    if not entry or entry['duration']<=0:
        raise ValueError('Серия или её длительность не найдена')
    if not 160<=args.width<=1280:
        raise ValueError('Ширина кадра должна быть 160–1280')
    times=parse_times(args.times,entry['duration'])
    video=Path(show['root'])/entry['file']
    output=args.output.expanduser().resolve();output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sofa-frames-') as temp:
        images=[]
        for i,t in enumerate(times):
            frame=Path(temp)/f'{i}.png'
            command=[ffmpeg,'-v','error','-nostdin','-threads','1','-ss',str(t),'-i',str(video),
                     '-an','-sn','-frames:v','1','-vf',f'scale={args.width}:-2','-threads','1',str(frame)]
            if shutil.which('nice'):
                command=['nice','-n','10',*command]
            subprocess.run(command,check=True,capture_output=True,timeout=40)
            with Image.open(frame) as im: images.append(im.convert('RGB'))
        height=max(im.height for im in images);columns=min(5,len(images));cell_height=height+30
        sheet=Image.new('RGB',(args.width*columns,cell_height*math.ceil(len(images)/columns)),(18,20,25))
        draw=ImageDraw.Draw(sheet);font=ImageFont.load_default()
        for i,(im,t) in enumerate(zip(images,times)):
            x=(i%columns)*args.width;y=(i//columns)*cell_height
            sheet.paste(im,(x,y+30));draw.text((x+6,y+8),f"{entry['key'].upper()}  {int(t//60):02}:{t%60:04.1f}  ({t:g}s)",font=font,fill='white')
        sheet.save(output)
    return {'output':str(output),'episode':entry['key'],'frames':len(times),'duration':entry['duration']}
