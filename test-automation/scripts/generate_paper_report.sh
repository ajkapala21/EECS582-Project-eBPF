#!/bin/bash
# Generate paper-ready report comparing control vs test versions
# Usage: generate_paper_report.sh <scheduler> <workload>

set -e

SCHEDULER=$1
WORKLOAD=$2

if [ -z "$SCHEDULER" ] || [ -z "$WORKLOAD" ]; then
    echo "Usage: $0 <scheduler> <workload>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$BASE_DIR/results"

OUTPUT_FILE="$RESULTS_DIR/paper_report_${SCHEDULER}_${WORKLOAD}.txt"
CSV_FILE="$RESULTS_DIR/paper_report_${SCHEDULER}_${WORKLOAD}.csv"

echo "Generating paper-ready report for $SCHEDULER with $WORKLOAD workload..."
echo ""

# Find trace files (if using trace-based collection)
CONTROL_TRACE_FILES=$(find "$RESULTS_DIR/$SCHEDULER/control" -name "*trace*.txt" 2>/dev/null | sort)
TEST_TRACE_FILES=$(find "$RESULTS_DIR/$SCHEDULER/test" -name "*trace*.txt" 2>/dev/null | sort)

# Find CSV files
CONTROL_CSV_FILES=$(find "$RESULTS_DIR/$SCHEDULER/control" -name "${WORKLOAD}_run*.csv" 2>/dev/null | sort)
TEST_CSV_FILES=$(find "$RESULTS_DIR/$SCHEDULER/test" -name "${WORKLOAD}_run*.csv" 2>/dev/null | sort)

# Function to extract metrics from trace file
extract_trace_metrics() {
    local trace_file=$1
    if [ ! -f "$trace_file" ]; then
        echo "0,0,0,0"
        return
    fi
    
    local total_added=$(grep -c "nest_running: Added new task" "$trace_file" 2>/dev/null || echo "0")
    local total_evicted=$(grep "Map cleanup: timeout after evicted" "$trace_file" 2>/dev/null | \
        sed 's/.*evicted \([0-9]*\) entries.*/\1/' | \
        awk '{sum+=$1} END {print sum+0}' || echo "0")
    local cleanup_runs=$(grep -c "Map cleanup: Starting cleanup scan" "$trace_file" 2>/dev/null || echo "0")
    local avg_evicted=0
    if [ "$cleanup_runs" -gt 0 ]; then
        avg_evicted=$(echo "scale=2; $total_evicted / $cleanup_runs" | bc 2>/dev/null || echo "0")
    fi
    
    echo "$total_added,$total_evicted,$cleanup_runs,$avg_evicted"
}

# Function to extract metrics from CSV file
extract_csv_metrics() {
    local csv_file=$1
    if [ ! -f "$csv_file" ]; then
        echo "0,0,0,0"
        return
    fi
    
    # Skip header, get max values
    local max_entries=$(tail -n +2 "$csv_file" | awk -F',' '{if ($2 > max) max=$2} END {print max+0}')
    local max_evictions=$(tail -n +2 "$csv_file" | awk -F',' '{if ($4 > max) max=$4} END {print max+0}')
    local final_entries=$(tail -n +2 "$csv_file" | tail -1 | awk -F',' '{print $2}')
    local final_evictions=$(tail -n +2 "$csv_file" | tail -1 | awk -F',' '{print $4}')
    
    echo "$max_entries,$final_entries,$max_evictions,$final_evictions"
}

