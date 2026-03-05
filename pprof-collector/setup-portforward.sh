#!/bin/bash

# Unified Port-Forward Setup Script
# Generates pod-port mappings and manages port-forwards for OVN Kubernetes pods

NAMESPACE="openshift-ovn-kubernetes"
OUTPUT_FILE="pod-port-map.lst"
FORWARD_SCRIPT="/tmp/setup-start-forwards.sh"

# Port scheme (8100+ for control-plane, 8200+ for nodes)
MASTER_PORT_START=${MASTER_PORT_START:-8100}
NODE_PORT_START=${NODE_PORT_START:-8200}

# Target pprof ports inside pods
CONTROL_PLANE_TARGET_PORT=29108
NODE_TARGET_PORT=29103

# Legacy mode flag (20000+ ports)
LEGACY_MODE=${LEGACY_MODE:-false}

# Action to perform
ACTION=${1:-setup}

show_usage() {
    echo "Usage: $0 [setup|start|stop|status|fix]"
    echo ""
    echo "Actions:"
    echo "  setup   - Generate pod-port mappings and port-forward script (default)"
    echo "  start   - Start port-forwards in background"
    echo "  stop    - Stop all running port-forwards"
    echo "  status  - Check port-forward status"
    echo "  fix     - Diagnose and fix port scheme issues"
    echo ""
    echo "Environment Variables:"
    echo "  MASTER_PORT_START=8100   - Starting port for control-plane (default: 8100)"
    echo "  NODE_PORT_START=8200     - Starting port for nodes (default: 8200)"
    echo "  LEGACY_MODE=true         - Use legacy 20000+ port scheme"
    echo ""
    echo "Examples:"
    echo "  $0 setup         # Generate mappings"
    echo "  $0 start         # Start port-forwards"
    echo "  $0 status        # Check status"
    echo "  LEGACY_MODE=true $0 setup  # Use legacy ports"
    exit 1
}

check_cluster() {
    # Check if oc is available
    if ! command -v oc &> /dev/null; then
        echo "Error: 'oc' command not found. Please install OpenShift CLI."
        exit 1
    fi

    # Check cluster connectivity
    if ! oc whoami &> /dev/null; then
        echo "Error: Not logged into OpenShift cluster"
        echo "Please run: oc login <cluster-url>"
        exit 1
    fi
}

