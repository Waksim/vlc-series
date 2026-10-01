from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sofa

class InstallTests(unittest.TestCase):
    def test_first_install_and_staging_preserve_settings_and_history(self):
        with tempfile.TemporaryDirectory() as temp:
            home=Path(temp);profile=home/'custom-profile'
            def build(path):path.write_bytes(b'mock binary')
            with patch('sofa.sys.platform','darwin'),patch('sofa.Path.home',return_value=home),patch('build_audio.build',side_effect=build),patch('sofa.subprocess.check_output',return_value='Example-Mac\n'),patch('sofa.vlc_pids',return_value=[]):
                result=sofa.install(profile)
            self.assertFalse(result['restartRequired']);self.assertIn('login',result)
            prefs=home/'Library/Preferences/org.videolan.vlc/vlcrc'
            self.assertIn(str(profile),prefs.read_text())
            loader=home/'Library/Application Support/org.videolan.vlc/lua/intf/sofa.lua'
            self.assertTrue(loader.exists())
            settings=(profile/'settings.json').read_bytes();config=prefs.read_bytes()
            (profile/'progress.json').write_text('{"version":1,"episodes":{}}')
            history=(profile/'progress.json').read_bytes()
            with patch('sofa.sys.platform','darwin'),patch('sofa.Path.home',return_value=home),patch('build_audio.build',side_effect=build),patch('sofa.vlc_pids',return_value=['123']):
                staged=sofa.install(profile,stage=True)
            self.assertTrue(staged['restartRequired']);self.assertNotIn('login',staged)
            self.assertEqual(prefs.read_bytes(),config);self.assertEqual((profile/'settings.json').read_bytes(),settings)
            self.assertEqual((profile/'progress.json').read_bytes(),history)
    def test_running_unconfigured_vlc_is_not_changed(self):
        with tempfile.TemporaryDirectory() as temp:
            home=Path(temp);profile=home/'profile'
            with patch('sofa.sys.platform','darwin'),patch('sofa.Path.home',return_value=home),patch('sofa.vlc_pids',return_value=['123']):
                with self.assertRaises(ValueError):sofa.install(profile,stage=True)
            self.assertFalse(profile.exists())
