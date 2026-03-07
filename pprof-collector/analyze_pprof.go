package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/google/pprof/profile"
)

type FunctionStats struct {
	Name     string
	Self     int64
	Cumulative int64
	SelfPct  float64
	CumPct   float64
}

type ProfileAnalysis struct {
	FileName      string
	PodName       string
	CPUUsage      string
	TotalSamples  int64
	TopFunctions  []FunctionStats
}

func main() {
	if len(os.Args) < 2 {
		fmt.Println("Usage: analyze_pprof <pprof_directory>")
		os.Exit(1)
	}

	pprofDir := os.Args[1]

	// Find all .profile files
	profileFiles, err := filepath.Glob(filepath.Join(pprofDir, "*.profile"))
	if err != nil {
		fmt.Printf("Error finding profile files: %v\n", err)
		os.Exit(1)
	}

	if len(profileFiles) == 0 {
		fmt.Printf("No .profile files found in %s\n", pprofDir)
		os.Exit(1)
	}

	fmt.Printf("Found %d profile files\n", len(profileFiles))
	fmt.Println("=" + strings.Repeat("=", 100))

	allAnalyses := []ProfileAnalysis{}

	for _, profileFile := range profileFiles {
		analysis := analyzeProfile(profileFile)
		if analysis != nil {
			allAnalyses = append(allAnalyses, *analysis)
		}
	}

	// Print summary
	printSummary(allAnalyses)
}

func analyzeProfile(profilePath string) *ProfileAnalysis {
	f, err := os.Open(profilePath)
	if err != nil {
		fmt.Printf("Error opening %s: %v\n", profilePath, err)
		return nil
	}
	defer f.Close()

	p, err := profile.Parse(f)
	if err != nil {
		fmt.Printf("Error parsing %s: %v\n", profilePath, err)
		return nil
	}

	if len(p.Sample) == 0 {
		fmt.Printf("Skipping %s: no samples\n", filepath.Base(profilePath))
		return nil
	}

	// Extract pod name and CPU usage from filename
	basename := filepath.Base(profilePath)
	podName := extractPodName(basename)
	cpuUsage := extractCPUUsage(basename)

	// Calculate function statistics
	funcStats := make(map[string]*FunctionStats)
	var totalSamples int64

	for _, sample := range p.Sample {
		value := sample.Value[0] // CPU samples
		totalSamples += value

		for i, loc := range sample.Location {
			for _, line := range loc.Line {
				funcName := line.Function.Name
				if funcName == "" {
					funcName = fmt.Sprintf("0x%x", loc.Address)
				}

				if _, exists := funcStats[funcName]; !exists {
					funcStats[funcName] = &FunctionStats{Name: funcName}
				}

				// Self time is only for the leaf function
				if i == 0 {
					funcStats[funcName].Self += value
				}
				// Cumulative includes all samples where this function appears
				funcStats[funcName].Cumulative += value
			}
		}
	}

	// Convert to slice and sort by self time
	topFuncs := []FunctionStats{}
	for _, stats := range funcStats {
		stats.SelfPct = float64(stats.Self) / float64(totalSamples) * 100
		stats.CumPct = float64(stats.Cumulative) / float64(totalSamples) * 100
		topFuncs = append(topFuncs, *stats)
	}

	sort.Slice(topFuncs, func(i, j int) bool {
		return topFuncs[i].Self > topFuncs[j].Self
	})

	// Keep top 15 functions
	if len(topFuncs) > 15 {
		topFuncs = topFuncs[:15]
	}

	analysis := &ProfileAnalysis{
		FileName:     filepath.Base(profilePath),
		PodName:      podName,
		CPUUsage:     cpuUsage,
		TotalSamples: totalSamples,
		TopFunctions: topFuncs,
	}

	printAnalysis(analysis)
	return analysis
}

func extractPodName(filename string) string {
	// Extract pod name from filename like "ovnkube-node-28zpp-CPU2250m-RAM3490Mi-29103-20260305_094147.profile"
	parts := strings.Split(filename, "-CPU")
	if len(parts) > 0 {
		return parts[0]
	}
	return filename
}

func extractCPUUsage(filename string) string {
	// Extract CPU usage like "2250m" from filename
	parts := strings.Split(filename, "-CPU")
	if len(parts) > 1 {
		cpuPart := strings.Split(parts[1], "-")[0]
		return cpuPart
	}
	return "unknown"
}

func printAnalysis(analysis *ProfileAnalysis) {
	fmt.Printf("\n📊 Profile: %s\n", analysis.FileName)
	fmt.Printf("Pod: %s\n", analysis.PodName)
	fmt.Printf("CPU Usage: %s\n", analysis.CPUUsage)
	fmt.Printf("Total Samples: %d\n", analysis.TotalSamples)
	fmt.Println("\nTop Functions by Self CPU Time:")
	fmt.Printf("%-80s %10s %10s %10s %10s\n", "Function", "Self", "Self%", "Cumulative", "Cum%")
	fmt.Println(strings.Repeat("-", 120))

	for _, fn := range analysis.TopFunctions {
		// Shorten function name if too long
		funcName := fn.Name
		if len(funcName) > 75 {
			funcName = "..." + funcName[len(funcName)-72:]
		}
		fmt.Printf("%-80s %10d %9.2f%% %10d %9.2f%%\n",
			funcName, fn.Self, fn.SelfPct, fn.Cumulative, fn.CumPct)
	}
	fmt.Println(strings.Repeat("=", 120))
}

