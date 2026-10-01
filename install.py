#!/usr/bin/env python3
"""Compatibility entry point. See `python3 sofa.py install --help`."""
import sys
from sofa import main
if __name__ == '__main__':
    raise SystemExit(main(['install', *sys.argv[1:]]))
