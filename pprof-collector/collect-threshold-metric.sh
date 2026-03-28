#!/bin/bash

# Threshold-based pprof collection for CPU or RAM metrics
# Monitors NODE-level metrics and collects from 2 control-plane + top 1 node when threshold exceeded

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib-common.sh"

# Configuration
METRIC_TYPE=${METRIC_TYPE:-cpu}          # cpu or ram
DURATION=${DURATION:-30}                 # Duration for profiling
INTERVAL=${INTERVAL:-60}                 # Check interval in seconds
CPU_THRESHOLD=${CPU_THRESHOLD:-80%}      # CPU threshold: 3000m or 80%
RAM_THRESHOLD=${RAM_THRESHOLD:-80%}      # RAM threshold: 10000Mi or 80%
COLLECTION_COUNT=${COLLECTION_COUNT:-0}  # 0 = infinite, >0 = stop after N collections
PPROF_MODE=${PPROF_MODE:-all}            # all, cpu, or ram

# Validate prerequisites
ensure_output_dirs
validate_pod_port_map || exit 1

# Function to check and collect from pods when node threshold exceeded
check_and_collect() {
    local iteration=$1
    echo ""
    echo "=========================================="
    echo "Collection cycle #$iteration - $(date)"
    echo "=========================================="

    # Get all node metrics
    local node_metrics=$(get_all_node_metrics)

    if [[ -z "$node_metrics" ]]; then
        echo "Warning: Cannot get node metrics"
        return 0
    fi

    # Check if ANY node exceeds threshold
    local threshold_exceeded=false
    local trigger_node=""
    local trigger_value=""
    local trigger_metric=""

    while read -r line; do
        local node_name=$(echo "$line" | awk '{print $1}')
        local cpu_cores=$(echo "$line" | awk '{print $2}')
        local cpu_percent=$(echo "$line" | awk '{print $3}' | sed 's/%//')
        local mem_bytes=$(echo "$line" | awk '{print $4}')
        local mem_percent=$(echo "$line" | awk '{print $5}' | sed 's/%//')

        if [[ "$METRIC_TYPE" == "cpu" ]]; then
            # Check CPU threshold
            if [[ "$CPU_THRESHOLD" =~ %$ ]]; then
                # Percentage-based threshold
                local threshold_pct=$(echo "$CPU_THRESHOLD" | sed 's/%//')
                if [[ $cpu_percent -ge $threshold_pct ]]; then
                    threshold_exceeded=true
                    trigger_node="$node_name"
                    trigger_value="CPU ${cpu_percent}% >= ${CPU_THRESHOLD}"
                    trigger_metric="$cpu_cores ($cpu_percent%)"
                    break
                fi
            else
                # Millicores-based threshold
                local cpu_mc=$(cpu_to_millicores "$cpu_cores")
                local threshold_mc=$(cpu_to_millicores "$CPU_THRESHOLD")
                if [[ $cpu_mc -ge $threshold_mc ]]; then
                    threshold_exceeded=true
                    trigger_node="$node_name"
                    trigger_value="CPU ${cpu_cores} (${cpu_mc}m) >= ${CPU_THRESHOLD}"
                    trigger_metric="$cpu_cores ($cpu_percent%)"
                    break
                fi
            fi
        elif [[ "$METRIC_TYPE" == "ram" ]]; then
            # Check RAM threshold
            if [[ "$RAM_THRESHOLD" =~ %$ ]]; then
                # Percentage-based threshold
                local threshold_pct=$(echo "$RAM_THRESHOLD" | sed 's/%//')
                if [[ $mem_percent -ge $threshold_pct ]]; then
                    threshold_exceeded=true
                    trigger_node="$node_name"
                    trigger_value="RAM ${mem_percent}% >= ${RAM_THRESHOLD}"
                    trigger_metric="$mem_bytes ($mem_percent%)"
                    break
                fi
            else
                # Mi-based threshold
                local mem_mi=$(ram_to_mi "$mem_bytes")
                local threshold_mi=$RAM_THRESHOLD
                if [[ $mem_mi -ge $threshold_mi ]]; then
                    threshold_exceeded=true
                    trigger_node="$node_name"
                    trigger_value="RAM ${mem_bytes} (${mem_mi}Mi) >= ${RAM_THRESHOLD}Mi"
                    trigger_metric="$mem_bytes ($mem_percent%)"
                    break
                fi
            fi
        fi
    done <<< "$node_metrics"

    if [[ "$threshold_exceeded" == "false" ]]; then
        metric_upper=$(echo "$METRIC_TYPE" | tr '[:lower:]' '[:upper:]')
        echo "No nodes exceed ${metric_upper} threshold"
        echo "Waiting for next check..."
        return 0
    fi

    # Threshold exceeded - collect from 2 CP + top 1 node
    echo "NODE THRESHOLD EXCEEDED!"
    echo "  Trigger Node: $trigger_node"
    echo "  Reason: $trigger_value"
    echo ""
    echo "Collecting from: ALL control-plane (2) + OVN pod on node with highest ${METRIC_TYPE}"
    echo ""

    # Get all control-plane pods
    local cp_pods=$(get_control_plane_pods)

    # Get all node pods with their node names and metrics
    local node_pods_list=$(oc -n "$NAMESPACE" get pods -l app=ovnkube-node --no-headers 2>/dev/null | \
                          grep -v 'Terminating' | \
                          awk '{print $1}')

    # Find the node pod running on the node with highest metric
    # If multiple nodes have same metric, choose first one
    local top_node_pod=""
    local top_node_value=-1
    local top_node_name=""

    for pod_name in $node_pods_list; do
        local pod_node=$(get_pod_node "$pod_name")

        # Get this node's metric from node_metrics
        local node_metric=$(echo "$node_metrics" | grep "^$pod_node " | head -1)

        if [[ -z "$node_metric" ]]; then
            continue
        fi

        if [[ "$METRIC_TYPE" == "cpu" ]]; then
            local cpu_percent=$(echo "$node_metric" | awk '{print $3}' | sed 's/%//')
            # Use > (not >=) so first pod wins if metrics are equal
            if [[ $cpu_percent -gt $top_node_value ]]; then
                top_node_value=$cpu_percent
                top_node_pod="$pod_name"
                top_node_name="$pod_node"
            fi
        else
            local mem_percent=$(echo "$node_metric" | awk '{print $5}' | sed 's/%//')
            # Use > (not >=) so first pod wins if metrics are equal
            if [[ $mem_percent -gt $top_node_value ]]; then
                top_node_value=$mem_percent
                top_node_pod="$pod_name"
                top_node_name="$pod_node"
            fi
        fi
    done

    local cp_count=$(echo "$cp_pods" | wc -w | tr -d ' ')
    local total_count=$((cp_count + 1))

    echo "Target pods:"
    echo "  Control-plane: $cp_count pods (all)"
    echo "  Nodes: 1 pod (on node with highest ${METRIC_TYPE}: $top_node_name)"
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

    # Collect from the node pod on the highest-metric node
    if [[ -n "$top_node_pod" ]]; then
        current=$((current + 1))

        local pod_metrics=$(get_pod_metrics "$top_node_pod")
        local cpu_usage=$(echo "$pod_metrics" | awk '{print $2}')
        local ram_usage=$(echo "$pod_metrics" | awk '{print $3}')

        # Get node metrics for this pod's node
        local node_metric=$(echo "$node_metrics" | grep "^$top_node_name " | head -1)
        local node_cpu=$(echo "$node_metric" | awk '{print $2}')
        local node_cpu_pct=$(echo "$node_metric" | awk '{print $3}')
        local node_ram=$(echo "$node_metric" | awk '{print $4}')
        local node_ram_pct=$(echo "$node_metric" | awk '{print $5}')

        if [[ "$METRIC_TYPE" == "cpu" ]]; then
            echo "[$current/$total_count] Node: $top_node_pod (Node: $top_node_name, CPU: $node_cpu_pct)"
        else
            echo "[$current/$total_count] Node: $top_node_pod (Node: $top_node_name, RAM: $node_ram_pct)"
        fi

        local proxy_port=$(lookup_pod_port "$top_node_pod")
        if [[ -z "$proxy_port" ]]; then
            echo "  ⚠️  No port mapping found, skipping"
        else
            echo "  Port: $proxy_port"
            echo "  Pod Resources: CPU=$cpu_usage, RAM=$ram_usage"
            echo "  Node Metrics: CPU=$node_cpu ($node_cpu_pct), RAM=$node_ram ($node_ram_pct)"

            if [[ "$PPROF_MODE" == "cpu" ]]; then
                collect_pprof_cpu "$top_node_pod" "$proxy_port" "$cpu_usage" "$ram_usage" "node" &
            elif [[ "$PPROF_MODE" == "ram" ]]; then
                collect_pprof_ram "$top_node_pod" "$proxy_port" "$cpu_usage" "$ram_usage" "node" &
            else
                collect_pprof "$top_node_pod" "$proxy_port" "$cpu_usage" "$ram_usage" "node" &
            fi
            collected_node=$((collected_node + 1))
        fi
    fi

    # Wait for all background collections
    wait

    echo ""
    echo "Summary:"
    echo "  Control-plane collected: $collected_cp"
    echo "  Nodes collected: $collected_node"
    echo "  Total collected: $((collected_cp + collected_node))"

    local cp_files=$(ls -1 "$OUTPUT_DIR_CP" 2>/dev/null | wc -l | tr -d ' ')
    local node_files=$(ls -1 "$OUTPUT_DIR_NODE" 2>/dev/null | wc -l | tr -d ' ')
    echo "  Total files - CP: $cp_files, Nodes: $node_files"

    return $((collected_cp + collected_node))
}

