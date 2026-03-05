#!/bin/bash

# Test script to verify pprof collection setup
# This does a quick test run without actually collecting data

echo "=========================================="
echo "Pprof Collection Test Script"
echo "=========================================="
echo ""

NAMESPACE="openshift-ovn-kubernetes"
errors=0

# Check 1: oc command
echo "1. Checking oc command..."
if command -v oc &> /dev/null; then
    echo "   ✓ oc command found"
else
    echo "   ✗ oc command not found"
    echo "     Install OpenShift CLI first"
    errors=$((errors + 1))
fi
echo ""

# Check 2: Cluster connectivity
echo "2. Checking cluster connectivity..."
if oc whoami &> /dev/null; then
    echo "   ✓ Connected to cluster: $(oc whoami --show-server)"
    echo "   ✓ User: $(oc whoami)"
else
    echo "   ✗ Not connected to cluster"
    echo "     Run: oc login <cluster-url>"
    errors=$((errors + 1))
fi
echo ""

# Check 3: Namespace and pods
echo "3. Checking OVN pods..."
cp_count=$(oc -n "$NAMESPACE" get pods 2>/dev/null | grep -c ovnkube-control-plane || echo 0)
node_count=$(oc -n "$NAMESPACE" get pods 2>/dev/null | grep -c "ovnkube-node" || echo 0)

if [[ $cp_count -gt 0 ]]; then
    echo "   ✓ Found $cp_count control-plane pod(s)"
else
    echo "   ⚠ No control-plane pods found"
fi

if [[ $node_count -gt 0 ]]; then
    echo "   ✓ Found $node_count node pod(s)"
else
    echo "   ⚠ No node pods found"
fi

if [[ $cp_count -eq 0 ]] && [[ $node_count -eq 0 ]]; then
    echo "   ✗ No OVN pods found in namespace $NAMESPACE"
    errors=$((errors + 1))
fi
echo ""

# Check 4: Required scripts
echo "4. Checking required scripts..."
required_scripts=(
    "setup-generate-portmap.sh"
    "setup-start-forwards.sh"
    "collect-periodic-all.sh"
    "collect-targeted-controlplane.sh"
    "collect-targeted-nodes.sh"
    "collect-continuous-threshold-complete.sh"
    "orchestrate-menu.sh"
)

missing_scripts=0
for script in "${required_scripts[@]}"; do
    if [[ -f "$script" ]]; then
        echo "   ✓ $script"
    else
        echo "   ✗ $script missing"
        missing_scripts=$((missing_scripts + 1))
    fi
done

if [[ $missing_scripts -gt 0 ]]; then
    errors=$((errors + 1))
fi
echo ""

# Check 5: Port-forward setup
echo "5. Checking port-forward setup..."
if [[ -f "pod-port-map.lst" ]]; then
    entries=$(wc -l < pod-port-map.lst | tr -d ' ')
    echo "   ✓ pod-port-map.lst exists with $entries entries"

    # Show sample entries
    echo ""
    echo "   Sample mappings:"
    head -3 pod-port-map.lst | while read -r line; do
        echo "     $line"
    done
else
    echo "   ⚠ pod-port-map.lst not found"
    echo "     Run: ./setup-generate-portmap.sh"
fi
echo ""

# Check 6: Active port-forwards
echo "6. Checking active port-forwards..."
pf_count=$(pgrep -f "port-forward.*ovnkube" | wc -l | tr -d ' ')
if [[ $pf_count -gt 0 ]]; then
    echo "   ✓ $pf_count port-forward process(es) running"

    # Test connectivity if mapping exists
    if [[ -f "pod-port-map.lst" ]]; then
        first_cp_port=$(grep "ovnkube-control-plane\|ovnkube-master" pod-port-map.lst 2>/dev/null | head -1 | awk '{print $2}')
        if [[ -n "$first_cp_port" ]]; then
            echo ""
            echo "   Testing control-plane connectivity on port $first_cp_port..."
            if curl -s -f --max-time 3 "http://localhost:$first_cp_port/debug/pprof/" > /dev/null 2>&1; then
                echo "   ✓ Control-plane port-forward working!"
            else
                echo "   ✗ Control-plane port-forward test failed"
                echo "     Port may still be initializing, or there's a connectivity issue"
            fi
        fi

        first_node_port=$(grep "ovnkube-node" pod-port-map.lst 2>/dev/null | head -1 | awk '{print $2}')
        if [[ -n "$first_node_port" ]]; then
            echo ""
            echo "   Testing node connectivity on port $first_node_port..."
            if curl -s -f --max-time 3 "http://localhost:$first_node_port/debug/pprof/" > /dev/null 2>&1; then
                echo "   ✓ Node port-forward working!"
            else
                echo "   ✗ Node port-forward test failed"
                echo "     Port may still be initializing, or there's a connectivity issue"
            fi
        fi
    fi
else
    echo "   ⚠ No active port-forwards detected"
    echo "     Run: ./setup-start-forwards.sh &"
fi
echo ""

# Check 7: Output directories
echo "7. Checking output directories..."
for dir in pprof-data pprof-data-control-plane pprof-data-node; do
    if [[ -d "$dir" ]]; then
        file_count=$(ls -1 "$dir" 2>/dev/null | wc -l | tr -d ' ')
        echo "   ✓ $dir/ exists ($file_count files)"
    else
        echo "   ⚠ $dir/ not created yet (will be created on first collection)"
    fi
done
echo ""

# Summary
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo ""

if [[ $errors -eq 0 ]]; then
    echo "✓ All critical checks passed!"
    echo ""
    echo "Ready to collect pprof data!"
    echo ""
    echo "Quick start options:"
    echo ""
    echo "1. Interactive mode:"
    echo "   ./orchestrate-menu.sh"
    echo ""
    echo "2. Periodic collection (every 5 min):"
    echo "   ./collect-periodic-all.sh"
    echo ""
    echo "3. Threshold-based collection:"
    echo "   CPU_THRESHOLD=50m ./collect-continuous-threshold-complete.sh"
    echo ""
    echo "4. One-time snapshots:"
    echo "   ./collect-targeted-controlplane.sh"
    echo "   ./collect-targeted-nodes.sh"
else
    echo "⚠ Found $errors critical issue(s)"
    echo ""
    echo "Please resolve the issues above before collecting."
    echo ""
    echo "Setup help:"
    echo "  1. Login to cluster: oc login <cluster-url>"
    echo "  2. Generate mappings: ./setup-generate-portmap.sh"
    echo "  3. Start port-forwards: ./setup-start-forwards.sh &"
    echo "  4. Wait 10 seconds and re-run this test"
fi
echo ""
