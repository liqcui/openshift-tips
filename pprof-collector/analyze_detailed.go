package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/google/pprof/profile"
)

type CallPath struct {
	Path  []string
	Count int64
}

type FunctionContext struct {
	Name          string
	Self          int64
	Cumulative    int64
	SelfPct       float64
	CumPct        float64
	CallPaths     map[string]int64 // caller -> count
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: analyze_detailed <pprof_directory>")
		os.Exit(1)
	}

	pprofDir := os.Args[1]

	profileFiles, err := filepath.Glob(filepath.Join(pprofDir, "*.profile"))
	if err != nil {
		fmt.Printf("Error finding profile files: %v\n", err)
		os.Exit(1)
	}

	if len(profileFiles) == 0 {
		fmt.Printf("No .profile files found in %s\n", pprofDir)
		os.Exit(1)
	}

	fmt.Printf("Analyzing %d profile files for application-level bottlenecks...\n\n", len(profileFiles))

	// Aggregate all profiles
	allFuncs := make(map[string]*FunctionContext)
	var totalSamples int64
	var totalFiles int

	for _, profilePath := range profileFiles {
		samples, funcs := analyzeProfileDetailed(profilePath)
		if samples > 0 {
			totalSamples += samples
			totalFiles++

			for name, ctx := range funcs {
				if _, exists := allFuncs[name]; !exists {
					allFuncs[name] = &FunctionContext{
						Name:      name,
						CallPaths: make(map[string]int64),
					}
				}
				allFuncs[name].Self += ctx.Self
				allFuncs[name].Cumulative += ctx.Cumulative
				for caller, count := range ctx.CallPaths {
					allFuncs[name].CallPaths[caller] += count
				}
			}
		}
	}

	// Filter for application functions (non-runtime)
	appFuncs := []*FunctionContext{}
	for name, ctx := range allFuncs {
		if !isRuntimeFunc(name) && ctx.Cumulative > 0 {
			ctx.SelfPct = float64(ctx.Self) / float64(totalSamples) * 100
			ctx.CumPct = float64(ctx.Cumulative) / float64(totalSamples) * 100
			appFuncs = append(appFuncs, ctx)
		}
	}

	sort.Slice(appFuncs, func(i, j int) bool {
		return appFuncs[i].Cumulative > appFuncs[j].Cumulative
	})

	fmt.Printf("Total samples: %d across %d profiles\n\n", totalSamples, totalFiles)
	fmt.Println("=" + strings.Repeat("=", 120))
	fmt.Println("🔥 TOP APPLICATION FUNCTIONS BY CUMULATIVE CPU TIME")
	fmt.Println("=" + strings.Repeat("=", 120))
	fmt.Printf("\n%-90s %10s %10s\n", "Function", "Cumulative", "Cum%")
	fmt.Println(strings.Repeat("-", 120))

	limit := 40
	if len(appFuncs) < limit {
		limit = len(appFuncs)
	}

	for i := 0; i < limit; i++ {
		fn := appFuncs[i]
		funcName := shortenName(fn.Name, 85)
		fmt.Printf("%-90s %10d %9.2f%%\n", funcName, fn.Cumulative, fn.CumPct)
	}

	// Detailed analysis of top functions
	fmt.Println("\n\n" + strings.Repeat("=", 120))
	fmt.Println("🎯 DETAILED ANALYSIS OF TOP 15 HOTTEST FUNCTIONS")
	fmt.Println(strings.Repeat("=", 120))

	detailLimit := 15
	if len(appFuncs) < detailLimit {
		detailLimit = len(appFuncs)
	}

	for i := 0; i < detailLimit; i++ {
		fn := appFuncs[i]
		fmt.Printf("\n%d. %s\n", i+1, fn.Name)
		fmt.Printf("   Cumulative: %d samples (%.2f%%), Self: %d samples (%.2f%%)\n",
			fn.Cumulative, fn.CumPct, fn.Self, fn.SelfPct)

		// Show top callers
		if len(fn.CallPaths) > 0 {
			fmt.Println("   Top callers:")

			type CallerInfo struct {
				Name  string
				Count int64
			}
			callers := []CallerInfo{}
			for caller, count := range fn.CallPaths {
				callers = append(callers, CallerInfo{caller, count})
			}
			sort.Slice(callers, func(i, j int) bool {
				return callers[i].Count > callers[j].Count
			})

			callerLimit := 5
			if len(callers) < callerLimit {
				callerLimit = len(callers)
			}
			for j := 0; j < callerLimit; j++ {
				fmt.Printf("      • %s (%d samples)\n", shortenName(callers[j].Name, 80), callers[j].Count)
			}
		}
	}

	// Category analysis
	fmt.Println("\n\n" + strings.Repeat("=", 120))
	fmt.Println("📊 CATEGORIZED BOTTLENECK ANALYSIS")
	fmt.Println(strings.Repeat("=", 120))

	categories := categorize(appFuncs[:limit])

	for _, cat := range []string{
		"Kubernetes Watch/Informer",
		"Networking/OVN Operations",
		"Reflection/Encoding",
		"Lock/Synchronization",
		"gRPC/Network I/O",
		"Resource Processing",
		"Other",
	} {
		if funcs, exists := categories[cat]; exists && len(funcs) > 0 {
			totalPct := 0.0
			for _, f := range funcs {
				totalPct += f.CumPct
			}
			fmt.Printf("\n%s (Total: %.2f%%):\n", cat, totalPct)
			for _, f := range funcs {
				fmt.Printf("  • %s (%.2f%%)\n", shortenName(f.Name, 90), f.CumPct)
			}
		}
	}

	// Summary recommendations
	fmt.Println("\n\n" + strings.Repeat("=", 120))
	fmt.Println("💡 BOTTLENECK SUMMARY & RECOMMENDATIONS")
	fmt.Println(strings.Repeat("=", 120))

	summarizeBottlenecks(appFuncs[:limit])
}

