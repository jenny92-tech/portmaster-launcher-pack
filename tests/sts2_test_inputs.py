# INPUT:  Explicit external STS2 test-input environment variables
# OUTPUT: Resolved paths or dependency-specific unittest skips
# POS:    Keeps optional integration inputs separate from disposable caches
import os
from pathlib import Path


def _provided_path(test, variable):
    value = os.environ.get(variable)
    if not value:
        test.skipTest(f'{variable} is not set; supply the external test input')
    return Path(value)


def external_file(test, variable):
    path = _provided_path(test, variable)
    if not path.is_file():
        test.skipTest(f'{variable} does not name an available regular file: {path}')
    return path.resolve()


def external_directory(test, variable):
    path = _provided_path(test, variable)
    if not path.is_dir():
        test.skipTest(f'{variable} does not name an available directory: {path}')
    return path.resolve()
