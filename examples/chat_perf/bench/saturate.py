#!/usr/bin/env python3
# One-shot saturating benchmark orchestrator: starts the chat server,
# samples server AND loader CPU during the run, runs wload.erl, tears down.
# No shell backgrounding (sandbox-safe shape); needs unsandboxed network.
import json
import os
import subprocess
import sys
import threading
import time
import urllib.request

BENCH = "/var/folders/m3/_sxhj6qs5zg90_0qksc_hchr0000gn/T/opencode/chat-bench"
REPO = "/Users/akos/Devel/rodolfo"
APP = os.environ.get("APP", "chat_perf")
PORT = int(os.environ.get("PORT", "3800"))
N = int(os.environ.get("N", "1000"))
PROTO = os.environ.get("PROTO", "delta")
SENDERS = int(os.environ.get("SENDERS", "20"))
SOAK = int(os.environ.get("SOAK", "12"))
FLOOD = int(os.environ.get("FLOOD", "200"))
PAYLOAD = int(os.environ.get("PAYLOAD", "1024"))
PACED = int(os.environ.get("PACED", "10"))
RUNG = os.environ.get("RUNG", str(N))
WAVE = int(os.environ.get("WAVE", "0"))
WAVEGAP = int(os.environ.get("WAVEGAP", "0"))
SYNC = os.environ.get("SYNC", "")
TIMEOUT = int(os.environ.get("TIMEOUT", "600"))


def sh(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def tree(pids):
    out, seen, stack = set(), set(pids), list(pids)
    while stack:
        p = stack.pop()
        if p in out:
            continue
        out.add(p)
        r = sh("pgrep", "-P", str(p))
        for line in r.stdout.split():
            try:
                q = int(line)
            except ValueError:
                continue
            if q not in out:
                stack.append(q)
    return sorted(out)


def cpu_sum(pids):
    if not pids:
        return 0.0
    r = sh("ps", "-o", "%cpu=", "-p", ",".join(map(str, pids)))
    total = 0.0
    for line in r.stdout.split():
        try:
            total += float(line.strip())
        except ValueError:
            pass
    return total


def listener_pids():
    r = sh("lsof", "-ti", f"tcp:{PORT}", "-sTCP:LISTEN")
    pids = []
    for line in r.stdout.split():
        try:
            pids.append(int(line.strip()))
        except ValueError:
            pass
    return pids


def loader_pids():
    r = sh("pgrep", "-f", "wload.erl")
    pids = []
    for line in r.stdout.split():
        try:
            pids.append(int(line.strip()))
        except ValueError:
            pass
    # exclude this orchestrator if it matched (it won't: pattern is wload.erl)
    return [p for p in pids if p != os.getpid()]


stop_flag = threading.Event()
server_cpu, loader_cpu = [], []


def sampler():
    while not stop_flag.is_set():
        srv = tree(listener_pids())
        if not srv:
            r = sh("pgrep", "-f", "beam")
            srv = [int(x) for x in r.stdout.split() if x.strip().isdigit()]
        server_cpu.append(cpu_sum(srv))
        loader_cpu.append(cpu_sum(tree(loader_pids())))
        time.sleep(0.2)


def main():
    log_path = os.path.join(BENCH, f"server-wload-{RUNG}.log")
    sh("bash", "-c", f"lsof -ti tcp:{PORT} | xargs kill 2>/dev/null; true")
    time.sleep(1)
    log = open(log_path, "w")
    env = dict(os.environ, PORT=str(PORT))
    # macOS default soft fd limit (256) caps both server and loader well
    # below 1000 connections; raise it for the whole process tree.
    srv = subprocess.Popen(["bash", "-c", "ulimit -n 65536 2>/dev/null || "
                                           "ulimit -n 10240; exec tey run"],
                           cwd=os.path.join(REPO, "examples", APP),
                           stdout=log, stderr=subprocess.STDOUT, env=env)
    try:
        ready = False
        for _ in range(120):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{PORT}/", timeout=1)
                ready = True
                break
            except Exception:
                time.sleep(0.5)
        if not ready:
            print("SERVER_FAILED_TO_START")
            srv.terminate()
            print(open(log_path).read()[-3000:])
            return 1
        t = threading.Thread(target=sampler, daemon=True)
        t.start()
        if os.environ.get("PROBE"):
            r = subprocess.run(["escript", os.path.join(BENCH, "wload.erl"),
                                "--port", str(PORT), "--probe"],
                               capture_output=True, text=True, timeout=60)
            stop_flag.set()
            print(r.stdout.strip() or "(no stdout)")
            print("STDERR:", r.stderr.strip()[-1000:], file=sys.stderr)
            return 0
        args = ["escript", os.path.join(BENCH, "wload.erl"),
                "--port", str(PORT), "--clients", str(N), "--rung", str(RUNG),
                "--proto", PROTO, "--senders", str(SENDERS),
                "--flood", str(FLOOD), "--payload", str(PAYLOAD),
                "--paced", str(PACED)]
        if SOAK > 0:
            args += ["--soak", str(SOAK)]
        if WAVE > 0:
            args += ["--wave", str(WAVE), "--wavegap", str(WAVEGAP)]
        if SYNC in ("1", "true", "yes"):
            args += ["--sync"]
        err_path = os.path.join(BENCH, f"bench-wload-{RUNG}.err")
        elog = open(err_path, "w")
        # stderr streams to disk so phase logs survive even a timeout kill.
        # Loader gets the raised fd limit too (1000 sockets + beams).
        import shlex
        loader_cmd = ("ulimit -n 65536 2>/dev/null || ulimit -n 10240; exec "
                      + " ".join(shlex.quote(a) for a in args))
        proc = subprocess.Popen(["bash", "-c", loader_cmd],
                                stdout=subprocess.PIPE, stderr=elog, text=True)
        try:
            out, _ = proc.communicate(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill()
            out, _ = proc.communicate()
            print(f"WLOAD TIMED OUT after {TIMEOUT}s; phase log so far:")
        elog.close()
        r = proc
        r.stdout = out
        stop_flag.set()
        t.join(timeout=5)
        print(r.stdout.strip() or "(no stdout)")
        err = open(err_path).read().strip()
        if err:
            print("STDERR tail:", err[-1500:])
        try:
            d = json.loads(r.stdout.strip().splitlines()[-1])
            fl = d.get("flood") or {}
            print(f"flood: fanout={fl.get('fanout_deliveries_per_s')}/s "
                  f"wall={fl.get('wall_s')}s loss={fl.get('loss')} "
                  f"p50/p99={((fl.get('per_delivery_latency_ms') or {}).get('p50'))}/"
                  f"{((fl.get('per_delivery_latency_ms') or {}).get('p99'))}ms")
        except Exception as e:
            print(f"(unparseable output: {e})")
        if server_cpu:
            print(f"server beam%: avg={sum(server_cpu)/len(server_cpu):.0f} "
                  f"max={max(server_cpu):.0f} over {len(server_cpu)} samples")
        if loader_cpu:
            print(f"loader beam%: avg={sum(loader_cpu)/len(loader_cpu):.0f} "
                  f"max={max(loader_cpu):.0f} over {len(loader_cpu)} samples")
        return 0
    finally:
        stop_flag.set()
        srv.terminate()
        try:
            srv.wait(timeout=5)
        except subprocess.TimeoutExpired:
            srv.kill()
        sh("bash", "-c", f"lsof -ti tcp:{PORT} | xargs kill 2>/dev/null; true")
        log.close()


sys.exit(main())