func analyzeProfileDetailed(profilePath string) (int64, map[string]*FunctionContext) {
	f, err := os.Open(profilePath)
	if err != nil {
		return 0, nil
	}
	defer f.Close()

	p, err := profile.Parse(f)
	if err != nil {
		return 0, nil
	}

	if len(p.Sample) == 0 {
		return 0, nil
	}

	funcStats := make(map[string]*FunctionContext)
	var totalSamples int64

	for _, sample := range p.Sample {
		value := sample.Value[0]
		totalSamples += value

		var prevFunc string
		for i, loc := range sample.Location {
			for _, line := range loc.Line {
				funcName := line.Function.Name
				if funcName == "" {
					continue
				}

				if _, exists := funcStats[funcName]; !exists {
					funcStats[funcName] = &FunctionContext{
						Name:      funcName,
						CallPaths: make(map[string]int64),
					}
				}

				// Self time only for leaf
				if i == 0 {
					funcStats[funcName].Self += value
				}
				// Cumulative for all
				funcStats[funcName].Cumulative += value

				// Track caller
				if i > 0 && prevFunc != "" {
					funcStats[funcName].CallPaths[prevFunc] += value
				}

				prevFunc = funcName
			}
		}
	}

	return totalSamples, funcStats
}

func isRuntimeFunc(name string) bool {
	runtimePrefixes := []string{
		"runtime.",
		"internal/runtime/",
		"internal/poll.",
		"internal/abi.",
		"sync.",
		"aeshashbody",
		"memeqbody",
	}

	for _, prefix := range runtimePrefixes {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}

	// Keep syscall as it's interesting
	if strings.Contains(name, "syscall") && !strings.Contains(name, "Syscall6") {
		return false
	}

	return false
}