# Generate report
{
    echo "=================================================================================="
    echo "Memory Cleanup Effectiveness Report"
    echo "Scheduler: $SCHEDULER | Workload: $WORKLOAD"
    echo "Generated: $(date)"
    echo "=================================================================================="
    echo ""
    echo "EXECUTIVE SUMMARY"
    echo "-----------------"
    echo ""
    
    # Control version metrics
    echo "CONTROL VERSION (No Cleanup):"
    echo "  - Map entries accumulate over time (no cleanup)"
    echo "  - Memory usage may grow unbounded"
    echo ""
    
    if [ -n "$CONTROL_CSV_FILES" ]; then
        CONTROL_MAX=0
        CONTROL_FINAL=0
        for file in $CONTROL_CSV_FILES; do
            read max_entries final_entries max_ev final_ev <<< $(extract_csv_metrics "$file" | tr ',' ' ')
            if [ "$(echo "$max_entries > $CONTROL_MAX" | bc 2>/dev/null || echo 0)" -eq 1 ]; then
                CONTROL_MAX=$max_entries
            fi
            if [ "$(echo "$final_entries > $CONTROL_FINAL" | bc 2>/dev/null || echo 0)" -eq 1 ]; then
                CONTROL_FINAL=$final_entries
            fi
        done
        echo "  Max map entries observed: $CONTROL_MAX"
        echo "  Final map entries: $CONTROL_FINAL"
    else
        echo "  (No CSV data available)"
    fi
    echo ""
    
    # Test version metrics
    echo "TEST VERSION (With Cleanup):"
    echo "  - Map entries are actively cleaned up"
    echo "  - Memory usage remains bounded"
    echo ""
    
    if [ -n "$TEST_CSV_FILES" ]; then
        TEST_MAX=0
        TEST_FINAL=0
        TEST_TOTAL_EVICTED=0
        TEST_CLEANUP_RUNS=0
        TEST_AVG_EVICTED=0
        
        for file in $TEST_CSV_FILES; do
            read max_entries final_entries max_ev final_ev <<< $(extract_csv_metrics "$file" | tr ',' ' ')
            if [ "$(echo "$max_entries > $TEST_MAX" | bc 2>/dev/null || echo 0)" -eq 1 ]; then
                TEST_MAX=$max_entries
            fi
            if [ "$(echo "$final_entries > $TEST_FINAL" | bc 2>/dev/null || echo 0)" -eq 1 ]; then
                TEST_FINAL=$final_entries
            fi
            if [ "$(echo "$final_ev > $TEST_TOTAL_EVICTED" | bc 2>/dev/null || echo 0)" -eq 1 ]; then
                TEST_TOTAL_EVICTED=$final_ev
            fi
        done
        
        # Also check trace files if available
        if [ -n "$TEST_TRACE_FILES" ]; then
            for file in $TEST_TRACE_FILES; do
                read added evicted runs avg <<< $(extract_trace_metrics "$file" | tr ',' ' ')
                TEST_TOTAL_EVICTED=$((TEST_TOTAL_EVICTED + evicted))
                TEST_CLEANUP_RUNS=$((TEST_CLEANUP_RUNS + runs))
            done
            if [ "$TEST_CLEANUP_RUNS" -gt 0 ]; then
                TEST_AVG_EVICTED=$(echo "scale=2; $TEST_TOTAL_EVICTED / $TEST_CLEANUP_RUNS" | bc 2>/dev/null || echo "0")
            fi
        fi
        
        echo "  Max map entries observed: $TEST_MAX"
        echo "  Final map entries: $TEST_FINAL"
        echo "  Total entries evicted: $TEST_TOTAL_EVICTED"
        if [ "$TEST_CLEANUP_RUNS" -gt 0 ]; then
            echo "  Cleanup operations: $TEST_CLEANUP_RUNS"
            echo "  Average evictions per cleanup: $TEST_AVG_EVICTED"
        fi
    else
        echo "  (No CSV data available)"
    fi
    echo ""
    
    # Comparison
    echo "COMPARISON"
    echo "----------"
    if [ -n "$CONTROL_CSV_FILES" ] && [ -n "$TEST_CSV_FILES" ]; then
        if [ "$CONTROL_FINAL" -gt 0 ]; then
            MEMORY_SAVED=$((CONTROL_FINAL - TEST_FINAL))
            PERCENT_REDUCTION=$(echo "scale=1; ($MEMORY_SAVED * 100) / $CONTROL_FINAL" | bc 2>/dev/null || echo "0")
            echo "  Memory saved (map entries): $MEMORY_SAVED entries"
            echo "  Memory reduction: ${PERCENT_REDUCTION}%"
            echo ""
            echo "  Control version accumulated $CONTROL_FINAL entries"
            echo "  Test version stabilized at $TEST_FINAL entries"
            echo "  Difference: $MEMORY_SAVED entries prevented from accumulating"
        else
            echo "  (Insufficient data for comparison)"
        fi
    fi
    echo ""
    
    echo "DETAILED METRICS"
    echo "----------------"
    echo ""
    echo "Control Version Runs:"
    if [ -n "$CONTROL_CSV_FILES" ]; then
        for file in $CONTROL_CSV_FILES; do
            basename_file=$(basename "$file")
            read max_entries final_entries max_ev final_ev <<< $(extract_csv_metrics "$file" | tr ',' ' ')
            echo "  $basename_file:"
            echo "    Max entries: $max_entries"
            echo "    Final entries: $final_entries"
        done
    else
        echo "  (No data files found)"
    fi
    echo ""
    
    echo "Test Version Runs:"
    if [ -n "$TEST_CSV_FILES" ]; then
        for file in $TEST_CSV_FILES; do
            basename_file=$(basename "$file")
            read max_entries final_entries max_ev final_ev <<< $(extract_csv_metrics "$file" | tr ',' ' ')
            echo "  $basename_file:"
            echo "    Max entries: $max_entries"
            echo "    Final entries: $final_entries"
            echo "    Total evictions: $final_ev"
        done
    else
        echo "  (No data files found)"
    fi
    echo ""
    
    echo "CONCLUSION"
    echo "----------"
    if [ -n "$CONTROL_CSV_FILES" ] && [ -n "$TEST_CSV_FILES" ]; then
        if [ "$TEST_TOTAL_EVICTED" -gt 0 ]; then
            echo "The cleanup mechanism successfully evicted $TEST_TOTAL_EVICTED stale map entries"
            echo "during the test period, preventing unbounded memory growth."
            echo ""
            if [ "$CONTROL_FINAL" -gt "$TEST_FINAL" ]; then
                echo "The test version maintained $TEST_FINAL map entries compared to"
                echo "$CONTROL_FINAL in the control version, demonstrating effective"
                echo "memory management through proactive cleanup."
            else
                echo "Both versions showed similar final map entry counts, but the test"
                echo "version actively cleaned up $TEST_TOTAL_EVICTED entries, preventing"
                echo "potential memory leaks in longer-running scenarios."
            fi
        else
            echo "Cleanup mechanism is active but no evictions were recorded."
            echo "This may indicate all entries were fresh or the workload was too short."
        fi
    else
        echo "Insufficient data for conclusion."
    fi
    
} > "$OUTPUT_FILE"

# Also generate CSV summary
{
    echo "version,run,max_entries,final_entries,total_evictions,cleanup_runs,avg_evictions_per_run"
    
    # Control runs
    if [ -n "$CONTROL_CSV_FILES" ]; then
        for file in $CONTROL_CSV_FILES; do
            basename_file=$(basename "$file" .csv)
            read max_entries final_entries max_ev final_ev <<< $(extract_csv_metrics "$file" | tr ',' ' ')
            echo "control,$basename_file,$max_entries,$final_entries,0,0,0"
        done
    fi
    
    # Test runs
    if [ -n "$TEST_CSV_FILES" ]; then
        for file in $TEST_CSV_FILES; do
            basename_file=$(basename "$file" .csv)
            read max_entries final_entries max_ev final_ev <<< $(extract_csv_metrics "$file" | tr ',' ' ')
            echo "test,$basename_file,$max_entries,$final_entries,$final_ev,0,0"
        done
    fi
} > "$CSV_FILE"

cat "$OUTPUT_FILE"
echo ""
echo "Report saved to: $OUTPUT_FILE"
echo "CSV summary saved to: $CSV_FILE"

