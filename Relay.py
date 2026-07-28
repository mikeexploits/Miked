#!/usr/bin/env python3
"""
Miked relay — local WebSocket hub for the alt swarm.

Every account (main + bots) connects to ws://127.0.0.1:8080. When one sends
a message, the relay fans it out to every OTHER connected client. That's it —
a dumb, fast hub. Targeting ("to": "bot3") and dedupe are handled client-side
in Miked.Socket, so this stays simple.

Run it BEFORE executing Socket.lua on your accounts:
    pip install websockets
    python relay.py
"""

import asyncio
import json

import websockets

HOST = "127.0.0.1"
PORT = 8080

clients = set()


async def handler(ws, *_):          # *_ swallows the 'path' arg on older websockets versions
    clients.add(ws)
    print(f"[+] connected  ({len(clients)} online)")
    try:
        async for message in ws:
            # log a one-line summary if it's a Miked envelope
            try:
                env = json.loads(message)
                print(f"    {env.get('from', '?')} -> {env.get('to', 'all')}  [{env.get('t', '?')}]")
            except Exception:
                pass

            # fan out to everyone except the sender
            dead = []
            for c in clients:
                if c is not ws:
                    try:
                        await c.send(message)
                    except Exception:
                        dead.append(c)
            for d in dead:
                clients.discard(d)
    except websockets.ConnectionClosed:
        pass
    finally:
        clients.discard(ws)
        print(f"[-] disconnected  ({len(clients)} online)")


async def main():
    print(f"Miked relay listening on ws://{HOST}:{PORT}")
    print("Leave this window open. Ctrl+C to stop.\n")
    async with websockets.serve(handler, HOST, PORT):
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\nrelay stopped.")
