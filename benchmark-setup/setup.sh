#!/bin/bash

# Global Benchmark Environment Deployment Script
# This script allows you to select a database setup, deploy it, and then deploy the benchmark applications
# Author: romankudravcev
# Created: 2025-07-16

set -e # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

print_header() {
  echo -e "${CYAN}[HEADER]${NC} $1"
}

# Function to convert relative path to absolute path
get_absolute_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    # Already absolute path
    echo "$path"
  else
    # Convert relative path to absolute
    echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
  fi
}

# Function to detect and set KUBECONFIG
detect_kubeconfig() {
  # If KUBECONFIG is already set, use it
  if [ -n "$KUBECONFIG" ]; then
    # Convert to absolute path to avoid issues when changing directories
    KUBECONFIG=$(get_absolute_path "$KUBECONFIG")
    export KUBECONFIG
    print_status "Using KUBECONFIG: $KUBECONFIG"
    return 0
  fi

  # Try to find kubeconfig in common locations
  local kubeconfig_paths=(
    "$HOME/.kube/config"
    "/home/$SUDO_USER/.kube/config"
    "/Users/$SUDO_USER/.kube/config"
  )

  for config_path in "${kubeconfig_paths[@]}"; do
    if [ -f "$config_path" ]; then
      export KUBECONFIG="$config_path"
      print_status "Found and using KUBECONFIG: $KUBECONFIG"
      return 0
    fi
  done

  print_warning "KUBECONFIG not found. Using default kubectl configuration."
  return 0
}

# Configuration variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_SETUP_DIR="${SCRIPT_DIR}"
BENCHMARK_SCRIPT="${SCRIPT_DIR}/../benchmark-applications/deploy-benchmark.sh"

# Database configuration using arrays instead of associative arrays
# Format: "db_type host port user password database"
DB_CONFIG_1="mongodb example-mongodb-svc.mongodb.svc.cluster.local 27017 testdb_user password testdb"
DB_CONFIG_2="mongodb mongo-stateful.mongodb.svc.cluster.local 27017 mongo mongopassword123 testdb"
DB_CONFIG_3="postgresql postgres.postgresql.svc.cluster.local 5432 postgres postgrespassword123 testdb"
DB_CONFIG_4="postgresql postgres-stateful.postgresql.svc.cluster.local 5432 postgres postgrespassword123 testdb"

DB_SCRIPT_1="${DB_SETUP_DIR}/mongodb-operator/setup.sh"
DB_SCRIPT_2="${DB_SETUP_DIR}/setup-mongodb-stateful.sh"
DB_SCRIPT_3="${DB_SETUP_DIR}/setup-postgres-operator.sh"
DB_SCRIPT_4="${DB_SETUP_DIR}/setup-postgres-stateful.sh"

DB_WAIT_1="example-mongodb mongodb"
DB_WAIT_2="mongodb-stateful mongodb"
DB_WAIT_3="postgres-deployment postgresql"
DB_WAIT_4="postgres-stateful postgresql"

DB_NAME_1="mongodb-operator"
DB_NAME_2="mongodb-stateful"
DB_NAME_3="postgres-operator"
DB_NAME_4="postgres-stateful"

# Global variable to store the selection
SELECTED_DB=""

# Function to get database configuration by number
get_db_config() {
  local selection=$1
  case $selection in
    1) echo "$DB_CONFIG_1" ;;
    2) echo "$DB_CONFIG_2" ;;
    3) echo "$DB_CONFIG_3" ;;
    4) echo "$DB_CONFIG_4" ;;
    *) echo "" ;;
  esac
}

# Function to get database script by number
get_db_script() {
  local selection=$1
  case $selection in
    1) echo "$DB_SCRIPT_1" ;;
    2) echo "$DB_SCRIPT_2" ;;
    3) echo "$DB_SCRIPT_3" ;;
    4) echo "$DB_SCRIPT_4" ;;
    *) echo "" ;;
  esac
}

# Function to get database wait config by number
get_db_wait() {
  local selection=$1
  case $selection in
    1) echo "$DB_WAIT_1" ;;
    2) echo "$DB_WAIT_2" ;;
    3) echo "$DB_WAIT_3" ;;
    4) echo "$DB_WAIT_4" ;;
    *) echo "" ;;
  esac
}

# Function to get database name by number
get_db_name() {
  local selection=$1
  case $selection in
    1) echo "$DB_NAME_1" ;;
    2) echo "$DB_NAME_2" ;;
    3) echo "$DB_NAME_3" ;;
    4) echo "$DB_NAME_4" ;;
    *) echo "" ;;
  esac
}

