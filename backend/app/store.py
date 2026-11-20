"""SQLite + content-addressed blob storage for clipboard history."""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import threading
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import unquote, urlparse

SCHEMA = """
CREATE TABLE IF NOT EXISTS items (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    hash            TEXT NOT NULL UNIQUE,
    kind            TEXT NOT NULL,
    preview         TEXT NOT NULL DEFAULT '',
    search_text     TEXT NOT NULL DEFAULT '',
    source_app      TEXT,
    source_app_name TEXT,
    types           TEXT NOT NULL,
    size            INTEGER NOT NULL,
    thumb_blob      TEXT,
    pinned          INTEGER NOT NULL DEFAULT 0,
    copy_count      INTEGER NOT NULL DEFAULT 1,
    created_at      REAL NOT NULL,
    last_used_at    REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS items_order ON items(pinned DESC, last_used_at DESC);
CREATE TABLE IF NOT EXISTS reps (
    item_id    INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    item_index INTEGER NOT NULL,
    type       TEXT NOT NULL,
    blob       TEXT NOT NULL,
    size       INTEGER NOT NULL,
    PRIMARY KEY (item_id, item_index, type)
);
CREATE INDEX IF NOT EXISTS reps_blob ON reps(blob);
"""

TEXT_TYPES = ("public.utf8-plain-text", "public.utf16-plain-text", "public.plain-text", "NSStringPboardType")
FILE_TYPES = ("public.file-url", "NSFilenamesPboardType")
IMAGE_TYPES = ("public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic", "com.adobe.pdf")
RICH_TYPES = ("public.rtf", "public.html", "com.apple.flat-rtfd", "com.apple.webarchive")
IMAGE_MIME = {"public.png": "image/png", "public.jpeg": "image/jpeg", "com.compuserve.gif": "image/gif"}

SEARCH_TEXT_LIMIT = 20_000
PREVIEW_LIMIT = 500


def normalize(text: str) -> str:
    """Case- and diacritic-insensitive form used for search (ş→s, İ/ı→i, ...)."""
    text = text.replace("İ", "i").replace("ı", "i").casefold()
    decomposed = unicodedata.normalize("NFKD", text)
    return "".join(c for c in decomposed if not unicodedata.combining(c))


def classify(types: set[str]) -> str:
    if types & set(FILE_TYPES):
        return "file"
    if types & set(IMAGE_TYPES):
        return "image"
    if types & set(RICH_TYPES):
        return "rich"
    if types & set(TEXT_TYPES):
        return "text"
    return "other"


def _decode_text(data: bytes, type_: str) -> str:
    encoding = "utf-16" if "utf16" in type_ else "utf-8"
    return data.decode(encoding, errors="replace")


def extract_text(items: list[dict[str, bytes]]) -> str:
    """Best-effort human-readable text of a clipboard snapshot."""
    texts, files = [], []
    for item in items:
        for t in FILE_TYPES[:1]:
            if t in item:
                url = item[t].decode("utf-8", errors="replace")
                files.append(unquote(urlparse(url).path) or url)
                break
        else:
            for t in TEXT_TYPES:
                if t in item:
                    texts.append(_decode_text(item[t], t))
                    break
    return "\n".join(files) if files else "\n".join(texts)


def content_hash(items: list[dict[str, bytes]]) -> str:
    """Hash of the meaningful content. Uses public.* types when present so that
    app-specific metadata does not defeat de-duplication."""
    h = hashlib.sha256()
    for idx, item in enumerate(items):
        keys = sorted(k for k in item if k.startswith("public.")) or sorted(item)
        for k in keys:
            h.update(f"{idx}\0{k}\0".encode())
            h.update(hashlib.sha256(item[k]).digest())
    return h.hexdigest()


@dataclass
class Settings:
    data_dir: str = os.environ.get("DATA_DIR", "/data")
    max_items: int = int(os.environ.get("MAX_ITEMS", "1000"))
    max_item_bytes: int = int(os.environ.get("MAX_ITEM_BYTES", str(50 * 1024 * 1024)))


class TooLarge(Exception):
    pass


