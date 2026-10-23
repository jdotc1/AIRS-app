"""Keep requested test evidence and clean temporary output roots at process exit."""
import atexit
from contextlib import ExitStack
import os
from pathlib import Path
import tempfile


_temporary_outputs = ExitStack()
atexit.register(_temporary_outputs.close)


def output_root():
    requested = os.environ.get('AIRS_TEST_OUTPUT_ROOT')
    if requested:
        return Path(requested)
    directory = _temporary_outputs.enter_context(
        tempfile.TemporaryDirectory(prefix='airs-integration-')
    )
    return Path(directory)
