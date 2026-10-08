#!/usr/bin/python3
"""Local process fixture: validates service arguments without contacting a panel."""
import os
import signal
import sys
import time

assert sys.argv[1:] == ["--config", "/etc/XrayR/config.yml"]
assert os.getcwd() == "/usr/local/XrayR"
assert os.getuid() == 0
assert os.path.isfile(sys.argv[2])
with open("/run/xrayr-child.pid", "w", encoding="ascii") as stream:
    stream.write(str(os.getpid()))
print("fixture-started", flush=True)
print("fixture-stderr", file=sys.stderr, flush=True)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while True:
    time.sleep(1)
