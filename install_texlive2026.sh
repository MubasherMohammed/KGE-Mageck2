#!/bin/bash
# Installs TeX Live (scheme-basic + collection-latexrecommended) into TEXLIVE_DIR
# and adds it to the target conda environment's PATH via activation hooks.
#
# WHY: `mageck count --pdf-report` renders the report with
#       R (Sweave/knitr) -> texi2dvi -> pdflatex.
#       conda-forge only provides a minimal texlive-core (no .sty files, no
#       texi2dvi), so a real TeX distribution must be installed separately.
#
# PORTABLE: works on Linux (x86_64 / aarch64) and macOS (x86_64 / arm64).
# The TeX Live platform bin dir name varies by OS/arch
# (x86_64-linux, aarch64-linux, x86_64-darwin, arm64-darwin) and is detected
# dynamically — nothing is hardcoded.
#
# Idempotent: if a usable pdflatex already exists in TEXLIVE_DIR, the
# (multi-GB) download is skipped and only the shims + conda hooks are
# (re)written.
#
# Usage (from the Conda_setup directory, on a login node or via sbatch):
#   bash install_texlive2026.sh
# Environment overrides:
#   TEXLIVE_DIR=/some/path   target TeX Live directory (default: <script dir>/texlive2026)
#   CONDA_ENV=mageckenv      conda environment to hook (default: mageckenv)
#   KGE_ENV_DIR=/path        explicit env directory to hook (most reliable; set by
#                            install_arrhenius.sh which runs in a shell where `conda`
#                            is available). When unset, falls back to `conda env list`,
#                            CONDA_ENVS_PATH, then well-known per-user locations.
#
# NOTE: a fresh install needs network access to CTAN (~2 GB) and ~3 GB free disk.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEXLIVE_DIR="${TEXLIVE_DIR:-${SCRIPT_DIR}/texlive2026}"
ENV_NAME="${CONDA_ENV:-mageckenv}"
WORKDIR="$(mktemp -d /tmp/install-tl-XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "[texlive] Target directory: ${TEXLIVE_DIR}"

# A tree is usable if pdflatex exists either as the bin/ shim or directly in
# bin/<platform>/ (shims are created below, so a freshly built tree matches the
# second case).
if [ -x "${TEXLIVE_DIR}/bin/pdflatex" ] || ls "${TEXLIVE_DIR}"/bin/*/pdflatex &> /dev/null; then
  echo "[texlive] Already installed (pdflatex found). Skipping download."
else
  echo "[texlive] Downloading install-tl (TeX Live)..."
  curl -fsSL -o "${WORKDIR}/install-tl-unx.tar.gz" \
     "https://mirror.ctan.org/systems/texlive/tlnet/install-tl-unx.tar.gz"
  tar xzf "${WORKDIR}/install-tl-unx.tar.gz" -C "${WORKDIR}"
  INSTALLER_BIN="$(ls "${WORKDIR}"/install-tl-*/install-tl 2> /dev/null | head -n1 || true)"
  if [ -z "${INSTALLER_BIN}" ] || [ ! -x "${INSTALLER_BIN}" ]; then
    echo "[texlive] ERROR: could not locate the install-tl binary in ${WORKDIR}." >&2
    ls -la "${WORKDIR}" >&2 || true
    exit 1
  fi
  printf 'selected_scheme scheme-basic\n' > "${WORKDIR}/tl.profile"
  echo "[texlive] Installing scheme-basic (~2 GB download, several minutes)..."
  "${INSTALLER_BIN}" \
    --profile "${WORKDIR}/tl.profile" \
    -texdir "${TEXLIVE_DIR}" \
    --no-interaction \
    --logfile "${WORKDIR}/texlive_install.log"

  # Detect the platform-specific bin dir (x86_64-linux / aarch64-linux /
  # x86_64-darwin / arm64-darwin) instead of hardcoding it, then use its tlmgr
  # to add the collections the MAGeCK report template needs.
  PLATFORM_BIN="$(find "${TEXLIVE_DIR}/bin" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  TLMGR="${PLATFORM_BIN}/tlmgr"
  if [ ! -x "${TLMGR}" ]; then
    echo "[texlive] ERROR: could not find tlmgr under ${TEXLIVE_DIR}/bin" >&2
    [ -f "${WORKDIR}/texlive_install.log" ] && tail -20 "${WORKDIR}/texlive_install.log" >&2
    exit 1
  fi
  echo "[texlive] Adding collection-latexrecommended + report deps via ${TLMGR}..."
  "${TLMGR}" install collection-latexrecommended >> "${WORKDIR}/texlive_install.log" 2>&1
  # extra packages required by the report .tex output (knitr adds framed and
  # upquote; fullpage.sty ships in the 'preprint' package)
  "${TLMGR}" install preprint framed upquote >> "${WORKDIR}/texlive_install.log" 2>&1
