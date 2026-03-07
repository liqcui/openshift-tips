#!/bin/bash

# Ultimate simple wrapper - just run this!
# Automatically selects the best approach

echo "=========================================="
echo "OVN Kubernetes Pprof Collection"
echo "=========================================="
echo ""
echo "Collection Modes:"
echo "  1. Threshold-based CPU (2 CP + node when NODE CPU > threshold)"
echo "  2. Threshold-based RAM (2 CP + node when NODE RAM > threshold)"
echo "  3. Top CPU pods optimized (2 CP + top 1 node periodically) ⭐ RECOMMENDED"
echo "  4. Top RAM pods optimized (2 CP + top 1 node periodically)"
echo ""
echo "Modes 1-2 monitor NODE metrics; Modes 3-4 collect periodically."
echo ""
read -p "Select mode [1-4]: " mode

# Setup port forwards for all modes
setup_port_forwards() {
    # Always regenerate pod-port mapping to ensure fresh pod information
    echo "Regenerating pod-port mapping..."
    ./setup-portforward.sh setup || exit 1
    echo ""

    # Stop existing port-forwards before starting new ones
    if pgrep -f "port-forward.*ovnkube" > /dev/null; then
        echo "Stopping existing port-forwards..."
        ./setup-portforward.sh stop
        echo ""
    fi

    echo "Starting port-forwards..."
    ./setup-portforward.sh start || exit 1
    echo ""
}

case $mode in
    1)
        echo ""
        echo "Starting NODE CPU threshold-based collection..."
        echo ""
        echo "CPU Threshold Options (NODE-level):"
        echo "  - Percentage: e.g., 80%, 100%, 110% (of node CPU capacity)"
        echo "  - Millicores: e.g., 2000m, 3000m, 4000m (absolute CPU cores)"
        echo ""
        read -p "CPU threshold [default: 80%]: " cpu_threshold
        CPU_THRESHOLD=${cpu_threshold:-80%}

        # Add 'm' suffix if user entered plain number (without %)
        if [[ $CPU_THRESHOLD =~ ^[0-9]+$ ]]; then
            CPU_THRESHOLD="${CPU_THRESHOLD}m"
        fi

        read -p "Check interval in seconds [default: 60]: " interval
        INTERVAL=${interval:-60}

        read -p "Profile duration in seconds [default: 30]: " duration
        DURATION=${duration:-30}

        setup_port_forwards

        echo ""
        echo "Starting CPU threshold collection..."
        echo "  CPU Threshold: ${CPU_THRESHOLD}"
        echo "  Check Interval: ${INTERVAL}s"
        echo "  Profile Duration: ${DURATION}s"
        echo ""

        METRIC_TYPE=cpu CPU_THRESHOLD=${CPU_THRESHOLD%m} INTERVAL=$INTERVAL DURATION=$DURATION ./collect-threshold-metric.sh
        ;;

    2)
        echo ""
        echo "Starting NODE RAM threshold-based collection..."
        echo ""
        echo "RAM Threshold Options (NODE-level):"
        echo "  - Percentage: e.g., 60%, 80%, 90% (of node memory capacity)"
        echo "  - Mi: e.g., 8000, 10000, 12000 (absolute memory in Mi)"
        echo ""
        read -p "RAM threshold [default: 80%]: " ram_threshold
        RAM_THRESHOLD=${ram_threshold:-80%}

        read -p "Check interval in seconds [default: 60]: " interval
        INTERVAL=${interval:-60}

        read -p "Profile duration in seconds [default: 30]: " duration
        DURATION=${duration:-30}

        setup_port_forwards

        echo ""
        echo "Starting RAM threshold collection..."
        echo "  RAM Threshold: ${RAM_THRESHOLD}Mi"
        echo "  Check Interval: ${INTERVAL}s"
        echo "  Profile Duration: ${DURATION}s"
        echo ""

        METRIC_TYPE=ram RAM_THRESHOLD=$RAM_THRESHOLD INTERVAL=$INTERVAL DURATION=$DURATION ./collect-threshold-metric.sh
        ;;

    3)
        echo ""
        echo "Starting top CPU pods optimized collection..."
        echo ""
        echo "This mode collects from:"
        echo "  - ALL control-plane pods (typically 2)"
        echo "  - TOP 1 node pod by CPU usage"
        echo "  - Optimized for ~85% time coverage with minimal gaps"
        echo ""
        echo "Configuration (optimized defaults):"
        echo "  Profile Duration: 30s"
        echo "  Collection Interval: 35s (5s gap = ~85% coverage)"
        echo "  Top N Nodes: 1"
        echo "  Metric: CPU"
        echo ""
        read -p "Use these defaults? [Y/n]: " use_defaults

        setup_port_forwards

        if [[ "$use_defaults" =~ ^[Nn]$ ]]; then
            read -p "Profile duration in seconds [30]: " duration
            DURATION=${duration:-30}

            read -p "Collection interval in seconds [35]: " interval
            INTERVAL=${interval:-35}

            read -p "Number of top nodes to collect [1]: " topn
            TOP_N_NODES=${topn:-1}

            echo ""
            METRIC_TYPE=cpu DURATION=$DURATION INTERVAL=$INTERVAL TOP_N_NODES=$TOP_N_NODES ./collect-top-metric.sh
        else
            echo ""
            METRIC_TYPE=cpu TOP_N_NODES=1 ./collect-top-metric.sh
        fi
        ;;

    4)
        echo ""
        echo "Starting top RAM pods optimized collection..."
        echo ""
        echo "This mode collects from:"
        echo "  - ALL control-plane pods (typically 2)"
        echo "  - TOP 1 node pod by RAM usage"
        echo "  - Optimized for ~85% time coverage with minimal gaps"
        echo ""
        echo "Configuration (optimized defaults):"
        echo "  Profile Duration: 30s"
        echo "  Collection Interval: 35s (5s gap = ~85% coverage)"
        echo "  Top N Nodes: 1"
        echo "  Metric: RAM"
        echo ""
        read -p "Use these defaults? [Y/n]: " use_defaults

        setup_port_forwards

        if [[ "$use_defaults" =~ ^[Nn]$ ]]; then
            read -p "Profile duration in seconds [30]: " duration
            DURATION=${duration:-30}

            read -p "Collection interval in seconds [35]: " interval
            INTERVAL=${interval:-35}

            read -p "Number of top nodes to collect [1]: " topn
            TOP_N_NODES=${topn:-1}

            echo ""
            METRIC_TYPE=ram DURATION=$DURATION INTERVAL=$INTERVAL TOP_N_NODES=$TOP_N_NODES ./collect-top-metric.sh
        else
            echo ""
            METRIC_TYPE=ram TOP_N_NODES=1 ./collect-top-metric.sh
        fi
        ;;

    *)
        echo "Invalid selection. Exiting."
        exit 1
        ;;
esac
