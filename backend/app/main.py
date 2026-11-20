"""HTTP API + web UI for copy-memory."""
from __future__ import annotations

import base64
import binascii
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .store import Settings, Store, TooLarge

STATIC_DIR = Path(__file__).parent / "static"


class Snapshot(BaseModel):
    """One clipboard snapshot: a list of pasteboard items, each mapping UTI -> base64 data."""
    items: list[dict[str, str]] = Field(min_length=1)
    source_app: str | None = None
    source_app_name: str | None = None
    thumbnail_png: str | None = None


class PinBody(BaseModel):
    pinned: bool


def _b64(value: str) -> bytes:
    try:
        return base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(422, "invalid base64 data")


def create_app(settings: Settings | None = None) -> FastAPI:
    store = Store(settings or Settings())
    app = FastAPI(title="copy-memory", version="1.0.0")
    app.state.store = store

    def found(item):
        if item is None:
            raise HTTPException(404, "item not found")
        return item

    @app.get("/api/health")
    def health():
        return {"status": "ok"}

    @app.get("/api/stats")
    def stats():
        return store.stats()

    @app.post("/api/items")
    def add_item(snapshot: Snapshot, response: Response):
        items = [{t: _b64(v) for t, v in item.items()} for item in snapshot.items]
        if not any(items):
            raise HTTPException(422, "snapshot has no data")
        try:
            item, created = store.add(
                items,
                source_app=snapshot.source_app,
                source_app_name=snapshot.source_app_name,
                thumbnail=_b64(snapshot.thumbnail_png) if snapshot.thumbnail_png else None,
            )
        except TooLarge as exc:
            raise HTTPException(413, f"snapshot too large ({exc.args[0]} bytes)")
        response.status_code = 201 if created else 200
        return {**item, "created": created}

    @app.get("/api/items")
    def list_items(
        q: str = "",
        kind: str | None = None,
        pinned: bool | None = None,
        limit: int = Query(50, ge=1, le=500),
        offset: int = Query(0, ge=0),
    ):
        items, total = store.list(q=q, kind=kind, pinned=pinned, limit=limit, offset=offset)
        return {"items": items, "total": total}

    @app.get("/api/items/{item_id}")
    def get_item(item_id: int):
        return found(store.get(item_id))

    @app.get("/api/items/{item_id}/payload")
    def get_payload(item_id: int):
        items = found(store.payload(item_id))
        return {"items": [{t: base64.b64encode(d).decode() for t, d in item.items()} for item in items]}

    @app.get("/api/items/{item_id}/thumbnail")
    def get_thumbnail(item_id: int):
        data, mime = found(store.thumbnail(item_id))
        return Response(data, media_type=mime, headers={"Cache-Control": "max-age=86400"})

    @app.post("/api/items/{item_id}/use")
    def use_item(item_id: int):
        return found(store.touch(item_id))

    @app.put("/api/items/{item_id}/pin")
    def pin_item(item_id: int, body: PinBody):
        return found(store.set_pinned(item_id, body.pinned))

    @app.delete("/api/items/{item_id}", status_code=204)
    def delete_item(item_id: int):
        if not store.delete(item_id):
            raise HTTPException(404, "item not found")

    @app.delete("/api/items")
    def clear_items(include_pinned: bool = False):
        return {"deleted": store.clear(include_pinned=include_pinned)}

    app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="web")
    return app

