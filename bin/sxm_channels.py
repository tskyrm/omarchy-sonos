#!/usr/bin/env python3
"""Build the SiriusXM channel list from siriusxm.com/channels.

The public lineup page embeds every channel's data (Next.js flight
payload), including the same channel UUID Sonos uses in
x-sonosapi-stream:channel-linear:<uuid> URIs. Prints JSON:
[{"uuid", "name", "number", "genre", "category", "logo"}], sorted by
channel number. Usage: sxm_channels.py [saved-page.html]
"""

import html
import json
import re
import sys
import urllib.request

URL = "https://www.siriusxm.com/channels"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"


def fetch():
    req = urllib.request.Request(URL, headers={"User-Agent": UA, "Accept-Language": "en-US"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read().decode("utf-8", "replace")


def enclosing_object(text, pos):
    """Start/end of the innermost {...} containing pos (strings ignored)."""
    depth = 0
    i = pos
    while i > 0:
        i -= 1
        c = text[i]
        if c == "}":
            depth += 1
        elif c == "{":
            if depth == 0:
                break
            depth -= 1
    start = i
    depth = 0
    in_str = False
    j = start
    while j < len(text):
        c = text[j]
        if in_str:
            if c == "\\":
                j += 2
                continue
            if c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return start, j + 1
        j += 1
    return start, None


def channels(page):
    # The payload is JSON inside JS string literals; undo one level of escaping.
    text = page.replace('\\"', '"').replace("\\\\", "\\")
    seen = {}
    for m in re.finditer(r'"uuid":"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"', text):
        start, end = enclosing_object(text, m.start())
        if end is None:
            continue
        try:
            obj = json.loads(text[start:end])
        except ValueError:
            continue
        if obj.get("channel_type") != "Linear" or not obj.get("displayName"):
            continue
        uuid = obj["uuid"]
        number = obj.get("streamingChannelNumber") or obj.get("siriusChannelNumber") or obj.get("xmChannelNumber")
        try:
            number = int(number)
        except (TypeError, ValueError):
            number = None
        logo = obj.get("colorLogo") or ""
        if isinstance(logo, dict):
            logo = logo.get("url", "")
        if logo.startswith("/"):
            logo = "https://www.siriusxm.com" + logo
        seen[uuid] = {
            "uuid": uuid,
            "name": html.unescape(obj["displayName"]),
            "number": number,
            "genre": obj.get("genreTitle") or "",
            "category": obj.get("categoryTitle") or "",
            "logo": logo,
        }
    return sorted(seen.values(), key=lambda c: (c["number"] is None, c["number"] or 0, c["name"].lower()))


if __name__ == "__main__":
    page = open(sys.argv[1], encoding="utf-8").read() if len(sys.argv) > 1 else fetch()
    json.dump(channels(page), sys.stdout, ensure_ascii=False)
