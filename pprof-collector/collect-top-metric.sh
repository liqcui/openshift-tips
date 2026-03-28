#!/bin/bash

# Optimized periodic collection from top pods by CPU or RAM
# Collects from: ALL control-plane + TOP N node (by CPU or RAM)

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib-common.sh"

# Configuration
METRIC_TYPE=${METRIC_TYPE:-cpu}          # cpu or ram
DURATION=${DURATION:-30}                 # Profile duration in seconds
INTERVAL=${INTERVAL:-35}                 # Collection interval
COLLECTION_COUNT=${COLLECTION_COUNT:-0}  # 0 = infinite, >0 = stop after N cycles
TOP_N_NODES=${TOP_N_NODES:-1}            # Number of top nodes to collect from
PPROF_MODE=${PPROF_MODE:-all}            # all, cpu, or ram

# Validate prerequisites
ensure_output_dirs
validate_pod_port_map || exit 1

# Calculate coverage
gap=$(calculate_gap "$DURATION" "$INTERVAL")
if [[ $gap -lt 0 ]]; then
    gap=0
    coverage=100
else
    coverage=$(calculate_coverage "$DURATION" "$INTERVAL")
fi

metric_upper=$(echo "$METRIC_TYPE" | tr '[:lower:]' '[:upper:]')
echo "==========================================="
echo "OVN Top ${metric_upper} Pods Collector"
echo "==========================================="
echo "Strategy:"
echo "  - Collect from ALL control-plane pods (always)"
echo "  - Collect from TOP $TOP_N_NODES node pod(s) (by ${metric_upper})"
echo "  - Maximize time coverage with minimal gaps"
echo ""
echo "Configuration:"
echo "  Namespace: $NAMESPACE"
echo "  Metric: $METRIC_TYPE"
echo "  Profile Duration: ${DURATION}s"
echo "  Collection Interval: ${INTERVAL}s"
echo "  Gap Between Collections: ${gap}s"
echo "  Time Coverage: ~${coverage}%"
echo "  Top N Nodes: $TOP_N_NODES"
echo "  Collection Cycles: $(if [[ $COLLECTION_COUNT -eq 0 ]]; then echo \"unlimited\"; else echo \"$COLLECTION_COUNT\"; fi)"
echo ""
echo "Output:"
echo "  Control-plane: $OUTPUT_DIR_CP"
echo "  Nodes: $OUTPUT_DIR_NODE"
echo ""

