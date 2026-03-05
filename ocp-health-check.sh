#!/bin/bash

# OpenShift Cluster Health Check Script
# This script checks connectivity and basic health of an OpenShift cluster
# Supports continuous monitoring mode with configurable intervals

set -e

# Configuration
LOOP_MODE=false
CHECK_INTERVAL=60  # Default: 60 seconds
MAX_ITERATIONS=0   # 0 = infinite
QUIET_MODE=false
LOG_FILE=""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    local msg="$2"
    if [ -n "$LOG_FILE" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $msg" >> "$LOG_FILE"
    fi
    
    if [ "$QUIET_MODE" = true ] && [ "$1" != "FAIL" ]; then
        return 0
    fi
    
    if [ "$1" == "OK" ]; then
        echo -e "${GREEN}[✓]${NC} $msg"
    elif [ "$1" == "FAIL" ]; then
        echo -e "${RED}[✗]${NC} $msg"
        return 1
    elif [ "$1" == "WARN" ]; then
        echo -e "${YELLOW}[!]${NC} $msg"
    elif [ "$1" == "INFO" ]; then
        echo -e "${BLUE}[i]${NC} $msg"
    else
        echo -e "$msg"
    fi
}

# Function to check if oc command exists
check_oc_installed() {
    if command -v oc &> /dev/null; then
        print_status "OK" "oc CLI is installed"
        if [ "$QUIET_MODE" = false ]; then
            oc version --client 2>/dev/null || true
        fi
        return 0
    else
        print_status "FAIL" "oc CLI is not installed"
        return 1
    fi
}

# Function to check cluster connectivity
check_cluster_connection() {
    if oc whoami &> /dev/null; then
        print_status "OK" "Connected to OpenShift cluster"
        if [ "$QUIET_MODE" = false ]; then
            echo "    User: $(oc whoami)"
            echo "    Server: $(oc whoami --show-server)"
        fi
        return 0
    else
        print_status "FAIL" "Cannot connect to OpenShift cluster"
        if [ "$QUIET_MODE" = false ]; then
            echo "    Please login using: oc login <cluster-url>"
        fi
        return 1
    fi
}

# Function to check cluster version
check_cluster_version() {
    if VERSION=$(oc version 2>/dev/null); then
        print_status "OK" "Cluster version retrieved"
        if [ "$QUIET_MODE" = false ]; then
            echo "$VERSION" | grep -E "(Server Version|Kubernetes Version)" || true
        fi
        return 0
    else
        print_status "WARN" "Could not retrieve cluster version"
        return 1
    fi
}

# Function to check cluster nodes
check_cluster_nodes() {
    if NODES=$(oc get nodes --no-headers 2>/dev/null); then
        NODE_COUNT=$(echo "$NODES" | wc -l)
        READY_COUNT=$(echo "$NODES" | grep -c " Ready" || true)
        print_status "OK" "Cluster has $NODE_COUNT node(s), $READY_COUNT ready"
        
        if [ "$READY_COUNT" -lt "$NODE_COUNT" ]; then
            print_status "WARN" "Some nodes are not ready"
            if [ "$QUIET_MODE" = false ]; then
                echo "$NODES" | grep -v " Ready" || true
            fi
        fi
        return 0
    else
        print_status "WARN" "Could not retrieve node information (may lack permissions)"
        return 1
    fi
}

# Function to check current project/namespace
check_current_project() {
    if PROJECT=$(oc project -q 2>/dev/null); then
        print_status "OK" "Current project: $PROJECT"
        return 0
    else
        print_status "WARN" "Could not determine current project"
        return 1
    fi
}

# Function to check API server health
check_api_health() {
    if oc get --raw /healthz &> /dev/null; then
        print_status "OK" "API server is healthy"
        return 0
    else
        print_status "FAIL" "API server health check failed"
        return 1
    fi
}

# Function to check cluster operators (if permissions allow)
check_cluster_operators() {
    if oc get clusteroperators &> /dev/null; then
        DEGRADED=$(oc get clusteroperators --no-headers 2>/dev/null | grep -v "True.*False.*False" || true)
        if [ -z "$DEGRADED" ]; then
            print_status "OK" "All cluster operators are healthy"
        else
            print_status "WARN" "Some cluster operators are degraded"
            if [ "$QUIET_MODE" = false ]; then
                echo "$DEGRADED"
            fi
        fi
        return 0
    else
        print_status "WARN" "Cannot check cluster operators (may lack cluster-admin permissions)"
        return 1
    fi
}

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

