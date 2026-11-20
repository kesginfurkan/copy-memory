import base64

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.store import Settings, classify, normalize

PNG_1PX = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
)


def b64(data: bytes | str) -> str:
    if isinstance(data, str):
        data = data.encode()
    return base64.b64encode(data).decode()


def text_snapshot(text: str, **extra) -> dict:
    return {"items": [{"public.utf8-plain-text": b64(text)}], **extra}


@pytest.fixture
def make_client(tmp_path):
    def factory(**settings):
        app = create_app(Settings(data_dir=str(tmp_path), **settings))
        return TestClient(app)
    return factory


@pytest.fixture
def client(make_client):
    return make_client()


def blob_count(client) -> int:
    blob_dir = client.app.state.store.blob_dir
    return sum(1 for p in blob_dir.rglob("*") if p.is_file())


def test_health_and_static_ui(client):
    assert client.get("/api/health").json() == {"status": "ok"}
    page = client.get("/")
    assert page.status_code == 200
    assert "copy-memory" in page.text


def test_add_text_and_list(client):
    r = client.post("/api/items", json=text_snapshot("merhaba dünya", source_app_name="Notes"))
    assert r.status_code == 201
    item = r.json()
    assert item["kind"] == "text"
    assert item["preview"] == "merhaba dünya"
    assert item["source_app_name"] == "Notes"

    listing = client.get("/api/items").json()
    assert listing["total"] == 1
    assert listing["items"][0]["id"] == item["id"]


def test_duplicate_is_bumped_not_duplicated(client):
    first = client.post("/api/items", json=text_snapshot("a")).json()
    client.post("/api/items", json=text_snapshot("b"))
    again = client.post("/api/items", json=text_snapshot("a"))
    assert again.status_code == 200
    assert again.json()["id"] == first["id"]
    assert again.json()["copy_count"] == 2
    items = client.get("/api/items").json()["items"]
    assert [i["preview"] for i in items] == ["a", "b"]


def test_dedup_ignores_app_specific_metadata(client):
    a = client.post("/api/items", json={"items": [{"public.utf8-plain-text": b64("x"), "com.app.meta": b64("1")}]})
    b = client.post("/api/items", json={"items": [{"public.utf8-plain-text": b64("x"), "com.app.meta": b64("2")}]})
    assert a.json()["id"] == b.json()["id"]


def test_payload_roundtrip_preserves_every_representation(client):
    snapshot = {
        "items": [
            {"public.utf8-plain-text": b64("hello"), "public.html": b64("<b>hello</b>"), "com.custom.type": b64(b"\x00\x01")},
            {"public.file-url": b64("file:///Users/me/a%20b.txt")},
        ]
    }
    item = client.post("/api/items", json=snapshot).json()
    assert item["kind"] == "file"
    assert item["preview"] == "/Users/me/a b.txt"
    payload = client.get(f"/api/items/{item['id']}/payload").json()
    assert payload == snapshot


@pytest.mark.parametrize(
    "types,kind",
    [
        ({"public.utf8-plain-text"}, "text"),
        ({"public.utf8-plain-text", "public.rtf"}, "rich"),
        ({"public.tiff", "public.html"}, "image"),
        ({"public.file-url", "public.tiff"}, "file"),
        ({"com.apple.cocoa.pasteboard.color"}, "other"),
    ],
)
def test_classify(types, kind):
    assert classify(types) == kind


def test_image_thumbnail(client):
    item = client.post("/api/items", json={"items": [{"public.png": b64(PNG_1PX)}]}).json()
    assert item["kind"] == "image"
    assert item["has_thumbnail"]
    r = client.get(f"/api/items/{item['id']}/thumbnail")
    assert r.status_code == 200
    assert r.headers["content-type"] == "image/png"
    assert r.content == PNG_1PX


def test_agent_supplied_thumbnail_for_tiff(client):
    item = client.post(
        "/api/items", json={"items": [{"public.tiff": b64(b"II*\x00fake")}], "thumbnail_png": b64(PNG_1PX)}
    ).json()
    assert item["has_thumbnail"]
    assert client.get(f"/api/items/{item['id']}/thumbnail").content == PNG_1PX


def test_search_is_case_and_diacritic_insensitive(client):
    client.post("/api/items", json=text_snapshot("Şirket toplantısı İstanbul"))
    client.post("/api/items", json=text_snapshot("alışveriş listesi"))
    client.post("/api/items", json=text_snapshot("kod parçası", source_app_name="Xcode"))

    def search(q):
        return [i["preview"] for i in client.get("/api/items", params={"q": q}).json()["items"]]

    assert search("sirket") == ["Şirket toplantısı İstanbul"]
    assert search("ISTANBUL toplanti") == ["Şirket toplantısı İstanbul"]
    assert search("alisveris") == ["alışveriş listesi"]
    assert search("xcode") == ["kod parçası"]
    assert search("yok") == []