# Main monitoring loop
metric_upper=$(echo "$METRIC_TYPE" | tr '[:lower:]' '[:upper:]')
echo "==========================================="
echo "OVN ${metric_upper} Node Threshold Collector"
echo "==========================================="
echo "Strategy:"
echo "  - Monitor NODE-level ${metric_upper} usage"
echo "  - When ANY node exceeds threshold → collect from:"
echo "    * ALL control-plane pods (typically 2)"
echo "    * OVN pod on node with highest ${metric_upper}"
echo ""
echo "Configuration:"
echo "  Namespace: $NAMESPACE"
echo "  Metric Type: $METRIC_TYPE (NODE-level)"
if [[ "$METRIC_TYPE" == "cpu" ]]; then
    if [[ "$CPU_THRESHOLD" =~ %$ ]]; then
        echo "  CPU Threshold: ${CPU_THRESHOLD} of node capacity"
    else
        echo "  CPU Threshold: ${CPU_THRESHOLD}"
    fi
else
    if [[ "$RAM_THRESHOLD" =~ %$ ]]; then
        echo "  RAM Threshold: ${RAM_THRESHOLD} of node capacity"
    else
        echo "  RAM Threshold: ${RAM_THRESHOLD}Mi"
    fi
fi
echo "  Profile Duration: ${DURATION}s"
echo "  Check Interval: ${INTERVAL}s"
echo "  Collection Count: $(if [[ $COLLECTION_COUNT -eq 0 ]]; then echo "unlimited"; else echo "$COLLECTION_COUNT"; fi)"
echo "  Output:"
echo "    Control-plane: $OUTPUT_DIR_CP"
echo "    Nodes: $OUTPUT_DIR_NODE"
echo ""
echo "Monitoring started at $(date)"
echo "Press Ctrl+C to stop"
echo ""

iteration=0
total_collections=0

# Trap Ctrl+C for graceful exit
trap 'echo ""; echo "Monitoring stopped at $(date)"; echo "Total collections: $total_collections"; exit 0' INT TERM

while true; do
    iteration=$((iteration + 1))

    check_and_collect $iteration
    collected=$?
    total_collections=$((total_collections + collected))

    # Check if we should stop
    if [[ $COLLECTION_COUNT -gt 0 ]] && [[ $total_collections -ge $COLLECTION_COUNT ]]; then
        echo ""
        echo "Reached collection limit ($COLLECTION_COUNT), stopping"
        break
    fi

    # Wait for next interval
    echo ""
    echo "Waiting ${INTERVAL}s until next check..."
    sleep "$INTERVAL"
done

echo ""
echo "Monitoring completed at $(date)"
echo "Total collections: $total_collections"
echo "Output: $OUTPUT_DIR_CP (CP), $OUTPUT_DIR_NODE (nodes)"
