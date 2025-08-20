#!/bin/bash

# Benchmark Applications Deployment Script
# This script deploys the clustershift-benchmark-application and k8s-metrics-collector
# with dynamic database configuration for PostgreSQL or MongoDB

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

# Default configuration variables
BENCHMARK_NAMESPACE=${BENCHMARK_NAMESPACE:-"benchmark"}
METRICS_NAMESPACE=${METRICS_NAMESPACE:-"clustershift"}

# Database configuration variables
DB_TYPE=""
DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASSWORD=""
DB_NAME=""

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_APP_DIR="${SCRIPT_DIR}/../benchmark-applications/clustershift-benchmark-application"
METRICS_COLLECTOR_DIR="${SCRIPT_DIR}/../benchmark-applications/k8s-metrics-collector"

# Function to check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to show help
show_help() {
  cat << EOF
Usage: $0 [OPTIONS]

Options:
  Application Configuration:
    --benchmark-namespace NAME      Specify benchmark namespace (default: benchmark)
    --metrics-namespace NAME        Specify metrics namespace (default: clustershift)

  Database Configuration:
    --db-type TYPE                  Database type: mongodb or postgresql (required)
    --db-host HOST                  Database host (required)
    --db-port PORT                  Database port (required)
    --db-user USER                  Database username (required)
    --db-password PASSWORD          Database password (required)
    --db-name NAME                  Database name (required)

  Actions:
    --cleanup                       Remove all resources and exit
    --help                          Show this help message

Examples:
  # Deploy with PostgreSQL
  $0 --db-type postgresql --db-host pg.example.com --db-port 5432 \\
     --db-user myuser --db-password mypass --db-name mydb

  # Deploy with MongoDB
  $0 --db-type mongodb --db-host mongo.example.com --db-port 27017 \\
     --db-user myuser --db-password mypass --db-name mydb

  # Deploy with in-cluster database
  $0 --db-type postgresql --db-host postgres-svc.database.svc.cluster.local --db-port 5432 \\
     --db-user myuser --db-password mypass --db-name mydb

EOF
}

# Function to validate required parameters
validate_parameters() {
  local errors=0

  if [ -z "$DB_TYPE" ]; then
    print_error "Database type is required. Use --db-type [mongodb|postgresql]"
    errors=$((errors + 1))
  elif [ "$DB_TYPE" != "mongodb" ] && [ "$DB_TYPE" != "postgresql" ]; then
    print_error "Invalid database type. Supported types: mongodb, postgresql"
    errors=$((errors + 1))
  fi

  if [ -z "$DB_HOST" ]; then
    print_error "Database host is required. Use --db-host HOST"
    errors=$((errors + 1))
  fi

  if [ -z "$DB_PORT" ]; then
    print_error "Database port is required. Use --db-port PORT"
    errors=$((errors + 1))
  fi

  if [ -z "$DB_USER" ]; then
    print_error "Database user is required. Use --db-user USER"
    errors=$((errors + 1))
  fi

  if [ -z "$DB_PASSWORD" ]; then
    print_error "Database password is required. Use --db-password PASSWORD"
    errors=$((errors + 1))
  fi

  if [ -z "$DB_NAME" ]; then
    print_error "Database name is required. Use --db-name NAME"
    errors=$((errors + 1))
  fi

  if [ $errors -gt 0 ]; then
    print_error "Please fix the above errors and try again."
    echo "Use --help for usage information."
    exit 1
  fi
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

  # Check if deployment files exist
  if [ ! -f "${BENCHMARK_APP_DIR}/infra/deployment.yml" ]; then
    print_error "Benchmark application deployment file not found: ${BENCHMARK_APP_DIR}/infra/deployment.yml"
    exit 1
  fi

  if [ ! -f "${METRICS_COLLECTOR_DIR}/deployment.yml" ]; then
    print_error "Metrics collector deployment file not found: ${METRICS_COLLECTOR_DIR}/deployment.yml"
    exit 1
  fi

  print_success "Prerequisites check passed!"
}

# Function to create namespaces
create_namespaces() {
  print_status "Creating namespaces..."

  # Create benchmark namespace
  if kubectl get namespace "$BENCHMARK_NAMESPACE" >/dev/null 2>&1; then
    print_warning "Namespace '$BENCHMARK_NAMESPACE' already exists."
  else
    kubectl create namespace "$BENCHMARK_NAMESPACE"
    print_success "Namespace '$BENCHMARK_NAMESPACE' created!"
  fi

  # Create metrics namespace
  if kubectl get namespace "$METRICS_NAMESPACE" >/dev/null 2>&1; then
    print_warning "Namespace '$METRICS_NAMESPACE' already exists."
  else
    kubectl create namespace "$METRICS_NAMESPACE"
    print_success "Namespace '$METRICS_NAMESPACE' created!"
  fi
}

