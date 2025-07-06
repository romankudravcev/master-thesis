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
HELM_RELEASE_NAME=${HELM_RELEASE_NAME:-"community-operator"}
MONGODB_OPERATOR_CHART="mongodb/community-operator"
YAML_FILE=${YAML_FILE:-"mongodb.yaml"}
MONGODB_RESOURCE_NAME="example-mongodb"
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

  # Check if helm is installed
  if ! command_exists helm; then
    print_error "helm is not installed. Please install helm first."
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

# Function to check existing MongoDB operator installation
check_existing_operator() {
  print_status "Checking for existing MongoDB Community Operator installations..."

  # Check for existing CRDs
  local crd_exists=$(kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com 2>/dev/null && echo "true" || echo "false")

  if [ "$crd_exists" = "true" ]; then
    print_warning "MongoDB Community CRD already exists!"

    # Check which Helm release owns it
    local existing_release=$(kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
    local existing_namespace=$(kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-namespace}' 2>/dev/null || echo "")

    if [ -n "$existing_release" ]; then
      print_warning "Found existing Helm release: '$existing_release' in namespace: '$existing_namespace'"

      # Check if it's a different release name
      if [ "$existing_release" != "$HELM_RELEASE_NAME" ]; then
        print_status "Using existing MongoDB Community Operator release: '$existing_release'"
        HELM_RELEASE_NAME="$existing_release"

        # If the existing release is in a different namespace, use that namespace for the operator
        if [ -n "$existing_namespace" ] && [ "$existing_namespace" != "$NAMESPACE" ]; then
          print_status "MongoDB operator is installed in namespace: '$existing_namespace'"
          OPERATOR_NAMESPACE="$existing_namespace"
        else
          OPERATOR_NAMESPACE="$NAMESPACE"
        fi
      fi
    else
      print_warning "MongoDB CRD exists but not managed by Helm. Proceeding with caution..."
      OPERATOR_NAMESPACE="$NAMESPACE"
    fi
  else
    print_status "No existing MongoDB Community Operator found."
    OPERATOR_NAMESPACE="$NAMESPACE"
  fi

  # Check for existing operator deployments using the correct label
  local operator_deployments=$(kubectl get deployments -A -l name=mongodb-kubernetes-operator --no-headers 2>/dev/null | wc -l)

  if [ "$operator_deployments" -gt 0 ]; then
    print_status "Found existing MongoDB operator deployments:"
    kubectl get deployments -A -l name=mongodb-kubernetes-operator
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

# Function to add MongoDB Helm repository
add_helm_repo() {
  print_status "Adding MongoDB Helm repository..."

  helm repo add mongodb https://mongodb.github.io/helm-charts
  helm repo update

  print_success "MongoDB Helm repository added and updated!"
}

# Function to install or use existing MongoDB Community Operator
install_mongodb_operator() {
  if [ "$OPERATOR_EXISTS" = true ]; then
    print_status "MongoDB Community Operator already exists. Verifying it's working..."

    # Check if the operator is running using the correct label
    local operator_ready=$(kubectl get deployments -A -l name=mongodb-kubernetes-operator -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || echo "0")

    if [ "$operator_ready" -gt 0 ]; then
      print_success "Existing MongoDB Community Operator is running!"
      return 0
    else
      print_warning "Existing MongoDB Community Operator is not ready. Attempting to fix..."
    fi
  fi

  print_status "Installing/Upgrading MongoDB Community Operator..."

  # Check if our target release exists
  if helm list -A | grep -q "$HELM_RELEASE_NAME"; then
    local release_namespace=$(helm list -A | grep "$HELM_RELEASE_NAME" | awk '{print $2}')
    print_status "Found existing release '$HELM_RELEASE_NAME' in namespace '$release_namespace'"

    print_status "Upgrading existing Helm release..."
    helm upgrade "$HELM_RELEASE_NAME" "$MONGODB_OPERATOR_CHART" \
      --namespace "$release_namespace" \
      --wait \
      --timeout=300s
  else
    # Try to install in the operator namespace
    print_status "Installing new MongoDB Community Operator in namespace: $OPERATOR_NAMESPACE"

    # Create operator namespace if it doesn't exist
    if ! kubectl get namespace "$OPERATOR_NAMESPACE" >/dev/null 2>&1; then
      kubectl create namespace "$OPERATOR_NAMESPACE"
    fi

    # If CRD exists but no Helm release, we need to adopt it or work around it
    if kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com >/dev/null 2>&1; then
      print_status "CRD exists but no Helm release found. Installing operator without CRD management..."

      # Install with --skip-crds flag to avoid CRD conflicts
      helm install "$HELM_RELEASE_NAME" "$MONGODB_OPERATOR_CHART" \
        --namespace "$OPERATOR_NAMESPACE" \
        --create-namespace \
        --skip-crds \
        --wait \
        --timeout=300s
    else
      # Normal installation
      helm install "$HELM_RELEASE_NAME" "$MONGODB_OPERATOR_CHART" \
        --namespace "$OPERATOR_NAMESPACE" \
        --create-namespace \
        --wait \
        --timeout=300s
    fi
  fi

  print_success "MongoDB Community Operator installation completed!"
}

# Function to wait for operator to be ready
wait_for_operator() {
  print_status "Waiting for MongoDB Community Operator to be ready..."

  kubectl wait --for=condition=available --timeout=300s deployment/mongodb-kubernetes-operator -n "$OPERATOR_NAMESPACE"

  print_success "MongoDB Community Operator is ready!"
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

# Function to wait for MongoDB Community resource to be running
wait_for_mongodb_running() {
  print_status "Waiting for MongoDB Community resource '$MONGODB_RESOURCE_NAME' to be running..."

  local max_attempts=60 # 10 minutes (60 * 10 seconds)
  local attempt=0

  while [ $attempt -lt $max_attempts ]; do
    # Check if the resource exists
    if ! kubectl get mongodbcommunity "$MONGODB_RESOURCE_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
      print_status "MongoDB Community resource not found yet, waiting..."
      sleep 10
      ((attempt++))
      continue
    fi

    # Get the current phase
    local phase=$(kubectl get mongodbcommunity "$MONGODB_RESOURCE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [ "$phase" = "Running" ]; then
      print_success "MongoDB Community resource is now running!"
      return 0
    else
      print_status "MongoDB Community resource phase: '$phase', waiting... (attempt $((attempt + 1))/$max_attempts)"

      sleep 10
      ((attempt++))
    fi
  done

  print_error "MongoDB Community resource did not reach 'Running' phase within timeout!"

  exit 1
}

# Function to get MongoDB credentials from the secret
get_mongodb_credentials() {
  print_status "Retrieving MongoDB credentials..."

  # Get the password from the secret
  local mongodb_password=$(kubectl get secret my-user-password -n "$NAMESPACE" -o jsonpath='{.data.password}' | base64 -d)
  
  if [ -z "$mongodb_password" ]; then
    print_error "Failed to retrieve MongoDB password from secret"
    exit 1
  fi

  # Set global variables
  MONGODB_HOST="${MONGODB_RESOURCE_NAME}-svc.${NAMESPACE}.svc.cluster.local"
  MONGODB_PORT="27017"
  MONGODB_USER="my-user"
  MONGODB_PASSWORD="$mongodb_password"
  MONGODB_TESTDB_USER="testdb_user"
  MONGODB_DATABASE="testdb"
  MONGODB_ADMIN_DATABASE="admin"

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
    kubectl logs -n "$NAMESPACE" "${MONGODB_RESOURCE_NAME}-0" -c mongodb-agent --tail=20 || true
    
    print_status "MongoDB pod status:"
    kubectl get pods -n "$NAMESPACE" -l app="${MONGODB_RESOURCE_NAME}-svc" -o wide
    
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
  kubectl delete pod mongodb-benchmark-temp -n "$NAMESPACE" --ignore-not-found=true

  # Remove MongoDB resources
  kubectl delete mongodbcommunity --all -n "$NAMESPACE" 2>/dev/null || true

  # Remove secrets
  kubectl delete secret my-user-password -n "$NAMESPACE" 2>/dev/null || true

  # Ask before removing operator
  read -p "Do you want to remove the MongoDB Community Operator? (y/N): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Uninstall Helm release
    helm uninstall "$HELM_RELEASE_NAME" -n "${OPERATOR_NAMESPACE:-$NAMESPACE}" 2>/dev/null || true

    # Remove CRDs if they exist
    kubectl delete crd mongodbcommunity.mongodbcommunity.mongodb.com 2>/dev/null || true
  fi

  # Delete namespace
  kubectl delete namespace "$NAMESPACE" 2>/dev/null || true

  print_success "Cleanup completed!"
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
    --benchmark)
      RUN_BENCHMARK=true
      shift
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
  check_existing_operator
  create_namespace
  add_helm_repo
  install_mongodb_operator
  wait_for_operator
  apply_yaml_config
  wait_for_mongodb_running
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
