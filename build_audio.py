"""Build the CoreAudio helper with the installed Apple command line tools."""
from pathlib import Path
import subprocess


def build(destination):
    source = Path(__file__).resolve().with_name('audio.m')
    clt = Path('/Library/Developer/CommandLineTools')
    if (clt / 'usr/bin/clang').exists():
        compiler = [str(clt / 'usr/bin/clang'), '-isysroot', str(clt / 'SDKs/MacOSX.sdk')]
    else:
        compiler = ['/usr/bin/xcrun', 'clang']
    target = Path(destination)
    temporary = target.with_suffix('.tmp')
    subprocess.run(compiler + ['-fobjc-arc', '-O2', '-Wall', '-Wextra',
                   '-framework', 'Foundation', '-framework', 'CoreAudio',
                   '-framework', 'AudioToolbox', str(source), '-o', str(temporary)], check=True)
    temporary.chmod(0o755)
    temporary.replace(target)


if __name__ == '__main__':
    build(Path(__file__).resolve().with_name('sofa-audio'))
