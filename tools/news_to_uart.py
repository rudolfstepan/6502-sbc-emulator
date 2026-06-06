#!/usr/bin/env python3
"""Send RSS/Atom headlines to the FPGA UART console.

Default serial settings match the FPGA UART serializer/deserializer:
COM15, 115200 baud, 8N1.

Requires pyserial:
    python -m pip install pyserial
"""

from __future__ import annotations

import argparse
import html
import sys
import textwrap
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from typing import Iterable


DEFAULT_FEEDS = [
    "https://www.tagesschau.de/index~rss2.xml",
    "https://feeds.bbci.co.uk/news/world/rss.xml",
]


@dataclass(frozen=True)
class Headline:
    source: str
    title: str


def clean_text(value: str | None) -> str:
    if not value:
        return ""
    text = html.unescape(value)
    return " ".join(text.replace("\n", " ").replace("\r", " ").split())


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def first_child_text(node: ET.Element, wanted_name: str) -> str:
    for child in node:
        if local_name(child.tag) == wanted_name:
            return clean_text(child.text)
    return ""


def feed_source(root: ET.Element, fallback: str) -> str:
    if local_name(root.tag) == "rss":
        channel = root.find("channel")
        if channel is not None:
            title = first_child_text(channel, "title")
            if title:
                return title
    title = first_child_text(root, "title")
    return title or fallback


def parse_feed(xml_bytes: bytes, fallback_source: str, limit: int) -> list[Headline]:
    root = ET.fromstring(xml_bytes)
    source = feed_source(root, fallback_source)
    headlines: list[Headline] = []

    if local_name(root.tag) == "rss":
        channel = root.find("channel")
        items = [] if channel is None else channel.findall("item")
        for item in items:
            title = first_child_text(item, "title")
            if title:
                headlines.append(Headline(source, title))
            if len(headlines) >= limit:
                break
        return headlines

    for entry in root:
        if local_name(entry.tag) != "entry":
            continue
        title = first_child_text(entry, "title")
        if title:
            headlines.append(Headline(source, title))
        if len(headlines) >= limit:
            break
    return headlines


def fetch_feed(url: str, timeout: float, limit: int) -> list[Headline]:
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "6502-sbc-news-uart/1.0",
            "Accept": "application/rss+xml, application/atom+xml, application/xml, text/xml",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        data = response.read()
    fallback = urllib.parse.urlparse(url).netloc or url
    return parse_feed(data, fallback, limit)


def iter_headlines(feeds: Iterable[str], timeout: float, limit_per_feed: int) -> list[Headline]:
    all_headlines: list[Headline] = []
    for url in feeds:
        try:
            all_headlines.extend(fetch_feed(url, timeout, limit_per_feed))
        except (ET.ParseError, OSError, urllib.error.URLError) as exc:
            all_headlines.append(Headline("FEED", f"ERROR {url}: {exc}"))
    return all_headlines


def ascii_lines(headline: Headline, width: int) -> list[str]:
    prefix = f"[{headline.source}] "
    text = (prefix + headline.title).encode("ascii", "replace").decode("ascii")
    return textwrap.wrap(text, width=width, break_long_words=False) or [text]


def send_line(port, line: str, char_delay: float) -> None:
    # The ROM treats CR/LF as newline, and char_delay keeps the VGA echo readable.
    payload = (line + "\r\n").encode("ascii", "replace")
    if char_delay <= 0:
        port.write(payload)
        port.flush()
        return
    for byte in payload:
        port.write(bytes([byte]))
        port.flush()
        time.sleep(char_delay)


def open_serial(port_name: str, baud: int):
    try:
        import serial
    except ImportError as exc:
        raise SystemExit(
            "pyserial is missing. Install it with: python -m pip install pyserial"
        ) from exc

    return serial.Serial(
        port=port_name,
        baudrate=baud,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=1,
        write_timeout=2,
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch RSS/Atom headlines and send them to the FPGA UART."
    )
    parser.add_argument("--port", default="COM15", help="serial port, default: COM15")
    parser.add_argument("--baud", type=int, default=115200, help="baud rate, default: 115200")
    parser.add_argument(
        "--interval",
        type=float,
        default=5.0,
        help="seconds between transmitted headlines, default: 5",
    )
    parser.add_argument(
        "--refresh",
        type=float,
        default=300.0,
        help="seconds before feeds are fetched again, default: 300",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        help="HTTP timeout in seconds, default: 10",
    )
    parser.add_argument(
        "--limit-per-feed",
        type=int,
        default=5,
        help="headlines to keep from each feed, default: 5",
    )
    parser.add_argument(
        "--width",
        type=int,
        default=38,
        help="wrap lines for the 40-column VGA display, default: 38",
    )
    parser.add_argument(
        "--char-delay",
        type=float,
        default=0.002,
        help="delay between bytes in seconds, default: 0.002",
    )
    parser.add_argument(
        "--feed",
        action="append",
        dest="feeds",
        help="RSS/Atom feed URL; can be used multiple times",
    )
    parser.add_argument("--once", action="store_true", help="send one refresh batch and exit")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    feeds = args.feeds or DEFAULT_FEEDS

    print(f"Opening {args.port} at {args.baud} baud (8N1)")
    with open_serial(args.port, args.baud) as port:
        while True:
            headlines = iter_headlines(feeds, args.timeout, args.limit_per_feed)
            if not headlines:
                headlines = [Headline("NEWS", "No headlines received")]

            for headline in headlines:
                for line in ascii_lines(headline, args.width):
                    print(line)
                    send_line(port, line, args.char_delay)
                time.sleep(args.interval)

            if args.once:
                return 0
            time.sleep(max(0.0, args.refresh))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
