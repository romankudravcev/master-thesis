#!/bin/bash

# PostgreSQL CNPG Benchmark Setup Script
# This script installs CloudNativePG Operator and applies configuration

set -e # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration variables
NAMESPACE=${NAMESPACE:-"postgres"}
CNPG_OPERATOR_URL="https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.26/releases/cnpg-1.26.0.yaml"
YAML_FILE=${YAML_FILE:-"postgres.yaml"}
POSTGRES_CLUSTER_NAME="my-postgres-cluster"
TEST_DATA_COUNT=100

# Function to check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to check prerequisites
check_prerequisites() {
  print_status "Checking prerequisites..."

  # Check if kubectl is installed
  if ! command_exists kubectl; then
    print_error "kubectl is not installed. Please install kubectl first."
    exit 1
  fi

  # Check if KUBECONFIG is set
  if [ -z "$KUBECONFIG" ]; then
    print_warning "KUBECONFIG environment variable is not set. Using default kubeconfig."
  else
    print_status "Using KUBECONFIG: $KUBECONFIG"
  fi

  # Test kubectl connection
  if ! kubectl cluster-info >/dev/null 2>&1; then
    print_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
    exit 1
  fi

  print_success "Prerequisites check passed!"
}

# Function to check existing CNPG operator installation
check_existing_operator() {
  print_status "Checking for existing CloudNativePG Operator installations..."

  # Check for existing CRDs
  local crd_exists=$(kubectl get crd clusters.postgresql.cnpg.io 2>/dev/null && echo "true" || echo "false")

  if [ "$crd_exists" = "true" ]; then
    print_warning "CloudNativePG CRD already exists!"
    OPERATOR_EXISTS=true
  else
    print_status "No existing CloudNativePG Operator found."
    OPERATOR_EXISTS=false
  fi

  # Check for existing operator deployments
  local operator_deployments=$(kubectl get deployments -n cnpg-system cnpg-controller-manager --no-headers 2>/dev/null | wc -l)

  if [ "$operator_deployments" -gt 0 ]; then
    print_status "Found existing CloudNativePG operator deployment:"
    kubectl get deployments -n cnpg-system cnpg-controller-manager
    OPERATOR_EXISTS=true
  else
    OPERATOR_EXISTS=false
  fi
}

# Function to create namespace
create_namespace() {
  print_status "Creating namespace: $NAMESPACE"

  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    print_warning "Namespace '$NAMESPACE' already exists, skipping creation."
  else
    kubectl create namespace "$NAMESPACE"
    print_success "Namespace '$NAMESPACE' created successfully!"
  fi
}

