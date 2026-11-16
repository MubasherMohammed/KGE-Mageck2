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
# KGE / MAGeCK2 Installer — PORTABLE
#
# Creates a working MAGeCK2 environment (mageckenv2) end-to-end from a single
# command on ANY machine (Arrhenius HPC and local Linux/macOS), with NO
# module-system requirement:
#
#   bash   install_mageck2.sh [env_name]     # interactive / login node
#   sbatch install_mageck2.sh [env_name]     # SLURM job (cd into this folder first)
#
# The installer:
#   1. Locates conda: conda on PATH -> existing local Miniconda/Miniforge/
#      Mambaforge/Micromamba -> (best-effort) Lmod module -> downloads a
#      platform-matched Miniconda into $HOME/miniconda3 (bash + zsh init).
#   2. Creates a conda env with Python + R + LaTeX + a C/C++ compiler (portable
#      core). mageck2 is NOT in the env spec.
#   3. Installs MAGeCK2 from git via pip (compiles the bundled RRA + GSEA C++
#      helpers using the env's make + compiler).
#   4. Overlays the KGE-modified MAGeCK2 source from ./mageck2/ (adds
#      --html-report + a UMI count figure to the reports).
#   5. Ensures TeX Live is available for `mageck2 count/test --pdf-report`.
#   6. Verifies the installation (MAGeCK2, RRA/GSEA binaries, HTML report, R,
#      pdflatex).
#
# Environment overrides:
#   ENV_NAME=mageckenv2        environment name (default: mageckenv2)  [also $1]
#   ENV_PREFIX=                if set, envs -> $ENV_PREFIX/conda_envs, pkgs ->
#                              $ENV_PREFIX/conda_pkgs. If empty (default), conda's
#                              native location is used — this makes the env "fit
#                              the OS" on any machine.
#   MAGECK2_GIT_URL=           default https://github.com/davidliwei/mageck2.git@fb2f9083
#                              (pinned to the commit the ./mageck2/ overlay was
#                              built against; override at your own risk)
#   TEXLIVE_DIR=               where TeX Live lives (default: $HOME/texlive2026 on
#                              macOS, <script dir>/texlive2026 on Linux)
#   KGE2_FORCE_RECREATE=1      remove & recreate the env even in batch mode
#   KGE2_FORCE_PIP=1           force re-running `pip install git+mageck2`
#   KGE2_SKIP_TEXLIVE=1        skip the TeX Live step (no PDF reports)
#
set -euo pipefail

ENV_NAME="${1:-mageckenv2}"
ENV_PREFIX="${ENV_PREFIX:-}"
# Pinned commit: the KGE overlay (./mageck2/) patches files from exactly this
# revision, so a moving git HEAD could break the overlay's context.
MAGECK2_GIT_URL="${MAGECK2_GIT_URL:-https://github.com/davidliwei/mageck2.git@fb2f9083eef258695e0d3a7ef2690e18fd851768}"

# --- Resolve the directory containing this script + the companion files ---
# Under sbatch, BASH_SOURCE resolves into SLURM's per-job dir which lacks the
# companion files, so prefer SLURM_SUBMIT_DIR (cd into this folder before
# submitting).
if [ -n "${SLURM_SUBMIT_DIR:-}" ]; then
    SCRIPT_DIR="${SLURM_SUBMIT_DIR}"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

for f in environment_mageck2.yml install_texlive2026.sh; do
    if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
        echo "ERROR: ${f} not found next to this script (${SCRIPT_DIR})."
        echo "  cd into the folder that also contains ${f} and mageck2/, then re-run."
        exit 1
    fi
done
if [ ! -d "${SCRIPT_DIR}/mageck2" ]; then
    echo "ERROR: mageck2/ source overlay not found at ${SCRIPT_DIR}/mageck2/"; exit 1
fi

# --- Platform detection (OS + arch) for the Miniconda download ---
OS="$(uname -s)"; ARCH="$(uname -m)"
case "${OS}" in
    Linux)  OS_TAG="Linux"  ;;
    Darwin) OS_TAG="MacOSX" ;;
    *)      echo "ERROR: unsupported OS: ${OS}"; exit 1 ;;
