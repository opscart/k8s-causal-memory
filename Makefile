.PHONY: help setup build run-collector run-storage scenario-01 scenario-02 scenario-03 clean

VENV        := storage/venv
PYTHON      := $(VENV)/bin/python
PIP         := $(VENV)/bin/pip

help:
	@echo ""
	@echo "k8s-causal-memory — Available Commands"
	@echo "======================================="
	@echo "  make setup          Install all dependencies"
	@echo "  make build          Build the Go collector"
	@echo "  make run-collector  Start the collector against current kubeconfig"
	@echo "  make run-storage    Start the storage query CLI"
	@echo "  make scenario-01    Run OOMKill POC scenario"
	@echo "  make scenario-02    Run ConfigMap env var POC scenario"
	@echo "  make scenario-03    Run ConfigMap volume mount POC scenario"
	@echo "  make clean          Remove build artifacts and runtime files"
	@echo ""

# ── Setup ─────────────────────────────────────────────────────────────────────

setup: setup-go setup-python
	@echo ""
	@echo "✓ Setup complete."
	@echo "  Run: make build"
	@echo ""

setup-go:
	@echo "→ Installing Go dependencies..."
	cd collector && go mod tidy
	@echo "✓ Go dependencies installed"

setup-python: $(VENV)
	@echo "→ Installing Python dependencies into venv..."
	$(PIP) install --upgrade pip --quiet
	$(PIP) install -r storage/requirements.txt --quiet
	@echo "✓ Python venv ready: $(VENV)"

$(VENV):
	@echo "→ Creating Python virtual environment..."
	python3 -m venv $(VENV)

# ── Build ─────────────────────────────────────────────────────────────────────

build:
	@echo "→ Building Go collector..."
	cd collector && mkdir -p bin && go build -o bin/collector .
	@echo "✓ Collector binary: collector/bin/collector"

# ── Run ───────────────────────────────────────────────────────────────────────

run-collector: build
	@echo "→ Starting collector (current kubeconfig context)..."
	./collector/bin/collector --output ./output

run-storage:
	@echo "→ Starting storage query interface..."
	$(PYTHON) storage/query.py summary --db storage/memory.db

ingest:
	@echo "→ Ingesting events into memory store..."
	$(PYTHON) storage/ingest.py \
		--events output/events.jsonl \
		--snapshots output/snapshots.jsonl \
		--db storage/memory.db

# ── Scenarios ─────────────────────────────────────────────────────────────────

scenario-01:
	@echo "→ Running Scenario 01: OOMKill causal chain..."
	bash scenarios/01-oomkill/trigger.sh

scenario-02:
	@echo "→ Running Scenario 02: ConfigMap env var silent misconfiguration..."
	bash scenarios/02-configmap-env/trigger.sh

scenario-03:
	@echo "→ Running Scenario 03: ConfigMap volume mount symlink swap..."
	bash scenarios/03-configmap-mount/trigger.sh

# ── Query shortcuts ───────────────────────────────────────────────────────────

query-chain:
	@test -n "$(POD)" || (echo "Usage: make query-chain POD=<name> NS=<namespace>"; exit 1)
	$(PYTHON) storage/query.py causal-chain \
		--pod $(POD) --namespace $(or $(NS),default) --db storage/memory.db

query-pattern:
	@test -n "$(PATTERN)" || (echo "Usage: make query-pattern PATTERN=P001"; exit 1)
	$(PYTHON) storage/query.py pattern-history \
		--pattern $(PATTERN) --db storage/memory.db

query-state:
	@test -n "$(NAME)" || (echo "Usage: make query-state OBJ=Pod NAME=<pod> TIME=<iso>"; exit 1)
	$(PYTHON) storage/query.py state-at \
		--object $(or $(OBJ),Pod) --name $(NAME) --time $(TIME) --db storage/memory.db

# ── Clean ─────────────────────────────────────────────────────────────────────

clean:
	rm -f collector/bin/collector
	rm -f storage/memory.db
	rm -rf output/
	@echo "✓ Clean complete (venv preserved — run 'make clean-all' to remove)"

clean-all: clean
	rm -rf $(VENV)
	@echo "✓ Full clean including venv"

# ── Results ───────────────────────────────────────────────────────────────────

save-01:
	bash save-results.sh 01-oomkill

save-02:
	bash save-results.sh 02-configmap-env

save-03:
	bash save-results.sh 03-configmap-mount

commit-results:
	git add docs/poc-results/ output/ .gitignore
	git status
	@echo ""
	@echo "Review above, then:"
	@echo "  git commit -m 'poc: scenario results - arXiv evidence'"
	@echo "  git push"