# Function to check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Function to show help
show_help() {
  cat << EOF
Usage: $0 [OPTIONS]

This script orchestrates the deployment of database and benchmark applications.

Options:
  --db-selection NUMBER           Select database configuration by number (1-4)
  --benchmark-namespace NAME      Specify benchmark namespace (default: benchmark)
  --metrics-namespace NAME        Specify metrics namespace (default: clustershift)
  --skip-db-setup                Skip database setup (only deploy benchmark apps)
  --cleanup                       Remove all resources and exit
  --list-configs                  List available database configurations
  --help                          Show this help message

Available Database Configurations:
  1. MongoDB Operator
  2. MongoDB Stateful
  3. Postgres Operator
  4. Postgres Stateful

Examples:
  # Interactive mode (don't use sudo unless necessary)
  $0

  # Direct selection with MongoDB Operator
  $0 --db-selection 1

  # If you must use sudo, preserve environment:
  sudo -E $0 --db-selection 1

EOF
}

# Function to display interactive menu
display_interactive_menu() {
  clear
  print_header "╔═══════════════════════════════════════════════════════════════╗"
  print_header "║              Benchmark Environment Deployment                ║"
  print_header "║                     Database Selection                       ║"
  print_header "╚═══════════════════════════════════════════════════════════════╝"
  echo ""
  echo -e "${CYAN}Please select your database configuration:${NC}"
  echo ""
  echo -e "${GREEN}1.${NC} MongoDB Operator    - MongoDB with Community Operator"
  echo -e "${GREEN}2.${NC} MongoDB Stateful    - MongoDB with StatefulSet"
  echo -e "${GREEN}3.${NC} Postgres Operator   - PostgreSQL with Operator"
  echo -e "${GREEN}4.${NC} Postgres Stateful   - PostgreSQL with StatefulSet"
  echo ""
  echo -e "${YELLOW}0.${NC} Exit"
  echo ""
}

# Function to get user selection interactively
get_interactive_selection() {
  while true; do
    display_interactive_menu
    echo -n "Enter your choice (0-4): "
    read -r selection

    case $selection in
      0)
        print_status "Exiting..."
        exit 0
        ;;
      1|2|3|4)
        SELECTED_DB="$selection"
        return 0
        ;;
      *)
        print_error "Invalid selection. Please choose a number between 0 and 4."
        echo "Press Enter to continue..."
        read -r
        ;;
    esac
  done
}

# Function to list database configurations
list_database_configs() {
  print_header "Available Database Configurations:"
  echo "=================================="

  for i in 1 2 3 4; do
    local config=$(get_db_config $i)
    local db_name=$(get_db_name $i)
    local db_script=$(get_db_script $i)

    if [ -n "$config" ]; then
      local config_array=($config)
      local db_type=${config_array[0]}
      local db_host=${config_array[1]}
      local db_port=${config_array[2]}
      local db_user=${config_array[3]}
      local db_database=${config_array[5]}

      echo "$i. ${db_name}"
      echo "   Type: $db_type"
      echo "   Host: $db_host"
      echo "   Port: $db_port"
      echo "   User: $db_user"
      echo "   Database: $db_database"
      echo "   Setup Script: ${db_script:-"None"}"
      echo ""
    fi
  done
}

# Function to validate selection
validate_selection() {
  local selection=$1

  if [[ ! "$selection" =~ ^[1-4]$ ]]; then
    print_error "Invalid selection. Please choose a number between 1 and 4."
    return 1
  fi

  local config=$(get_db_config "$selection")
  if [ -z "$config" ]; then
    print_error "Invalid database selection."
    return 1
  fi

  return 0
}

# Function to confirm selection
confirm_selection() {
  local selection=$1
  local config=$(get_db_config $selection)
  local db_name=$(get_db_name $selection)
  local db_script=$(get_db_script $selection)

  local config_array=($config)
  local db_type=${config_array[0]}
  local db_host=${config_array[1]}
  local db_port=${config_array[2]}
  local db_user=${config_array[3]}
  local db_database=${config_array[5]}

  echo ""
  print_header "Configuration Summary:"
  echo "======================"
  echo "Database Type: ${db_name}"
  echo "Database Engine: $db_type"
  echo "Host: $db_host"
  echo "Port: $db_port"
  echo "User: $db_user"
  echo "Database: $db_database"
  echo "Setup Script: $db_script"
  echo ""

  while true; do
    echo -n "Do you want to proceed with this configuration? (y/n): "
    read -r confirm
    case $confirm in
      [Yy]* ) return 0 ;;
      [Nn]* ) return 1 ;;
      * ) echo "Please answer yes (y) or no (n)." ;;
    esac
  done
}