esac
case "${ARCH}" in
    x86_64)            MARCH_TAG="x86_64" ;;
    ppc64le)           MARCH_TAG="ppc64le" ;;
    aarch64|arm64)     MARCH_TAG="aarch64"; [ "${OS_TAG}" = "MacOSX" ] && MARCH_TAG="arm64" ;;
    *)                 echo "ERROR: unsupported architecture: ${ARCH}"; exit 1 ;;
esac
MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-latest-${OS_TAG}-${MARCH_TAG}.sh"

# TeX Live location: on macOS default to the user's home dir. The
# Conda_setup_Mageck2 folder is often copied over from the HPC where
# ./texlive2026 is a symlink to a Linux-built tree that cannot run on macOS.
if [ "${OS_TAG}" = "MacOSX" ]; then
    TEXLIVE_DIR="${TEXLIVE_DIR:-${HOME}/texlive2026}"
else
    TEXLIVE_DIR="${TEXLIVE_DIR:-${SCRIPT_DIR}/texlive2026}"
fi

echo "============================================"
echo "  KGE / MAGeCK2 Installer (portable)"
echo "  host: $(hostname 2>/dev/null || echo local)   user: $(whoami 2>/dev/null || echo unknown)"
echo "  platform: ${OS_TAG}-${ARCH}   miniconda asset: Miniconda3-latest-${OS_TAG}-${MARCH_TAG}.sh"
echo "  env name  : ${ENV_NAME}   texlive: ${TEXLIVE_DIR}"
echo "  env loc   : ${ENV_PREFIX:-<conda default>}"
echo "  mageck2   : ${MAGECK2_GIT_URL}"
echo "============================================"
echo ""

_has_conda() { command -v conda &> /dev/null; }

# ---- Step 1: Locate conda (PATH -> local install -> module -> download) ----
echo "[1/6] Locating conda..."
has_conda=false

# 1a. conda already on PATH (e.g. module preloaded or shell init).
if _has_conda; then
    has_conda=true
    echo "  conda already on PATH."
fi

# 1b. existing local install in well-known locations.
if ! $has_conda; then
    for d in "${HOME}/miniconda3" "${HOME}/miniforge3" "${HOME}/mambaforge" \
             "${HOME}/micromamba" "${HOME}/anaconda3"; do
        if [ -x "${d}/bin/conda" ]; then
            eval "$("${d}/bin/conda" shell.bash hook)"
            has_conda=true
            echo "  Found existing conda at ${d}"
            break
        fi
    done
fi

# 1c. best-effort Lmod / Environment-Modules load (HPC niceness; NEVER fatal).
if ! $has_conda; then
    if command -v ml &> /dev/null || command -v module &> /dev/null; then
        for mod in "Miniforge/26.3.2-2-eb" "Miniforge/recommendation" "Miniforge3/26.3.2-2" \
                   "miniforge" "Miniforge3" "Miniforge"; do
            ml "${mod}" 2>/dev/null || module load "${mod}" 2>/dev/null || true
            if _has_conda; then has_conda=true; echo "  Loaded module: ${mod}"; break; fi
        done
    fi
fi

# 1d. fallback: download a platform-matched Miniconda.
if ! $has_conda; then
    MINICONDA_DIR="${HOME}/miniconda3"
    echo "  No conda found — downloading Miniconda (${MINICONDA_URL}) ..."
    curl -fsSL -o /tmp/miniconda_installer.sh "${MINICONDA_URL}"
    chmod +x /tmp/miniconda_installer.sh
    echo "  Installing Miniconda to ${MINICONDA_DIR} ..."
    bash /tmp/miniconda_installer.sh -b -p "${MINICONDA_DIR}"
    rm -f /tmp/miniconda_installer.sh
    eval "$("${MINICONDA_DIR}/bin/conda" shell.bash hook)"
    conda init bash 2>/dev/null || true
    conda init zsh  2>/dev/null || true
    has_conda=true
