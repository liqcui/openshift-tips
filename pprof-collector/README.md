# OVN Kubernetes Pprof Collector

Automated toolkit for collecting pprof profiling data from OpenShift OVN Kubernetes pods (both control-plane and nodes).

## Quick Start

```bash
# Interactive menu (recommended)
./orchestrate-menu.sh
```

## Collection Modes

The toolkit supports 4 collection scenarios, all collecting from **both control-plane and node pods periodically**:

### 1. CPU Threshold-based Collection
When ANY **node** exceeds CPU threshold, collects from 2 control-plane + OVN pod on highest-CPU node.

```bash
# Via menu
./orchestrate-menu.sh  # Choose option 1

# Direct execution - Percentage (recommended)
METRIC_TYPE=cpu CPU_THRESHOLD=80% INTERVAL=60 DURATION=30 ./collect-threshold-metric.sh

# Direct execution - Millicores
METRIC_TYPE=cpu CPU_THRESHOLD=3000m INTERVAL=60 DURATION=30 ./collect-threshold-metric.sh
```

**Use case:** Capture data when nodes are under high CPU load.

**How it works:**
- Monitors **NODE-level** CPU usage (via `oc adm top node`)
- When ANY node exceeds threshold → triggers collection
- Collects from: ALL control-plane (2) + OVN pod on node with highest CPU

**Configuration:**
- `METRIC_TYPE=cpu` - Monitor CPU metric (node-level)
- `CPU_THRESHOLD=80%` - Percentage of node capacity (e.g., 80%, 100%, 110%)
  - OR `CPU_THRESHOLD=3000m` - Absolute millicores (e.g., 2000m, 3000m, 4000m)
- `INTERVAL=60` - Check interval in seconds (default: 60s)
- `DURATION=30` - Profile duration in seconds (default: 30s)

**Threshold Formats:**
- **Percentage**: `80%`, `100%`, `110%` - Percentage of node CPU capacity (recommended)
- **Millicores**: `2000m`, `3000m`, `4000m` - Absolute CPU cores

### 2. RAM Threshold-based Collection
When ANY **node** exceeds RAM threshold, collects from 2 control-plane + OVN pod on highest-RAM node.

```bash
# Via menu
./orchestrate-menu.sh  # Choose option 2

# Direct execution - Percentage (recommended)
METRIC_TYPE=ram RAM_THRESHOLD=80% INTERVAL=60 DURATION=30 ./collect-threshold-metric.sh

# Direct execution - Mi
METRIC_TYPE=ram RAM_THRESHOLD=10000 INTERVAL=60 DURATION=30 ./collect-threshold-metric.sh
```

**Use case:** Capture data when nodes are under memory pressure.

**How it works:**
- Monitors **NODE-level** RAM usage (via `oc adm top node`)
- When ANY node exceeds threshold → triggers collection
- Collects from: ALL control-plane (2) + OVN pod on node with highest RAM

**Configuration:**
- `METRIC_TYPE=ram` - Monitor RAM metric (node-level)
- `RAM_THRESHOLD=80%` - Percentage of node memory (e.g., 60%, 80%, 90%)
  - OR `RAM_THRESHOLD=10000` - Absolute Mi (e.g., 8000, 10000, 12000)
- `INTERVAL=60` - Check interval in seconds (default: 60s)
- `DURATION=30` - Profile duration in seconds (default: 30s)

**Threshold Formats:**
- **Percentage**: `60%`, `80%`, `90%` - Percentage of node memory capacity (recommended)
- **Mi**: `8000`, `10000`, `12000` - Absolute memory in Mi

### 3. Top CPU Pods Optimized (⭐ RECOMMENDED)
Periodically collects from ALL control-plane + TOP 1 worker node by CPU usage.

```bash
# Via menu
./orchestrate-menu.sh  # Choose option 3

# Direct execution
METRIC_TYPE=cpu TOP_N_NODES=1 DURATION=30 INTERVAL=35 ./collect-top-metric.sh
```

**Use case:** Maximum time coverage with minimal gaps, focusing on most CPU-intensive pods.

**Configuration:**
- `METRIC_TYPE=cpu` - Sort nodes by CPU
- `TOP_N_NODES=1` - Collect from top 1 node (default)
- `DURATION=30` - Profile duration (default: 30s)
- `INTERVAL=35` - Collection interval (default: 35s = ~85% coverage, 5s gap)

