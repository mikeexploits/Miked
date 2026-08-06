#!/usr/bin/env python3
"""
Miked relay — local WebSocket hub for the alt swarm.

Every account (main + bots) connects to ws://127.0.0.1:8080. When one sends
a message, the relay fans it out to every OTHER connected client. Targeting
("to": "bot3") and dedupe are handled client-side in Miked.Socket, so this
stays a dumb, fast hub.

Fanout never blocks. Each client owns an outbound queue drained by its own
writer task, so one laggy account can only ever stall itself.

    pip install websockets
    python Relay.py            # log every message
    python Relay.py -q         # connects + warnings only (fastest)
"""

import asyncio
import json
import sys

import websockets

HOST = "127.0.0.1"
PORT = 8080

# How many messages may pile up for one client before we start dropping its
# oldest. 16 accounts at ~20 msgs/sec each: roughly a second of slack.
QUEUE_MAX = 256

# Per-message logging costs a json parse AND a stdout write on every packet.
# Under 16 accounts that is the single most expensive thing the relay does.
QUIET = any(a in ("-q", "--quiet") for a in sys.argv[1:])

clients: dict = {}          # ws -> asyncio.Queue


async def writer(ws, q):
    """Drains one client's queue. Owns every send to that socket."""
    try:
        while True:
            message = await q.get()
            if message is None:              # shutdown sentinel
                return
            await ws.send(message)
    except Exception:
        pass                                 # handler's finally does cleanup


def fanout(message, sender):
    """Non-blocking. Never awaits, so `clients` cannot mutate underneath it."""
    dropped = 0
    for c, q in list(clients.items()):
        if c is sender:
            continue
        if q.full():
            try:
                q.get_nowait()               # shed the oldest, keep the newest
                dropped += 1
            except asyncio.QueueEmpty:
                pass
        try:
            q.put_nowait(message)
        except asyncio.QueueFull:
            dropped += 1
    return dropped


async def handler(ws, *_):      # *_ swallows the 'path' arg on older websockets
    q = asyncio.Queue(maxsize=QUEUE_MAX)
    clients[ws] = q
    task = asyncio.create_task(writer(ws, q))
    print(f"[+] connected  ({len(clients)} online)")
    try:
        async for message in ws:
            if not QUIET:
                try:
                    env = json.loads(message)
                    print(f"    {env.get('from', '?')} -> {env.get('to', 'all')}"
                          f"  [{env.get('t', '?')}]")
                except Exception:
                    pass

            dropped = fanout(message, ws)
            if dropped:
                print(f"    ! {dropped} dropped - a client is backed up")
    except websockets.ConnectionClosed:
        pass
    except Exception as e:
        print(f"    ! {type(e).__name__}: {e}")
    finally:
        clients.pop(ws, None)
        try:
            q.put_nowait(None)               # let the writer finish what it has
        except asyncio.QueueFull:
            pass                             # backed up: the timeout kills it
        try:
            await asyncio.wait_for(task, timeout=1.0)
        except (asyncio.TimeoutError, asyncio.CancelledError):
            task.cancel()
        print(f"[-] disconnected  ({len(clients)} online)")


async def main():
    print(f"Miked relay listening on ws://{HOST}:{PORT}")
    if QUIET:
        print("quiet mode - only connects and warnings")
    print("Leave this window open. Ctrl+C to stop.\n")
    async with websockets.serve(handler, HOST, PORT,
                                ping_interval=20, ping_timeout=60):
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nrelay stopped.")
    except OSError as e:
        if getattr(e, "errno", None) in (48, 98, 10048) or "10048" in str(e):
            print(f"\nport {PORT} is already in use - an older relay is still")
            print("running. close it (Task Manager -> python.exe) and retry.")
        else:
            raise