fi

if ! _has_conda; then
    echo "ERROR: conda still not available. Open a new shell and re-run."
    exit 1
fi
echo "  conda base: $(conda info --base)"

# Point envs/pkgs into ENV_PREFIX only when the user asked for a custom
# location; otherwise use conda's native locations (portable default).
if [ -n "${ENV_PREFIX}" ]; then
    export CONDA_ENVS_PATH="${ENV_PREFIX}/conda_envs"
    export CONDA_PKGS_DIRS="${ENV_PREFIX}/conda_pkgs"
    mkdir -p "${CONDA_ENVS_PATH}" "${CONDA_PKGS_DIRS}"
    echo "  envs: ${CONDA_ENVS_PATH}   pkgs: ${CONDA_PKGS_DIRS}"
else
    ENV_DIR_RESOLVED="$(conda config --show envs_dirs 2>/dev/null | awk '/^ *- /{sub(/^ *- /,""); print; exit}')"
    echo "  envs: conda default (${ENV_DIR_RESOLVED:-<base>/envs})   pkgs: conda default"
fi

env_exists() { conda env list 2>/dev/null | awk '{print $1}' | grep -qx "${ENV_NAME}"; }

# Robust removal: `conda env remove` can hang / leave a partial tree on some
# NFS mounts, so also rm -rf the resolved directory if it still exists.
remove_env() {
    conda env remove -n "${ENV_NAME}" -y 2>/dev/null || true
    local d
    d="$(conda env list 2>/dev/null | awk -v e="${ENV_NAME}" '$1==e {print $NF}' | head -n1 || true)"
    if [ -n "${d}" ] && [ -d "${d}" ]; then rm -rf "${d}" 2>/dev/null || true; fi
}

# ---- Step 2: Create the conda environment (portable core) ----
echo "[2/6] Creating conda environment '${ENV_NAME}' (Python + R + LaTeX + C/C++ toolchain)..."
if env_exists; then
    echo "  Environment '${ENV_NAME}' already exists."
    if [ "${KGE2_FORCE_RECREATE:-0}" = "1" ]; then
        echo "  KGE2_FORCE_RECREATE=1 — removing and recreating."
        remove_env
    elif [ -t 0 ]; then
        read -p "  Remove and recreate? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then remove_env; else echo "  Keeping existing environment."; fi
    else
        echo "  Non-interactive (batch): keeping existing environment."
        echo "  Set KGE2_FORCE_RECREATE=1 to recreate."
    fi
fi
if ! env_exists; then
    conda env create -f "${SCRIPT_DIR}/environment_mageck2.yml" -n "${ENV_NAME}"
fi

# ---- Step 3: Install MAGeCK2 from git via pip (compiles RRA + GSEA C++) ----
echo "[3/6] Installing MAGeCK2 from git via pip ..."
# python -I (isolated) keeps cwd off sys.path: without it, running the
# installer from this folder would "import" the ./mageck2/ overlay directory
# as a namespace package and skip the pip install entirely.
if [ "${KGE2_FORCE_PIP:-0}" = "1" ] || ! conda run -n "${ENV_NAME}" python -I -c "import mageck2" 2>/dev/null; then
    echo "  pip install git+${MAGECK2_GIT_URL}"
    echo "  (this compiles the bundled RRA + mageckGSEA C++ helpers with make + c++)"
    conda run -n "${ENV_NAME}" pip install --upgrade "git+${MAGECK2_GIT_URL}" \
        > /tmp/kge2_pip.log 2>&1 || {
            echo "  ERROR: pip install of mageck2 failed. Last lines of /tmp/kge2_pip.log:"
            tail -n 20 /tmp/kge2_pip.log 2>/dev/null || true
            exit 1
        }
    echo "  mageck2: OK"
else
    echo "  mageck2 already installed — skipping pip (set KGE2_FORCE_PIP=1 to reinstall)."
fi

