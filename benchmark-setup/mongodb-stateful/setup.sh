#!/bin/bash

# MongoDB Benchmark Setup Script
# This script installs MongoDB Community Operator via Helm and applies configuration

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
NAMESPACE=${NAMESPACE:-"mongodb"}
MONGODB_REPLICAS=${MONGODB_REPLICAS:-3}
MONGODB_RESOURCE_NAME="mongodb"
TEST_DATA_COUNT=1000

# Set global variables
MONGODB_HOST="mongodb-0.mongodb-headless.${NAMESPACE}.svc.cluster.local"
MONGODB_PORT="27017"
MONGODB_TESTDB_USER="testdb_user"
MONGODB_DATABASE="testdb"
MONGODB_ADMIN_DATABASE="admin"

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

# Function to deploy MongoDB resources
deploy_mongodb() {
  print_status "Deploying MongoDB StatefulSet resources..."

  # Deploy in order: keyfile, secrets, service, statefulset
  print_status "Applying Keyfile..."
  kubectl apply -f keyfile.yaml

  print_status "Applying Secrets..."
  kubectl apply -f secrets.yaml

  print_status "Applying Service..."
  kubectl apply -f service.yaml

  print_status "Applying StatefulSet..."
  kubectl apply -f statefulset.yaml

  print_success "MongoDB resources deployed successfully"
}

# Function to wait for StatefulSet to be ready
wait_for_statefulset() {
  print_status "Waiting for MongoDB StatefulSet to be ready..."

  STATEFULSET_NAME="mongodb"
  TIMEOUT=300 # seconds
  SLEEP_INTERVAL=5
  start_time=$(date +%s)

  while true; do
    desired=$(kubectl get statefulset "$STATEFULSET_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    ready=$(kubectl get statefulset "$STATEFULSET_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)

    ready=${ready:-0}

    if [[ "$desired" == "$ready" && "$desired" != "" ]]; then
      print_success "MongoDB StatefulSet is ready: $ready/$desired"
      break
    fi

    now=$(date +%s)
    elapsed=$((now - start_time))
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
      print_error "Timeout waiting for MongoDB StatefulSet to be ready"
      exit 1
    fi

    print_status "Still waiting... Ready: $ready/$desired"
    sleep "$SLEEP_INTERVAL"
  done
}

# Function to get MongoDB pod hostnames
get_mongodb_hostnames() {
  print_status "Getting MongoDB pod hostnames..." >&2

  local hostnames=()
  for i in $(seq 0 $((MONGODB_REPLICAS - 1))); do
    hostnames+=("mongodb-$i.mongodb-headless.$NAMESPACE.svc.cluster.local:27017")
  done

  echo "${hostnames[@]}"
}

# Function to initialize MongoDB replica set

init_replica_set() {
  print_status "Initializing MongoDB replica set and creating users..."
  local hostnames=($(get_mongodb_hostnames))

  # Build replica set configuration
  local members=""
  for i in "${!hostnames[@]}"; do
    if [ $i -eq 0 ]; then
      members="{ _id: $i, host: \"${hostnames[$i]}\" }"
    else
      members="$members, { _id: $i, host: \"${hostnames[$i]}\" }"
    fi
  done
  local rs_config="rs.initiate({ _id: \"rs0\", members: [ $members ] })"
  print_status "Replica set configuration: $rs_config"

  # Retrieve root credentials from secret
  local ROOT_USER
  local ROOT_PASSWORD
  ROOT_USER=$(kubectl get secret mongodb-secret -n "$NAMESPACE" -o jsonpath='{.data.mongodb-root-username}' | base64 -d)
  ROOT_PASSWORD=$(kubectl get secret mongodb-secret -n "$NAMESPACE" -o jsonpath='{.data.mongodb-root-password}' | base64 -d)

  if [ -z "$ROOT_USER" ] || [ -z "$ROOT_PASSWORD" ]; then
    print_error "Failed to retrieve root credentials from secret 'mongodb-secret'"
    exit 1
  fi

  # If no explicit testdb password provided, reuse root password
  if [ -z "$MONGODB_TESTDB_PASSWORD" ]; then
    MONGODB_TESTDB_PASSWORD="$ROOT_PASSWORD"
  fi

  # Check if replica set already initiated
  if kubectl exec -n "$NAMESPACE" mongodb-0 -- mongosh --quiet --eval "rs.status().ok" >/dev/null 2>&1; then
    print_warning "Replica set already initialized. Skipping rs.initiate."
  else
    kubectl exec -n "$NAMESPACE" mongodb-0 -- mongosh --eval "$rs_config"
    print_status "Waiting 20s for primary election..."
    sleep 20
  fi

  # Create users (idempotent)
  print_status "Creating/ensuring root and testdb users exist..."
  kubectl exec -n "$NAMESPACE" mongodb-0 -- mongosh --quiet --eval "
    try {
      var adminDB = db.getSiblingDB('admin');
      var testDB  = db.getSiblingDB('testdb');
      var createdRoot = false;

        adminDB.createUser({
          user: '$ROOT_USER',
          pwd: '$ROOT_PASSWORD',
          roles: [ { role: 'root', db: 'admin' } ]
        });
        createdRoot = true;
    
    } catch (e) {
      print('Error during user creation: ' + e);
      throw e;
    }
  " || {
    print_error "Failed to create users."
    exit 1
  }

  # Show replica status
  kubectl exec -n "$NAMESPACE" mongodb-0 -- mongosh --eval "rs.status()" >/dev/null 2>&1 || true
  print_success "Replica set and users ready"
}

