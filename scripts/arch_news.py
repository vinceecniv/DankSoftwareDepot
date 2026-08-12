#!/usr/bin/env python3
"""Arch Linux news, for the distributions that publish it.

Arch is the one distribution in scope that announces, in prose and ahead of
time, that an update needs something done by hand: a key imported, a config
moved, a package replaced before the rest will resolve. The feed at
archlinux.org/feeds/news is where that is said, and it is what `informant` and
the various pacman hooks read. A software centre that updates an Arch system
without ever mentioning it is hiding the one thing the distribution went out
of its way to tell you.

Two decisions worth stating, because they are the difference between this
being useful and being noise:

* Only unread items are worth interrupting for. The feed always has something
  in it; that something is usually months old and already acted on. What is
  shown is what has appeared since the last time these were read.

* Items are kept rather than mirrored. The feed is a window of the most recent
  announcements, so a mirror would quietly lose the one from last spring that
  explains the state the machine is in now. Everything seen is stored, and the
  archive only grows (to a cap of KEEP_ITEMS, which is years of Arch news).

Read state lives in XDG_DATA_HOME next to the action log, not in the cache:
"I have read this" is not something to lose when a cache is cleared.

Modes (NDJSON-free, one JSON document per call):

    arch_news.py --list [--refresh]   items, newest first, each with `unread`
    arch_news.py --mark-read <id>...  mark specific items read
    arch_news.py --mark-all-read      mark everything currently stored read
"""

import html as htmlmod
import json
import os
import re
import sys
import time
from html.parser import HTMLParser

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pkg_backend  # noqa: E402

FEED_URL = "https://archlinux.org/feeds/news/"
USER_AGENT = "dankSoftwareDepot/0.1"
FETCH_TIMEOUT = 15
# The feed is announcements, not a timeline: checking it more often than a
# few times a day tells you nothing new and costs somebody bandwidth.
MAX_AGE = 6 * 3600
KEEP_ITEMS = 200

DATA_DIR = os.path.join(
    os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
    "dankSoftwareDepot")
DATA_FILE = os.path.join(DATA_DIR, "news-arch.json")


def supported():
    """Only the Arch family publishes a feed of this kind."""
    return pkg_backend.detect() == "pacman"


# ── Turning an announcement into something safe to render ────────────────────
# Same rule as everywhere else in this plugin: nothing external reaches the Qt
# rich-text renderer with its markup intact. The subset here is a little wider
# than the AppStream one because an Arch announcement's whole point is often a
# command, and a reducer that keeps only <p> and <li> would drop it silently.

class _NewsHtml(HTMLParser):
    """HTML in, an escaped <p>/<ul>/<li>/<code> subset out."""

    KEEP_BLOCK = {"p", "ul", "ol", "li"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self._text = []
        self._stack = []
        self._code_depth = 0

    def _flush(self, wrapper=None):
        text = " ".join("".join(self._text).split())
        self._text = []
        if not text:
            return
        escaped = htmlmod.escape(text)
        self.out.append(f"<{wrapper}>{escaped}</{wrapper}>" if wrapper else f"<p>{escaped}</p>")

    def handle_starttag(self, tag, attrs):
        # <pre> is a block of its own; <code> is usually a word inside a
        # sentence ("back up <code>/etc/pacman.conf</code>") and pulling that
        # out into a block of its own would take the sentence apart.
        if tag == "pre":
            self._flush()
            self._code_depth += 1
            return
        if tag in self.KEEP_BLOCK:
            self._flush()
            self._stack.append(tag)
            if tag in ("ul", "ol"):
                self.out.append(f"<{tag}>")
        elif tag == "br":
            self._text.append(" ")

    def handle_endtag(self, tag):
        if tag == "pre":
            if self._code_depth:
                self._code_depth -= 1
                self._flush("pre")
            return
        if tag in ("p", "li"):
            self._flush("li" if tag == "li" else "p")
            if self._stack and self._stack[-1] == tag:
                self._stack.pop()
        elif tag in ("ul", "ol"):
            self._flush()
            if self._stack and self._stack[-1] == tag:
                self._stack.pop()
            self.out.append(f"</{tag}>")

    def handle_data(self, data):
        self._text.append(data)

    def result(self):
        self._flush()
        # <pre> is not in the renderer's subset; it is a code block that keeps
        # its own line, which is what a command needs
        return "".join(self.out).replace("<pre>", "<p><code>").replace("</pre>", "</code></p>")


def news_html(raw):
    """Reduce an item's HTML body to the subset the UI renders."""
    if not raw:
        return ""
    try:
        parser = _NewsHtml()
        parser.feed(raw)
        parser.close()
        out = parser.result()
    except Exception:
        out = ""
    if out:
        return out
    # Malformed enough to defeat the parser: keep the words, drop the tags
    return "<p>" + htmlmod.escape(" ".join(re.sub(r"<[^>]+>", " ", raw).split())) + "</p>"


def _text(elem, tag):
    child = elem.find(tag)
    return (child.text or "").strip() if child is not None and child.text else ""


def parse_feed(xml_bytes):
    """RSS 2.0 in, a list of items (newest first) out."""
    import xml.etree.ElementTree as ET
    from email.utils import parsedate_to_datetime

    root = ET.fromstring(xml_bytes)
    items = []
    for item in root.iter("item"):
        link = _text(item, "link")
        guid = _text(item, "guid") or link
        if not guid:
            continue
        published = 0
        raw_date = _text(item, "pubDate")
        if raw_date:
            try:
                published = int(parsedate_to_datetime(raw_date).timestamp())
            except (TypeError, ValueError):
                published = 0
        items.append({
            "id": guid,
            "title": _text(item, "title"),
            "url": link,
            "published": published,
            "html": news_html(_text(item, "description")),
        })
    items.sort(key=lambda i: i.get("published", 0), reverse=True)
    return items


def load_state():
    try:
        with open(DATA_FILE) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}
    state.setdefault("items", {})
    state.setdefault("read", [])
    state.setdefault("fetchedAt", 0)
    return state