func printSummary(analyses []ProfileAnalysis) {
	fmt.Println("\n\n🔍 SUMMARY: Aggregated Hot Functions Across All Profiles")
	fmt.Println(strings.Repeat("=", 120))

	// Aggregate function stats across all profiles
	aggregatedStats := make(map[string]*FunctionStats)
	var totalSamplesAll int64

	for _, analysis := range analyses {
		totalSamplesAll += analysis.TotalSamples
		for _, fn := range analysis.TopFunctions {
			if _, exists := aggregatedStats[fn.Name]; !exists {
				aggregatedStats[fn.Name] = &FunctionStats{Name: fn.Name}
			}
			aggregatedStats[fn.Name].Self += fn.Self
			aggregatedStats[fn.Name].Cumulative += fn.Cumulative
		}
	}

	// Convert to slice and recalculate percentages
	topAggregated := []FunctionStats{}
	for _, stats := range aggregatedStats {
		stats.SelfPct = float64(stats.Self) / float64(totalSamplesAll) * 100
		stats.CumPct = float64(stats.Cumulative) / float64(totalSamplesAll) * 100
		topAggregated = append(topAggregated, *stats)
	}

	sort.Slice(topAggregated, func(i, j int) bool {
		return topAggregated[i].Self > topAggregated[j].Self
	})

	fmt.Printf("\nTotal samples across all profiles: %d\n", totalSamplesAll)
	fmt.Printf("Number of profiles analyzed: %d\n\n", len(analyses))

	fmt.Println("Top 30 Hot Functions (aggregated across all profiles):")
	fmt.Printf("%-80s %10s %10s %10s %10s\n", "Function", "Self", "Self%", "Cumulative", "Cum%")
	fmt.Println(strings.Repeat("-", 120))

	limit := 30
	if len(topAggregated) < limit {
		limit = len(topAggregated)
	}

	for i := 0; i < limit; i++ {
		fn := topAggregated[i]
		funcName := fn.Name
		if len(funcName) > 75 {
			funcName = "..." + funcName[len(funcName)-72:]
		}
		fmt.Printf("%-80s %10d %9.2f%% %10d %9.2f%%\n",
			funcName, fn.Self, fn.SelfPct, fn.Cumulative, fn.CumPct)
	}

	fmt.Println("\n\n🎯 KEY FINDINGS:")
	fmt.Println(strings.Repeat("-", 120))

	// Categorize hot functions
	categorizeHotFunctions(topAggregated[:limit])
}

func categorizeHotFunctions(functions []FunctionStats) {
	categories := map[string][]string{
		"Reflection/Type System": []string{},
		"Network/gRPC": []string{},
		"Synchronization": []string{},
		"JSON Processing": []string{},
		"Kubernetes Client": []string{},
		"OVN/Networking": []string{},
		"Memory/GC": []string{},
		"Other": []string{},
	}

	for _, fn := range functions {
		name := fn.Name
		category := "Other"

		if strings.Contains(name, "reflect.") || strings.Contains(name, "type.") {
			category = "Reflection/Type System"
		} else if strings.Contains(name, "grpc") || strings.Contains(name, "net/http") || strings.Contains(name, "net.") {
			category = "Network/gRPC"
		} else if strings.Contains(name, "sync.") || strings.Contains(name, "runtime.lock") || strings.Contains(name, "mutex") || strings.Contains(name, "semacquire") {
			category = "Synchronization"
		} else if strings.Contains(name, "json") || strings.Contains(name, "encoding") {
			category = "JSON Processing"
		} else if strings.Contains(name, "k8s.io") || strings.Contains(name, "client-go") {
			category = "Kubernetes Client"
		} else if strings.Contains(name, "ovn") || strings.Contains(name, "OVN") || strings.Contains(name, "ovnkube") {
			category = "OVN/Networking"
		} else if strings.Contains(name, "runtime.gc") || strings.Contains(name, "runtime.malloc") || strings.Contains(name, "runtime.scanobject") {
			category = "Memory/GC"
		}

		entry := fmt.Sprintf("  • %s (%.2f%%)", shortenFuncName(name, 90), fn.SelfPct)
		categories[category] = append(categories[category], entry)
	}

	// Print categories
	for _, catName := range []string{"Reflection/Type System", "Synchronization", "Network/gRPC", "Kubernetes Client",
		"JSON Processing", "OVN/Networking", "Memory/GC", "Other"} {
		funcs := categories[catName]
		if len(funcs) > 0 {
			fmt.Printf("\n%s:\n", catName)
			for _, f := range funcs {
				fmt.Println(f)
			}
		}
	}
}

func shortenFuncName(name string, maxLen int) string {
	if len(name) <= maxLen {
		return name
	}
	return "..." + name[len(name)-maxLen+3:]
}