func categorize(funcs []*FunctionContext) map[string][]*FunctionContext {
	categories := make(map[string][]*FunctionContext)

	for _, fn := range funcs {
		name := fn.Name
		cat := "Other"

		if strings.Contains(name, "k8s.io/client-go/tools/cache") ||
		   strings.Contains(name, "Informer") ||
		   strings.Contains(name, "ResourceEventHandler") ||
		   strings.Contains(name, "listWatch") ||
		   strings.Contains(name, "watchHandler") {
			cat = "Kubernetes Watch/Informer"
		} else if strings.Contains(name, "ovn") || strings.Contains(name, "OVN") ||
			strings.Contains(name, "ovnkube") || strings.Contains(name, "goovn") ||
			strings.Contains(name, "libovsdb") {
			cat = "Networking/OVN Operations"
		} else if strings.Contains(name, "reflect.") || strings.Contains(name, "encoding/json") ||
			strings.Contains(name, "json.") {
			cat = "Reflection/Encoding"
		} else if strings.Contains(name, "sync.") || strings.Contains(name, ".Lock") ||
			strings.Contains(name, "Mutex") || strings.Contains(name, "RWMutex") {
			cat = "Lock/Synchronization"
		} else if strings.Contains(name, "grpc") || strings.Contains(name, "net/http") ||
			strings.Contains(name, "transport") {
			cat = "gRPC/Network I/O"
		} else if strings.Contains(name, "Process") || strings.Contains(name, "Handle") ||
			strings.Contains(name, "Reconcile") {
			cat = "Resource Processing"
		}

		categories[cat] = append(categories[cat], fn)
	}

	return categories
}

func summarizeBottlenecks(topFuncs []*FunctionContext) {
	// Analyze patterns
	k8sWatchPct := 0.0
	ovnPct := 0.0
	reflectPct := 0.0
	lockPct := 0.0

	for _, fn := range topFuncs {
		name := fn.Name
		if strings.Contains(name, "k8s.io/client-go") || strings.Contains(name, "Informer") {
			k8sWatchPct += fn.CumPct
		}
		if strings.Contains(name, "ovn") || strings.Contains(name, "libovsdb") {
			ovnPct += fn.CumPct
		}
		if strings.Contains(name, "reflect") || strings.Contains(name, "json") {
			reflectPct += fn.CumPct
		}
		if strings.Contains(name, "Lock") || strings.Contains(name, "Mutex") {
			lockPct += fn.CumPct
		}
	}

	findings := []string{}

	if k8sWatchPct > 1.0 {
		findings = append(findings, fmt.Sprintf(
			"• Kubernetes watch/informer operations: %.2f%% - High watch activity suggests many resource updates",
			k8sWatchPct))
	}
	if ovnPct > 1.0 {
		findings = append(findings, fmt.Sprintf(
			"• OVN/networking operations: %.2f%% - Network configuration processing overhead",
			ovnPct))
	}
	if reflectPct > 2.0 {
		findings = append(findings, fmt.Sprintf(
			"• Reflection/JSON encoding: %.2f%% - Overhead from serialization/deserialization",
			reflectPct))
	}
	if lockPct > 1.0 {
		findings = append(findings, fmt.Sprintf(
			"• Lock contention: %.2f%% - Synchronization overhead between goroutines",
			lockPct))
	}

	if len(findings) > 0 {
		fmt.Println("\nKey findings:")
		for _, f := range findings {
			fmt.Println(f)
		}

		fmt.Println("\nRecommendations:")
		if k8sWatchPct > 1.0 {
			fmt.Println("  1. Review watch filters and reduce unnecessary watch events")
			fmt.Println("  2. Consider batching or rate-limiting event processing")
		}
		if ovnPct > 1.0 {
			fmt.Println("  3. Optimize OVN database operations and reduce update frequency")
		}
		if reflectPct > 2.0 {
			fmt.Println("  4. Cache frequently serialized objects or use code generation")
		}
		if lockPct > 1.0 {
			fmt.Println("  5. Profile lock contention and consider lock-free data structures")
		}
	}
}

func shortenName(name string, maxLen int) string {
	if len(name) <= maxLen {
		return name
	}
	return "..." + name[len(name)-maxLen+3:]
}
