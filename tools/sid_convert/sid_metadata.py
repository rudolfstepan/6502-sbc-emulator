"""Read display metadata and the subtune range from a PSID header."""

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class SidMetadata:
    title: str
    composer: str
    songs: int
    start_song: int


def read_sid_metadata(path: Path, *, allow_rsid: bool = False) -> SidMetadata:
    with path.open("rb") as sid:
        header = sid.read(0x76)
    accepted = (b"PSID", b"RSID") if allow_rsid else (b"PSID",)
    if len(header) != 0x76 or header[:4] not in accepted:
        raise ValueError("expected a PSID file with a complete header")

    songs = int.from_bytes(header[14:16], "big")
    start_song = int.from_bytes(header[16:18], "big")
    if not 1 <= start_song <= songs <= 256:
        raise ValueError("PSID subtune count or default is invalid")

    title = header[22:54].split(b"\0", 1)[0].decode("cp1252", errors="replace").strip()
    composer = header[54:86].split(b"\0", 1)[0].decode("cp1252", errors="replace").strip()
    return SidMetadata(title or path.stem[:64], composer, songs, start_song)