fi

# TL only ships bin/<platform>/; create the classic bin/ symlink shims so a
# stable ${TEXLIVE_DIR}/bin path can be put on PATH.
PLATFORM_BIN="$(find "${TEXLIVE_DIR}/bin" -mindepth 1 -maxdepth 1 -type d | head -n1)"
if [ -n "${PLATFORM_BIN}" ]; then
  for f in "${PLATFORM_BIN}"/*; do
    [ -e "${f}" ] || continue
    ln -sf "$(basename "${PLATFORM_BIN}")/$(basename "$f")" "${TEXLIVE_DIR}/bin/$(basename "$f")"
  done
fi

if [ ! -x "${TEXLIVE_DIR}/bin/pdflatex" ]; then
  echo "[texlive] ERROR: installation did not produce ${TEXLIVE_DIR}/bin/pdflatex" >&2
  [ -f "${WORKDIR}/texlive_install.log" ] && tail -20 "${WORKDIR}/texlive_install.log" >&2
  exit 1
fi
echo "[texlive] TeX Live OK: $("${TEXLIVE_DIR}/bin/pdflatex" --version | head -n1)"

# ---------------------------------------------------------------------------
# Conda activation hooks: prepend/append the TeX bin dir to PATH when the
# environment is activated/deactivated, so R's texi2dvi() call finds texi2dvi
# and pdflatex in batch and interactive sessions alike.
# ---------------------------------------------------------------------------
# Resolve the conda env directory WITHOUT assuming a module system. Prefer the
# explicit KGE_ENV_DIR (set by the parent installer where `conda` works), then
# `conda env list`, then CONDA_ENVS_PATH, then well-known per-user locations.
ENV_PREFIX="${KGE_ENV_DIR:-}"
if [ -z "${ENV_PREFIX}" ] || [ ! -d "${ENV_PREFIX}" ]; then
  if command -v conda &> /dev/null; then
    ENV_PREFIX="$(conda env list 2>/dev/null | awk -v e="${ENV_NAME}" '$1==e {print $NF}' | head -n1 || true)"
  fi
fi
if [ -z "${ENV_PREFIX}" ] || [ ! -d "${ENV_PREFIX}" ]; then
  if [ -n "${CONDA_ENVS_PATH:-}" ] && [ -d "${CONDA_ENVS_PATH}/${ENV_NAME}" ]; then
    ENV_PREFIX="${CONDA_ENVS_PATH}/${ENV_NAME}"
  else
    for c in "${HOME}/.conda-hpc"/*/envs "${HOME}/miniforge3/envs" "${HOME}/mambaforge/envs" \
             "${HOME}/micromamba/envs" "${HOME}/miniconda3/envs"; do
      if [ -d "${c}/${ENV_NAME}" ]; then ENV_PREFIX="${c}/${ENV_NAME}"; break; fi
    done
  fi
fi
if [ -z "${ENV_PREFIX}" ] || [ ! -d "${ENV_PREFIX}" ]; then
  echo "[texlive] WARNING: conda environment '${ENV_NAME}' not found; hooks not written." >&2
  echo "[texlive]          Re-run this script after the env exists (or set KGE_ENV_DIR=...)." >&2
  exit 0
fi

mkdir -p "${ENV_PREFIX}/etc/conda/activate.d" "${ENV_PREFIX}/etc/conda/deactivate.d"

cat > "${ENV_PREFIX}/etc/conda/activate.d/zz_texlive.sh" <<EOF
# Added by install_texlive2026.sh: TeX Live for 'mageck count --pdf-report'
export PATH="${TEXLIVE_DIR}/bin:\$PATH"
# conda-forge r-base bakes the build machine's texi2dvi path into Renviron;
# point R at the texi2dvi of this environment instead
export TEXI2DVI="\${CONDA_PREFIX}/bin/texi2dvi"
EOF

cat > "${ENV_PREFIX}/etc/conda/deactivate.d/zz_texlive.sh" <<EOF
# Added by install_texlive2026.sh
export PATH="\${PATH//${TEXLIVE_DIR}/bin:/}"
EOF

echo "[texlive] Activation hooks written for env '${ENV_NAME}' at ${ENV_PREFIX}"
echo "[texlive] Done. 'conda activate ${ENV_NAME}' now provides R + pdflatex + texi2dvi."