**Coverage:** ~85% time coverage (30s collection / 35s interval)

**Pod Selection Logic:**
- Always collects from ALL control-plane pods (by default)
- Selects TOP 1 worker node by highest CPU usage
- If multiple worker nodes have identical CPU usage, selects the first one
- Ensures consistent, predictable collection behavior

### 4. Top RAM Pods Optimized
Periodically collects from ALL control-plane + TOP 1 worker node by RAM usage.

```bash
# Via menu
./orchestrate-menu.sh  # Choose option 4

# Direct execution
METRIC_TYPE=ram TOP_N_NODES=1 DURATION=30 INTERVAL=35 ./collect-top-metric.sh
```

**Use case:** Maximum time coverage with minimal gaps, focusing on most memory-intensive pods.

**Configuration:**
- `METRIC_TYPE=ram` - Sort nodes by RAM
- `TOP_N_NODES=1` - Collect from top 1 node (default)
- `DURATION=30` - Profile duration (default: 30s)
- `INTERVAL=35` - Collection interval (default: 35s = ~85% coverage, 5s gap)

**Coverage:** ~85% time coverage (30s collection / 35s interval)

## Setup

### Prerequisites
- `kubectl` or `oc` CLI installed and configured
- Access to OpenShift cluster with OVN Kubernetes
- `curl` for fetching pprof endpoints
- `go tool pprof` for analysis (optional)

### Initial Setup

The setup happens automatically when you run `orchestrate-menu.sh`, but you can also run manually:

```bash
# All-in-one setup script
./setup-portforward.sh setup   # Generate mappings
./setup-portforward.sh start   # Start port-forwards
./setup-portforward.sh status  # Check status
```

## Collected Profiles

Each collection captures 6 profile types:

1. **profile** - CPU profile (where CPU time is spent)
2. **heap** - Memory heap allocation profile
3. **allocs** - Memory allocation profile (all allocations since start)
4. **goroutine** - Goroutine stack traces
5. **mutex** - Mutex contention profile
6. **block** - Blocking operations profile

## Output

Profiles are saved in separate directories:

```
pprof-data-control-plane/
├── ovnkube-control-plane-xxx-CPU1m-RAM74Mi-29108-20260305_120000.profile
├── ovnkube-control-plane-xxx-CPU1m-RAM74Mi-29108-20260305_120000.heap
└── ...

pprof-data-node/
├── ovnkube-node-xxx-CPU160m-RAM2989Mi-29103-20260305_120000.profile
├── ovnkube-node-xxx-CPU160m-RAM2989Mi-29103-20260305_120000.heap
└── ...
```

**Filename format:** `{pod-name}-CPU{cpu}-RAM{ram}-{port}-{timestamp}.{type}`

## Monitoring Cluster Metrics

### Check Node Metrics

```bash
# View all nodes (unsorted)
oc adm top node

# Sort by CPU percentage (highest first)
oc adm top node | sort -k3 -nr

# Sort by Memory percentage (highest first)
oc adm top node | sort -k5 -nr

# View top 5 nodes by CPU
oc adm top node | sort -k3 -nr | head -6

# View top 5 nodes by Memory
oc adm top node | sort -k5 -nr | head -6
```

**Important:** Do NOT use `sort -rn` without specifying the column (`-k`), as it will sort by the first field (node name) instead of the metric columns.

### Check Pod Metrics

```bash
# View all OVN pods
oc -n openshift-ovn-kubernetes adm top pod

# Sort by CPU
oc -n openshift-ovn-kubernetes adm top pod | grep ovnkube | sort -k2 -nr

# Sort by Memory
oc -n openshift-ovn-kubernetes adm top pod | grep ovnkube | sort -k3 -nr
```

## Analysis

### Quick Analysis

```bash
# View collected files
ls -lht pprof-data-control-plane/ | head -20
ls -lht pprof-data-node/ | head -20

# Count files by type
echo "CPU profiles: $(ls -1 pprof-data-node/*.profile 2>/dev/null | wc -l)"
echo "Heap profiles: $(ls -1 pprof-data-node/*.heap 2>/dev/null | wc -l)"
```

### Manual Analysis

