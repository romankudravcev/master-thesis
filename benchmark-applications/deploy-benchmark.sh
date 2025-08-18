#!/bin/bash

# Benchmark Applications Deployment Script
# This script deploys the clustershift-benchmark-application and k8s-metrics-collector

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
BENCHMARK_NAMESPACE=${BENCHMARK_NAMESPACE:-"benchmark"}
METRICS_NAMESPACE=${METRICS_NAMESPACE:-"clustershift"}
MONGODB_NAMESPACE=${MONGODB_NAMESPACE:-"mongodb"}
MONGODB_RESOURCE_NAME=${MONGODB_RESOURCE_NAME:-"example-mongodb"}
MONGODB_TESTDB_USER=${MONGODB_TESTDB_USER:-"testdb_user"}
MONGODB_DATABASE=${MONGODB_DATABASE:-"testdb"}

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_APP_DIR="${SCRIPT_DIR}/../benchmark-applications/clustershift-benchmark-application"
METRICS_COLLECTOR_DIR="${SCRIPT_DIR}/../benchmark-applications/k8s-metrics-collector"

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

# Function to get MongoDB credentials and create ConfigMap
create_mongodb_configmap() {
  print_status "Creating MongoDB ConfigMap..."

  # Check if MongoDB is running
  if ! kubectl get mongodbcommunity "$MONGODB_RESOURCE_NAME" -n "$MONGODB_NAMESPACE" >/dev/null 2>&1; then
    print_error "MongoDB resource '$MONGODB_RESOURCE_NAME' not found in namespace '$MONGODB_NAMESPACE'"
    print_error "Please run the MongoDB setup script first."
    exit 1
  fi

  # Get the password from the secret
  local mongodb_password=$(kubectl get secret my-user-password -n "$MONGODB_NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)

  if [ -z "$mongodb_password" ]; then
    print_error "Failed to retrieve MongoDB password from secret"
    exit 1
  fi

  # Set MongoDB connection details
  local mongodb_host="${MONGODB_RESOURCE_NAME}-svc.${MONGODB_NAMESPACE}.svc.cluster.local"
  local mongodb_port="27017"
  local mongodb_uri="mongodb://${MONGODB_TESTDB_USER}:${mongodb_password}@${mongodb_host}:${mongodb_port}/${MONGODB_DATABASE}"

  # Create the ConfigMap
  kubectl create configmap clustershift-benchmark-config \
    --from-literal=DB_HOST="$mongodb_host" \
    --from-literal=DB_PORT="$mongodb_port" \
    --from-literal=DB_USER="$MONGODB_TESTDB_USER" \
    --from-literal=DB_PASSWORD="$mongodb_password" \
    --from-literal=DB_NAME="$MONGODB_DATABASE" \
    --from-literal=DB_TYPE="mongodb" \
    --from-literal=MONGODB_URI="$mongodb_uri" \
    --namespace="$BENCHMARK_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

  print_success "MongoDB ConfigMap created successfully!"
  print_status "MongoDB connection details:"
  print_status "  Host: $mongodb_host"
  print_status "  Port: $mongodb_port"
  print_status "  Database: $MONGODB_DATABASE"
  print_status "  User: $MONGODB_TESTDB_USER"
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
  echo "MongoDB Namespace: $MONGODB_NAMESPACE"
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
    --mongodb-namespace)
      MONGODB_NAMESPACE="$2"
      shift 2
      ;;
    --mongodb-resource)
      MONGODB_RESOURCE_NAME="$2"
      shift 2
      ;;
    --cleanup)
      cleanup
      exit 0
      ;;
    --help)
      echo "Usage: $0 [OPTIONS]"
      echo "Options:"
      echo "  --benchmark-namespace NAME  Specify benchmark namespace (default: benchmark)"
      echo "  --metrics-namespace NAME    Specify metrics namespace (default: clustershift)"
      echo "  --mongodb-namespace NAME    Specify MongoDB namespace (default: mongodb)"
      echo "  --mongodb-resource NAME     Specify MongoDB resource name (default: example-mongodb)"
      echo "  --cleanup                   Remove all resources and exit"
      echo "  --help                      Show this help message"
      exit 0
      ;;
    *)
      print_error "Unknown option: $1"
      echo "Use --help for usage information."
      exit 1
      ;;
    esac
  done

  # Execute deployment steps
  check_prerequisites
  create_namespaces
  create_mongodb_configmap
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
