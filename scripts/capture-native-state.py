#!/usr/bin/env python3
"""Retain one native AX snapshot without starting window screen capture."""
import argparse
import json
import pathlib
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--window-id', type=int, required=True)
    parser.add_argument('--session', required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.pid <= 0 or args.window_id <= 0:
        parser.error('PID and window ID must be positive.')
    if not args.output.is_absolute() or not args.output.parent.is_dir():
        parser.error('Output must be an absolute path in an existing directory.')
    if args.output.exists():
        parser.error('Output exists; retain it and choose a new capture path.')
    request = {'pid': args.pid, 'window_id': args.window_id,
               'session': args.session, 'include_screenshot': False,
               'timeout_ms': 5000}
    try:
        result = subprocess.run(['cua-driver', 'get_window_state', json.dumps(request)],
                                capture_output=True, text=True, timeout=30, check=True)
        state = json.loads(result.stdout)
        if (state.get('pid') != args.pid or state.get('window_id') != args.window_id
                or not state.get('elements') or state.get('truncated')
                or state.get('screenshot_png_b64')):
            raise ValueError('Incomplete or unexpected native AX capture; no receipt written.')
        # Exclusive creation preserves prior receipts even if another caller races us.
        with args.output.open('x') as output:
            json.dump({'mode': 'ax-only', 'request': request, 'state': state}, output, indent=2)
            output.write('\n')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(f'AX-only native state retained: {args.output}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
