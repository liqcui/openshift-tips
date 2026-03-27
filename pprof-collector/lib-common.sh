#!/bin/bash

# Common Functions Library for OVN Kubernetes Pprof Collector
# Shared constants, functions, and utilities

# ===========================================
# Constants
# ===========================================

NAMESPACE="openshift-ovn-kubernetes"
POD_PORT_MAP="pod-port-map.lst"
OUTPUT_DIR_CP="${OUTPUT_DIR_CP:-./pprof-data-control-plane}"
OUTPUT_DIR_NODE="${OUTPUT_DIR_NODE:-./pprof-data-node}"

# Target pprof ports inside pods
CONTROL_PLANE_TARGET_PORT=29108
NODE_TARGET_PORT=29103

# ===========================================
# Metric Conversion Functions
# ===========================================

# Convert CPU value to millicores for comparison
# Supports: 50m, 1, 0.5, etc.
cpu_to_millicores() {
    local cpu=$1
    if [[ $cpu =~ ([0-9]+)m$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ $cpu =~ ^[0-9]+$ ]]; then
        echo $((cpu * 1000))
    elif [[ $cpu =~ ([0-9.]+)$ ]]; then
        echo "$(echo "${BASH_REMATCH[1]}" | awk '{printf "%d", $1 * 1000}')"
    else
        echo "0"
    fi
}

# Get pod CPU limit in millicores
# Returns 0 if no limit set
get_pod_cpu_limit() {
    local pod_name=$1
    local limit=$(oc -n "$NAMESPACE" get pod "$pod_name" -o jsonpath='{.spec.containers[0].resources.limits.cpu}' 2>/dev/null)

    if [[ -z "$limit" ]]; then
        echo "0"
    else
        cpu_to_millicores "$limit"
    fi
}

# Convert CPU threshold to millicores
# Supports: 50m (millicores), 50% (percentage of limit)
cpu_threshold_to_millicores() {
    local threshold=$1
    local pod_name=$2

    # Check if percentage-based
    if [[ $threshold =~ ^([0-9]+)%$ ]]; then
        local percent=${BASH_REMATCH[1]}
        local limit_mc=$(get_pod_cpu_limit "$pod_name")

        if [[ $limit_mc -eq 0 ]]; then
            # No limit set, cannot use percentage
            echo "0"
        else
            # Calculate percentage of limit
            echo $(echo "$limit_mc $percent" | awk '{printf "%d", ($1 * $2) / 100}')
        fi
    else
        # Millicores-based threshold
        cpu_to_millicores "$threshold"
    fi
}

# Convert RAM value to Mi for comparison
# Supports: 1000Mi, 1Gi, etc.
ram_to_mi() {
    local ram=$1
    if [[ $ram =~ ([0-9]+)Mi$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ $ram =~ ([0-9]+)Gi$ ]]; then
        echo $((${BASH_REMATCH[1]} * 1024))
    elif [[ $ram =~ ^[0-9]+$ ]]; then
        echo "$ram"
    else
        echo "0"
    fi
}

# ===========================================
# Cluster Validation Functions
# ===========================================

# Check if oc CLI is available and cluster is accessible
check_cluster() {
    # Check if oc is available
    if ! command -v oc &> /dev/null; then
        echo "Error: 'oc' command not found. Please install OpenShift CLI."
        return 1
    fi

    # Check cluster connectivity
    if ! oc whoami &> /dev/null; then
        echo "Error: Not logged into OpenShift cluster"
        echo "Please run: oc login <cluster-url>"
        return 1
    fi

    return 0
}

# Validate that pod-port-map file exists
validate_pod_port_map() {
    if [[ ! -f "$POD_PORT_MAP" ]]; then
        echo "Error: $POD_PORT_MAP not found"
        echo "Run: ./setup-portforward.sh setup"
        return 1
    fi
    return 0
}

