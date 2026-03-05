#!/bin/bash

# Diagnostic script to check why control-plane pods aren't being collected

NAMESPACE="openshift-ovn-kubernetes"
POD_PORT_MAP="pod-port-map.lst"
CPU_THRESHOLD=${CPU_THRESHOLD:-50}

echo "=========================================="
echo "Collection Diagnostic Tool"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Namespace: $NAMESPACE"
echo "  CPU Threshold: $CPU_THRESHOLD"
echo "  Pod-Port Map: $POD_PORT_MAP"
echo ""

# Function to convert CPU to millicores
cpu_to_millicores() {
    local cpu=$1
    if [[ $cpu =~ ([0-9]+)m$ ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ $cpu =~ ^[0-9]+$ ]]; then
        echo $((cpu * 1000))
    elif [[ $cpu =~ ([0-9.]+)$ ]]; then
        echo "$(awk "BEGIN {print int(${BASH_REMATCH[1]} * 1000)}")"
    else
        echo "0"
    fi
}

# Check 1: Cluster connectivity
echo "Check 1: Cluster Connectivity"
echo "------------------------------"
if ! oc whoami &> /dev/null; then
    echo "❌ ERROR: Not logged into OpenShift cluster"
    echo "   Run: oc login <cluster-url>"
    exit 1
fi
echo "✓ Logged in as: $(oc whoami)"
echo "✓ Cluster: $(oc whoami --show-server)"
echo ""

# Check 2: Pod existence
echo "Check 2: Pod Existence"
echo "----------------------"
echo "Looking for OVN pods in namespace: $NAMESPACE"
echo ""

all_pods=$(oc -n "$NAMESPACE" get pods --no-headers 2>/dev/null | \
           grep -E 'ovnkube-control-plane|ovnkube-node' | \
           awk '{print $1}')

if [[ -z "$all_pods" ]]; then
    echo "❌ ERROR: No OVN pods found"
    echo ""
    echo "Available namespaces:"
    oc get namespaces | grep ovn
    exit 1
fi

control_plane_pods=$(echo "$all_pods" | grep ovnkube-control-plane || true)
node_pods=$(echo "$all_pods" | grep ovnkube-node || true)

control_plane_count=$(echo "$control_plane_pods" | grep -c . || echo 0)
node_count=$(echo "$node_pods" | grep -c . || echo 0)

echo "Found pods:"
echo "  Control-plane pods: $control_plane_count"
echo "  Node pods: $node_count"
echo ""

if [[ $control_plane_count -eq 0 ]]; then
    echo "❌ WARNING: No control-plane pods found!"
    echo ""
    echo "All OVN pods:"
    oc -n "$NAMESPACE" get pods | grep ovnkube
    echo ""
fi

# Check 3: Pod-Port Map
echo "Check 3: Pod-Port Map File"
echo "--------------------------"
if [[ ! -f "$POD_PORT_MAP" ]]; then
    echo "❌ ERROR: $POD_PORT_MAP not found"
    echo ""
    echo "Run: ./setup-generate-portmap-legacy.sh"
    exit 1
fi

echo "✓ Found $POD_PORT_MAP"
echo ""
echo "Entries in pod-port-map:"
control_plane_in_map=$(grep "ovnkube-control-plane" "$POD_PORT_MAP" | wc -l | tr -d ' ')
node_in_map=$(grep "ovnkube-node" "$POD_PORT_MAP" | wc -l | tr -d ' ')

echo "  Control-plane entries: $control_plane_in_map"
echo "  Node entries: $node_in_map"
echo ""

if [[ $control_plane_in_map -eq 0 ]]; then
    echo "❌ ERROR: No control-plane pods in pod-port-map.lst!"
    echo ""
    echo "Current map contents:"
    cat "$POD_PORT_MAP"
    echo ""
    echo "SOLUTION: Regenerate the pod-port map:"
    echo "  ./setup-generate-portmap-legacy.sh"
    echo ""
fi

# Check 4: CPU levels
echo "Check 4: Current CPU Levels"
echo "---------------------------"
echo "Checking CPU usage for all OVN pods..."
echo ""

threshold_millicores=$(cpu_to_millicores "$CPU_THRESHOLD")

printf "%-50s %-15s %-10s %-10s\n" "POD NAME" "CPU" "Millicores" "Collect?"
printf "%-50s %-15s %-10s %-10s\n" "--------" "---" "----------" "--------"

