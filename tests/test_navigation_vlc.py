"""Native Next/Previous regression: separate VLC, generated media, private queue."""
from pathlib import Path
import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.request
import uuid
import sofa

VLC = Path('/Applications/VLC.app/Contents/MacOS/VLC')
BRIDGE = '''
local json = require "dkjson"
local last
while true do
    local f = io.open(config.root .. "/native-request.json", "r")
    local request
    if f then request = json.decode(f:read("*a")); f:close() end
    if request and request.id ~= last then
        last = request.id
        if request.action == "next" or request.action == "previous" then
            local key = request.action == "next" and "key-next" or "key-prev"
            vlc.var.set(vlc.object.libvlc(), "key-action", vlc.misc.action_id(key))
        elseif request.action == "seek" then
            vlc.var.set(vlc.object.input(), "time", request.time * 1000000)
        end
        local queue = vlc.playlist.get("playlist")
        local paths = {}
        for _, node in ipairs(queue.children or {}) do paths[#paths+1] = node.path end
        local reply = {id=last, paths=paths, generation=vlc.playlist.current()}
        local out = assert(io.open(config.root .. "/native-reply.json.tmp", "w"))
        out:write(json.encode(reply)); out:close()
        os.rename(config.root .. "/native-reply.json.tmp", config.root .. "/native-reply.json")
    end
    vlc.misc.mwait(vlc.misc.mdate() + 50000)
end
'''


@unittest.skipUnless(os.environ.get('SOFA_TEST_VLC') == '1' and VLC.exists(),
                     'set SOFA_TEST_VLC=1 on a Mac with VLC and ffmpeg')