# Test connectivity to a specific port
test_port_connectivity() {
    local port=$1
    local timeout=${2:-3}

    if curl -s -f --max-time "$timeout" "http://localhost:$port/debug/pprof/" > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# ===========================================
# Pod Discovery Functions
# ===========================================

# Get all control-plane pods
get_control_plane_pods() {
    local pods=""

    # Try label-based discovery first
    if oc -n "$NAMESPACE" get pods 2>/dev/null | grep -q ovnkube-master; then
        pods=$(oc -n "$NAMESPACE" get pods -l app=ovnkube-master -o=jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    elif oc -n "$NAMESPACE" get pods 2>/dev/null | grep -q ovnkube-control-plane; then
        pods=$(oc -n "$NAMESPACE" get pods -l app=ovnkube-control-plane -o=jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    fi

    # Fallback to name pattern
    if [[ -z "$pods" ]]; then
        pods=$(oc -n "$NAMESPACE" get pods --no-headers 2>/dev/null | \
               grep 'ovnkube-control-plane\|ovnkube-master' | \
               grep -v 'Terminating' | \
               awk '{print $1}')
    fi

    echo "$pods"
}

# Get all node pods
get_node_pods() {
    local pods=""

    # Try label-based discovery first
    pods=$(oc -n "$NAMESPACE" get pods -l app=ovnkube-node -o=jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    # Fallback to name pattern
    if [[ -z "$pods" ]]; then
        pods=$(oc -n "$NAMESPACE" get pods --no-headers 2>/dev/null | \
               grep 'ovnkube-node' | \
               grep -v 'Terminating' | \
               awk '{print $1}')
    fi

    echo "$pods"
}

# Get pod metrics (CPU and RAM)
get_pod_metrics() {
    local pod_name=$1
    oc -n "$NAMESPACE" adm top pod "$pod_name" --no-headers 2>/dev/null
}

# Get node metrics (CPU and RAM)
get_node_metrics() {
    local node_name=$1
    oc adm top node "$node_name" --no-headers 2>/dev/null
}

# Get all node metrics
get_all_node_metrics() {
    oc adm top node --no-headers 2>/dev/null
}

# Get node name for a pod
get_pod_node() {
    local pod_name=$1
    oc -n "$NAMESPACE" get pod "$pod_name" -o jsonpath='{.spec.nodeName}' 2>/dev/null
}

# ===========================================
# Pprof Collection Function
# ===========================================

# Collect all pprof profiles from a pod
# Args: pod_name, proxy_port, cpu_size, ram_size, pod_type
collect_pprof() {
    local pod_name=$1
    local proxy_port=$2
    local cpu_size=$3
    local ram_size=$4
    local pod_type=$5
    local timestamp=$(date +"%Y%m%d_%H%M%S")

    # Determine output directory and port suffix
    local output_dir
    local port_suffix
    if [[ $pod_type == "control-plane" ]]; then
        output_dir="$OUTPUT_DIR_CP"
        port_suffix="29108"
    else
        output_dir="$OUTPUT_DIR_NODE"
        port_suffix="29103"
    fi

    local base_name="${output_dir}/${pod_name}-CPU${cpu_size}-RAM${ram_size}-${port_suffix}-${timestamp}"
    local base_url="http://localhost:${proxy_port}/debug/pprof"
    local duration=${DURATION:-30}

    echo "    Collecting pprof data..."

    # Collect profiles in parallel for speed
    curl -s -f --max-time $((duration + 10)) "${base_url}/profile?seconds=${duration}" -o "${base_name}.profile" 2>/dev/null &
    curl -s -f --max-time 30 "${base_url}/heap" -o "${base_name}.heap" 2>/dev/null &
    curl -s -f --max-time 30 "${base_url}/allocs" -o "${base_name}.allocs" 2>/dev/null &
    curl -s -f --max-time 30 "${base_url}/goroutine?debug=1" -o "${base_name}.goroutine" 2>/dev/null &
    curl -s -f --max-time 30 "${base_url}/mutex" -o "${base_name}.mutex" 2>/dev/null &
    curl -s -f --max-time 30 "${base_url}/block" -o "${base_name}.block" 2>/dev/null &
    curl -s -f --max-time $((duration + 10)) "${base_url}/trace?seconds=${duration}" -o "${base_name}.trace" 2>/dev/null &

    # Wait for all parallel collections
    wait

    echo "      ✓ Collection complete"
}

# ===========================================
# Utility Functions
# ===========================================

# Ensure output directories exist
ensure_output_dirs() {
    mkdir -p "$OUTPUT_DIR_CP"
    mkdir -p "$OUTPUT_DIR_NODE"
}

# Lookup pod's local port from pod-port-map file
lookup_pod_port() {
    local pod_name=$1
    awk -v pod="$pod_name" '$1 == pod {print $2}' "$POD_PORT_MAP"
}

# Calculate time coverage percentage
calculate_coverage() {
    local duration=$1
    local interval=$2
    echo "$duration $interval" | awk '{printf "%.1f", ($1 / $2) * 100}'
}

# Calculate gap between collections
calculate_gap() {
    local duration=$1
    local interval=$2
    echo $((interval - duration))
}

# Check if port-forwards are running
check_port_forwards_running() {
    if pgrep -f "port-forward.*ovnkube" > /dev/null; then
        return 0
    else
        return 1
    fi
}

# Count running port-forwards
count_running_port_forwards() {
    pgrep -f "port-forward.*ovnkube" | wc -l | tr -d ' '
}
