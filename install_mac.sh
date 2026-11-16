#!/bin/bash
#
# KGE / MAGeCK2 Installer — local machine (one go)
# macOS (Apple Silicon / Intel) and local Linux.
#
# Local entry point for the MAGeCK2 (UMI) installer. Thin wrapper around
# install_mageck2.sh (same folder): ALL steps and env overrides live there, so
# there is exactly one installer to maintain (no logic duplication/drift):
#
#   bash install_mac.sh            # create env 'mageckenv2'
#   bash install_mac.sh myenv      # custom env name
#
# What it does (via install_mageck2.sh): conda bootstrap (reuses an existing
# local install, else downloads Miniconda + inits bash/zsh) -> mageckenv2
# (Python+R+LaTeX+C/C++ toolchain) -> mageck2 from git (pip, compiles
# RRA/mageckGSEA) -> KGE overlay -> TeX Live (installed into ~/texlive2026
# on macOS) -> verification.
#
# Copy this whole Conda_setup_Mageck2 folder to the machine first (exclude the
# texlive2026 symlink — it points at a Linux-built tree that cannot run on
# macOS; the installer puts the Mac TeX tree in ~/texlive2026 instead).
#
# Env overrides (documented in install_mageck2.sh): KGE2_FORCE_RECREATE,
# KGE2_FORCE_PIP, KGE2_SKIP_TEXLIVE, ENV_PREFIX, MAGECK2_GIT_URL, TEXLIVE_DIR.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "${SCRIPT_DIR}/install_mageck2.sh" ]; then
    echo "ERROR: install_mageck2.sh not found next to this script (${SCRIPT_DIR})."
    echo "  Copy the whole Conda_setup_Mageck2 folder to this machine, then re-run."
    exit 1
fi

exec bash "${SCRIPT_DIR}/install_mageck2.sh" "$@"