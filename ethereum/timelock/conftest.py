"""Pytest configuration for the TimeLock Ape project."""

import sys
from pathlib import Path

# make `scripts.*` importable from the tests
PROJECT_ROOT = Path(__file__).parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))
