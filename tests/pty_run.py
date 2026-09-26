#!/usr/bin/env python3
"""Run a command inside a pseudo-terminal and script its interactive answers.

The plan is read from stdin, one directive per line:

    expect TEXT       wait until TEXT appears in the terminal output
    expect-not TEXT   fail if TEXT already appears in the terminal output
    secret TEXT       wait for TEXT, then require terminal echo to be disabled
    send VALUE        write VALUE and a newline to the terminal
    run COMMAND       command to execute (parsed with shlex), must come last

All terminal output is copied to stdout. The exit status is the child's exit
status, 124 when the plan times out, or 2 when the plan itself fails.
"""

import argparse
import os
import pty
import select
import shlex
import sys
import termios
import time


class PlanError(Exception):
    pass


class Terminal:
    def __init__(self, fd, timeout):
        self.fd = fd
        self.output = bytearray()
        self.deadline = time.time() + timeout
        self.eof = False

    def pump(self, duration=0.2):
        end = min(self.deadline, time.time() + duration)
        while time.time() < end:
            wait = max(0.0, min(0.05, end - time.time()))
            ready, _, _ = select.select([self.fd], [], [], wait)
            if not ready:
                continue
            try:
                data = os.read(self.fd, 4096)
            except OSError:
                self.eof = True
                return
            if not data:
                self.eof = True
                return
            self.output += data

    def wait_for(self, text):
        needle = text.encode()
        while needle not in self.output:
            if self.eof:
                raise PlanError("terminal closed before %r appeared" % text)
            if time.time() >= self.deadline:
                raise PlanError("timed out waiting for %r" % text)
            self.pump()

    def send_line(self, value):
        os.write(self.fd, value.encode() + b"\n")

    def require_echo_disabled(self, label):
        end = time.time() + 3.0
        while time.time() < end:
            if not (termios.tcgetattr(self.fd)[3] & termios.ECHO):
                return
            time.sleep(0.05)
        raise PlanError("terminal echo stayed enabled at %r" % label)

    def drain(self, duration=1.0):
        end = time.time() + duration
        while not self.eof and time.time() < end:
            self.pump(0.1)


def read_plan(stream):
    plan = []
    command = None
    for raw_line in stream:
        line = raw_line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        verb, _, payload = line.partition(" ")
        if verb == "run":
            command = shlex.split(payload)
            break
        if verb not in ("expect", "expect-not", "secret", "send"):
            raise PlanError("unknown directive %r" % verb)
        plan.append((verb, payload))
    if not command:
        raise PlanError("plan is missing a 'run' directive")
    return plan, command


def flush_output(terminal):
    sys.stdout.buffer.write(bytes(terminal.output))
    sys.stdout.buffer.flush()


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cwd", default=None)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args(argv)

    try:
        plan, command = read_plan(sys.stdin)
    except PlanError as error:
        print("pty_run: %s" % error, file=sys.stderr)
        return 2

    pid, fd = pty.fork()
    if pid == 0:
        if args.cwd:
            os.chdir(args.cwd)
        os.execvp(command[0], command)

    terminal = Terminal(fd, args.timeout)
    status = None
    try:
        for verb, payload in plan:
            if verb == "expect":
                terminal.wait_for(payload)
            elif verb == "expect-not":
                if payload.encode() in terminal.output:
                    raise PlanError("%r unexpectedly appeared" % payload)
            elif verb == "secret":
                terminal.wait_for(payload)
                terminal.require_echo_disabled(payload)
            elif verb == "send":
                terminal.send_line(payload)

        while True:
            done, wait_status = os.waitpid(pid, os.WNOHANG)
            if done == pid:
                status = wait_status
                break
            if time.time() >= terminal.deadline:
                raise PlanError("timed out waiting for the command to exit")
            terminal.pump()
    except PlanError as error:
        terminal.drain(0.3)
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        os.close(fd)
        flush_output(terminal)
        print("pty_run: plan failed: %s" % error, file=sys.stderr)
        return 2

    terminal.drain(0.2)
    os.close(fd)
    flush_output(terminal)

    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