# Function to check prerequisites
check_prerequisites() {
  print_status "Checking prerequisites..."

  # Detect and set KUBECONFIG
  detect_kubeconfig

  # Check if kubectl is installed
  if ! command_exists kubectl; then
    print_error "kubectl is not installed. Please install kubectl first."
    exit 1
  fi

  # Test kubectl connection
  if ! kubectl cluster-info >/dev/null 2>&1; then
    print_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
    print_error "Current KUBECONFIG: ${KUBECONFIG:-"not set"}"
    print_error "Try running without sudo or use: sudo -E $0"
    exit 1
  fi

  # Check if benchmark deployment script exists
  if [ ! -f "$BENCHMARK_SCRIPT" ]; then
    print_error "Benchmark deployment script not found: $BENCHMARK_SCRIPT"
    exit 1
  fi

  print_success "Prerequisites check passed!"
}

# Function to run database setup
run_database_setup() {
  local selection=$1
  local setup_script=$(get_db_script $selection)

  if [ -z "$setup_script" ]; then
    print_status "No setup required for selection: $selection"
    return 0
  fi

  if [ ! -f "$setup_script" ]; then
    print_error "Database setup script not found: $setup_script"
    exit 1
  fi

  print_status "Running database setup for selection: $selection"
  print_status "Executing: $setup_script"

  # Make script executable and run it with environment variables
  chmod +x "$setup_script"

  # Get the directory of the setup script and run from there
  local script_dir=$(dirname "$setup_script")

  # Pass KUBECONFIG to the child script and run from its directory
  print_status "Running setup script from directory: $script_dir"
  print_status "Using KUBECONFIG: $KUBECONFIG"

  if [ -n "$KUBECONFIG" ]; then
    (cd "$script_dir" && KUBECONFIG="$KUBECONFIG" ./$(basename "$setup_script"))
  else
    (cd "$script_dir" && ./$(basename "$setup_script"))
  fi

  print_success "Database setup completed for selection: $selection"
}