# ---- Step 4: Overlay the KGE-modified source (adds --html-report + UMI figure) ----
echo "[4/6] Installing KGE modifications (HTML report + UMI figure)..."
SITE_PACKAGES="$(conda run -n "${ENV_NAME}" python -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null || true)"
if [ -z "${SITE_PACKAGES}" ] || [ ! -d "${SITE_PACKAGES}" ]; then
    echo "  conda run did not return site-packages; trying activation..."
    eval "$(conda shell.bash hook)"
    # set +u: some conda-forge activation hooks (e.g. cctools_osx-arm64)
    # reference bare $VAR, which is fatal under set -u (conda/conda#9966).
    # The compiler vars those hooks set are irrelevant to this probe.
    set +u
    conda activate "${ENV_NAME}" 2>/dev/null || true
    set -u
    SITE_PACKAGES="$(python -c 'import site; print(site.getsitepackages()[0])' 2>/dev/null || true)"
fi
MAGECK2_DIR="${SITE_PACKAGES:-/nonexistent}/mageck2"
if [ ! -d "${MAGECK2_DIR}" ]; then
    echo "ERROR: mageck2 package not found (site-packages: '${SITE_PACKAGES:-none}')."
    echo "  The pip install (step 3) may have failed. Check /tmp/kge2_pip.log."
    exit 1
fi
echo "  Found: ${MAGECK2_DIR}"
for ext in py gmt txt Rnw Rmd RTemplate; do
    for f in "${SCRIPT_DIR}"/mageck2/*.${ext}; do
        [ -e "${f}" ] || continue
        # Delete-then-copy (NOT a plain cp): env files are hard links into the
        # conda package cache; copying over them in place would rewrite the
        # shared cache inode and corrupt it. Done explicitly because macOS
        # BSD cp has no --remove-destination flag.
        rm -f "${MAGECK2_DIR}/$(basename "${f}")"
        cp "${f}" "${MAGECK2_DIR}/"
    done
done
rm -rf "${MAGECK2_DIR}/__pycache__"
echo "  Overlaid KGE source into ${MAGECK2_DIR}"

# ---- Step 5: TeX Live for --pdf-report (idempotent, non-fatal) ----
# Resolve the env dir HERE (where `conda` is available) and hand it to the
# helper via KGE_ENV_DIR, since the helper runs in a child shell that does not
# inherit the `conda` shell function.
RESOLVED_ENV_DIR="$(conda env list 2>/dev/null | awk -v e="${ENV_NAME}" '$1==e {print $NF}' | head -n1 || true)"

if [ "${KGE2_SKIP_TEXLIVE:-0}" != "1" ]; then
    # Guard against a TeX tree copied from another platform: a Linux-built
    # tree (e.g. the shared ./texlive2026) has its executable bits set but
    # cannot run on macOS. The helper's idempotency check would then "reuse"
    # it and silently break --pdf-report, so verify it runs FIRST.
    if [ -e "${TEXLIVE_DIR}/bin/pdflatex" ] || ls "${TEXLIVE_DIR}"/bin/*/pdflatex > /dev/null 2>&1; then
        if ! "${TEXLIVE_DIR}/bin/pdflatex" --version > /dev/null 2>&1; then
            echo "ERROR: ${TEXLIVE_DIR}/bin/pdflatex exists but does not run on this machine"
            echo "  (a TeX tree copied from another OS/arch is not usable here)."
            echo "  Pick another TEXLIVE_DIR (default on macOS: ${HOME}/texlive2026),"
            echo "  or delete the unusable tree and re-run."
            exit 1
        fi
    fi

    echo "[texlive] Ensuring TeX Live for --pdf-report (idempotent) at ${TEXLIVE_DIR}..."
    # The install-tl installer is a Perl script and modern macOS no longer
    # ships /usr/bin/perl by default — prepend the env's bin dir (r-base pulls
    # in perl from conda-forge) so install-tl finds a working interpreter.
    HELPER_PATH="${PATH}"
    if [ -n "${RESOLVED_ENV_DIR}" ] && [ -d "${RESOLVED_ENV_DIR}/bin" ]; then
        HELPER_PATH="${RESOLVED_ENV_DIR}/bin:${PATH}"
        if [ ! -x "${RESOLVED_ENV_DIR}/bin/perl" ]; then
            echo "  NOTE: env perl not found. If the TeX Live download fails to start,"
            echo "        run: xcode-select --install   (provides /usr/bin/perl)"
        fi
    fi
    if CONDA_ENV="${ENV_NAME}" KGE_ENV_DIR="${RESOLVED_ENV_DIR}" \
        TEXLIVE_DIR="${TEXLIVE_DIR}" PATH="${HELPER_PATH}" \
        bash "${SCRIPT_DIR}/install_texlive2026.sh"; then
        echo "  TeX Live: OK"
    else
        echo "  TeX Live: FAILED — 'mageck2 count/test --pdf-report' will not produce PDFs."
    fi
