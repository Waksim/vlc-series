from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

@unittest.skipUnless(sys.platform=='darwin','CoreAudio is macOS-only')
class AudioTests(unittest.TestCase):
    def test_driver_contract_without_real_device_writes(self):
        root=Path(__file__).resolve().parents[1]
        clt=Path('/Library/Developer/CommandLineTools')
        compiler=[str(clt/'usr/bin/clang'),'-isysroot',str(clt/'SDKs/MacOSX.sdk')] if (clt/'usr/bin/clang').exists() else ['xcrun','clang']
        with tempfile.TemporaryDirectory() as temp:
            binary=Path(temp)/'test-audio'
            subprocess.run(compiler+['-fobjc-arc','-O2','-Wall','-Wextra','-framework','Foundation','-framework','CoreAudio','-framework','AudioToolbox',str(root/'tests/test_audio.m'),'-o',str(binary)],check=True,capture_output=True)
            run=subprocess.run([str(binary)],check=True,capture_output=True,text=True)
            self.assertIn('PASS 13 CoreAudio mock cases',run.stderr)