class NavigationVLCTests(unittest.TestCase):
    def test_native_keys_follow_catalog_and_restore_fresh_bookmarks(self):
        source = Path(__file__).resolve().parents[1]
        loaders, process = [], None
        with tempfile.TemporaryDirectory(prefix='sofa-navigation-') as temp:
            root = Path(temp).resolve()
            profile = root/'profile'; profile.mkdir()
            for name in sofa.MODULES: shutil.copy2(source/name, profile/name)
            shutil.copytree(source/'web', profile/'web')
            media = root/'blank.mp4'
            subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-f', 'lavfi', '-i',
                            'color=black:s=160x90:r=5', '-f', 'lavfi', '-i',
                            'anullsrc=r=48000:cl=stereo', '-t', '120', '-c:v', 'libx264',
                            '-preset', 'ultrafast', '-c:a', 'aac', '-threads', '1', str(media)],
                           check=True, capture_output=True)
            keys = ['s03e01', 's03e02', 's06e03', 's06e04', 's06e05', 's06e06']
            for show, episodes in [('one', keys), ('two', ['s01e01', 's01e02'])]:
                folder = root/show; folder.mkdir()
                for key in episodes: os.link(media, folder/f'Example.{key.upper()}.mp4')
                sofa.add_series(profile, [folder], title=show, series_id=show)
            history = {key: {'ranges': [[0, start]], 'resume': start,
                             'duration': 120, 'meaningfulAt': 1000}
                       for key, start in [('one:s06e03', 10), ('one:s06e05', 15),
                                          ('one:s06e06', 7), ('two:s01e01', 12)]}
            history['one:s06e04'] = {'ranges': [[0, 119]], 'resume': 90,
                                     'duration': 120, 'meaningfulAt': 1000}
            sofa.atomic_json(profile/'progress.json', {'version': 1, 'episodes': history})
            entry = next(e for e in sofa.scan(root/'one', durations=True)['episodes'] if e['key'] == 's06e04')
            marker = {**{k: entry[k] for k in ['file', 'size', 'mtime', 'duration']},
                      'verified': True, 'credits': {'start': 85, 'nextAt': 87}}
            sofa.atomic_json(root/'one/markers.json', {'version': 1, 'episodes': {'s06e04': marker}})
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
            pattern = uuid.uuid4().hex
            sofa.atomic_json(profile/'settings.json', {'port': port, 'pattern': pattern, 'hostname': 'localhost'})
            interface = Path.home()/'Library/Application Support/org.videolan.vlc/lua/intf'
            interface.mkdir(parents=True, exist_ok=True)
            names = ['sofa_nav_'+uuid.uuid4().hex[:10] for _ in range(3)]
            for name, module in zip(names, ['sofa.lua', 'tracker.lua', None]):
                loader = interface/(name+'.lua')
                loader.write_text('dofile(config.root .. "/'+module+'")\n' if module else BRIDGE)
                loaders.append(loader)
            conf = ','.join(n+'={root='+json.dumps(str(profile))+',host="127.0.0.1",port='+str(port)+'}' for n in names)
            token = ''
            def api(action, **extra):
                payload = {'action': action, 'token': token, 'requestId': uuid.uuid4().hex, **extra}
                req = urllib.request.Request(f'http://127.0.0.1:{port}/api', data=json.dumps(payload).encode(),
                                             headers={'Content-Type': 'application/json'})
                with urllib.request.urlopen(req, timeout=4) as response: return json.load(response)
            def eventually(predicate, timeout=6):
                end = time.monotonic()+timeout; state = None
                while time.monotonic() < end:
                    state = api('status')
                    if predicate(state): return state
                    time.sleep(.1)
                self.fail(f'Timeout: {state}')
            def native(action='snapshot', **extra):
                request = {'id': uuid.uuid4().hex, 'action': action, **extra}
                sofa.atomic_json(profile/'native-request.json', request)
                end = time.monotonic()+4
                while time.monotonic() < end:
                    reply = sofa.read_json(profile/'native-reply.json', {})
                    if reply.get('id') == request['id']: return reply
                    time.sleep(.05)
                self.fail('Native-key test bridge did not respond')
            def queue_is(show, expected):
                paths = native()['paths']
                return paths == [(root/show/f'Example.{key.upper()}.mp4').as_uri() for key in expected]
            log = (root/'vlc.log').open('w')
            try:
                process = subprocess.Popen([str(VLC), '--ignore-config', '-I', 'dummy', '--extraintf',
                    ':'.join('luaintf{intf='+n+'}' for n in names)+':hotkeys', '--lua-config', conf,
                    '--no-video', '--aout', 'dummy', '--no-volume-save', '--no-metadata-network-access',
                    str(root/'one/Example.S03E01.mp4')], stdout=log, stderr=log)
                for _ in range(50):
                    try: token = api('login', pattern=pattern)['token']; break
                    except OSError: time.sleep(.1)
                self.assertTrue(token)
                eventually(lambda s: s.get('episodeId') == 'one:s03e01' and queue_is('one', keys))
                api('play_episode', id='one:s06e03')
                eventually(lambda s: s.get('episodeId') == 'one:s06e03' and 10 <= s['time'] < 14 and queue_is('one', keys))
                native('next')
                eventually(lambda s: s.get('episodeId') == 'one:s06e04' and s['time'] < 4 and queue_is('one', keys))
                native('next')
                eventually(lambda s: s.get('episodeId') == 'one:s06e05' and 15 <= s['time'] < 19 and queue_is('one', keys))
                # Qualify a real visit and prove the return uses the newly saved point,
                # rather than the 15-second bookmark that existed when the queue was built.
                eventually(lambda s: sofa.read_json(profile/'progress.json')['episodes']['one:s06e05']['resume'] > 44,
                           timeout=36)
                fresh = sofa.read_json(profile/'progress.json')['episodes']['one:s06e05']['resume']
                native('next')
                eventually(lambda s: s.get('episodeId') == 'one:s06e06' and s['time'] >= 7 and queue_is('one', keys))
                native('previous')
                state = eventually(lambda s: s.get('episodeId') == 'one:s06e05' and s['time'] >= fresh-.5 and queue_is('one', keys))
                self.assertLess(state['time'], fresh+4)
                native('previous')
                eventually(lambda s: s.get('episodeId') == 'one:s06e04' and s['time'] >= 90 and queue_is('one', keys))
                time.sleep(1.2)
                self.assertEqual(api('status')['episodeId'], 'one:s06e04', 'Back into credits must not bounce forward')
                api('play_episode', id='one:s06e03', fromStart=True)
                eventually(lambda s: s.get('episodeId') == 'one:s06e03' and s['time'] < 4 and queue_is('one', keys))
                api('toggle'); eventually(lambda s: s['state'] == 'paused')
                before, generation = api('status')['time'], native()['generation']
                sofa.add_series(profile, [root/'one'], title='one', series_id='one')
                time.sleep(1.3)
                self.assertEqual(native()['generation'], generation, 'Queue refresh must preserve the input')
                self.assertEqual(api('status')['state'], 'paused')
                self.assertAlmostEqual(api('status')['time'], before, delta=.2)
                api('toggle'); native('seek', time=119)
                eventually(lambda s: s.get('episodeId') == 'one:s06e04' and s['time'] < 4 and queue_is('one', keys))
                api('play_episode', id='two:s01e01')
                eventually(lambda s: s.get('episodeId') == 'two:s01e01' and queue_is('two', ['s01e01', 's01e02']))
                native('next'); eventually(lambda s: s.get('episodeId') == 'two:s01e02' and queue_is('two', ['s01e01', 's01e02']))
                api('previous'); eventually(lambda s: s.get('episodeId') == 'two:s01e01' and s['time'] >= 12)
                api('next'); eventually(lambda s: s.get('episodeId') == 'two:s01e02' and queue_is('two', ['s01e01', 's01e02']))
                # VLC's manual Next wraps even with loop=off; it must stay in this
                # series. Natural EOF at the last episode must stop instead.
                native('next'); eventually(lambda s: s.get('episodeId') == 'two:s01e01')
                api('next'); eventually(lambda s: s.get('episodeId') == 'two:s01e02' and queue_is('two', ['s01e01', 's01e02']))
                native('seek', time=119); eventually(lambda s: s['state'] == 'stopped')
                api('logout')
            except Exception:
                log.flush(); print((root/'vlc.log').read_text()[-5000:]); raise
            finally:
                if process:
                    process.terminate()
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
                log.close()
                for loader in loaders: loader.unlink(missing_ok=True)