else
    echo "  TeX Live: skipped (KGE2_SKIP_TEXLIVE=1)."
fi

# ---- Step 6: Verify ----
echo "[6/6] Verifying installation..."
if ! conda run -n "${ENV_NAME}" python -c "
from mageck2.version import __version__
from mageck2.htmlReport import mageck_report_main
import plotly
import decoupler
print(f'  MAGeCK2 version:   {__version__}')
print(f'  Plotly version:    {plotly.__version__}')
print(f'  Decoupler version: {decoupler.__version__}')
print('  HTML report:       OK (mageck2.htmlReport.mageck_report_main)')
" 2>/dev/null; then
    echo "  ERROR: MAGeCK2 import verification failed."
    exit 1
fi

# The compiled C++ helpers (RRA, mageckGSEA) must be on the env PATH.
for tool in RRA mageckGSEA; do
    if conda run -n "${ENV_NAME}" bash -c "command -v ${tool} >/dev/null 2>&1" 2>/dev/null; then
        echo "  ${tool}: present (compiled C++ helper)"
    else
        echo "  ${tool}: NOT found — mageck2 pathway/QC steps may fail."
    fi
done

# CLI smoke test.
if conda run -n "${ENV_NAME}" bash -c "mageck2 count --help >/dev/null 2>&1"; then
    echo "  CLI:             mageck2 count --help OK"
fi

# PDF-report toolchain (R + pdflatex). Prefer the activated PATH (proves the
# TeX hook works end-to-end); fall back to the known TeX tree.
RVER="$(conda run -n "${ENV_NAME}" Rscript -e 'cat(R.version.string)' 2>/dev/null | tail -n1 || true)"
[ -n "${RVER}" ] && echo "  R:                 ${RVER}"
PDX_BIN="${TEXLIVE_DIR}/bin/pdflatex"
if conda run -n "${ENV_NAME}" bash -c 'command -v pdflatex >/dev/null 2>&1' 2>/dev/null; then
    echo "  pdflatex:          $(conda run -n "${ENV_NAME}" bash -c 'pdflatex --version' 2>/dev/null | head -n1)  (on activated PATH)"
elif [ -x "${PDX_BIN}" ]; then
    echo "  pdflatex:          $("${PDX_BIN}" --version | head -n1)  (via ${PDX_BIN})"
else
    echo "  pdflatex:          NOT found — PDF reports will fail (re-run the TeX Live step)"
fi

echo ""
echo "============================================"
echo "  Installation complete!"
echo "============================================"
echo ""
echo "  To use it (if you just installed Miniconda, open a NEW shell first, or"
echo "  run: source ~/.bashrc):"
echo ""
echo "      conda activate ${ENV_NAME}"
echo ""
echo "  MAGeCK2 (PDF + HTML reports, UMI-aware counting):"
echo "      mageck2 count -l library.csv -n demo --fastq R1a R1b ... --fastq-2 R2a R2b ... \\"
echo "                  --umi auto --sample-label A,B --pdf-report --html-report"
echo "      mageck2 test  -k demo.count.txt -t treat -c ctrl -n demo \\"
echo "                  --norm-method none --pdf-report --html-report"
echo ""