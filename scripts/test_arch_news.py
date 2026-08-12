#!/usr/bin/env python3
"""Checks the Arch news path against a real-shaped feed, with no network.

Runnable on any distribution: the feed is a fixture and the fetch is stubbed,
so this says the same thing on the Fedora machine it was written on as it does
on the Arch install it is for.
"""

import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

FEED = b"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <channel>
    <title>Arch Linux: Recent news updates</title>
    <item>
      <title>Manual intervention for pacman 7 required</title>
      <link>https://archlinux.org/news/manual-intervention-required/</link>
      <guid isPermaLink="true">https://archlinux.org/news/manual-intervention-required/</guid>
      <pubDate>Tue, 04 Aug 2026 09:15:00 +0000</pubDate>
      <description>&lt;p&gt;Before upgrading, run this:&lt;/p&gt;
        &lt;pre&gt;pacman -Syu --ignore pacman&lt;/pre&gt;
        &lt;ul&gt;&lt;li&gt;Back up &lt;code&gt;/etc/pacman.conf&lt;/code&gt;&lt;/li&gt;&lt;/ul&gt;</description>
    </item>
    <item>
      <title>Old announcement about &amp; entities</title>
      <link>https://archlinux.org/news/older/</link>
      <guid isPermaLink="true">https://archlinux.org/news/older/</guid>
      <pubDate>Mon, 06 Jan 2025 10:00:00 +0000</pubDate>
      <description>&lt;p&gt;Nothing to do &amp;amp; nothing to see.&lt;/p&gt;</description>
    </item>
  </channel>
</rss>
"""

LATER = b"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <channel>
    <item>
      <title>Something new</title>
      <link>https://archlinux.org/news/newest/</link>
      <guid isPermaLink="true">https://archlinux.org/news/newest/</guid>
      <pubDate>Wed, 12 Aug 2026 08:00:00 +0000</pubDate>
      <description>&lt;p&gt;Fresh.&lt;/p&gt;</description>
    </item>
  </channel>
</rss>
"""

failures = []


def check(label, condition, detail=""):
    if condition:
        print(f"  ok    {label}")
    else:
        print(f"  FAIL  {label}{(': ' + detail) if detail else ''}")
        failures.append(label)


def main():
    with tempfile.TemporaryDirectory() as tmp:
        os.environ["XDG_DATA_HOME"] = tmp
        import arch_news

        # ── Parsing ──────────────────────────────────────────────────────────
        items = arch_news.parse_feed(FEED)
        check("both items parsed", len(items) == 2, str(len(items)))
        check("newest first", items[0]["title"].startswith("Manual intervention"))
        check("pubDate becomes epoch seconds", items[0]["published"] > 1_700_000_000)
        check("guid is the id", items[0]["id"].endswith("manual-intervention-required/"))

        body = items[0]["html"]
        check("paragraph survives", "<p>Before upgrading, run this:</p>" in body, body)
        check("the command is not dropped", "pacman -Syu --ignore pacman" in body, body)
        check("a command is code, on its own block", "<p><code>pacman -Syu" in body, body)
        check("list structure survives", "<ul><li>" in body and "</li></ul>" in body, body)
        check("entities are text, not markup", "&amp;" in items[1]["html"], items[1]["html"])

        # ── Nothing external reaches the renderer as markup ───────────────────
        hostile = arch_news.news_html('<p>hi</p><script>alert("x")</script><a href="http://x">l</a>')
        check("no script tag survives", "<script" not in hostile, hostile)
        check("no link tag survives", "<a " not in hostile, hostile)
        check("the link text is kept", "l" in hostile, hostile)

        # ── First run is the state of the world, not eleven interruptions ────
        arch_news.supported = lambda: True
        arch_news.fetch = lambda url=None: FEED

        out = capture(arch_news.run_list, True)
        check("first fetch stores both", len(out["items"]) == 2, str(len(out["items"])))
        check("first fetch announces nothing", out["unread"] == 0, str(out["unread"]))

        # ── What appears afterwards is news ──────────────────────────────────
        arch_news.fetch = lambda url=None: LATER
        out = capture(arch_news.run_list, True)
        check("the new item is unread", out["unread"] == 1, str(out["unread"]))
        check("items that left the feed are kept", len(out["items"]) == 3, str(len(out["items"])))
        check("the archive is newest first",
              out["items"][0]["title"] == "Something new", out["items"][0]["title"])

        # ── Reading it ───────────────────────────────────────────────────────
        capture(arch_news.run_mark_read, [out["items"][0]["id"]])
        out = capture(arch_news.run_list, False)
        check("reading it clears the count", out["unread"] == 0, str(out["unread"]))
        check("read state survives a reload", all(not i["unread"] for i in out["items"]))

        # ── An unreachable feed is not a crash ───────────────────────────────
        def boom(url=None):
            raise OSError("network is a place you cannot always go")

        arch_news.fetch = boom
        out = capture(arch_news.run_list, True)
        check("a failed fetch still returns the archive", len(out["items"]) == 3)
        check("and says what went wrong", "network is a place" in out.get("error", ""))

    print()
    if failures:
        print(f"{len(failures)} failed")
        return 1
    print("arch news: all checks passed")
    return 0


def capture(fn, *args):
    """Run a mode and return the JSON it printed."""
    import io
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        fn(*args)
    return json.loads(buf.getvalue())


if __name__ == "__main__":
    sys.exit(main())
