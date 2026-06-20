.DEFAULT_GOAL := help
SERVICES := appointment-service report-service notification-service

.PHONY: help up down logs migrate test lint fmt fe-install fe-dev

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Build + start the full local stack (Postgres, Redis, migrate, 3 services)
	docker compose up --build

down: ## Stop the stack and remove volumes
	docker compose down -v

logs: ## Tail service logs
	docker compose logs -f

migrate: ## Run Alembic migrations + seed only
	docker compose run --rm migrate

test: ## Run service smoke tests (requires local Python deps per service)
	@for s in $(SERVICES); do \
		echo "== pytest $$s =="; \
		(cd backend/$$s && python -m pytest -q) || exit 1; \
	done

lint: ## Ruff lint all backend services + serverless
	ruff check backend serverless

fmt: ## Ruff format all backend services + serverless
	ruff format backend serverless

fe-install: ## Install frontend deps
	cd frontend && pnpm install

fe-dev: ## Run the frontend dev server
	cd frontend && pnpm dev