for pod_name in $all_pods; do
    pod_metrics=$(oc -n "$NAMESPACE" adm top pod "$pod_name" --no-headers 2>/dev/null)

    if [[ -z "$pod_metrics" ]]; then
        printf "%-50s %-15s %-10s %-10s\n" "$pod_name" "N/A" "N/A" "NO (no metrics)"
        continue
    fi

    cpu_size=$(echo "$pod_metrics" | awk '{print $2}')
    cpu_millicores=$(cpu_to_millicores "$cpu_size")

    # Check if in map
    in_map=$(grep -c "^$pod_name " "$POD_PORT_MAP" || echo 0)

    if [[ $in_map -eq 0 ]]; then
        collect_status="NO (not in map)"
    elif [[ $cpu_millicores -ge $threshold_millicores ]]; then
        collect_status="YES ✓"
    else
        collect_status="NO (CPU < ${CPU_THRESHOLD})"
    fi

    printf "%-50s %-15s %-10s %-10s\n" "$pod_name" "$cpu_size" "${cpu_millicores}m" "$collect_status"
done

echo ""
echo "Threshold: ${CPU_THRESHOLD} (${threshold_millicores}m)"
echo ""

# Check 5: Port forwards
echo "Check 5: Port Forward Status"
echo "----------------------------"
port_forward_count=$(ps aux | grep -c "oc.*port-forward" | grep -v grep || echo 0)

if [[ $port_forward_count -gt 0 ]]; then
    echo "✓ Port-forwards running: $port_forward_count processes"
    echo ""
    echo "Active port-forwards:"
    ps aux | grep "oc.*port-forward" | grep -v grep | awk '{print "  " $11 " " $12 " " $13 " " $14}'
else
    echo "❌ WARNING: No port-forwards detected"
    echo ""
    echo "You may need to start port-forwards:"
    echo "  ./setup-start-forwards.sh"
fi
echo ""

# Check 6: Test port connectivity
echo "Check 6: Port Connectivity Test"
echo "--------------------------------"
echo "Testing connectivity to mapped ports..."
echo ""

test_count=0
success_count=0

while IFS=' ' read -r pod_name local_port; do
    if [[ $pod_name =~ ovnkube-control-plane ]]; then
        test_count=$((test_count + 1))

        if curl -s -f --max-time 2 "http://localhost:$local_port/debug/pprof/" > /dev/null 2>&1; then
            echo "✓ $pod_name (localhost:$local_port) - OK"
            success_count=$((success_count + 1))
        else
            echo "❌ $pod_name (localhost:$local_port) - FAILED"
        fi

        # Only test first 3 control-plane pods
        if [[ $test_count -ge 3 ]]; then
            break
        fi
    fi
done < "$POD_PORT_MAP"

echo ""
if [[ $test_count -eq 0 ]]; then
    echo "⚠️  No control-plane pods to test"
elif [[ $success_count -eq 0 ]]; then
    echo "❌ ERROR: All port connectivity tests failed"
    echo ""
    echo "Possible issues:"
    echo "  1. Port-forwards not running"
    echo "  2. Port-forwards on wrong ports"
    echo "  3. Pods not exposing pprof endpoints"
    echo ""
    echo "Start port-forwards:"
    echo "  ./setup-start-forwards.sh"
elif [[ $success_count -lt $test_count ]]; then
    echo "⚠️  Some port tests failed ($success_count/$test_count succeeded)"
else
    echo "✓ All port tests passed ($success_count/$test_count)"
fi
echo ""

# Summary
echo "=========================================="
echo "Summary"
echo "=========================================="
echo ""

issues_found=0

if [[ $control_plane_count -eq 0 ]]; then
    echo "❌ ISSUE: No control-plane pods found in cluster"
    issues_found=$((issues_found + 1))
fi

if [[ $control_plane_in_map -eq 0 ]]; then
    echo "❌ ISSUE: No control-plane pods in pod-port-map.lst"
    echo "   SOLUTION: Run ./setup-generate-portmap-legacy.sh"
    issues_found=$((issues_found + 1))
fi

if [[ $port_forward_count -eq 0 ]]; then
    echo "⚠️  WARNING: No port-forwards running"
    echo "   SOLUTION: Run ./setup-start-forwards.sh"
    issues_found=$((issues_found + 1))
fi

if [[ $success_count -eq 0 ]] && [[ $test_count -gt 0 ]]; then
    echo "❌ ISSUE: Port connectivity tests failed"
    echo "   SOLUTION: Check port-forwards and pod status"
    issues_found=$((issues_found + 1))
fi

echo ""
if [[ $issues_found -eq 0 ]]; then
    echo "✓ All checks passed!"
    echo ""
    echo "The script should collect from both control-plane and node pods."
    echo "If it's still only collecting from node pods, check:"
    echo "  1. Control-plane pod CPU levels (must exceed threshold)"
    echo "  2. Review collection logs for specific errors"
else
    echo "Found $issues_found issue(s) that may prevent collection."
    echo "Fix the issues above and try again."
fi
echo ""
