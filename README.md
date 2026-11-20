# copy-memory 📋

Self-hosted clipboard history for macOS, inspired by Maccy. It remembers **everything you copy** (text, rich text, images, files, app-specific formats) and lets you bring any of it back with a shortcut.

The history lives in a Docker container on your own machine. Nothing leaves your Mac.

> Türkçe özet aşağıda.

## How it works

```
┌──────────── macOS ─────────────────┐   HTTP (127.0.0.1)   ┌──────────── Docker ────────────┐
│ copy-memory-agent (Swift)          │ ───────────────────► │ FastAPI + SQLite               │
│ • watches NSPasteboard             │                      │ • history, search, pinning     │
│ • stores every UTI representation  │ ◄─────────────────── │ • content-addressed blob store │
│ • ⌘⇧V popup, menu bar icon, paste  │                      │ • web UI at localhost:5050     │
└────────────────────────────────────┘                      └────────────────────────────────┘
```

Docker containers on macOS run inside a Linux VM, so they **cannot** see the Mac clipboard or register global shortcuts. A small native agent does those jobs and talks to the containerised backend, which owns storage, search and the web UI.

## Features

- **Lossless capture.** Every representation of every pasteboard item (plain text, RTF, HTML, PNG/TIFF, file URLs, custom app types) is stored and restored byte-for-byte.
- **Quick popup.** ⌘⇧V opens the history near the mouse: type to search, ↑↓ and ↩ to paste into the previous app, ⌘1–9 to pick quickly, ⌘P to pin, ⌘⌫ to delete.
- **Web UI** at <http://localhost:5050> with search, type filters, pinning, deleting and image previews.
- **Search** ignores case and diacritics (`sirket` finds `Şirket`).
- **De-duplication.** Copying the same thing again moves it to the top instead of adding a duplicate.
- **Privacy.** Copies marked as concealed or transient ([nspasteboard.org](http://nspasteboard.org)) and copies from password managers are never stored. The port is bound to `127.0.0.1` only.
- **Retention.** Keeps the newest `MAX_ITEMS` entries (default 1000). Pinned items are never pruned.
- **Resilience.** If Docker is down, the agent queues copies in memory and retries.

## Install

Requirements: macOS 14+, Docker Desktop (or OrbStack/Colima), Xcode command line tools.

```bash
git clone https://github.com/kesginfurkan/copy-memory.git
cd copy-memory
make up              # backend + web UI (restarts automatically with Docker)
make install-agent   # builds the agent, starts it now and at every login
```

Allow **CopyMemory** in *System Settings → Privacy & Security → Accessibility* when asked. This is only needed for auto-paste. Without it, the selected item is copied to the clipboard and you press ⌘V yourself.

## Configuration

Agent options (environment variables, passed to `make install-agent`):

| Variable | Default | |
|---|---|---|
| `COPY_MEMORY_HOTKEY` | `cmd+shift+v` | e.g. `cmd+option+v`, `ctrl+space` |
| `COPY_MEMORY_AUTO_PASTE` | `1` | `0` = only copy, don't send ⌘V |
| `COPY_MEMORY_IGNORE_APPS` | – | extra bundle IDs to ignore, comma separated |
| `COPY_MEMORY_API` | `http://127.0.0.1:5050` | backend URL |

```bash
COPY_MEMORY_HOTKEY=cmd+option+v make install-agent
```

> ⌘⇧V is "Paste and Match Style" in many apps. If you use that, pick another shortcut.

Backend options (`.env` or environment variables for `docker compose`): `PORT` (5050), `MAX_ITEMS` (1000), `MAX_ITEM_BYTES` (50 MB), `DATA_DIR` (`./data`).

Scripting: `copy-memory-agent restore <id>` puts an item back on the clipboard. This is handy for Raycast or Alfred.

## API

| Method | Path | |
|---|---|---|
| `GET` | `/api/items?q=&kind=&pinned=&limit=&offset=` | list / search |
| `POST` | `/api/items` | add snapshot `{items: [{uti: base64}], source_app?, thumbnail_png?}` |
| `GET` | `/api/items/{id}/payload` | all representations (base64) |
| `GET` | `/api/items/{id}/thumbnail` | image preview |
| `POST` | `/api/items/{id}/use` | move to top |
| `PUT` | `/api/items/{id}/pin` | `{pinned: bool}` |
| `DELETE` | `/api/items/{id}` · `/api/items?include_pinned=` | delete one / clear |
| `GET` | `/api/stats` · `/api/health` | |

## Development

```bash
make test        # backend (pytest in Docker) + agent (XCTest)
make e2e         # real pasteboard + real Docker + real agent, isolated port/data
```

`make e2e` overwrites your clipboard while it runs and restores the text afterwards.

## Uninstall

```bash
make uninstall-agent && make down   # history stays in ./data, delete it to wipe
```

---

### Türkçe özet

Maccy benzeri, kendi bilgisayarında çalışan bir pano geçmişi. Kopyaladığın her şeyi (metin, zengin metin, görsel, dosya, uygulamaya özel türler) tüm temsilleriyle saklar.

- **Kurulum:** `make up` ve ardından `make install-agent`.
- **Kullanım:** **⌘⇧V** ile geçmiş açılır. Yazarak ara, ↩ ile yapıştır.
- **Web arayüzü:** <http://localhost:5050>.
- **Veriler:** `./data` klasöründe tutulur ve hiçbir yere gönderilmez. Parola yöneticilerinden kopyalananlar kaydedilmez.

## License

MIT
