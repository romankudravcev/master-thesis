#!/bin/bash

# PostgreSQL StatefulSet Benchmark Setup Script

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Config
NAMESPACE="postgres"
SECRET_FILE="secret.yaml"
POSTGRES_FILE="postgres.yaml"
TEST_DATA_COUNT=1000
POSTGRES_SERVICE="postgres"
POSTGRES_PORT="5432"
POSTGRES_DB="app"
POSTGRES_USER="admin"

# Functions
check_prerequisites() {
  print_status "Checking prerequisites..."
  if ! command -v kubectl >/dev/null 2>&1; then
    print_error "kubectl not found!"
    exit 1
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    print_error "Cannot connect to Kubernetes cluster!"
    exit 1
  fi
  print_success "Prerequisites OK"
}

create_namespace() {
  if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    print_warning "Namespace $NAMESPACE already exists."
  else
    kubectl create namespace "$NAMESPACE"
    print_success "Namespace $NAMESPACE created."
  fi
}

apply_yamls() {
  print_status "Applying ConfigMap/Secret..."
  kubectl apply -n "$NAMESPACE" -f "$SECRET_FILE"
  print_status "Applying StatefulSet and Service..."
  kubectl apply -n "$NAMESPACE" -f "$POSTGRES_FILE"
}

wait_for_statefulset() {
  print_status "Waiting for StatefulSet pods to be ready..."
  kubectl rollout status statefulset/postgres -n "$NAMESPACE" --timeout=600s
  print_success "All pods are ready."
}

get_postgres_password() {
  POSTGRES_PASSWORD=$(kubectl get secret postgres-secret -n "$NAMESPACE" -o jsonpath='{.data.POSTGRESQL_PASSWORD}' | base64 -d)
}

create_test_data() {
  get_postgres_password
  print_status "Creating PostgreSQL client pod..."
  kubectl run postgres-client-temp -n "$NAMESPACE" --image=postgres:16 --restart=Never -- sleep 3600
  kubectl wait --for=condition=ready pod/postgres-client-temp -n "$NAMESPACE" --timeout=120s

  print_status "Creating database '$POSTGRES_DB' if not exists..."
  kubectl exec -n "$NAMESPACE" postgres-client-temp -- bash -c "
    export PGPASSWORD=$POSTGRES_PASSWORD;
    psql -h ${POSTGRES_SERVICE} -p ${POSTGRES_PORT} -U ${POSTGRES_USER} -d postgres -c \"
      CREATE DATABASE ${POSTGRES_DB};
    \" || true
  "

  print_status "Inserting $TEST_DATA_COUNT test rows into '$POSTGRES_DB'..."
  kubectl exec -n "$NAMESPACE" postgres-client-temp -- bash -c "
    export PGPASSWORD=$POSTGRES_PASSWORD;
    psql -h ${POSTGRES_SERVICE} -p ${POSTGRES_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \"
      DROP TABLE IF EXISTS messages;
      CREATE TABLE messages (
          id SERIAL PRIMARY KEY,
          content TEXT NOT NULL,
          created_at TIMESTAMP DEFAULT NOW(),
          host_ip TEXT NOT NULL
      );
      CREATE INDEX idx_messages_id ON messages(id);
      CREATE INDEX idx_messages_created_at ON messages(created_at);
      CREATE INDEX idx_messages_host_ip ON messages(host_ip);
      INSERT INTO messages (content, host_ip)
      SELECT
          'Test message ' || generate_series || ' - Benchmark data',
          ('192.168.1.' || (FLOOR(RANDOM() * 254) + 1)::int)::inet
      FROM generate_series(1, ${TEST_DATA_COUNT});
      SELECT COUNT(*) as total_count FROM messages;
    \"
  "
}

verify_test_data() {
  get_postgres_password
  print_status "Verifying test data in '$POSTGRES_DB'..."
  kubectl exec -n "$NAMESPACE" postgres-client-temp -- bash -c "
    export PGPASSWORD=$POSTGRES_PASSWORD;
    psql -h ${POSTGRES_SERVICE} -p ${POSTGRES_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'SELECT COUNT(*) FROM messages;'
  "
}

cleanup_client_pod() {
  print_status "Cleaning up client pod..."
  kubectl delete pod postgres-client-temp -n "$NAMESPACE" --ignore-not-found
}

# Main
check_prerequisites
create_namespace
apply_yamls
wait_for_statefulset
create_test_data
verify_test_data
cleanup_client_pod
print_success "PostgreSQL StatefulSet benchmark setup completed."
