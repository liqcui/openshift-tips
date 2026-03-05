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

# Control-plane: ovnkube-control-plane-d48758dd6-887vx
oc -n $NAMESPACE port-forward ovnkube-control-plane-d48758dd6-887vx 8100:29108 > /dev/null 2>&1 &
PIDS+=($!)
echo "✓ ovnkube-control-plane-d48758dd6-887vx -> localhost:8100"

# Control-plane: ovnkube-control-plane-d48758dd6-l2k8r
oc -n $NAMESPACE port-forward ovnkube-control-plane-d48758dd6-l2k8r 8101:29108 > /dev/null 2>&1 &
PIDS+=($!)
echo "✓ ovnkube-control-plane-d48758dd6-l2k8r -> localhost:8101"

# Node: ovnkube-node-cnfdr
oc -n $NAMESPACE port-forward ovnkube-node-cnfdr 8200:29103 > /dev/null 2>&1 &
PIDS+=($!)
echo "✓ ovnkube-node-cnfdr -> localhost:8200"

# Node: ovnkube-node-gdz94
oc -n $NAMESPACE port-forward ovnkube-node-gdz94 8201:29103 > /dev/null 2>&1 &
PIDS+=($!)
echo "✓ ovnkube-node-gdz94 -> localhost:8201"

# Node: ovnkube-node-sfnn6
oc -n $NAMESPACE port-forward ovnkube-node-sfnn6 8202:29103 > /dev/null 2>&1 &
PIDS+=($!)
echo "✓ ovnkube-node-sfnn6 -> localhost:8202"

# Node: ovnkube-node-v4l78
oc -n $NAMESPACE port-forward ovnkube-node-v4l78 8203:29103 > /dev/null 2>&1 &
PIDS+=($!)
echo "✓ ovnkube-node-v4l78 -> localhost:8203"

# Node: ovnkube-node-wzj4f
oc -n $NAMESPACE port-forward ovnkube-node-wzj4f 8204:29103 > /dev/null 2>&1 &
PIDS+=($!)
echo "✓ ovnkube-node-wzj4f -> localhost:8204"


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
