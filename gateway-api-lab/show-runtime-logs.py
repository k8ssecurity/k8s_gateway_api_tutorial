#!/usr/bin/env python3
"""
Display runtime logs (fw.jsonl) for troubleshooting gateway and MCP interactions.

Usage:
    python3 show-runtime-logs.py [--log-path PATH] [--format FORMAT]

    --log-path PATH    Path to the fw.jsonl log file (default: /home/runner/work/_temp/runtime-logs/fw.jsonl)
    --format FORMAT    Output format: json, pretty, or text (default: pretty)
"""

import argparse
import json
import sys
from pathlib import Path


DEFAULT_LOG_PATH = "/home/runner/work/_temp/runtime-logs/fw.jsonl"


def load_jsonl_logs(log_path):
    """Load and parse JSONL log file.
    
    Returns a tuple (logs, message) where:
    - logs is None and message is an error string if fatal error occurs
    - logs is a list and message is None if all lines parse successfully
    - logs is a list and message is a warning string if some lines failed to parse
    """
    path = Path(log_path)
    
    if not path.exists():
        return None, f"Log file not found: {log_path}"
    
    if not path.is_file():
        return None, f"Path is not a file: {log_path}"
    
    try:
        logs = []
        errors = []
        with open(path, 'r') as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    logs.append(json.loads(line))
                except json.JSONDecodeError as e:
                    errors.append(f"Line {line_num}: {e}")
        
        # Report any parsing errors as warnings
        if errors:
            warning = f"Loaded {len(logs)} valid log entries. Skipped {len(errors)} invalid lines:\n" + "\n".join(errors[:5])
            if len(errors) > 5:
                warning += f"\n... and {len(errors) - 5} more invalid lines"
            return logs, warning
        
        return logs, None
    except IOError as e:
        return None, f"Failed to read file: {e}"


def format_pretty(logs):
    """Format logs as pretty-printed JSON."""
    output = []
    for i, log in enumerate(logs, 1):
        output.append(f"--- Log Entry {i} ---")
        output.append(json.dumps(log, indent=2))
        output.append("")
    return "\n".join(output)


def format_json(logs):
    """Format logs as JSON array."""
    return json.dumps(logs, indent=2)


def format_text(logs):
    """Format logs as plain text with key fields."""
    output = []
    for i, log in enumerate(logs, 1):
        output.append(f"--- Log Entry {i} ---")
        
        # Extract common fields if they exist
        for key in ['time', 'timestamp', 'level', 'msg', 'message', 'error', 'status', 'path', 'method']:
            if key in log:
                value = log[key]
                if isinstance(value, (dict, list)):
                    value = json.dumps(value, indent=2)
                output.append(f"{key}: {value}")
        
        # Show any remaining fields
        shown_keys = {'time', 'timestamp', 'level', 'msg', 'message', 'error', 'status', 'path', 'method'}
        for key, value in log.items():
            if key not in shown_keys:
                if isinstance(value, (dict, list)):
                    value = json.dumps(value, indent=2)
                output.append(f"{key}: {value}")
        
        output.append("")
    return "\n".join(output)


def main():
    parser = argparse.ArgumentParser(
        description="Display runtime logs (fw.jsonl) for troubleshooting gateway and MCP interactions"
    )
    parser.add_argument(
        "--log-path",
        default=DEFAULT_LOG_PATH,
        help="Path to the fw.jsonl log file"
    )
    parser.add_argument(
        "--format",
        choices=["json", "pretty", "text"],
        default="pretty",
        help="Output format"
    )
    
    args = parser.parse_args()
    
    logs, warning = load_jsonl_logs(args.log_path)
    
    if logs is None:
        # Fatal error: file not found or not readable
        print(f"Error: {warning}", file=sys.stderr)
        print("\nTo troubleshoot gateway and MCP interactions, make sure:", file=sys.stderr)
        print("1. The test script or gateway has been executed", file=sys.stderr)
        log_dir = str(Path(args.log_path).parent)
        print(f"2. The runtime logs directory exists: {log_dir}/", file=sys.stderr)
        print("3. Pass --log-path if your logs are in a different location", file=sys.stderr)
        return 1
    
    # Report parsing warnings if any (non-fatal: some lines were skipped)
    if warning:
        print(f"Warning: {warning}", file=sys.stderr)
    
    if not logs:
        print("No logs found in the file.", file=sys.stderr)
        return 0
    
    print(f"Found {len(logs)} log entries:", file=sys.stdout)
    print(file=sys.stdout)
    
    if args.format == "json":
        print(format_json(logs))
    elif args.format == "text":
        print(format_text(logs))
    else:  # pretty
        print(format_pretty(logs))
    
    return 0


if __name__ == "__main__":
    sys.exit(main())