# Function to get MongoDB credentials from the secret
get_mongodb_credentials() {
  print_status "Retrieving MongoDB credentials..."

  # Get the username and password from the secret
  local mongodb_username=$(kubectl get secret mongodb-secret -n "$NAMESPACE" -o jsonpath='{.data.mongodb-root-username}' | base64 -d)
  local mongodb_password=$(kubectl get secret mongodb-secret -n "$NAMESPACE" -o jsonpath='{.data.mongodb-root-password}' | base64 -d)

  if [ -z "$mongodb_username" ] || [ -z "$mongodb_password" ]; then
    print_error "Failed to retrieve MongoDB credentials from secret"
    exit 1
  fi

  MONGODB_USER="$mongodb_username"
  MONGODB_PASSWORD="$mongodb_password"

  print_success "MongoDB credentials retrieved successfully!"
  print_status "MongoDB connection details:"
  print_status "  Host: $MONGODB_HOST"
  print_status "  Port: $MONGODB_PORT"
  print_status "  User: $MONGODB_USER"
  print_status "  TestDB User: $MONGODB_TESTDB_USER"
  print_status "  Password: (hidden)"
  print_status "  Database: $MONGODB_DATABASE"
}

# Function to create test data with proper authentication
create_test_data() {
  print_status "Creating test data in MongoDB..."

  # Get MongoDB credentials
  get_mongodb_credentials

  # Create a temporary pod to run MongoDB client
  print_status "Creating temporary MongoDB client pod..."

  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: mongodb-client-temp
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: mongodb-client
    image: mongo:7.0
    command: ["/bin/bash", "-c", "sleep 3600"]
    env:
    - name: MONGODB_HOST
      value: "${MONGODB_HOST}"
    - name: MONGODB_PORT
      value: "${MONGODB_PORT}"
    - name: MONGODB_USER
      value: "${MONGODB_USER}"
    - name: MONGODB_ROOT_USER
      value: "${MONGODB_ROOT_USER}"
    - name: MONGODB_PASSWORD
      value: "${MONGODB_PASSWORD}"
    - name: MONGODB_DATABASE
      value: "${MONGODB_DATABASE}"
    - name: MONGODB_ADMIN_DATABASE
      value: "${MONGODB_ADMIN_DATABASE}"
  restartPolicy: Never
EOF

  # Wait for the client pod to be ready
  print_status "Waiting for MongoDB client pod to be ready..."
  kubectl wait --for=condition=ready pod/mongodb-client-temp -n "$NAMESPACE" --timeout=120s

  # Wait a bit more for MongoDB to be fully ready
  print_status "Waiting for MongoDB to be fully ready..."
  sleep 30

  # Test MongoDB connectivity first
  print_status "Testing MongoDB connectivity..."

  # Try to connect to MongoDB and run a simple command
  local connection_test=$(kubectl exec -n "$NAMESPACE" mongodb-client-temp -- mongosh \
    "mongodb://${MONGODB_USER}:${MONGODB_PASSWORD}@${MONGODB_HOST}:${MONGODB_PORT}/${MONGODB_ADMIN_DATABASE}?authSource=${MONGODB_ADMIN_DATABASE}" \
    --quiet \
    --eval "db.runCommand('ping').ok" 2>/dev/null || echo "0")

  if [ "$connection_test" != "1" ]; then
    print_error "Cannot connect to MongoDB. Checking MongoDB status..."

    # Debug information
    print_status "MongoDB pod logs:"
    kubectl logs -n "$NAMESPACE" "${MONGODB_RESOURCE_NAME}-0" --tail=20 || true

    print_status "MongoDB pod status:"
    kubectl get pods -n "$NAMESPACE" -l app="${MONGODB_RESOURCE_NAME}" -o wide

    print_status "All MongoDB pods:"
    kubectl get pods -n "$NAMESPACE" --selector="app.kubernetes.io/name=mongodb" -o wide || kubectl get pods -n "$NAMESPACE" -l app=mongodb -o wide

    print_status "Testing direct connection to MongoDB service..."
    kubectl exec -n "$NAMESPACE" mongodb-client-temp -- mongosh \
      "mongodb://${MONGODB_USER}:${MONGODB_PASSWORD}@${MONGODB_HOST}:${MONGODB_PORT}/${MONGODB_ADMIN_DATABASE}?authSource=${MONGODB_ADMIN_DATABASE}" \
      --eval "db.runCommand('ping')" 2>&1 || true

    exit 1
  fi

  print_success "MongoDB connection test passed!"

  # Create root user if needed and set up database
  print_status "Setting up MongoDB database and user permissions..."

  kubectl exec -n "$NAMESPACE" mongodb-client-temp -- mongosh \
    "mongodb://${MONGODB_USER}:${MONGODB_PASSWORD}@${MONGODB_HOST}:${MONGODB_PORT}/${MONGODB_ADMIN_DATABASE}?authSource=${MONGODB_ADMIN_DATABASE}" \
    --eval "
      // Switch to testdb database first
      db = db.getSiblingDB('${MONGODB_DATABASE}');

      // Create a dedicated user for testdb with read/write permissions
      try {
        let userInfo = db.runCommand({usersInfo: '${MONGODB_TESTDB_USER}'});
        if (userInfo.users && userInfo.users.length > 0) {
          print('${MONGODB_TESTDB_USER} already exists');
        } else {
          db.createUser({
            user: '${MONGODB_TESTDB_USER}',
            pwd: '${MONGODB_PASSWORD}',
            roles: [
              { role: 'readWrite', db: '${MONGODB_DATABASE}' }
            ]
          });
          print('${MONGODB_TESTDB_USER} created with readWrite permissions in testdb');
        }
      } catch (e) {
        db.createUser({
          user: '${MONGODB_TESTDB_USER}',
          pwd: '${MONGODB_PASSWORD}',
          roles: [
            { role: 'readWrite', db: '${MONGODB_DATABASE}' }
          ]
        });
        print('${MONGODB_TESTDB_USER} created with readWrite permissions in testdb');
      }

      print('Database setup completed');
    " 2>&1 || true

  # Create and execute the data insertion script using the testdb user
  print_status "Inserting $TEST_DATA_COUNT test messages..."

  local insert_output=$(kubectl exec -n "$NAMESPACE" mongodb-client-temp -- mongosh \
    "mongodb://${MONGODB_TESTDB_USER}:${MONGODB_PASSWORD}@${MONGODB_HOST}:${MONGODB_PORT}/${MONGODB_DATABASE}?authSource=${MONGODB_DATABASE}" \
    --quiet \
    --eval "
      // Clear existing data
      db.messages.drop();

      // Create test messages data
      let testMessages = [];
      let batchSize = 10;

      for (let i = 1; i <= ${TEST_DATA_COUNT}; i++) {
          testMessages.push({
              id: i,
              content: 'Test message ' + i + ' - This is a sample message for benchmarking purposes. Message ID: ' + i,
              created_at: new Date(),
              host_ip: '192.168.1.' + (Math.floor(Math.random() * 254) + 1)
          });

          // Insert in batches to avoid memory issues
          if (testMessages.length === batchSize || i === ${TEST_DATA_COUNT}) {
              try {
                  let result = db.messages.insertMany(testMessages);
                  print('Inserted batch of ' + result.insertedIds.length + ' messages');
                  testMessages = [];
              } catch (e) {
                  print('Error inserting batch: ' + e.message);
                  throw e;
              }
          }
      }

      // Create indexes for better performance
      db.messages.createIndex({ id: 1 });
      db.messages.createIndex({ created_at: 1 });
      db.messages.createIndex({ host_ip: 1 });

      print('Indexes created');

      // Return the count
      let count = db.messages.countDocuments();
      print('FINAL_COUNT=' + count);
      count;
    " 2>&1)

  print_status "Insert operation output:"
  echo "$insert_output"

  # Extract the count from the output
  local inserted_count=$(echo "$insert_output" | grep -o "FINAL_COUNT=[0-9]*" | sed 's/FINAL_COUNT=//' | tail -1)

  # If we can't find the FINAL_COUNT, try to get the last number in the output
  if [ -z "$inserted_count" ]; then
    inserted_count=$(echo "$insert_output" | grep -o "[0-9]*" | tail -1)
  fi

  if [ -n "$inserted_count" ] && [ "$inserted_count" -eq "$TEST_DATA_COUNT" ]; then
    print_success "Test data created successfully!"
    print_status "Inserted $inserted_count messages into the 'messages' collection in database '$MONGODB_DATABASE'"
  else
    print_error "Failed to create test data! Expected $TEST_DATA_COUNT, got: $inserted_count"

    # Try to get actual count from database
    print_status "Checking actual count in database..."
    local actual_count=$(kubectl exec -n "$NAMESPACE" mongodb-client-temp -- mongosh \
      "mongodb://${MONGODB_TESTDB_USER}:${MONGODB_PASSWORD}@${MONGODB_HOST}:${MONGODB_PORT}/${MONGODB_DATABASE}?authSource=${MONGODB_DATABASE}" \
      --quiet \
      --eval "db.messages.countDocuments()" 2>/dev/null || echo "0")

    print_status "Actual count in database: $actual_count"

    if [ "$actual_count" -eq "$TEST_DATA_COUNT" ]; then
      print_success "Data insertion actually succeeded! Count matches expected value."
    else
      print_error "Data insertion failed. Check MongoDB logs for details."
      kubectl logs -n "$NAMESPACE" "${MONGODB_RESOURCE_NAME}-0" -c mongodb-agent --tail=50 || true
      exit 1
    fi
  fi

  # Clean up temporary pod
  print_status "Cleaning up temporary MongoDB client pod..."
  kubectl delete pod mongodb-client-temp -n "$NAMESPACE" --ignore-not-found=true
}

# Function to verify test data
verify_test_data() {
  print_status "Verifying test data..."

  # Create a temporary pod to verify data
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: mongodb-verify-temp
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: mongodb-client
    image: mongo:7.0
    command: ["/bin/bash", "-c", "sleep 300"]
  restartPolicy: Never
EOF

  kubectl wait --for=condition=ready pod/mongodb-verify-temp -n "$NAMESPACE" --timeout=60s

  # Execute verification
  local verify_output=$(kubectl exec -n "$NAMESPACE" mongodb-verify-temp -- mongosh \
    "mongodb://${MONGODB_TESTDB_USER}:${MONGODB_PASSWORD}@${MONGODB_HOST}:${MONGODB_PORT}/${MONGODB_DATABASE}?authSource=${MONGODB_DATABASE}" \
    --quiet \
    --eval "
      // Count documents
      let count = db.messages.countDocuments();
      print('DOCUMENT_COUNT=' + count);

      // Show some sample data
      let samples = db.messages.find().limit(2).toArray();
      print('SAMPLE_DATA=' + JSON.stringify(samples));

      // Show collection stats
      let stats = db.messages.stats();
      print('COLLECTION_SIZE=' + stats.count);

      // Show indexes
      let indexes = db.messages.getIndexes();
      print('INDEXES_COUNT=' + indexes.length);

      count;
    " 2>&1)

  # Extract count from output
  local count=$(echo "$verify_output" | grep -o "DOCUMENT_COUNT=[0-9]*" | sed 's/DOCUMENT_COUNT=//' | tail -1)

  # If we can't find DOCUMENT_COUNT, try to get the last number
  if [ -z "$count" ]; then
    count=$(echo "$verify_output" | grep -o "[0-9]*" | tail -1)
  fi

  print_status "Verification output:"
  echo "$verify_output"

  print_status "Total documents in database: $count"

  # Check if count is a valid number
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    if [ "$count" -eq "$TEST_DATA_COUNT" ]; then
      print_success "Test data verification passed!"

      # Show sample data
      local sample_data=$(echo "$verify_output" | grep "SAMPLE_DATA=" | sed 's/SAMPLE_DATA=//')
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
  kubectl delete pod mongodb-verify-temp -n "$NAMESPACE" --ignore-not-found=true
}

# Function to display cluster and deployment info
display_info() {
  print_status "Deployment Information:"
  echo "=========================="
  echo "Namespace: $NAMESPACE"
  echo "Operator Namespace: ${OPERATOR_NAMESPACE:-$NAMESPACE}"
  echo "Helm Release: $HELM_RELEASE_NAME"
  echo "MongoDB Resource: $MONGODB_RESOURCE_NAME"
  echo "KUBECONFIG: ${KUBECONFIG:-"default"}"
  echo "Test Data Count: $TEST_DATA_COUNT"
  echo "=========================="

  print_status "Checking MongoDB Community Operator status..."
  kubectl get deployments -A -l name=mongodb-kubernetes-operator || print_status "No MongoDB operator deployments found"

  print_status "Checking MongoDB Community resource status..."
  kubectl get mongodbcommunity "$MONGODB_RESOURCE_NAME" -n "$NAMESPACE" -o wide

  print_status "MongoDB Connection Information:"
  echo "Host: ${MONGODB_HOST}"
  echo "Port: ${MONGODB_PORT}"
  echo "Username: ${MONGODB_TESTDB_USER}"
  echo "Root User: ${MONGODB_USER}"
  echo "Password: (hidden, stored in secret 'my-user-password')"
  echo "Database: ${MONGODB_DATABASE}"
  echo "Collection: messages"

  print_status "MongoDB Pods:"
  kubectl get pods -n "$NAMESPACE" -l app="${MONGODB_RESOURCE_NAME}-svc"

  print_status "MongoDB Services:"
  kubectl get svc -n "$NAMESPACE" -l app="${MONGODB_RESOURCE_NAME}-svc"
}

# Function to cleanup (optional)
cleanup() {
  print_status "Cleaning up MongoDB benchmark setup..."

  # Remove temporary pods
  kubectl delete pod mongodb-client-temp -n "$NAMESPACE" --ignore-not-found=true
  kubectl delete pod mongodb-verify-temp -n "$NAMESPACE" --ignore-not-found=true

  # Delete StatefulSet
  kubectl delete statefulset mongodb -n "$NAMESPACE" --ignore-not-found=true

  # Delete Services
  kubectl delete svc mongodb mongodb-headless -n "$NAMESPACE" --ignore-not-found=true

  # Delete ConfigMap
  kubectl delete configmap mongodb-config -n "$NAMESPACE" --ignore-not-found=true

  # Delete Secrets
  kubectl delete secret mongodb-secret -n "$NAMESPACE" --ignore-not-found=true

  # Delete PVCs
  kubectl delete pvc -l app=mongodb -n "$NAMESPACE" --ignore-not-found=true

  # Optionally delete namespace
  read -p "Do you want to delete the namespace '$NAMESPACE'? (y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    kubectl delete namespace "$NAMESPACE" --ignore-not-found=true
    print_success "Namespace '$NAMESPACE' deleted"
  fi

  print_success "MongoDB cleanup completed"
}

# Main function
main() {
  print_status "Starting MongoDB Benchmark Setup..."

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
    --release-name)
      HELM_RELEASE_NAME="$2"
      shift 2
      ;;
    --mongodb-name)
      MONGODB_RESOURCE_NAME="$2"
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
      echo "  --namespace NAME        Specify namespace (default: mongodb)"
      echo "  --yaml-file FILE        Specify YAML file to apply (default: mongodb.yaml)"
      echo "  --release-name NAME     Specify Helm release name (default: community-operator)"
      echo "  --mongodb-name NAME     Specify MongoDB resource name (default: example-mongodb)"
      echo "  --test-data-count NUM   Number of test records to create (default: 100)"
      echo "  --cleanup               Remove all resources and exit"
      echo "  --help                  Show this help message"
      echo ""
      echo "Environment variables:"
      echo "  NAMESPACE              Override default namespace"
      echo "  YAML_FILE              Override default YAML file"
      echo "  HELM_RELEASE_NAME      Override default Helm release name"
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
  create_namespace
  deploy_mongodb
  wait_for_statefulset
  init_replica_set
  create_test_data
  verify_test_data
  display_info

  print_success "MongoDB benchmark setup completed successfully!"
  print_status "Your MongoDB cluster is ready for benchmarking with $TEST_DATA_COUNT test records!"
  print_status "To run benchmark tests: $0 --benchmark"
}

# Trap to handle script interruption
trap 'print_error "Script interrupted!"; exit 1' INT TERM

# Run main function
main "$@"
