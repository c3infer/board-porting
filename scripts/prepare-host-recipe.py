#!/usr/bin/env python3
"""Add the board-porting overlay to the pinned Rock 5B image recipe."""

import pathlib
import sys

source, destination = map(pathlib.Path, sys.argv[1:])
recipe = source.read_text()
size = '{{ $imagesize := or .imagesize "4GB" }}'
anchor = '  - action: apt\n    description: install opencca packages'
if recipe.count(size) != 1 or recipe.count(anchor) != 1:
    raise SystemExit("Pinned host recipe layout changed; update this adapter")
recipe = recipe.replace(size, '{{ $imagesize := or .imagesize "8GB" }}')
recipe = recipe.replace(
    anchor,
    '  - action: overlay\n'
    '    description: Install realm disk, guest kernel and VM runner\n'
    '    source: overlays/board-porting\n'
    '    destination: /home/user\n\n' + anchor,
)
destination.write_text(recipe)
