.PHONY: up down logs install-agent uninstall-agent test test-backend test-agent e2e

up:              ## Backend + web UI'ı Docker'da başlat
	docker compose up -d --build

down:
	docker compose down

logs:
	docker compose logs -f

install-agent:   ## macOS ajanını derle, girişte otomatik başlayacak şekilde kur
	./scripts/install-agent.sh

uninstall-agent:
	./scripts/uninstall-agent.sh

test: test-backend test-agent

test-backend:
	docker build -q --target test -t copy-memory-test backend >/dev/null
	docker run --rm copy-memory-test

test-agent:
	cd agent && swift test

e2e:             ## Gerçek pano + Docker + ajan ile uçtan uca test
	./scripts/e2e.sh
