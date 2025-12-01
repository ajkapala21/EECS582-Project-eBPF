#!/bin/bash
# Aggregate results from multiple test runs
# Usage: aggregate_results.sh <scheduler> <workload>

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

OUTPUT_FILE="$RESULTS_DIR/summary_${SCHEDULER}_${WORKLOAD}.txt"

echo "Aggregating results for $SCHEDULER with $WORKLOAD workload..."
echo "========================================" > "$OUTPUT_FILE"
echo "Summary: $SCHEDULER - $WORKload" >> "$OUTPUT_FILE"
echo "Generated: $(date)" >> "$OUTPUT_FILE"
echo "========================================" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# Aggregate control results
echo "CONTROL VERSION:" >> "$OUTPUT_FILE"
CONTROL_FILES=$(find "$RESULTS_DIR/$SCHEDULER/control" -name "${WORKLOAD}_run*.csv" 2>/dev/null | sort)
if [ -n "$CONTROL_FILES" ]; then
    echo "  Files found: $(echo "$CONTROL_FILES" | wc -l)" >> "$OUTPUT_FILE"
    
    # Calculate average max map entries
    MAX_ENTRIES=$(cat $CONTROL_FILES 2>/dev/null | awk -F',' 'NR>1 {if ($2 > max) max=$2} END {print max+0}')
    AVG_ENTRIES=$(cat $CONTROL_FILES 2>/dev/null | awk -F',' 'NR>1 {sum+=$2; count++} END {print (count>0 ? sum/count : 0)}')
    echo "  Max map entries: $MAX_ENTRIES" >> "$OUTPUT_FILE"
    echo "  Avg map entries: $(printf "%.0f" $AVG_ENTRIES)" >> "$OUTPUT_FILE"
else
    echo "  No results found" >> "$OUTPUT_FILE"
fi

echo "" >> "$OUTPUT_FILE"

# Aggregate test results
echo "TEST VERSION:" >> "$OUTPUT_FILE"
TEST_FILES=$(find "$RESULTS_DIR/$SCHEDULER/test" -name "${WORKLOAD}_run*.csv" 2>/dev/null | sort)
if [ -n "$TEST_FILES" ]; then
    echo "  Files found: $(echo "$TEST_FILES" | wc -l)" >> "$OUTPUT_FILE"
    
    # Calculate average max map entries
    MAX_ENTRIES=$(cat $TEST_FILES 2>/dev/null | awk -F',' 'NR>1 {if ($2 > max) max=$2} END {print max+0}')
    AVG_ENTRIES=$(cat $TEST_FILES 2>/dev/null | awk -F',' 'NR>1 {sum+=$2; count++} END {print (count>0 ? sum/count : 0)}')
    TOTAL_EVICTIONS=$(cat $TEST_FILES 2>/dev/null | awk -F',' 'NR>1 {if ($5 > max) max=$5} END {print max+0}')
    echo "  Max map entries: $MAX_ENTRIES" >> "$OUTPUT_FILE"
    echo "  Avg map entries: $(printf "%.0f" $AVG_ENTRIES)" >> "$OUTPUT_FILE"
    echo "  Total evictions: $TOTAL_EVICTIONS" >> "$OUTPUT_FILE"
else
    echo "  No results found" >> "$OUTPUT_FILE"
fi

cat "$OUTPUT_FILE"
echo ""
echo "Summary saved to: $OUTPUT_FILE"

