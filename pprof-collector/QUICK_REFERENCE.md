# Quick Reference Guide

## One-Line Start

```bash
./orchestrate-menu.sh
```

## 4 Collection Scenarios

### Scenario 1: CPU Threshold-based
**When:** Collect only when CPU usage exceeds threshold
**Use for:** CPU spikes, performance issues
**Collects from:** All pods (control-plane + nodes) exceeding threshold

```bash
# Default: Collect when CPU > 50m, check every 60s
METRIC_TYPE=cpu ./collect-threshold-metric.sh

# Custom: Collect when CPU > 100m, check every 30s
METRIC_TYPE=cpu CPU_THRESHOLD=100 INTERVAL=30 ./collect-threshold-metric.sh
```

**Environment Variables:**
- `METRIC_TYPE=cpu` (required)
- `CPU_THRESHOLD=50` (millicores, default: 50)
- `INTERVAL=60` (check interval in seconds, default: 60)
- `DURATION=30` (profile duration in seconds, default: 30)

---

### Scenario 2: RAM Threshold-based
**When:** Collect only when RAM usage exceeds threshold
**Use for:** Memory leaks, allocation issues
**Collects from:** All pods (control-plane + nodes) exceeding threshold

```bash
# Default: Collect when RAM > 1000Mi, check every 60s
METRIC_TYPE=ram ./collect-threshold-metric.sh

# Custom: Collect when RAM > 2000Mi, check every 45s
METRIC_TYPE=ram RAM_THRESHOLD=2000 INTERVAL=45 ./collect-threshold-metric.sh
```

**Environment Variables:**
- `METRIC_TYPE=ram` (required)
- `RAM_THRESHOLD=1000` (Mi, default: 1000)
- `INTERVAL=60` (check interval in seconds, default: 60)
- `DURATION=30` (profile duration in seconds, default: 30)

---

### Scenario 3: Top CPU Pods ⭐ RECOMMENDED
**When:** Continuous profiling with maximum time coverage
**Use for:** General monitoring, finding bottlenecks
**Collects from:** ALL control-plane + TOP 1 node by CPU

```bash
# Default: 85% coverage (30s/35s), top 1 node by CPU
METRIC_TYPE=cpu ./collect-top-metric.sh

# Max coverage: 94% coverage (30s/32s)
METRIC_TYPE=cpu INTERVAL=32 ./collect-top-metric.sh

# Top 2 nodes instead of 1
METRIC_TYPE=cpu TOP_N_NODES=2 ./collect-top-metric.sh
```

**Environment Variables:**
- `METRIC_TYPE=cpu` (required)
- `TOP_N_NODES=1` (number of top nodes, default: 1)
- `DURATION=30` (profile duration, default: 30s)
- `INTERVAL=35` (collection interval, default: 35s = 85% coverage)

**Coverage:** 30s/35s = ~85% (5s gap)

---

### Scenario 4: Top RAM Pods
**When:** Continuous profiling focusing on memory-intensive pods
**Use for:** Memory analysis, allocation patterns
**Collects from:** ALL control-plane + TOP 1 node by RAM

```bash
# Default: 85% coverage (30s/35s), top 1 node by RAM
METRIC_TYPE=ram ./collect-top-metric.sh

# Max coverage: 94% coverage (30s/32s)
METRIC_TYPE=ram INTERVAL=32 ./collect-top-metric.sh

# Top 2 nodes instead of 1
METRIC_TYPE=ram TOP_N_NODES=2 ./collect-top-metric.sh
```

**Environment Variables:**
- `METRIC_TYPE=ram` (required)
- `TOP_N_NODES=1` (number of top nodes, default: 1)
- `DURATION=30` (profile duration, default: 30s)
- `INTERVAL=35` (collection interval, default: 35s = 85% coverage)

**Coverage:** 30s/35s = ~85% (5s gap)

---

## Quick Decision Tree