# Function to collect from selected pods
collect_from_pods() {
    local iteration=$1
    echo ""
    echo "==========================================="
    echo "Collection cycle #$iteration - $(date)"
    echo "==========================================="

    # Get all control-plane pods
    local cp_pods=$(get_control_plane_pods)

    # Get all node pods with their metrics
    local node_pods_data=$(oc -n "$NAMESPACE" adm top pod --no-headers 2>/dev/null | \
                           grep ovnkube-node | \
                           grep -v 'Terminating')

    if [[ -z "$cp_pods" ]] && [[ -z "$node_pods_data" ]]; then
        echo "Warning: No OVN pods found"
        return 0
    fi

    # Get top N node pods by specified metric
    # If multiple nodes have same metric, sort is stable so first one is chosen
    local top_node_pods
    if [[ "$METRIC_TYPE" == "cpu" ]]; then
        top_node_pods=$(echo "$node_pods_data" | \
                       awk '{print $1, $2}' | \
                       while read -r pod cpu; do
                           cpu_mc=$(cpu_to_millicores "$cpu")
                           echo "$cpu_mc $pod $cpu"
                       done | \
                       sort -rn -s | \
                       head -n $TOP_N_NODES | \
                       awk '{print $2}')
    else
        top_node_pods=$(echo "$node_pods_data" | \
                       awk '{print $1, $3}' | \
                       while read -r pod ram; do
                           ram_mi=$(ram_to_mi "$ram")
                           echo "$ram_mi $pod $ram"
                       done | \
                       sort -rn -s | \
                       head -n $TOP_N_NODES | \
                       awk '{print $2}')
    fi

    local cp_count=$(echo "$cp_pods" | wc -w | tr -d ' ')
    local node_count=$(echo "$top_node_pods" | wc -w | tr -d ' ')
    local total_count=$((cp_count + node_count))

    echo "Target pods:"
    echo "  Control-plane: $cp_count pods (all)"
    echo "  Nodes: $node_count pods (top $TOP_N_NODES by ${metric_upper})"
    echo "  Total: $total_count pods"
    echo ""

    local current=0
    local collected_cp=0
    local collected_node=0

    # Collect from all control-plane pods
    for pod_name in $cp_pods; do
        current=$((current + 1))
        echo "[$current/$total_count] Control-Plane: $pod_name"

        local proxy_port=$(lookup_pod_port "$pod_name")

        if [[ -z "$proxy_port" ]]; then
            echo "  ⚠️  No port mapping found, skipping"
            continue
        fi

        echo "  Port: $proxy_port"

        local pod_metrics=$(get_pod_metrics "$pod_name")
        if [[ -z "$pod_metrics" ]]; then
            cpu_size="unknown"
            ram_size="unknown"
        else
            cpu_size=$(echo "$pod_metrics" | awk '{print $2}')
            ram_size=$(echo "$pod_metrics" | awk '{print $3}')
        fi
        echo "  Resources: CPU=$cpu_size, RAM=$ram_size"

        if [[ "$PPROF_MODE" == "cpu" ]]; then
            collect_pprof_cpu "$pod_name" "$proxy_port" "$cpu_size" "$ram_size" "control-plane" &
        elif [[ "$PPROF_MODE" == "ram" ]]; then
            collect_pprof_ram "$pod_name" "$proxy_port" "$cpu_size" "$ram_size" "control-plane" &
        else
            collect_pprof "$pod_name" "$proxy_port" "$cpu_size" "$ram_size" "control-plane" &
        fi
        collected_cp=$((collected_cp + 1))
    done

    # Collect from top N node pods
    for pod_name in $top_node_pods; do
        current=$((current + 1))

        # Get metrics for display
        local pod_metrics=$(get_pod_metrics "$pod_name")
        local cpu_usage=$(echo "$pod_metrics" | awk '{print $2}')
        local ram_usage=$(echo "$pod_metrics" | awk '{print $3}')

        if [[ "$METRIC_TYPE" == "cpu" ]]; then
            echo "[$current/$total_count] Node: $pod_name (CPU: $cpu_usage)"
        else
            echo "[$current/$total_count] Node: $pod_name (RAM: $ram_usage)"
        fi

        local proxy_port=$(lookup_pod_port "$pod_name")

        if [[ -z "$proxy_port" ]]; then
            echo "  ⚠️  No port mapping found, skipping"
            continue
        fi

        echo "  Port: $proxy_port"
        echo "  Resources: CPU=$cpu_usage, RAM=$ram_usage"

        if [[ "$PPROF_MODE" == "cpu" ]]; then
            collect_pprof_cpu "$pod_name" "$proxy_port" "$cpu_usage" "$ram_usage" "node" &
        elif [[ "$PPROF_MODE" == "ram" ]]; then
            collect_pprof_ram "$pod_name" "$proxy_port" "$cpu_usage" "$ram_usage" "node" &
        else
            collect_pprof "$pod_name" "$proxy_port" "$cpu_usage" "$ram_usage" "node" &
        fi
        collected_node=$((collected_node + 1))
    done

    # Wait for all background collections
    wait

    echo ""
    echo "==========================================="
    echo "Cycle #$iteration Summary"
    echo "==========================================="
    echo "Control-plane collected: $collected_cp"
    echo "Nodes collected: $collected_node"
    echo "Total collected: $((collected_cp + collected_node))"
    echo ""
    echo "Files:"
    local cp_files=$(ls -1 "$OUTPUT_DIR_CP" 2>/dev/null | wc -l | tr -d ' ')
    local node_files=$(ls -1 "$OUTPUT_DIR_NODE" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Control-plane: $cp_files"
    echo "  Nodes: $node_files"
    echo ""

    return $((collected_cp + collected_node))
}

# Main monitoring loop
echo "Collection started at $(date)"
echo "Press Ctrl+C to stop"
echo ""

cycle=0
total_collections=0

trap 'echo ""; echo "Collection stopped at $(date)"; echo "Total cycles: $cycle"; echo "Total pod collections: $total_collections"; exit 0' INT TERM

while true; do
    cycle=$((cycle + 1))

    cycle_start=$(date +%s)

    collect_from_pods $cycle
    collected=$?
    total_collections=$((total_collections + collected))

    cycle_end=$(date +%s)
    cycle_duration=$((cycle_end - cycle_start))

    # Check if we should stop
    if [[ $COLLECTION_COUNT -gt 0 ]] && [[ $cycle -ge $COLLECTION_COUNT ]]; then
        echo ""
        echo "Reached collection cycle limit ($COLLECTION_COUNT), stopping"
        break
    fi

    # Calculate wait time
    wait_time=$((INTERVAL - cycle_duration))
    if [[ $wait_time -lt 0 ]]; then
        wait_time=0
        echo "⚠️  Warning: Cycle took ${cycle_duration}s > interval ${INTERVAL}s"
    fi

    echo ""
    if [[ $wait_time -gt 0 ]]; then
        echo "Next collection in ${wait_time}s (cycle took ${cycle_duration}s)..."
        sleep "$wait_time"
    else
        echo "Starting next collection immediately..."
    fi
done

echo ""
echo "==========================================="
echo "Collection Complete"
echo "==========================================="
echo "Total cycles: $cycle"
echo "Total pod collections: $total_collections"
echo "Coverage: ~${coverage}%"
echo ""
echo "Output: $OUTPUT_DIR_CP (CP), $OUTPUT_DIR_NODE (nodes)"
echo ""
echo "✓ Done!"
