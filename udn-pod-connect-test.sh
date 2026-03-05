#!/bin/bash

# Script to check pod connectivity within namespaces
# Tests curl from first client pod to all service IPs and pod IPs

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get all udn-density-pods namespaces
NAMESPACES=$(oc get ns | grep "udn-density-pods-" | awk '{print $1}')

if [ -z "$NAMESPACES" ]; then
    echo -e "${RED}No udn-density-pods namespaces found${NC}"
    exit 1
fi

echo "Found $(echo "$NAMESPACES" | wc -l) namespaces to check"
echo "========================================"

# Iterate through each namespace
for NS in $NAMESPACES; do
    echo -e "\n${YELLOW}Checking namespace: $NS${NC}"
    echo "----------------------------------------"
    
    # Get the first client pod
    CLIENT_POD=$(oc -n $NS get pods | grep "^client-" | head -1 | awk '{print $1}')
    
    if [ -z "$CLIENT_POD" ]; then
        echo -e "${RED}No client pod found in namespace $NS${NC}"
        continue
    fi
    
    echo "Using client pod: $CLIENT_POD"
    
    # Get all service IPs
    echo -e "\n${YELLOW}Testing Service IPs:${NC}"
    SERVICES=$(oc -n $NS get services -o custom-columns=NAME:.metadata.name,IP:.spec.clusterIP --no-headers)
    
    while IFS= read -r line; do
        SVC_NAME=$(echo $line | awk '{print $1}')
        SVC_IP=$(echo $line | awk '{print $2}')
        
        if [ "$SVC_IP" != "None" ] && [ ! -z "$SVC_IP" ]; then
            echo -n "  Testing $SVC_NAME ($SVC_IP:80) ... "
            
            # Curl with 3 second timeout
            if oc -n $NS exec $CLIENT_POD -- curl -s --max-time 3 http://$SVC_IP:80 > /dev/null 2>&1; then
                echo -e "${GREEN}SUCCESS${NC}"
            else
                echo -e "${RED}FAILED${NC}"
            fi
        fi
    done <<< "$SERVICES"
    
    # Get all server pod names only
    echo -e "\n${YELLOW}Testing Server Pod UDN IPs:${NC}"
    SERVER_PODS=$(oc -n $NS get pods --no-headers | grep "^server-" | awk '{print $1}')
    
    for POD_NAME in $SERVER_PODS; do
        # Extract UDN IP from ovn-udn1 interface
        UDN_IP=$(oc -n $NS get pod $POD_NAME -o json | jq -r '.metadata.annotations."k8s.v1.cni.cncf.io/network-status"' | jq -r '.[] | select(.interface=="ovn-udn1") | .ips[0]' 2>/dev/null)
        
        if [ ! -z "$UDN_IP" ] && [ "$UDN_IP" != "null" ]; then
            echo -n "  Testing $POD_NAME (UDN IP: $UDN_IP:8080) ... "
            
            # Curl with 3 second timeout
            if oc -n $NS exec $CLIENT_POD -- curl -s --max-time 3 http://$UDN_IP:8080 > /dev/null 2>&1; then
                echo -e "${GREEN}SUCCESS${NC}"
            else
                echo -e "${RED}FAILED${NC}"
            fi
        else
            echo -e "  ${YELLOW}Skipping $POD_NAME - No UDN IP found${NC}"
        fi
    done
    
    echo "----------------------------------------"
done

echo -e "\n${GREEN}Connectivity check completed for all namespaces${NC}"