# Function to install CloudNativePG Operator
install_cnpg_operator() {
  if [ "$OPERATOR_EXISTS" = true ]; then
    print_status "CloudNativePG Operator already exists. Verifying it's working..."

    # Check if the operator is running
    local operator_ready=$(kubectl get deployments -n cnpg-system cnpg-controller-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

    if [ "$operator_ready" -gt 0 ]; then
      print_success "Existing CloudNativePG Operator is running!"
      return 0
    else
      print_warning "Existing CloudNativePG Operator is not ready. Attempting to reinstall..."
    fi
  fi

  print_status "Installing CloudNativePG Operator..."

  # Install the operator
  kubectl apply --server-side -f "$CNPG_OPERATOR_URL"

  print_success "CloudNativePG Operator installation completed!"
}

# Function to wait for operator to be ready
wait_for_operator() {
  print_status "Waiting for CloudNativePG Operator to be ready..."

  # Wait for the cnpg-system namespace to be created
  local max_attempts=30
  local attempt=0
  while [ $attempt -lt $max_attempts ]; do
    if kubectl get namespace cnpg-system >/dev/null 2>&1; then
      break
    fi
    print_status "Waiting for cnpg-system namespace... (attempt $((attempt + 1))/$max_attempts)"
    sleep 5
    ((attempt++))
  done

  if [ $attempt -eq $max_attempts ]; then
    print_error "cnpg-system namespace was not created within timeout!"
    exit 1
  fi

  # Wait for the operator deployment to be ready
  kubectl wait --for=condition=available --timeout=300s deployment/cnpg-controller-manager -n cnpg-system

  print_success "CloudNativePG Operator is ready!"
}

# Function to apply YAML configuration
apply_yaml_config() {
  if [ -f "$YAML_FILE" ]; then
    print_status "Applying YAML configuration from: $YAML_FILE"
    kubectl apply -f "$YAML_FILE"
    print_success "YAML configuration applied successfully!"
  else
    print_warning "YAML file '$YAML_FILE' not found. Skipping YAML application."
    print_status "You can specify the YAML file using: YAML_FILE=your-file.yaml $0"
  fi
}

# Function to wait for PostgreSQL cluster to be running
wait_for_postgres_running() {
  print_status "Waiting for PostgreSQL cluster '$POSTGRES_CLUSTER_NAME' to be running..."

  local max_attempts=60 # 10 minutes (60 * 10 seconds)
  local attempt=0

  while [ $attempt -lt $max_attempts ]; do
    # Check if the resource exists
    if ! kubectl get cluster "$POSTGRES_CLUSTER_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
      print_status "PostgreSQL cluster not found yet, waiting..."
      sleep 10
      ((attempt++))
      continue
    fi

    # Get the current phase
    local phase=$(kubectl get cluster "$POSTGRES_CLUSTER_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [ "$phase" = "Cluster in healthy state" ]; then
      print_success "PostgreSQL cluster is now running!"
      return 0
    else
      print_status "PostgreSQL cluster phase: '$phase', waiting... (attempt $((attempt + 1))/$max_attempts)"
      sleep 10
      ((attempt++))
    fi
  done

  print_error "PostgreSQL cluster did not reach healthy state within timeout!"
  exit 1
}

# Function to get PostgreSQL credentials
get_postgres_credentials() {
  print_status "Retrieving PostgreSQL credentials..."

  # Get the password from the secret (CNPG creates a secret with the cluster name)
  local postgres_password=$(kubectl get secret "${POSTGRES_CLUSTER_NAME}-app" -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

  if [ -z "$postgres_password" ]; then
    print_error "Failed to retrieve PostgreSQL password from secret"
    exit 1
  fi

  # Set global variables
  POSTGRES_HOST="${POSTGRES_CLUSTER_NAME}-rw.${NAMESPACE}.svc.cluster.local"
  POSTGRES_PORT="5432"
  POSTGRES_USER="app"
  POSTGRES_PASSWORD="$postgres_password"
  POSTGRES_DATABASE="app"

  print_success "PostgreSQL credentials retrieved successfully!"
  print_status "PostgreSQL connection details:"
  print_status "  Host: $POSTGRES_HOST"
  print_status "  Port: $POSTGRES_PORT"
  print_status "  User: $POSTGRES_USER"
  print_status "  Password: (hidden)"
  print_status "  Database: $POSTGRES_DATABASE"
}

# Function to create test data
create_test_data() {
  print_status "Creating test data in PostgreSQL..."

  # Get PostgreSQL credentials
  get_postgres_credentials

  # Create a temporary pod to run PostgreSQL client
  print_status "Creating temporary PostgreSQL client pod..."

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: postgres-client-temp
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: postgres-client
    image: postgres:16
    command: ["/bin/bash", "-c", "sleep 3600"]
    env:
    - name: PGHOST
      value: "${POSTGRES_HOST}"
    - name: PGPORT
      value: "${POSTGRES_PORT}"
    - name: PGUSER
      value: "${POSTGRES_USER}"
    - name: PGPASSWORD
      value: "${POSTGRES_PASSWORD}"
    - name: PGDATABASE
      value: "${POSTGRES_DATABASE}"
  restartPolicy: Never
EOF

  # Wait for the client pod to be ready
  print_status "Waiting for PostgreSQL client pod to be ready..."
  kubectl wait --for=condition=ready pod/postgres-client-temp -n "$NAMESPACE" --timeout=120s

  # Wait a bit more for PostgreSQL to be fully ready
  print_status "Waiting for PostgreSQL to be fully ready..."
  sleep 30

  # Test PostgreSQL connectivity first
  print_status "Testing PostgreSQL connectivity..."

  local connection_test=$(kubectl exec -n "$NAMESPACE" postgres-client-temp -- psql -c "SELECT 1;" -t 2>/dev/null | grep -c "1" || echo "0")

  if [ "$connection_test" != "1" ]; then
    print_error "Cannot connect to PostgreSQL. Checking PostgreSQL status..."

    # Debug information
    print_status "PostgreSQL cluster status:"
    kubectl get cluster -n "$NAMESPACE" "$POSTGRES_CLUSTER_NAME" -o wide

    print_status "PostgreSQL pods:"
    kubectl get pods -n "$NAMESPACE" -l cnpg.io/cluster="$POSTGRES_CLUSTER_NAME"

    exit 1
  fi

  print_success "PostgreSQL connection test passed!"

  # Create the messages table and insert test data
  print_status "Creating messages table and inserting $TEST_DATA_COUNT test messages..."

  local insert_output=$(kubectl exec -n "$NAMESPACE" postgres-client-temp -- psql -c "
    -- Drop table if exists
    DROP TABLE IF EXISTS messages;

    -- Create messages table
    CREATE TABLE messages (
        id SERIAL PRIMARY KEY,
        content TEXT NOT NULL,
        created_at TIMESTAMP DEFAULT NOW(),
        host_ip INET
    );

    -- Create indexes for better performance
    CREATE INDEX idx_messages_id ON messages(id);
    CREATE INDEX idx_messages_created_at ON messages(created_at);
    CREATE INDEX idx_messages_host_ip ON messages(host_ip);

    -- Insert test data
    INSERT INTO messages (content, host_ip)
    SELECT
        'Test message ' || generate_series || ' - This is a sample message for benchmarking purposes. Message ID: ' || generate_series,
        ('192.168.1.' || (FLOOR(RANDOM() * 254) + 1)::int)::inet
    FROM generate_series(1, ${TEST_DATA_COUNT});

    -- Return the count
    SELECT COUNT(*) as total_count FROM messages;
  " 2>&1)

  print_status "Insert operation output:"
  echo "$insert_output"

  # Extract the count from the output
  local inserted_count=$(echo "$insert_output" | grep -E "^\s*[0-9]+\s*$" | tail -1 | tr -d ' ')

  if [ -n "$inserted_count" ] && [ "$inserted_count" -eq "$TEST_DATA_COUNT" ]; then
    print_success "Test data created successfully!"
    print_status "Inserted $inserted_count messages into the 'messages' table in database '$POSTGRES_DATABASE'"
  else
    print_error "Failed to create test data! Expected $TEST_DATA_COUNT, got: $inserted_count"

    # Try to get actual count from database
    print_status "Checking actual count in database..."
    local actual_count=$(kubectl exec -n "$NAMESPACE" postgres-client-temp -- psql -c "SELECT COUNT(*) FROM messages;" -t 2>/dev/null | tr -d ' ' || echo "0")

    print_status "Actual count in database: $actual_count"

    if [ "$actual_count" -eq "$TEST_DATA_COUNT" ]; then
      print_success "Data insertion actually succeeded! Count matches expected value."
    else
      print_error "Data insertion failed. Check PostgreSQL logs for details."
      kubectl logs -n "$NAMESPACE" "${POSTGRES_CLUSTER_NAME}-1" --tail=50 || true
      exit 1
    fi
  fi

  # Clean up temporary pod
  print_status "Cleaning up temporary PostgreSQL client pod..."
  kubectl delete pod postgres-client-temp -n "$NAMESPACE" --ignore-not-found=true
}

# Function to verify test data
verify_test_data() {
  print_status "Verifying test data..."

  # Create a temporary pod to verify data
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: postgres-verify-temp
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: postgres-client
    image: postgres:16
    command: ["/bin/bash", "-c", "sleep 300"]
    env:
    - name: PGHOST
      value: "${POSTGRES_HOST}"
    - name: PGPORT
      value: "${POSTGRES_PORT}"
    - name: PGUSER
      value: "${POSTGRES_USER}"
    - name: PGPASSWORD
      value: "${POSTGRES_PASSWORD}"
    - name: PGDATABASE
      value: "${POSTGRES_DATABASE}"
  restartPolicy: Never
EOF

  kubectl wait --for=condition=ready pod/postgres-verify-temp -n "$NAMESPACE" --timeout=60s

  # Execute verification
  local verify_output=$(kubectl exec -n "$NAMESPACE" postgres-verify-temp -- psql -c "
    -- Count documents
    SELECT 'DOCUMENT_COUNT=' || COUNT(*) FROM messages;

    -- Show some sample data
    SELECT 'SAMPLE_DATA: ' || jsonb_pretty(jsonb_agg(row_to_json(t)))
    FROM (SELECT id, content, created_at, host_ip FROM messages LIMIT 2) t;

    -- Show table stats
    SELECT 'TABLE_SIZE=' || COUNT(*) FROM messages;

    -- Show indexes
    SELECT 'INDEXES_COUNT=' || COUNT(*) FROM pg_indexes WHERE tablename = 'messages';
  " 2>&1)

  # Extract count from output
  local count=$(echo "$verify_output" | grep "DOCUMENT_COUNT=" | sed 's/.*DOCUMENT_COUNT=//' | tr -d ' ')

  print_status "Verification output:"
  echo "$verify_output"

  print_status "Total documents in database: $count"

  # Check if count is a valid number
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    if [ "$count" -eq "$TEST_DATA_COUNT" ]; then
      print_success "Test data verification passed!"

      # Show sample data
      local sample_data=$(echo "$verify_output" | grep "SAMPLE_DATA:" | sed 's/.*SAMPLE_DATA: //')
      if [ -n "$sample_data" ]; then
        print_status "Sample data preview:"
        echo "$sample_data" | head -c 200
        echo "..."
      fi
    else
      print_warning "Expected $TEST_DATA_COUNT documents, found $count"
    fi
  else
    print_error "Could not determine document count. Raw output:"
    echo "$verify_output"
  fi

  # Clean up verification pod
  kubectl delete pod postgres-verify-temp -n "$NAMESPACE" --ignore-not-found=true
}

# Function to display cluster and deployment info
display_info() {
  print_status "Deployment Information:"
  echo "=========================="
  echo "Namespace: $NAMESPACE"
  echo "PostgreSQL Cluster: $POSTGRES_CLUSTER_NAME"
  echo "KUBECONFIG: ${KUBECONFIG:-"default"}"
  echo "Test Data Count: $TEST_DATA_COUNT"
  echo "=========================="

  print_status "Checking CloudNativePG Operator status..."
  kubectl get deployments -n cnpg-system cnpg-controller-manager || print_status "No CNPG operator deployment found"

  print_status "Checking PostgreSQL cluster status..."
  kubectl get cluster "$POSTGRES_CLUSTER_NAME" -n "$NAMESPACE" -o wide

  print_status "PostgreSQL Connection Information:"
  echo "Host: ${POSTGRES_HOST}"
  echo "Port: ${POSTGRES_PORT}"
  echo "Username: ${POSTGRES_USER}"
  echo "Password: (hidden, stored in secret '${POSTGRES_CLUSTER_NAME}-app')"
  echo "Database: ${POSTGRES_DATABASE}"
  echo "Table: messages"

  print_status "PostgreSQL Pods:"
  kubectl get pods -n "$NAMESPACE" -l cnpg.io/cluster="$POSTGRES_CLUSTER_NAME"

  print_status "PostgreSQL Services:"
  kubectl get svc -n "$NAMESPACE" -l cnpg.io/cluster="$POSTGRES_CLUSTER_NAME"
}

# Function to cleanup (optional)
cleanup() {
  print_status "Cleaning up PostgreSQL benchmark setup..."

  # Remove temporary pods
  kubectl delete pod postgres-client-temp -n "$NAMESPACE" --ignore-not-found=true
  kubectl delete pod postgres-verify-temp -n "$NAMESPACE" --ignore-not-found=true

  # Remove PostgreSQL cluster
  kubectl delete cluster --all -n "$NAMESPACE" 2>/dev/null || true

  # Remove secrets
  kubectl delete secret "${POSTGRES_CLUSTER_NAME}-app" -n "$NAMESPACE" 2>/dev/null || true

  # Ask before removing operator
  read -p "Do you want to remove the CloudNativePG Operator? (y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Remove operator
    kubectl delete -f "$CNPG_OPERATOR_URL" 2>/dev/null || true
  fi

  # Delete namespace
  kubectl delete namespace "$NAMESPACE" 2>/dev/null || true

  print_success "Cleanup completed!"
}

# Main function
main() {
  print_status "Starting PostgreSQL CNPG Benchmark Setup..."

  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --yaml-file)
      YAML_FILE="$2"
      shift 2
      ;;
    --cluster-name)
      POSTGRES_CLUSTER_NAME="$2"
      shift 2
      ;;
    --test-data-count)
      TEST_DATA_COUNT="$2"
      shift 2
      ;;
    --cleanup)
      cleanup
      exit 0
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo "Options:"
      echo "  --namespace NAME        Specify namespace (default: postgres)"
      echo "  --yaml-file FILE        Specify YAML file to apply (default: postgres.yaml)"
      echo "  --cluster-name NAME     Specify PostgreSQL cluster name (default: my-postgres-cluster)"
      echo "  --test-data-count NUM   Number of test records to create (default: 100)"
      echo "  --cleanup               Remove all resources and exit"
      echo "  --help                  Show this help message"
      echo ""
      echo "Environment variables:"
      echo "  NAMESPACE              Override default namespace"
      echo "  YAML_FILE              Override default YAML file"
      echo "  KUBECONFIG             Kubernetes config file (should be exported)"
      exit 0
      ;;
    *)
      print_error "Unknown option: $1"
      echo "Use --help for usage information."
      exit 1
      ;;
    esac
  done

  # Execute setup steps
  check_prerequisites
  check_existing_operator
  create_namespace
  install_cnpg_operator
  wait_for_operator
  apply_yaml_config
  wait_for_postgres_running
  create_test_data
  verify_test_data
  display_info

  print_success "PostgreSQL CNPG benchmark setup completed successfully!"
  print_status "Your PostgreSQL cluster is ready for benchmarking with $TEST_DATA_COUNT test records!"
}

# Trap to handle script interruption
trap 'print_error "Script interrupted!"; exit 1' INT TERM

# Run main function
main "$@"