class Store:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.blob_dir = Path(settings.data_dir) / "blobs"
        self.blob_dir.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        self.db = sqlite3.connect(Path(settings.data_dir) / "clipboard.db", check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript(SCHEMA)

    # ---- blobs ---------------------------------------------------------
    def _blob_path(self, digest: str) -> Path:
        return self.blob_dir / digest[:2] / digest

    def _put_blob(self, data: bytes) -> str:
        digest = hashlib.sha256(data).hexdigest()
        path = self._blob_path(digest)
        if not path.exists():
            path.parent.mkdir(exist_ok=True)
            tmp = path.with_suffix(".tmp")
            tmp.write_bytes(data)
            tmp.replace(path)
        return digest

    def read_blob(self, digest: str) -> bytes:
        return self._blob_path(digest).read_bytes()

    def _gc_blobs(self, candidates: set[str]) -> None:
        for digest in candidates:
            used = self.db.execute(
                "SELECT 1 FROM reps WHERE blob=? UNION SELECT 1 FROM items WHERE thumb_blob=? LIMIT 1",
                (digest, digest),
            ).fetchone()
            if not used:
                self._blob_path(digest).unlink(missing_ok=True)

    def _blobs_of(self, where: str, params: tuple) -> set[str]:
        rows = self.db.execute(
            f"SELECT r.blob FROM reps r JOIN items i ON i.id=r.item_id WHERE {where} "
            f"UNION SELECT thumb_blob FROM items i WHERE {where} AND thumb_blob IS NOT NULL",
            params + params,
        ).fetchall()
        return {r[0] for r in rows}

    # ---- writes --------------------------------------------------------
    def add(
        self,
        items: list[dict[str, bytes]],
        source_app: str | None = None,
        source_app_name: str | None = None,
        thumbnail: bytes | None = None,
    ) -> tuple[dict, bool]:
        """Insert a snapshot. Returns (item, created). Duplicates are bumped to the top."""
        size = sum(len(d) for item in items for d in item.values())
        if size > self.settings.max_item_bytes:
            raise TooLarge(size)
        digest = content_hash(items)
        now = time.time()
        with self.lock, self.db:
            existing = self.db.execute("SELECT id FROM items WHERE hash=?", (digest,)).fetchone()
            if existing:
                self.db.execute(
                    "UPDATE items SET last_used_at=?, copy_count=copy_count+1, "
                    "source_app=COALESCE(?, source_app), source_app_name=COALESCE(?, source_app_name) WHERE id=?",
                    (now, source_app, source_app_name, existing["id"]),
                )
                return self._get(existing["id"]), False

            types = sorted({t for item in items for t in item})
            text = extract_text(items)
            kind = classify(set(types))
            preview = text[:PREVIEW_LIMIT] if text.strip() else ", ".join(types[:4])
            thumb = self._put_blob(thumbnail) if thumbnail else None
            cur = self.db.execute(
                "INSERT INTO items(hash, kind, preview, search_text, source_app, source_app_name, types, size,"
                " thumb_blob, created_at, last_used_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                (digest, kind, preview, normalize(f"{text[:SEARCH_TEXT_LIMIT]}\n{source_app_name or ''}"),
                 source_app, source_app_name, json.dumps(types), size, thumb, now, now),
            )
            item_id = cur.lastrowid
            for idx, item in enumerate(items):
                for type_, data in item.items():
                    self.db.execute(
                        "INSERT INTO reps(item_id, item_index, type, blob, size) VALUES (?,?,?,?,?)",
                        (item_id, idx, type_, self._put_blob(data), len(data)),
                    )
            self._enforce_limit()
            return self._get(item_id), True

    def _enforce_limit(self) -> None:
        where = "i.id IN (SELECT id FROM items WHERE pinned=0 ORDER BY last_used_at DESC LIMIT -1 OFFSET ?)"
        params = (self.settings.max_items,)
        blobs = self._blobs_of(where, params)
        removed = self.db.execute(f"DELETE FROM items AS i WHERE {where}", params).rowcount
        if removed:
            self._gc_blobs(blobs)

    def touch(self, item_id: int) -> dict | None:
        with self.lock, self.db:
            self.db.execute("UPDATE items SET last_used_at=? WHERE id=?", (time.time(), item_id))
            return self._get(item_id)

    def set_pinned(self, item_id: int, pinned: bool) -> dict | None:
        with self.lock, self.db:
            self.db.execute("UPDATE items SET pinned=? WHERE id=?", (int(pinned), item_id))
            return self._get(item_id)

    def delete(self, item_id: int) -> bool:
        with self.lock, self.db:
            blobs = self._blobs_of("i.id=?", (item_id,))
            removed = self.db.execute("DELETE FROM items WHERE id=?", (item_id,)).rowcount
            self._gc_blobs(blobs)
            return bool(removed)

    def clear(self, include_pinned: bool = False) -> int:
        where = "1=1" if include_pinned else "i.pinned=0"
        with self.lock, self.db:
            blobs = self._blobs_of(where, ())
            removed = self.db.execute(f"DELETE FROM items AS i WHERE {where}").rowcount
            self._gc_blobs(blobs)
            return removed

    # ---- reads ---------------------------------------------------------
    @staticmethod
    def _row(row: sqlite3.Row) -> dict:
        d = dict(row)
        d["types"] = json.loads(d["types"])
        d["pinned"] = bool(d["pinned"])
        d["has_thumbnail"] = bool(d.pop("thumb_blob")) or d["kind"] == "image" and any(
            t in IMAGE_MIME for t in d["types"]
        )
        d.pop("search_text", None)
        d.pop("hash", None)
        return d

    def _get(self, item_id: int) -> dict | None:
        row = self.db.execute("SELECT * FROM items WHERE id=?", (item_id,)).fetchone()
        return self._row(row) if row else None

    def get(self, item_id: int) -> dict | None:
        with self.lock:
            return self._get(item_id)

    def list(self, q: str = "", kind: str | None = None, pinned: bool | None = None,
             limit: int = 50, offset: int = 0) -> tuple[list[dict], int]:
        clauses, params = [], []
        for token in normalize(q).split():
            clauses.append("instr(search_text, ?) > 0")
            params.append(token)
        if kind:
            clauses.append("kind=?")
            params.append(kind)
        if pinned is not None:
            clauses.append("pinned=?")
            params.append(int(pinned))
        where = " AND ".join(clauses) or "1=1"
        with self.lock:
            total = self.db.execute(f"SELECT COUNT(*) FROM items WHERE {where}", params).fetchone()[0]
            rows = self.db.execute(
                f"SELECT * FROM items WHERE {where} ORDER BY pinned DESC, last_used_at DESC LIMIT ? OFFSET ?",
                params + [limit, offset],
            ).fetchall()
        return [self._row(r) for r in rows], total

    def payload(self, item_id: int) -> list[dict[str, bytes]] | None:
        with self.lock:
            rows = self.db.execute(
                "SELECT item_index, type, blob FROM reps WHERE item_id=? ORDER BY item_index", (item_id,)
            ).fetchall()
        if not rows:
            return None
        items: list[dict[str, bytes]] = []
        for r in rows:
            while len(items) <= r["item_index"]:
                items.append({})
            items[r["item_index"]][r["type"]] = self.read_blob(r["blob"])
        return items

    def thumbnail(self, item_id: int) -> tuple[bytes, str] | None:
        with self.lock:
            row = self.db.execute("SELECT thumb_blob FROM items WHERE id=?", (item_id,)).fetchone()
            if not row:
                return None
            if row["thumb_blob"]:
                return self.read_blob(row["thumb_blob"]), "image/png"
            for type_, mime in IMAGE_MIME.items():
                rep = self.db.execute(
                    "SELECT blob FROM reps WHERE item_id=? AND type=? LIMIT 1", (item_id, type_)
                ).fetchone()
                if rep:
                    return self.read_blob(rep["blob"]), mime
        return None

    def stats(self) -> dict:
        with self.lock:
            row = self.db.execute(
                "SELECT COUNT(*) AS count, COALESCE(SUM(size),0) AS bytes, COALESCE(SUM(pinned),0) AS pinned FROM items"
            ).fetchone()
            kinds = dict(self.db.execute("SELECT kind, COUNT(*) FROM items GROUP BY kind").fetchall())
        return {**dict(row), "kinds": kinds, "max_items": self.settings.max_items}