def save_state(state):
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        with open(DATA_FILE, "w") as f:
            json.dump(state, f)
    except OSError:
        pass


def fetch(url=FEED_URL):
    import urllib.request
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=FETCH_TIMEOUT) as response:
        return response.read()


def merge(state, items):
    """Fold a fetched feed into the archive, keeping what has scrolled off it.

    An item already stored is refreshed rather than replaced, so a correction
    upstream lands without resetting whether it has been read.
    """
    stored = state["items"]
    for item in items:
        existing = stored.get(item["id"], {})
        merged = dict(existing)
        merged.update(item)
        stored[item["id"]] = merged
    if len(stored) > KEEP_ITEMS:
        keep = sorted(stored.values(), key=lambda i: i.get("published", 0), reverse=True)[:KEEP_ITEMS]
        kept_ids = {i["id"] for i in keep}
        state["items"] = {k: v for k, v in stored.items() if k in kept_ids}
        state["read"] = [r for r in state["read"] if r in kept_ids]
    return state


def _first_run_is_not_a_backlog(state, items):
    """The first fetch is not news; it is the state of the world on arrival.

    Announcing eleven items nobody has missed, the first time the plugin runs
    on an Arch install, would teach the user to dismiss this thing on sight.
    Everything already published is marked read, and what appears after today
    is what gets called new.
    """
    if state.get("bootstrapped"):
        return
    state["read"] = sorted({i["id"] for i in items} | set(state.get("read", [])))
    state["bootstrapped"] = True


def run_list(refresh):
    if not supported():
        print(json.dumps({"supported": False, "items": [], "unread": 0}))
        return

    state = load_state()
    error = ""
    stale = time.time() - state.get("fetchedAt", 0) > MAX_AGE
    if refresh or stale:
        try:
            items = parse_feed(fetch())
            merge(state, items)
            _first_run_is_not_a_backlog(state, items)
            state["fetchedAt"] = int(time.time())
            save_state(state)
        except Exception as exc:
            # An unreachable feed is not a failure worth a dialog: the archive
            # is still readable and the next check will try again
            error = str(exc)

    read = set(state.get("read", []))
    items = sorted(state["items"].values(), key=lambda i: i.get("published", 0), reverse=True)
    for item in items:
        item["unread"] = item["id"] not in read
    print(json.dumps({
        "supported": True,
        "items": items,
        "unread": sum(1 for i in items if i["unread"]),
        "fetchedAt": state.get("fetchedAt", 0),
        "error": error,
    }))


def run_mark_read(ids):
    state = load_state()
    read = set(state.get("read", []))
    read.update(ids if ids else state["items"].keys())
    state["read"] = sorted(read & set(state["items"].keys()) | (read & set(ids)))
    save_state(state)
    print(json.dumps({"ok": True, "unread": sum(1 for i in state["items"] if i not in read)}))


def main():
    args = sys.argv[1:]
    if args and args[0] == "--list":
        run_list("--refresh" in args)
        return
    if args and args[0] == "--mark-read":
        run_mark_read(args[1:])
        return
    if args and args[0] == "--mark-all-read":
        run_mark_read([])
        return
    print(json.dumps({"error": "usage: arch_news.py --list [--refresh] | --mark-read <id>... | --mark-all-read"}))


if __name__ == "__main__":
    main()