def test_normalize():
    assert normalize("ŞİŞLİ Çığ Öğün") == "sisli cig ogun"


def test_kind_filter_and_pagination(client):
    for i in range(5):
        client.post("/api/items", json=text_snapshot(f"t{i}"))
    client.post("/api/items", json={"items": [{"public.png": b64(PNG_1PX)}]})
    assert client.get("/api/items", params={"kind": "image"}).json()["total"] == 1
    page = client.get("/api/items", params={"kind": "text", "limit": 2, "offset": 2}).json()
    assert page["total"] == 5
    assert [i["preview"] for i in page["items"]] == ["t2", "t1"]


def test_pin_keeps_item_on_top_and_survives_limit(make_client):
    client = make_client(max_items=3)
    pinned = client.post("/api/items", json=text_snapshot("önemli")).json()
    client.put(f"/api/items/{pinned['id']}/pin", json={"pinned": True})
    for i in range(5):
        client.post("/api/items", json=text_snapshot(f"n{i}"))
    previews = [i["preview"] for i in client.get("/api/items").json()["items"]]
    assert previews == ["önemli", "n4", "n3", "n2"]


def test_retention_limit_removes_oldest_and_their_blobs(make_client):
    client = make_client(max_items=2)
    for i in range(4):
        client.post("/api/items", json=text_snapshot(f"item {i}"))
    previews = [i["preview"] for i in client.get("/api/items").json()["items"]]
    assert previews == ["item 3", "item 2"]
    assert blob_count(client) == 2


def test_use_moves_item_to_top(client):
    old = client.post("/api/items", json=text_snapshot("eski")).json()
    client.post("/api/items", json=text_snapshot("yeni"))
    client.post(f"/api/items/{old['id']}/use")
    assert client.get("/api/items").json()["items"][0]["preview"] == "eski"


def test_delete_and_shared_blob_gc(client):
    # two items sharing the same text representation share one blob
    a = client.post("/api/items", json=text_snapshot("ortak")).json()
    b = client.post("/api/items", json={"items": [{"public.utf8-plain-text": b64("ortak"), "public.rtf": b64("{rtf}")}]}).json()
    assert a["id"] != b["id"]
    assert blob_count(client) == 2
    assert client.delete(f"/api/items/{a['id']}").status_code == 204
    assert blob_count(client) == 2  # still used by b
    client.delete(f"/api/items/{b['id']}")
    assert blob_count(client) == 0
    assert client.delete(f"/api/items/{b['id']}").status_code == 404


def test_clear_keeps_pinned_by_default(client):
    keep = client.post("/api/items", json=text_snapshot("pin")).json()
    client.put(f"/api/items/{keep['id']}/pin", json={"pinned": True})
    client.post("/api/items", json=text_snapshot("geçici"))
    assert client.delete("/api/items").json() == {"deleted": 1}
    assert client.get("/api/items").json()["total"] == 1
    assert client.delete("/api/items", params={"include_pinned": True}).json() == {"deleted": 1}


def test_too_large_is_rejected(make_client):
    client = make_client(max_item_bytes=10)
    r = client.post("/api/items", json=text_snapshot("x" * 11))
    assert r.status_code == 413
    assert client.get("/api/items").json()["total"] == 0


def test_validation_errors(client):
    assert client.post("/api/items", json={"items": []}).status_code == 422
    assert client.post("/api/items", json={"items": [{"public.utf8-plain-text": "!!notbase64"}]}).status_code == 422
    assert client.get("/api/items/999").status_code == 404
    assert client.get("/api/items/999/payload").status_code == 404


def test_stats(client):
    client.post("/api/items", json=text_snapshot("a"))
    client.post("/api/items", json={"items": [{"public.png": b64(PNG_1PX)}]})
    stats = client.get("/api/stats").json()
    assert stats["count"] == 2
    assert stats["kinds"] == {"text": 1, "image": 1}


def test_data_persists_across_restarts(tmp_path):
    settings = Settings(data_dir=str(tmp_path))
    TestClient(create_app(settings)).post("/api/items", json=text_snapshot("kalıcı"))
    listing = TestClient(create_app(settings)).get("/api/items").json()
    assert listing["items"][0]["preview"] == "kalıcı"