setup_portmap() {
    echo "=========================================="
    echo "OVN Kubernetes Port-Forward Setup"
    echo "=========================================="
    echo ""

    check_cluster

    echo "Cluster: $(oc whoami --show-server)"
    echo "User: $(oc whoami)"
    echo "Namespace: $NAMESPACE"
    echo ""

    # Determine port scheme
    if [[ "$LEGACY_MODE" == "true" ]]; then
        echo "Mode: Legacy (20000+ ports)"
        MASTER_PORT_START=20000
        NODE_PORT_START=20000
        CONTROL_PLANE_TARGET_PORT=29102
        NODE_TARGET_PORT=29103
    else
        echo "Mode: Standard (8100+ control-plane, 8200+ nodes)"
    fi
    echo ""

    # Get control-plane pods
    echo "Fetching control-plane pods..."
    if oc -n "$NAMESPACE" get pods 2>/dev/null | grep -q ovnkube-master; then
        echo "  Using ovnkube-master pods..."
        control_plane_pods=$(oc -n "$NAMESPACE" get pods -l app=ovnkube-master -o=jsonpath='{.items[*].metadata.name}')
    elif oc -n "$NAMESPACE" get pods 2>/dev/null | grep -q ovnkube-control-plane; then
        echo "  Using ovnkube-control-plane pods..."
        control_plane_pods=$(oc -n "$NAMESPACE" get pods -l app=ovnkube-control-plane -o=jsonpath='{.items[*].metadata.name}')
    else
        # Fallback: get all control-plane pods by name pattern
        control_plane_pods=$(oc -n "$NAMESPACE" get pods --no-headers 2>/dev/null | \
                           grep 'ovnkube-control-plane\|ovnkube-master' | \
                           grep -v 'Terminating' | \
                           awk '{print $1}')
    fi

    # Get node pods
    echo "Fetching node pods..."
    node_pods=$(oc -n "$NAMESPACE" get pods -l app=ovnkube-node -o=jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [[ -z "$node_pods" ]]; then
        # Fallback: get node pods by name pattern
        node_pods=$(oc -n "$NAMESPACE" get pods --no-headers 2>/dev/null | \
                   grep 'ovnkube-node' | \
                   grep -v 'Terminating' | \
                   awk '{print $1}')
    fi

    control_plane_count=$(echo $control_plane_pods | wc -w | tr -d ' ')
    node_count=$(echo $node_pods | wc -w | tr -d ' ')

    if [[ $control_plane_count -eq 0 ]] && [[ $node_count -eq 0 ]]; then
        echo "Error: No OVN pods found in namespace $NAMESPACE"
        exit 1
    fi

    echo "Found $control_plane_count control-plane pods"
    echo "Found $node_count node pods"
    echo ""

    # Create backup of existing file
    if [[ -f "$OUTPUT_FILE" ]]; then
        backup_file="${OUTPUT_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        echo "Backing up existing $OUTPUT_FILE to $backup_file"
        cp "$OUTPUT_FILE" "$backup_file"
        echo ""
    fi

    # Generate new mapping file
    echo "Generating $OUTPUT_FILE..."
    > "$OUTPUT_FILE"

    current_port=$MASTER_PORT_START
    count=0

    # Process control-plane pods
    if [[ $control_plane_count -gt 0 ]]; then
        echo ""
        echo "Control-Plane Pods:"
        echo "-------------------"
        for pod_name in $control_plane_pods; do
            count=$((count + 1))
            echo "$pod_name $current_port" >> "$OUTPUT_FILE"
            echo "[$count] $pod_name -> localhost:$current_port (target: $CONTROL_PLANE_TARGET_PORT)"
            if [[ "$LEGACY_MODE" != "true" ]]; then
                current_port=$((current_port + 1))
            else
                current_port=$((current_port + 1))
            fi
        done
    fi

    # Process node pods
    if [[ $node_count -gt 0 ]]; then
        if [[ "$LEGACY_MODE" != "true" ]]; then
            current_port=$NODE_PORT_START
        fi

        node_num=0
        echo ""
        echo "Node Pods:"
        echo "----------"
        for pod_name in $node_pods; do
            node_num=$((node_num + 1))
            count=$((count + 1))
            echo "$pod_name $current_port" >> "$OUTPUT_FILE"
            echo "[$node_num] $pod_name -> localhost:$current_port (target: $NODE_TARGET_PORT)"
            current_port=$((current_port + 1))
        done
    fi

    echo ""
    echo "✓ Generated $OUTPUT_FILE with $count entries"
    echo ""

    # Display the mapping file
    echo "Pod-Port Mapping:"
    echo "-----------------"
    cat "$OUTPUT_FILE"
    echo ""

    # Generate port-forward script
    echo "Generating $FORWARD_SCRIPT..."
    > "$FORWARD_SCRIPT"
    chmod +x "$FORWARD_SCRIPT"

    cat > "$FORWARD_SCRIPT" << 'EOF_HEADER'
#!/bin/bash

# Auto-generated port-forward script

NAMESPACE="openshift-ovn-kubernetes"
PIDS=()

function cleanup() {
    echo ""
    echo "Stopping all port-forwards..."
    for pid in "${PIDS[@]}"; do
        kill -KILL $pid 2>/dev/null
    done
    exit 0
}

trap cleanup INT TERM EXIT

echo "Starting port-forwards..."
echo ""

EOF_HEADER

    # Add control-plane port-forwards
    current_port=$MASTER_PORT_START
    for pod_name in $control_plane_pods; do
        cat >> "$FORWARD_SCRIPT" << EOF
# Control-plane: $pod_name
oc -n \$NAMESPACE port-forward $pod_name $current_port:$CONTROL_PLANE_TARGET_PORT > /dev/null 2>&1 &
PIDS+=(\$!)
echo "✓ $pod_name -> localhost:$current_port"

EOF
        if [[ "$LEGACY_MODE" != "true" ]]; then
            current_port=$((current_port + 1))
        else
            current_port=$((current_port + 1))
        fi
    done

    # Add node port-forwards
    if [[ "$LEGACY_MODE" != "true" ]]; then
        current_port=$NODE_PORT_START
    fi
    for pod_name in $node_pods; do
        cat >> "$FORWARD_SCRIPT" << EOF
# Node: $pod_name
oc -n \$NAMESPACE port-forward $pod_name $current_port:$NODE_TARGET_PORT > /dev/null 2>&1 &
PIDS+=(\$!)
echo "✓ $pod_name -> localhost:$current_port"

EOF
        current_port=$((current_port + 1))
    done

    cat >> "$FORWARD_SCRIPT" << 'EOF_FOOTER'

echo ""
echo "All port-forwards started!"
echo "Press Ctrl+C to stop all port-forwards"
echo ""

# Keep checking connections
sleep 5
while true; do
    alive=0
    dead=0

    for pid in "${PIDS[@]}"; do
        if kill -0 $pid 2>/dev/null; then
            ((alive++))
        else
            ((dead++))
        fi
    done

    echo "[$(date +'%H:%M:%S')] Port-forwards alive: $alive, dead: $dead"

    if [[ $dead -gt 0 ]]; then
        echo "WARNING: Some port-forwards have died!"
        echo "Restart the script to re-establish connections."
    fi

    sleep 60
done

wait "${PIDS[@]}"
EOF_FOOTER

    echo "✓ Generated $FORWARD_SCRIPT"
    echo ""

    echo "=========================================="
    echo "Next Steps"
    echo "=========================================="
    echo ""
    echo "1. Start port-forwards:"
    echo "   $0 start"
    echo ""
    echo "2. Or run in screen/tmux:"
    echo "   screen -S port-forwards"
    echo "   ./$FORWARD_SCRIPT"
    echo "   # Press Ctrl+A, D to detach"
    echo ""
    echo "3. Test connectivity:"
    echo "   curl http://localhost:$MASTER_PORT_START/debug/pprof/"
    echo ""
    echo "4. Start collection:"
    echo "   ./orchestrate-menu.sh"
    echo ""
}

start_forwards() {
    echo "=========================================="
    echo "Starting Port-Forwards"
    echo "=========================================="
    echo ""

    if [[ ! -f "$FORWARD_SCRIPT" ]]; then
        echo "Error: $FORWARD_SCRIPT not found"
        echo "Run: $0 setup"
        exit 1
    fi

    # Check if already running
    if pgrep -f "port-forward.*ovnkube" > /dev/null; then
        echo "⚠️  Port-forwards already running"
        echo ""
        read -p "Stop and restart? [y/N]: " restart
        if [[ "$restart" =~ ^[Yy]$ ]]; then
            stop_forwards
            echo ""
        else
            exit 0
        fi
    fi

    echo "Starting port-forwards in background..."
    nohup $FORWARD_SCRIPT > /tmp/port-forwards.log 2>&1 &
    PORTFORWARD_PID=$!
    echo $PORTFORWARD_PID > /tmp/port-forwards.pid
    echo ""
    echo "✓ Port-forwards started (PID: $PORTFORWARD_PID)"
    echo "  Log: /tmp/port-forwards.log"
    echo "  PID file: /tmp/port-forwards.pid"
    echo ""

    sleep 5

    echo "Testing connectivity..."
    if curl -s -f --max-time 3 "http://localhost:$MASTER_PORT_START/debug/pprof/" > /dev/null 2>&1; then
        echo "✓ Control-plane port-forward working!"
    else
        echo "⚠️  Control-plane port-forward test failed"
    fi

    if curl -s -f --max-time 3 "http://localhost:$NODE_PORT_START/debug/pprof/" > /dev/null 2>&1; then
        echo "✓ Node port-forward working!"
    else
        echo "⚠️  Node port-forward test failed"
    fi

    echo ""
    echo "Ready to collect! Run: ./orchestrate-menu.sh"
    echo ""
}

stop_forwards() {
    echo "=========================================="
    echo "Stopping Port-Forwards"
    echo "=========================================="
    echo ""

    if [[ -f "/tmp/port-forwards.pid" ]]; then
        pid=$(cat /tmp/port-forwards.pid)
        if kill -0 $pid 2>/dev/null; then
            echo "Stopping port-forwards (PID: $pid)..."
            kill $pid 2>/dev/null
            rm /tmp/port-forwards.pid
        fi
    fi

    # Kill all port-forward processes
    echo "Killing all ovnkube port-forwards..."
    pkill -f "port-forward.*ovnkube"

    sleep 2

    if pgrep -f "port-forward.*ovnkube" > /dev/null; then
        echo "⚠️  Some port-forwards still running, force killing..."
        pkill -9 -f "port-forward.*ovnkube"
    fi

    echo "✓ Port-forwards stopped"
    echo ""
}

check_status() {
    echo "=========================================="
    echo "Port-Forward Status"
    echo "=========================================="
    echo ""

    if [[ ! -f "$OUTPUT_FILE" ]]; then
        echo "Status: Not configured"
        echo "Run: $0 setup"
        echo ""
        exit 0
    fi

    echo "Configuration: ✓ Found $OUTPUT_FILE"
    echo ""

    # Count running port-forwards
    running=$(pgrep -f "port-forward.*ovnkube" | wc -l | tr -d ' ')
    total=$(cat "$OUTPUT_FILE" | wc -l | tr -d ' ')

    echo "Port-forwards: $running/$total running"
    echo ""

    if [[ $running -eq 0 ]]; then
        echo "Status: ⚠️  Not running"
        echo "Start: $0 start"
    elif [[ $running -lt $total ]]; then
        echo "Status: ⚠️  Partially running"
        echo "Restart: $0 stop && $0 start"
    else
        echo "Status: ✓ Running"
    fi
    echo ""

    # Test connectivity
    if [[ $running -gt 0 ]]; then
        echo "Testing connectivity..."
        first_cp_port=$MASTER_PORT_START
        first_node_port=$NODE_PORT_START

        if curl -s -f --max-time 2 "http://localhost:$first_cp_port/debug/pprof/" > /dev/null 2>&1; then
            echo "✓ Control-plane: http://localhost:$first_cp_port/debug/pprof/"
        else
            echo "✗ Control-plane: http://localhost:$first_cp_port/debug/pprof/"
        fi

        if curl -s -f --max-time 2 "http://localhost:$first_node_port/debug/pprof/" > /dev/null 2>&1; then
            echo "✓ Node: http://localhost:$first_node_port/debug/pprof/"
        else
            echo "✗ Node: http://localhost:$first_node_port/debug/pprof/"
        fi
        echo ""
    fi
}

fix_portscheme() {
    echo "=========================================="
    echo "Port Scheme Diagnostics & Fix"
    echo "=========================================="
    echo ""

    check_cluster

    # Check current configuration
    if [[ -f "$OUTPUT_FILE" ]]; then
        echo "Current Configuration:"
        echo "---------------------"
        cp_count=$(grep -c "ovnkube-control-plane\|ovnkube-master" "$OUTPUT_FILE" 2>/dev/null || echo 0)
        node_count=$(grep -c "ovnkube-node" "$OUTPUT_FILE" 2>/dev/null || echo 0)

        first_cp_line=$(grep "ovnkube-control-plane\|ovnkube-master" "$OUTPUT_FILE" 2>/dev/null | head -1)
        first_node_line=$(grep "ovnkube-node" "$OUTPUT_FILE" 2>/dev/null | head -1)

        first_cp_port=$(echo "$first_cp_line" | awk '{print $2}')
        first_node_port=$(echo "$first_node_line" | awk '{print $2}')

        echo "  Control-plane pods: $cp_count"
        echo "  Node pods: $node_count"
        echo "  Control-plane port: $first_cp_port"
        echo "  Node port: $first_node_port"
        echo ""

        # Diagnose port scheme
        if [[ $first_cp_port -ge 8100 ]] && [[ $first_cp_port -lt 8200 ]] && \
           [[ $first_node_port -ge 8200 ]] && [[ $first_node_port -lt 8300 ]]; then
            echo "Port scheme: ✓ Correct (8100+ CP, 8200+ nodes)"
            echo ""
            echo "Your configuration looks good!"
            exit 0
        elif [[ $first_cp_port -ge 20000 ]]; then
            echo "Port scheme: Legacy (20000+)"
            echo ""
            echo "You're using the legacy port scheme."
            echo "Recommendation: Migrate to standard scheme (8100+/8200+)"
            echo ""
            read -p "Regenerate with standard scheme? [y/N]: " regen
            if [[ "$regen" =~ ^[Yy]$ ]]; then
                LEGACY_MODE=false
                setup_portmap
                exit 0
            fi
        else
            echo "Port scheme: ⚠️  Unknown"
            echo ""
            echo "Recommendation: Regenerate configuration"
            echo ""
            read -p "Regenerate configuration? [y/N]: " regen
            if [[ "$regen" =~ ^[Yy]$ ]]; then
                setup_portmap
                exit 0
            fi
        fi
    else
        echo "No configuration found."
        echo ""
        echo "Run: $0 setup"
    fi
    echo ""
}

# Main logic
case $ACTION in
    setup)
        setup_portmap
        ;;
    start)
        start_forwards
        ;;
    stop)
        stop_forwards
        ;;
    status)
        check_status
        ;;
    fix)
        fix_portscheme
        ;;
    -h|--help|help)
        show_usage
        ;;
    *)
        echo "Error: Unknown action '$ACTION'"
        echo ""
        show_usage
        ;;
esac