```bash
# CPU hotspots
go tool pprof -top pprof-data-node/*.profile

# Memory usage
go tool pprof -top pprof-data-node/*.heap

# Interactive web UI (BEST!)
go tool pprof -http=:8080 pprof-data-node/*.profile

# Compare two profiles (show changes)
FIRST=$(ls -1t pprof-data-node/*.profile | tail -1)
LAST=$(ls -1t pprof-data-node/*.profile | head -1)
go tool pprof -base=$FIRST $LAST
```

## Troubleshooting

### Diagnostics

```bash
# Pre-flight check
./util-test-preflight.sh

# Comprehensive diagnostics
./util-diagnose-setup.sh

# Port-forward status and fix
./setup-portforward.sh status
./setup-portforward.sh fix
```

### Common Issues

**No data collected:**
1. Check port-forwards: `./setup-portforward.sh status`
2. Test connectivity: `curl http://localhost:8100/debug/pprof/`
3. Restart forwards: `./setup-portforward.sh stop && ./setup-portforward.sh start`

**Port-forwards died:**
```bash
./setup-portforward.sh stop
./setup-portforward.sh start
```

**Threshold too high (no collections):**
- Lower CPU_THRESHOLD (e.g., 10% instead of 80%)
- Lower RAM_THRESHOLD (e.g., 50% instead of 80%)
- Check current node usage:
  ```bash
  # Sort by CPU percentage (column 3)
  oc adm top node | sort -k3 -nr

  # Sort by Memory percentage (column 5)
  oc adm top node | sort -k5 -nr
  ```
- Check current pod usage: `oc -n openshift-ovn-kubernetes adm top pod`

## Script Organization

### Core Library
- `lib-common.sh` - Shared functions and constants used by all scripts

### Setup Scripts
- `setup-portforward.sh` - Unified port-forward management (setup/start/stop/status/fix)

### Collection Scripts
- `collect-threshold-metric.sh` - Threshold-based collection (CPU or RAM)
- `collect-top-metric.sh` - Top pods optimized collection (CPU or RAM)

### Orchestration Scripts
- `orchestrate-menu.sh` - Interactive menu (main entry point)

### Utility Scripts
- `util-diagnose-setup.sh` - Comprehensive diagnostics
- `util-test-preflight.sh` - Pre-flight validation

## Examples

### Example 1: Capture CPU spikes
```bash
# Collect when CPU > 100m, check every 30s
./orchestrate-menu.sh
# Choose option 1
# Enter threshold: 100
# Enter interval: 30
```

### Example 2: Monitor memory growth
```bash
# Collect when RAM > 2000Mi, check every 60s
./orchestrate-menu.sh
# Choose option 2
# Enter threshold: 2000
# Enter interval: 60
```

### Example 3: Continuous profiling (recommended)
```bash
# Collect every 35s from most active pods
./orchestrate-menu.sh
# Choose option 3 (Top CPU)
# Use defaults (Y)
```

### Example 4: Focus on memory-intensive pods
```bash
# Collect from pods with highest RAM usage
./orchestrate-menu.sh
# Choose option 4 (Top RAM)
# Use defaults (Y)
```

## Storage Estimates

Based on 4 pods (2 control-plane + 2 top nodes):

| Mode | Interval | Files/Hour | Storage/Hour | Storage/Day |
|------|----------|------------|--------------|-------------|
| Top CPU/RAM (default) | 35s | ~3,672 | ~82 MB | ~2 GB |
| Top CPU/RAM (max coverage) | 32s | ~4,050 | ~90 MB | ~2.2 GB |
| Threshold-based | Variable | Variable | Variable | Variable |

**Per cycle:** ~36 files (4 pods × 6 profiles + metadata)

## Stopping Collection

Press `Ctrl+C` to stop any running collection.

To stop background port-forwards:
```bash
./setup-portforward.sh stop
```

## Temporary Files

All temporary files are created in `/tmp/`:
- `/tmp/setup-start-forwards.sh` - Auto-generated port-forward script
- `/tmp/port-forwards.log` - Port-forward runtime logs
- `/tmp/port-forwards.pid` - Process ID tracking

## Additional Resources

- Port-forward scheme: Control-plane uses port 29108, nodes use port 29103
- Local port mapping: 8100+ for control-plane, 8200+ for nodes
- See `pod-port-map.lst` for complete pod-to-port mappings

## Support

For issues or questions:
1. Run diagnostics: `./util-diagnose-setup.sh`
2. Check pod status: `oc -n openshift-ovn-kubernetes get pods`
3. Check port-forwards: `pgrep -f "port-forward" | xargs ps -p`
