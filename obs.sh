#!/usr/bin/env bash
set -euo pipefail

# ── Configurações ─────────────────────────────────────────────────────────────
CONFIG_DIR="$(cd "$(dirname "$0")/config" && pwd)"
NETWORK="otel-net"

# ── Cores para output ─────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; }

# ── Rede ──────────────────────────────────────────────────────────────────────

create_network() {
  if ! sudo podman network exists "$NETWORK" 2>/dev/null; then
    echo "🌐 Criando rede $NETWORK..."
    sudo podman network create \
      --driver bridge \
      --opt com.docker.network.bridge.name=otel-br0 \
      --subnet 172.20.0.0/16 \
      --gateway 172.20.0.1 \
      --disable-dns=false \
      "$NETWORK"
    log "Rede $NETWORK criada"
  else
    warn "Rede $NETWORK já existe, reutilizando"
  fi
}

remove_network() {
  if sudo podman network exists "$NETWORK" 2>/dev/null; then
    sudo podman network rm "$NETWORK" 2>/dev/null || true
    log "Rede $NETWORK removida"
  fi
}

# ── Subir serviços ────────────────────────────────────────────────────────────

start_tempo() {
  echo "🔷 Subindo Grafana Tempo..."
  sudo podman run -d \
    --name tempo \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p 3200:3200 \
    -v "$CONFIG_DIR/tempo.yaml:/etc/tempo/config.yaml:ro" \
    docker.io/grafana/tempo:latest \
    -config.file=/etc/tempo/config.yaml
  log "Tempo ok → http://localhost:3200"
}

start_prometheus() {
  echo "🔶 Subindo Prometheus..."
  sudo podman run -d \
    --name prometheus \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p 9090:9090 \
    -v "$CONFIG_DIR/prometheus.yaml:/etc/prometheus/prometheus.yaml:ro" \
    docker.io/prom/prometheus:latest \
    --config.file=/etc/prometheus/prometheus.yaml \
    --web.enable-remote-write-receiver \
    --enable-feature=exemplar-storage
  log "Prometheus ok → http://localhost:9090"
}

start_loki() {
  echo "🟠 Subindo Grafana Loki..."
  sudo podman run -d \
    --name loki \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p 3100:3100 \
    -v "$CONFIG_DIR/loki.yaml:/etc/loki/config.yaml:ro" \
    docker.io/grafana/loki:latest \
    -config.file=/etc/loki/config.yaml
  log "Loki ok → http://localhost:3100"
}

start_collector() {
  echo "🟣 Subindo OTel Collector..."
  sudo podman run -d \
    --name otel-collector \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p 4317:4317 \
    -p 4318:4318 \
    -p 8888:8888 \
    -v "$CONFIG_DIR/otel-collector.yaml:/etc/otel/config.yaml:ro" \
    docker.io/otel/opentelemetry-collector-contrib:latest \
    --config=/etc/otel/config.yaml
  log "OTel Collector ok → gRPC :4317"
}

start_grafana() {
  echo "🟡 Subindo Grafana..."
  sudo podman run -d \
    --name grafana \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p 3000:3000 \
    -e GF_AUTH_ANONYMOUS_ENABLED=true \
    -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
    -e GF_AUTH_DISABLE_LOGIN_FORM=true \
    -v "$CONFIG_DIR/grafana/provisioning:/etc/grafana/provisioning:ro" \
    docker.io/grafana/grafana:latest
  log "Grafana ok → http://localhost:3000"
}

# ── Up ────────────────────────────────────────────────────────────────────────

up() {
  echo "🚀 Subindo ambiente de observabilidade..."
  echo ""

  create_network

  # Sobe na ordem correta — backends primeiro, collector depois, grafana por último
  start_tempo
  start_prometheus
  start_loki
  start_collector
  start_grafana

  echo ""
  echo "═══════════════════════════════════════════"
  log "Ambiente pronto!"
  echo ""
  echo "  Grafana      → http://localhost:3000"
  echo "  Prometheus   → http://localhost:9090"
  echo "  Loki API     → http://localhost:3100"
  echo "  Tempo API    → http://localhost:3200"
  echo "  OTel gRPC    → localhost:4317  ← microsserviços apontam aqui"
  echo "═══════════════════════════════════════════"
  echo ""
}

# ── Down ──────────────────────────────────────────────────────────────────────

down() {
  echo "🛑 Derrubando ambiente..."
  echo ""

  for container in grafana otel-collector loki prometheus tempo; do
    if sudo podman container exists "$container" 2>/dev/null; then
      echo "  Removendo $container..."
      sudo podman rm -f "$container" 2>/dev/null || true
    fi
  done

  remove_network

  echo ""
  log "Ambiente encerrado."
}

# ── Logs ──────────────────────────────────────────────────────────────────────

logs() {
  local service="${1:-}"

  if [ -z "$service" ]; then
    echo "Uso: $0 logs {tempo|prometheus|loki|otel-collector|grafana}"
    exit 1
  fi

  sudo podman logs -f "$service"
}

# ── Status ────────────────────────────────────────────────────────────────────

status() {
  echo "📊 Status dos containers:"
  echo ""
  sudo podman ps --filter "name=tempo" \
                 --filter "name=prometheus" \
                 --filter "name=loki" \
                 --filter "name=otel-collector" \
                 --filter "name=grafana" \
                 --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# ── Restart ───────────────────────────────────────────────────────────────────

restart() {
  down
  sleep 2
  up
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

case "${1:-up}" in
  up)      up ;;
  down)    down ;;
  restart) restart ;;
  logs)    logs "${2:-}" ;;
  status)  status ;;
  *)
    echo "Uso: $0 {up|down|restart|logs <serviço>|status}"
    exit 1
    ;;
esac
