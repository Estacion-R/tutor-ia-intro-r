#!/usr/bin/env python3
"""Postea mensaje al canal Discord #pedagogía vía bot dedicado de OpenClaw.

Lee secrets.env (DISCORD_BOT_TOKEN_PEDAGOGIA), invoca lib.discord_post.
Discord limita mensajes a 2000 chars; mensajes más largos se parten.

Uso desde shell:
    echo "mensaje" | python3 tools/post-pedagogia.py
    python3 tools/post-pedagogia.py < archivo.md
"""
import os
import sys

# Cargar tokens de OpenClaw
sys.path.insert(0, os.path.expanduser("~/.openclaw/workers"))
from lib.estacion_r_auth import load_secrets  # noqa: E402
load_secrets()

from lib.discord_post import post_to_channel  # noqa: E402

CHANNEL_ID = "1492495531555950723"  # #pedagogía
MAX_CHARS = 1900  # buffer bajo el límite Discord 2000

def main():
    content = sys.stdin.read().strip()
    if not content:
        print("(stdin vacío, no posteo)", file=sys.stderr)
        return 1

    # Partir en chunks si excede el límite
    chunks = []
    while content:
        if len(content) <= MAX_CHARS:
            chunks.append(content)
            break
        # Cortar en el último salto de línea antes del límite
        cut = content.rfind("\n", 0, MAX_CHARS)
        if cut == -1:
            cut = MAX_CHARS
        chunks.append(content[:cut])
        content = content[cut:].lstrip()

    for i, chunk in enumerate(chunks):
        status = post_to_channel(CHANNEL_ID, chunk)
        suffix = f" ({i+1}/{len(chunks)})" if len(chunks) > 1 else ""
        print(f"Posted chunk{suffix} · status={status} · len={len(chunk)}",
              file=sys.stderr)
    return 0

if __name__ == "__main__":
    sys.exit(main())
