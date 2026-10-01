"""Opt-in integration: isolated VLC, synthetic media, private data and a random port."""
from pathlib import Path
import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import uuid
import sofa

VLC=Path('/Applications/VLC.app/Contents/MacOS/VLC')

@unittest.skipUnless(os.environ.get('SOFA_TEST_VLC')=='1' and VLC.exists(),'set SOFA_TEST_VLC=1 on a Mac with VLC and ffmpeg')
class VLCTests(unittest.TestCase):
    def test_catalog_switching_live_markers_and_readonly_timeline(self):
        source=Path(__file__).resolve().parents[1]
        created=[];process=None
        with tempfile.TemporaryDirectory(prefix='sofa-integration-') as temp:
            root=Path(temp).resolve();profile=root/'profile';profile.mkdir()
            for name in sofa.MODULES:shutil.copy2(source/name,profile/name)
            shutil.copytree(source/'web',profile/'web')
            media=root/'blank.mp4'
            subprocess.run(['ffmpeg','-v','error','-nostdin','-f','lavfi','-i','color=black:s=160x90:r=5','-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-t','90','-c:v','libx264','-preset','ultrafast','-c:a','aac','-threads','1',str(media)],check=True,capture_output=True)
            for show,episode in [('one',1),('one',2),('two',1)]:
                folder=root/show;folder.mkdir(exist_ok=True);os.link(media,folder/f'Example.S01E{episode:02}.mp4')
            sofa.add_series(profile,[root/'one'],title='First show',series_id='one')
            sofa.add_series(profile,[root/'two'],title='Second show',series_id='two')
            entries=sofa.scan(root/'one',durations=True)['episodes']
            def marker(entry,intro,credits):
                return {**{k:entry[k] for k in ['file','size','mtime','duration']},'verified':True,'intro':intro,'credits':credits}
            intro={'start':0,'skipTo':3,'finish':6};credit={'start':80,'nextAt':82}
            sofa.atomic_json(root/'one/markers.json',{'version':1,'episodes':{entries[0]['key']:marker(entries[0],intro,credit)}})
            sofa.atomic_json(profile/'progress.json',{'version':1,'continueId':'one:s01e01','episodes':{'one:s01e01':{'ranges':[[20,83]],'resume':83,'duration':90,'meaningfulAt':1000}}})
            with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
            pattern=uuid.uuid4().hex
            sofa.atomic_json(profile/'settings.json',{'port':port,'hostname':'localhost','pattern':pattern})
            interface=Path.home()/'Library/Application Support/org.videolan.vlc/lua/intf';interface.mkdir(parents=True,exist_ok=True)
            names=['sofa_test_'+uuid.uuid4().hex[:10],'sofa_track_'+uuid.uuid4().hex[:10]]
            for name,module in zip(names,['sofa.lua','tracker.lua']):
                loader=interface/(name+'.lua');loader.write_text('dofile(config.root .. "/'+module+'")\n');created.append(loader)
            conf=','.join(n+'={root='+json.dumps(str(profile))+',host="127.0.0.1",port='+str(port)+'}' for n in names)
            log=(root/'vlc.log').open('w');token=''
            def api(action,**extra):
                payload={'action':action,'token':token,'requestId':uuid.uuid4().hex,**extra}
                request=urllib.request.Request(f'http://127.0.0.1:{port}/api',data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})
                with urllib.request.urlopen(request,timeout=4) as response:return json.load(response)
            def eventually(predicate):
                end=time.monotonic()+5;state=None
                while time.monotonic()<end:
                    state=api('status')
                    if predicate(state):return state
                    time.sleep(.1)
                self.fail(f'Timeout: {state}')
            try:
                process=subprocess.Popen([str(VLC),'--ignore-config','-I','dummy','--extraintf',':'.join('luaintf{intf='+n+'}' for n in names),'--lua-config',conf,'--no-video','--aout','dummy','--no-volume-save','--no-metadata-network-access',str(root/'one'/entries[0]['file'])],stdout=log,stderr=log)
                for _ in range(50):
                    try:token=api('login',pattern=pattern)['token'];break
                    except OSError:time.sleep(.1)
                self.assertTrue(token)
                state=eventually(lambda s:s.get('seriesId')=='one' and s['time']>=3)
                self.assertLess(state['time'],10)
                one=api('library',seriesId='one');two=api('library',seriesId='two')
                self.assertEqual([s['count'] for s in one['series']],[2,1])
                self.assertEqual(one['episodes'][0]['id'],'one:s01e01');self.assertEqual(two['episodes'][0]['id'],'two:s01e01')
                self.assertEqual(one['continueId'],'one:s01e01');self.assertNotIn('continueId',two)
                api('toggle');eventually(lambda s:s['state']=='paused');before=api('status')['time']
                with self.assertRaises(urllib.error.HTTPError) as rejected:api('scrub',value=70)
                self.assertEqual(json.load(rejected.exception)['error'],'timeline_read_only');rejected.exception.close()
                self.assertAlmostEqual(api('status')['time'],before,delta=.2)
                api('seek',delta=5);eventually(lambda s:abs(s['time']-before-5)<.3)
                api('play_episode',id='two:s01e01');eventually(lambda s:s.get('seriesId')=='two' and s['state']=='playing')
                with self.assertRaises(urllib.error.HTTPError) as rejected:api('next')
                self.assertEqual(json.load(rejected.exception)['error'],'last_episode');rejected.exception.close()
                e=sofa.scan(root/'two',durations=True)['episodes'][0]
                sofa.atomic_json(root/'two/markers.json',{'version':1,'episodes':{e['key']:marker(e,{'start':0,'skipTo':8,'finish':11},None)}})
                state=eventually(lambda s:s['time']>=8 and s['marked']);self.assertLess(state['time'],14)
                # Returning to the saved late bookmark triggers credits -> same-series E02.
                api('play_episode',id='one:s01e01');state=eventually(lambda s:s.get('episodeId')=='one:s01e02')
                self.assertEqual(state['seriesId'],'one')
                (root/'three').mkdir();os.link(media,root/'three/Example.S02E01.mp4')
                sofa.add_series(profile,[root/'three'],title='Third show',series_id='three')
                self.assertEqual(len(api('library',seriesId='three')['series']),3)
                self.assertEqual(api('library',seriesId='three')['episodes'][0]['id'],'three:s02e01')
                api('logout')
            except Exception:
                log.flush();print((root/'vlc.log').read_text()[-3000:]);raise
            finally:
                if process:
                    process.terminate()
                    try:process.wait(timeout=5)
                    except subprocess.TimeoutExpired:process.kill();process.wait()
                log.close()
                for path in created:path.unlink(missing_ok=True)