```
Need to capture data?
│
├─ Only during high usage? → Threshold-based (1 or 2)
│  │
│  ├─ CPU spikes? → Scenario 1 (CPU Threshold)
│  └─ Memory pressure? → Scenario 2 (RAM Threshold)
│
└─ Continuous monitoring? → Top pods optimized (3 or 4)
   │
   ├─ CPU analysis? → Scenario 3 (Top CPU) ⭐
   └─ Memory analysis? → Scenario 4 (Top RAM)
```

## Common Patterns

### Pattern 1: Troubleshooting CPU issue
```bash
# Low threshold to catch all activity
METRIC_TYPE=cpu CPU_THRESHOLD=10 INTERVAL=30 ./collect-threshold-metric.sh
```

### Pattern 2: Investigating memory leak
```bash
# Continuous profiling sorted by RAM
METRIC_TYPE=ram TOP_N_NODES=1 ./collect-top-metric.sh
```

### Pattern 3: General health monitoring
```bash
# Recommended: Top CPU pods with default settings
METRIC_TYPE=cpu ./collect-top-metric.sh
```

### Pattern 4: Maximum coverage for incident
```bash
# Minimize gap to 2s
METRIC_TYPE=cpu INTERVAL=32 ./collect-top-metric.sh
```

## Quick Commands

### Setup
```bash
# Unified setup command
./setup-portforward.sh setup    # Generate mappings
./setup-portforward.sh start    # Start port-forwards
./setup-portforward.sh status   # Check status
```

### Analysis
```bash
# Analyze CPU
go tool pprof -http=:8080 pprof-data-node/*.profile

# Analyze memory
go tool pprof -http=:8080 pprof-data-node/*.heap

# Quick summary
ls -lht pprof-data-node/ | head -20
echo "Total profiles: $(ls -1 pprof-data-node/*.profile 2>/dev/null | wc -l)"
```

### Troubleshooting
```bash
# Check port-forward status
./setup-portforward.sh status

# Fix port scheme issues
./setup-portforward.sh fix

# Full diagnostics
./util-diagnose-setup.sh

# Pre-flight check
./util-test-preflight.sh
```

### Monitoring
```bash
# Watch file count
watch -n 5 'ls -1 pprof-data-node/ | wc -l'

# Check current top pods
oc -n openshift-ovn-kubernetes adm top pod | sort -k2 -rn

# Monitor disk usage
watch -n 60 'du -sh pprof-data*'
```

### Cleanup
```bash
# Stop collection
Ctrl+C

# Stop port-forwards
./setup-portforward.sh stop

# Clean old data (keep last 24h)
find pprof-data-* -mtime +1 -delete
```

## Output Locations

```
pprof-data-control-plane/   # Control-plane pod profiles
pprof-data-node/            # Node pod profiles
pod-port-map.lst            # Pod to port mappings
port-forwards.log           # Port-forward logs
```

## Profile Types

Each collection cycle generates 6 files per pod:

1. `.profile` - CPU profile
2. `.heap` - Memory heap
3. `.allocs` - Memory allocations
4. `.goroutine` - Goroutine traces
5. `.mutex` - Mutex contention
6. `.block` - Blocking operations

## Typical Cluster Stats

**Example cluster:** 2 control-plane + 5 nodes

| Scenario | Pods/Cycle | Coverage | Storage/Day |
|----------|------------|----------|-------------|
| 1. CPU Threshold | Variable | Variable | Variable |
| 2. RAM Threshold | Variable | Variable | Variable |
| 3. Top 1 CPU | 3 (2 CP + 1 node) | 85% | ~1.5 GB |
| 4. Top 1 RAM | 3 (2 CP + 1 node) | 85% | ~1.5 GB |

With TOP_N_NODES=2: ~2 GB/day
With TOP_N_NODES=3: ~2.5 GB/day

## Remember

- **Threshold-based:** Event-driven, captures only when threshold exceeded
- **Top pods:** Time-driven, continuous profiling of most active pods
- **All scenarios:** Collect from both control-plane AND nodes
- **All scenarios:** Periodic (recurring collections)
- **Coverage:** Ratio of profiling time to total time (higher = less gaps)