OpenShift Cluster Health Check Script

OPTIONS:
    -l, --loop              Enable continuous monitoring mode
    -i, --interval SECONDS  Check interval in seconds (default: 60)
    -n, --iterations COUNT  Number of iterations (default: infinite in loop mode)
    -q, --quiet             Quiet mode - only show failures and warnings
    -o, --output FILE       Write logs to file
    -h, --help              Show this help message

EXAMPLES:
    # Single health check
    $0

    # Continuous monitoring every 30 seconds
    $0 --loop --interval 30

    # Run 10 checks with 60 second intervals
    $0 --loop --iterations 10

    # Quiet mode with logging
    $0 --loop --quiet --output health.log

EOF
    exit 0
}

# Function to handle script termination
cleanup() {
    echo ""
    print_status "INFO" "Health check monitoring stopped"
    exit 0
}

# Function to run a single health check iteration
run_health_check() {
    local iteration=$1
    
    if [ "$LOOP_MODE" = true ]; then
        echo ""
        echo "========================================="
        echo "  Health Check #$iteration"
        echo "  $(date '+%Y-%m-%d %H:%M:%S')"
        echo "========================================="
    else
        echo "========================================="
        echo "  OpenShift Cluster Health Check"
        echo "========================================="
    fi
    echo ""
    
    FAILED=0
    
    check_oc_installed || ((FAILED++))
    echo ""
    
    if [ $FAILED -eq 0 ]; then
        check_cluster_connection || ((FAILED++))
        echo ""
        
        if [ $FAILED -eq 0 ]; then
            check_api_health || true
            echo ""
            check_cluster_version || true
            echo ""
            check_current_project || true
            echo ""
            check_cluster_nodes || true
            echo ""
            check_cluster_operators || true
            echo ""
        fi
    fi
    
    if [ "$LOOP_MODE" = false ]; then
        echo "========================================="
    fi
    
    if [ $FAILED -eq 0 ]; then
        print_status "OK" "Health check completed successfully"
        return 0
    else
        print_status "FAIL" "Health check completed with errors"
        return 1
    fi
}

# Main execution
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -l|--loop)
                LOOP_MODE=true
                shift
                ;;
            -i|--interval)
                CHECK_INTERVAL="$2"
                shift 2
                ;;
            -n|--iterations)
                MAX_ITERATIONS="$2"
                shift 2
                ;;
            -q|--quiet)
                QUIET_MODE=true
                shift
                ;;
            -o|--output)
                LOG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    # Set up signal handlers for graceful shutdown
    trap cleanup SIGINT SIGTERM
    
    # Create log file if specified
    if [ -n "$LOG_FILE" ]; then
        touch "$LOG_FILE" || {
            echo "Error: Cannot create log file $LOG_FILE"
            exit 1
        }
        print_status "INFO" "Logging to: $LOG_FILE"
    fi
    
    if [ "$LOOP_MODE" = true ]; then
        print_status "INFO" "Starting continuous health monitoring (interval: ${CHECK_INTERVAL}s)"
        if [ "$MAX_ITERATIONS" -gt 0 ]; then
            print_status "INFO" "Will run $MAX_ITERATIONS iterations"
        else
            print_status "INFO" "Running indefinitely (press Ctrl+C to stop)"
        fi
        
        iteration=1
        while true; do
            run_health_check $iteration
            
            # Check if we've reached max iterations
            if [ "$MAX_ITERATIONS" -gt 0 ] && [ $iteration -ge "$MAX_ITERATIONS" ]; then
                print_status "INFO" "Reached maximum iterations ($MAX_ITERATIONS)"
                break
            fi
            
            # Wait for next iteration
            if [ "$QUIET_MODE" = false ]; then
                echo ""
                print_status "INFO" "Next check in ${CHECK_INTERVAL} seconds..."
            fi
            sleep "$CHECK_INTERVAL"
            
            ((iteration++))
        done
    else
        # Single check mode
        run_health_check 1
        
        echo "========================================="
        exit $?
    fi
}

# Run main function
main "$@"