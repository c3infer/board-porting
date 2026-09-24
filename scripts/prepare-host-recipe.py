#!/usr/bin/env python3
"""Adapt pinned Rock 5B Debos recipes without changing upstream checkouts."""

import pathlib
import sys

def replace_once(recipe: str, old: str, new: str) -> str:
    if recipe.count(old) != 1:
        raise SystemExit("Pinned recipe layout changed; update this adapter")
    return recipe.replace(old, new)


image_source, image_destination, ospack_source, ospack_destination = map(
    pathlib.Path, sys.argv[1:]
)
image = image_source.read_text()
image = replace_once(
    image, '{{ $imagesize := or .imagesize "4GB" }}',
    '{{ $imagesize := or .imagesize "8GB" }}',
)
anchor = '  - action: apt\n    description: install opencca packages'
image = replace_once(
    image, anchor,
    '  - action: apt\n'
    '    description: Install QEMU runtime libraries\n'
    '    packages: [zlib1g, libpixman-1-0, libfdt1, '
    'libglib2.0-0t64, libslirp0]\n\n'
    '  - action: overlay\n'
    '    description: Install realm disk, guest kernel and VM runners\n'
    '    source: overlays/board-porting\n'
    '    destination: /home/user\n\n' + anchor,
)
image_destination.write_text(image)

ospack = ospack_source.read_text()
collabora = '''  - action: overlay
    decription: Add collabora rk3588 hardware enablement repositories
    source: overlays/repositories

  - action: apt
    description: Install collabora keyring package
    package:
      - collabora-archive-keyring

'''
# The pinned Collabora key is rejected by current Debian sqv. The host kernel
# is installed from the local build, so this image uses Debian's base packages.
ospack = replace_once(ospack, collabora, '')
ospack_destination.write_text(ospack)
