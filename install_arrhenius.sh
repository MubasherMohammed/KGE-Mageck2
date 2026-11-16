#!/bin/bash
#
#SBATCH -n 1
#SBATCH -c 8
#SBATCH -t 02:00:00
#SBATCH -A naiss2026-4-1258-cpu
#SBATCH -p cpu
#SBATCH --job-name=kge2-install
#SBATCH --output=kge2-install-%j.out
#
# KGE / MAGeCK2 Installer — Arrhenius HPC (one go)
#
# Arrhenius entry point for the MAGeCK2 (UMI) installer. Thin wrapper around
# install_mageck2.sh (same folder): ALL steps and env overrides live there, so
# there is exactly one installer to maintain (no logic duplication/drift):
#
#   sbatch install_arrhenius.sh            # SLURM job (cd into this folder first)
#   bash   install_arrhenius.sh            # interactive / login node
#   bash   install_arrhenius.sh myenv      # custom env name
#
# What it does (via install_mageck2.sh): conda bootstrap (module-first on
# Arrhenius) -> mageckenv2 (Python+R+LaTeX+C/C++ toolchain) -> mageck2 from
# git (pip, compiles RRA/mageckGSEA) -> KGE overlay -> TeX Live (reuses the
# shared texlive2026/ tree) -> verification.
#
# Env overrides (documented in install_mageck2.sh): KGE2_FORCE_RECREATE,
# KGE2_FORCE_PIP, KGE2_SKIP_TEXLIVE, ENV_PREFIX, MAGECK2_GIT_URL, TEXLIVE_DIR.
#
set -euo pipefail

# Under sbatch, BASH_SOURCE resolves into SLURM's per-job dir; prefer the
# submit dir (cd into this folder before submitting).
if [ -n "${SLURM_SUBMIT_DIR:-}" ] && [ -f "${SLURM_SUBMIT_DIR}/install_mageck2.sh" ]; then
    SCRIPT_DIR="${SLURM_SUBMIT_DIR}"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [ ! -f "${SCRIPT_DIR}/install_mageck2.sh" ]; then
    echo "ERROR: install_mageck2.sh not found next to this script (${SCRIPT_DIR})."
    echo "  cd into the Conda_setup_Mageck2 folder (with environment_mageck2.yml"
    echo "  and mageck2/) and re-run."
    exit 1
fi

exec bash "${SCRIPT_DIR}/install_mageck2.sh" "$@"