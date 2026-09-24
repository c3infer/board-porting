#!/usr/bin/env python3
"""Add OpenSSL to the pinned guest recipe for encrypted benchmark modes."""

import pathlib
import sys

source, destination = map(pathlib.Path, sys.argv[1:])
recipe = source.read_text()
anchor = '  - action: apt\n    description: Small runtime libs often used by scientific wheels\n'
if recipe.count(anchor) != 1:
    raise SystemExit("Pinned guest recipe layout changed; update this adapter")
recipe = recipe.replace(anchor, '  - action: apt\n'
                        '    description: OpenSSL for encrypted communication benchmarks\n'
                        '    packages: [openssl]\n\n' + anchor)
destination.write_text(recipe)