# Function to create database ConfigMap
create_database_configmap() {
  print_status "Creating database ConfigMap..."

  # Create database URI based on type
  local db_uri=""
  if [ "$DB_TYPE" = "mongodb" ]; then
    db_uri="mongodb://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?authSource=${DB_NAME}"
  elif [ "$DB_TYPE" = "postgresql" ]; then
    db_uri="postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
  fi

  # Create the ConfigMap
  kubectl create configmap clustershift-benchmark-config \
    --from-literal=DB_HOST="$DB_HOST" \
    --from-literal=DB_PORT="$DB_PORT" \
    --from-literal=DB_USER="$DB_USER" \
    --from-literal=DB_PASSWORD="$DB_PASSWORD" \
    --from-literal=DB_NAME="$DB_NAME" \
    --from-literal=DB_TYPE="$DB_TYPE" \
    --from-literal=DATABASE_URI="$db_uri" \
    --namespace="$BENCHMARK_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  print_success "Database ConfigMap created successfully!"
  print_status "Database connection details:"
  print_status "  Type: $DB_TYPE"
  print_status "  Host: $DB_HOST"
  print_status "  Port: $DB_PORT"
  print_status "  Database: $DB_NAME"
  print_status "  User: $DB_USER"
  print_status "  URI: $(echo "$db_uri" | sed "s/:${DB_PASSWORD}@/:***@/")" # Hide password in output
}

# Function to deploy benchmark application
deploy_benchmark_application() {
  print_status "Deploying benchmark application..."

  kubectl apply -f "${BENCHMARK_APP_DIR}/infra/deployment.yml"

  print_success "Benchmark application deployed successfully!"
}

# Function to deploy metrics collector
deploy_metrics_collector() {
  print_status "Deploying k8s-metrics-collector..."

  kubectl apply -f "${METRICS_COLLECTOR_DIR}/deployment.yml"

  print_success "k8s-metrics-collector deployed successfully!"
}

# Function to wait for deployments to be ready
wait_for_deployments() {
  print_status "Waiting for deployments to be ready..."

  # Wait for benchmark application
  print_status "Waiting for benchmark application to be ready..."
  kubectl wait --for=condition=available --timeout=300s deployment/clustershift-benchmark-deployment -n "$BENCHMARK_NAMESPACE"

  # Wait for metrics collector
  print_status "Waiting for metrics collector to be ready..."
  kubectl wait --for=condition=available --timeout=300s deployment/metrics-collector -n "$METRICS_NAMESPACE"

  print_success "All deployments are ready!"
}

# Function to display deployment information
display_info() {
  print_status "Deployment Information:"
  echo "=========================="
  echo "Benchmark Namespace: $BENCHMARK_NAMESPACE"
  echo "Metrics Namespace: $METRICS_NAMESPACE"
  echo "Database Type: $DB_TYPE"
  echo "Database Host: $DB_HOST"
  echo "Database Port: $DB_PORT"
  echo "Database Name: $DB_NAME"
  echo "=========================="

  print_status "Pod Status:"
  kubectl get pods -n "$BENCHMARK_NAMESPACE"
  kubectl get pods -n "$METRICS_NAMESPACE"

  print_status "Service URLs (from within cluster):"
  echo "Benchmark Application: http://clustershift-benchmark-service.${BENCHMARK_NAMESPACE}.svc.cluster.local"
  echo "Metrics Collector: http://metrics-collector.${METRICS_NAMESPACE}.svc.cluster.local"

  print_status "To access services from outside cluster, use port-forward:"
  echo "kubectl port-forward -n $BENCHMARK_NAMESPACE svc/clustershift-benchmark-service 8080:80"
  echo "kubectl port-forward -n $METRICS_NAMESPACE svc/metrics-collector 8089:80"
}

# Function to cleanup deployments
cleanup() {
  print_status "Cleaning up benchmark deployments..."

  # Remove applications
  kubectl delete -f "${BENCHMARK_APP_DIR}/infra/deployment.yml" --ignore-not-found=true
  kubectl delete -f "${METRICS_COLLECTOR_DIR}/deployment.yml" --ignore-not-found=true

  # Remove ConfigMap
  kubectl delete configmap clustershift-benchmark-config -n "$BENCHMARK_NAMESPACE" --ignore-not-found=true

  print_success "Cleanup completed!"
}

# Main function
main() {
  print_status "Starting benchmark applications deployment..."

  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
    --benchmark-namespace)
      BENCHMARK_NAMESPACE="$2"
      shift 2
      ;;
    --metrics-namespace)
      METRICS_NAMESPACE="$2"
      shift 2
      ;;
    --db-type)
      DB_TYPE="$2"
      shift 2
      ;;
    --db-host)
      DB_HOST="$2"
      shift 2
      ;;
    --db-port)
      DB_PORT="$2"
      shift 2
      ;;
    --db-user)
      DB_USER="$2"
      shift 2
      ;;
    --db-password)
      DB_PASSWORD="$2"
      shift 2
      ;;
    --db-name)
      DB_NAME="$2"
      shift 2
      ;;
    --cleanup)
      cleanup
      exit 0
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      print_error "Unknown option: $1"
      echo "Use --help for usage information."
      exit 1
      ;;
    esac
  done

  # Validate required parameters
  validate_parameters

  # Execute deployment steps
  check_prerequisites
  create_namespaces
  create_database_configmap
  deploy_benchmark_application
  deploy_metrics_collector
  wait_for_deployments
  display_info

  print_success "Benchmark applications deployment completed successfully!"
  print_status "Your benchmark environment is ready!"
}

# Trap to handle script interruption
trap 'print_error "Script interrupted!"; exit 1' INT TERM

# Run main function
main "$@"