# Function to wait for database deployment
wait_for_database() {
  local selection=$1
  local wait_config=$(get_db_wait $selection)

  if [ -z "$wait_config" ]; then
    print_status "No deployment waiting required for selection: $selection"
    return 0
  fi

  local wait_array=($wait_config)
  local deployment_name=${wait_array[0]}
  local namespace=${wait_array[1]}

  print_status "Waiting for database deployment to be ready..."
  print_status "Deployment: $deployment_name in namespace: $namespace"

  # Wait for deployment to be available
  if kubectl wait --for=condition=available --timeout=600s deployment/"$deployment_name" -n "$namespace" >/dev/null 2>&1; then
    print_success "Database deployment is ready!"
  else
    print_warning "Deployment wait timed out, but continuing with benchmark deployment..."
  fi

  # Additional wait for pods to be ready
  print_status "Waiting for database pods to be ready..."
  sleep 30

  local ready_pods=$(kubectl get pods -n "$namespace" -l app="$deployment_name" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  if [ "$ready_pods" -gt 0 ]; then
    print_success "Database pods are running!"
  else
    print_warning "No running pods found, but continuing..."
  fi
}

# Function to deploy benchmark applications
deploy_benchmark_applications() {
  local selection=$1
  local benchmark_namespace=$2
  local metrics_namespace=$3

  local config=$(get_db_config $selection)
  local config_array=($config)
  local db_type=${config_array[0]}
  local db_host=${config_array[1]}
  local db_port=${config_array[2]}
  local db_user=${config_array[3]}
  local db_password=${config_array[4]}
  local db_name=${config_array[5]}

  local db_name_str=$(get_db_name $selection)
  print_status "Deploying benchmark applications with $db_name_str configuration..."

  # Build benchmark deployment command
  local benchmark_cmd=("$BENCHMARK_SCRIPT")
  benchmark_cmd+=("--db-type" "$db_type")
  benchmark_cmd+=("--db-host" "$db_host")
  benchmark_cmd+=("--db-port" "$db_port")
  benchmark_cmd+=("--db-user" "$db_user")
  benchmark_cmd+=("--db-password" "$db_password")
  benchmark_cmd+=("--db-name" "$db_name")
  benchmark_cmd+=("--benchmark-namespace" "$benchmark_namespace")
  benchmark_cmd+=("--metrics-namespace" "$metrics_namespace")

  print_status "Executing benchmark deployment command:"
  print_status "${benchmark_cmd[*]}"

  # Make benchmark script executable and run it with environment variables
  chmod +x "$BENCHMARK_SCRIPT"

  # Pass KUBECONFIG to the child script
  if [ -n "$KUBECONFIG" ]; then
    KUBECONFIG="$KUBECONFIG" "${benchmark_cmd[@]}"
  else
    "${benchmark_cmd[@]}"
  fi

  print_success "Benchmark applications deployed successfully!"
}

# Function to cleanup all resources
cleanup_all() {
  print_status "Cleaning up all resources..."

  # Cleanup benchmark applications
  if [ -f "$BENCHMARK_SCRIPT" ]; then
    print_status "Cleaning up benchmark applications..."
    chmod +x "$BENCHMARK_SCRIPT"
    if [ -n "$KUBECONFIG" ]; then
      KUBECONFIG="$KUBECONFIG" "$BENCHMARK_SCRIPT" --cleanup || print_warning "Benchmark cleanup had issues"
    else
      "$BENCHMARK_SCRIPT" --cleanup || print_warning "Benchmark cleanup had issues"
    fi
  fi

  # Cleanup database resources
  for i in 1 2 3 4; do
    local setup_script=$(get_db_script $i)
    local db_name=$(get_db_name $i)
    if [ -f "$setup_script" ]; then
      print_status "Attempting to cleanup database: $db_name"
      chmod +x "$setup_script"
      local script_dir=$(dirname "$setup_script")
      if [ -n "$KUBECONFIG" ]; then
        (cd "$script_dir" && KUBECONFIG="$KUBECONFIG" ./$(basename "$setup_script") --cleanup) || print_warning "Database cleanup for $db_name had issues"
      else
        (cd "$script_dir" && ./$(basename "$setup_script") --cleanup) || print_warning "Database cleanup for $db_name had issues"
      fi
    fi
  done

  print_success "Cleanup completed!"
}

# Function to display final information
display_final_info() {
  local selection=$1
  local benchmark_namespace=$2
  local metrics_namespace=$3

  local db_name=$(get_db_name $selection)

  clear
  print_header "╔═══════════════════════════════════════════════════════════════╗"
  print_header "║                    Deployment Complete!                      ║"
  print_header "╚═══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "Database Configuration: ${db_name^}"
  echo "Benchmark Namespace: $benchmark_namespace"
  echo "Metrics Namespace: $metrics_namespace"
  echo "Deployment Time: $(date)"
  echo ""
  print_status "Environment is ready for benchmarking!"
  print_status "You can now run your benchmark tests."
  echo ""
}

# Main function
main() {
  # Default values
  local db_selection=""
  local benchmark_namespace="benchmark"
  local metrics_namespace="clustershift"
  local skip_db_setup="false"
  local interactive_mode=false

  # Parse command line arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
    --db-selection)
      db_selection="$2"
      shift 2
      ;;
    --benchmark-namespace)
      benchmark_namespace="$2"
      shift 2
      ;;
    --metrics-namespace)
      metrics_namespace="$2"
      shift 2
      ;;
    --skip-db-setup)
      skip_db_setup="true"
      shift
      ;;
    --cleanup)
      cleanup_all
      exit 0
      ;;
    --list-configs)
      list_database_configs
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

  # Check if running in interactive mode (no command line args)
  if [ -z "$db_selection" ] && [ $# -eq 0 ]; then
    interactive_mode=true
  fi

  # Interactive selection if not provided
  if [ -z "$db_selection" ]; then
    get_interactive_selection
    db_selection="$SELECTED_DB"
  fi

  # Validate selection
  if ! validate_selection "$db_selection"; then
    exit 1
  fi

  # Confirm selection in interactive mode
  if [ "$interactive_mode" = true ]; then
    if ! confirm_selection "$db_selection"; then
      print_status "Configuration cancelled. Restarting selection..."
      exec "$0"  # Use exec to restart the script properly
    fi
  fi

  local db_name=$(get_db_name $db_selection)
  print_status "Selected database configuration: $db_name"

  # Execute deployment steps
  check_prerequisites

  if [ "$skip_db_setup" = "false" ]; then
    run_database_setup "$db_selection"
    wait_for_database "$db_selection"
  else
    print_status "Skipping database setup as requested"
  fi

  deploy_benchmark_applications "$db_selection" "$benchmark_namespace" "$metrics_namespace"
  display_final_info "$db_selection" "$benchmark_namespace" "$metrics_namespace"

  print_success "Global benchmark environment deployment completed successfully!"
  print_status "Your complete benchmarking environment is ready!"
}

# Trap to handle script interruption
trap 'print_error "Script interrupted!"; exit 1' INT TERM

# Run main function
main "$@"
