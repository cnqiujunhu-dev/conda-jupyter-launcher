#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REQUESTED_ENV=""
DRY_RUN=0
LAUNCHER_VERSION="2026.04.19.19"

CONDA_ROOT=""
CONDA_BIN=""
CONDA_SH=""
CONDA_ACTIVATION_MODE=""

export CONDA_NOTIFY_OUTDATED_CONDA=false

ENV_COUNT=0
ENV_NAMES=()
ENV_PATHS=()
ENV_ACTIVE=()
ENV_BASE=()

COLOR_RESET=""
COLOR_HEADER=""
COLOR_LINE=""
COLOR_TEXT=""
COLOR_NUMBER=""
COLOR_NAME_BG=""
COLOR_NAME_FG=""
COLOR_PATH=""
COLOR_NOTICE=""
COLOR_ERROR=""
COLOR_SUCCESS=""

init_colors() {
    if [[ -t 1 ]]; then
        COLOR_RESET=$'\033[0m'
        COLOR_HEADER=$'\033[36m'
        COLOR_LINE=$'\033[36;2m'
        COLOR_TEXT=$'\033[97m'
        COLOR_NUMBER=$'\033[36m'
        COLOR_NAME_BG=$'\033[46m'
        COLOR_NAME_FG=$'\033[30m'
        COLOR_PATH=$'\033[90m'
        COLOR_NOTICE=$'\033[33m'
        COLOR_ERROR=$'\033[31m'
        COLOR_SUCCESS=$'\033[32m'
    fi
}

print_line() {
    printf "%b%68s%b\n" "$COLOR_LINE" "" "$COLOR_RESET" | tr ' ' '='
}

print_info_line() {
    local label="$1"
    local value="$2"

    printf "%b%-12s%b: %b%s%b\n" "$COLOR_PATH" "$label" "$COLOR_RESET" "$COLOR_TEXT" "$value" "$COLOR_RESET"
}

pause_before_exit() {
    if [[ -t 0 ]]; then
        printf "\nPress Enter to close..."
        read -r _
    fi
}

fail() {
    printf "\n%b%s%b\n" "$COLOR_ERROR" "$1" "$COLOR_RESET"
    pause_before_exit
    exit 1
}

show_header() {
    local title="CONDA JUPYTER LAUNCHER"
    local padding=0

    printf "\033]0;%s\007" "Conda Jupyter Launcher"
    printf "\n"
    print_line
    padding=$(( (68 - ${#title}) / 2 ))
    if (( padding < 0 )); then
        padding=0
    fi
    printf "%b%*s%s%b\n" "$COLOR_HEADER" "$padding" "" "$title" "$COLOR_RESET"
    print_line
    print_info_line "Version" "$LAUNCHER_VERSION"
    print_info_line "Author" "CunCun"
}

normalize_dir() {
    local candidate="$1"
    if [[ -d "$candidate" ]]; then
        (cd "$candidate" && pwd -P)
    fi
}

find_conda_cli_path() {
    local root="$1"

    for candidate in "$root/bin/conda"; do
        if [[ -x "$candidate" ]]; then
            printf "%s\n" "$candidate"
            return 0
        fi
    done

    return 1
}

find_conda_activation_script() {
    local root="$1"

    for candidate in "$root/etc/profile.d/conda.sh" "$root/bin/activate"; do
        if [[ -f "$candidate" ]]; then
            printf "%s\n" "$candidate"
            return 0
        fi
    done

    return 1
}

test_conda_root_layout() {
    local root="$1"

    if find_conda_cli_path "$root" >/dev/null && find_conda_activation_script "$root" >/dev/null; then
        return 0
    fi

    return 1
}

convert_to_conda_root() {
    local candidate="$1"
    local resolved=""
    local parent=""
    local base=""

    [[ -n "$candidate" ]] || return 1
    candidate="${candidate%\"}"
    candidate="${candidate#\"}"
    [[ -e "$candidate" ]] || return 1

    if [[ -d "$candidate" ]]; then
        resolved="$(normalize_dir "$candidate")"
    else
        parent="$(cd "$(dirname "$candidate")" && pwd -P)"
        resolved="$parent/$(basename "$candidate")"
    fi

    if [[ -d "$resolved" ]]; then
        if test_conda_root_layout "$resolved"; then
            printf "%s\n" "$resolved"
            return 0
        fi
        return 1
    fi

    base="$(basename "$resolved")"
    parent="$(dirname "$resolved")"

    case "$base" in
        conda|python)
            if [[ "$(basename "$parent")" == "bin" ]]; then
                resolved="$(dirname "$parent")"
            fi
            ;;
        activate)
            if [[ "$(basename "$parent")" == "bin" ]]; then
                resolved="$(dirname "$parent")"
            fi
            ;;
        conda.sh)
            if [[ "$(basename "$parent")" == "profile.d" ]]; then
                resolved="$(dirname "$(dirname "$parent")")"
            fi
            ;;
    esac

    if [[ "$(basename "$parent")" == "condabin" && "$base" == "conda" ]]; then
        resolved="$(dirname "$parent")"
    fi

    if test_conda_root_layout "$resolved"; then
        printf "%s\n" "$resolved"
        return 0
    fi

    return 1
}

test_conda_installation() {
    local candidate_root="$1"
    local resolved_root=""

    resolved_root="$(convert_to_conda_root "$candidate_root")" || return 1

    local conda_cli=""
    local activate_script=""

    conda_cli="$(find_conda_cli_path "$resolved_root")" || return 1
    activate_script="$(find_conda_activation_script "$resolved_root")" || return 1

    if ! "$conda_cli" env list --json >/dev/null 2>&1; then
        return 1
    fi

    CONDA_ROOT="$resolved_root"
    CONDA_BIN="$conda_cli"
    CONDA_SH="$activate_script"
    if [[ "$(basename "$activate_script")" == "conda.sh" ]]; then
        CONDA_ACTIVATION_MODE="conda_sh"
    else
        CONDA_ACTIVATION_MODE="activate"
    fi
    return 0
}

resolve_conda_from_path() {
    local conda_path=""

    conda_path="$(type -P conda 2>/dev/null || true)"
    if [[ -n "$conda_path" ]] && test_conda_installation "$conda_path"; then
        return 0
    fi

    return 1
}

append_unique_candidate() {
    local candidate="$1"

    [[ -n "$candidate" ]] || return 0
    COMMON_CANDIDATES+=("$candidate")
}

collect_common_conda_candidates() {
    COMMON_CANDIDATES=()

    append_unique_candidate "${CONDA_EXE:-}"
    append_unique_candidate "${CONDA_PREFIX:-}"
    append_unique_candidate "${CONDA_PYTHON_EXE:-}"
    append_unique_candidate "$HOME/anaconda"
    append_unique_candidate "$HOME/anaconda3"
    append_unique_candidate "$HOME/miniconda"
    append_unique_candidate "$HOME/miniconda3"
    append_unique_candidate "$HOME/miniforge3"
    append_unique_candidate "$HOME/mambaforge"
    append_unique_candidate "$HOME/opt/anaconda"
    append_unique_candidate "$HOME/opt/anaconda3"
    append_unique_candidate "$HOME/opt/miniconda"
    append_unique_candidate "$HOME/opt/miniconda3"
    append_unique_candidate "$HOME/opt/miniforge3"
    append_unique_candidate "$HOME/opt/mambaforge"
    append_unique_candidate "/opt/anaconda"
    append_unique_candidate "/opt/anaconda3"
    append_unique_candidate "/opt/miniconda"
    append_unique_candidate "/opt/miniconda3"
    append_unique_candidate "/opt/miniforge3"
    append_unique_candidate "/opt/mambaforge"
    append_unique_candidate "/usr/local/anaconda"
    append_unique_candidate "/usr/local/anaconda3"
    append_unique_candidate "/usr/local/miniconda"
    append_unique_candidate "/usr/local/miniconda3"
    append_unique_candidate "/usr/local/miniforge3"
    append_unique_candidate "/usr/local/mambaforge"
    append_unique_candidate "/opt/homebrew/Caskroom/miniconda"
    append_unique_candidate "/opt/homebrew/Caskroom/miniconda/base"
    append_unique_candidate "/opt/homebrew/Caskroom/miniforge"
    append_unique_candidate "/opt/homebrew/Caskroom/miniforge/base"
    append_unique_candidate "/usr/local/Caskroom/miniconda"
    append_unique_candidate "/usr/local/Caskroom/miniconda/base"
    append_unique_candidate "/usr/local/Caskroom/miniforge"
    append_unique_candidate "/usr/local/Caskroom/miniforge/base"
}

find_local_conda_installation() {
    local candidate=""
    local root=""
    local scan_base=""

    collect_common_conda_candidates
    for candidate in "${COMMON_CANDIDATES[@]}"; do
        if test_conda_installation "$candidate"; then
            return 0
        fi
    done

    for scan_base in "$HOME" "$HOME/opt" "/opt" "/usr/local" "/opt/homebrew/Caskroom" "/usr/local/Caskroom"; do
        [[ -d "$scan_base" ]] || continue

        while IFS= read -r root; do
            [[ -n "$root" ]] || continue
            if test_conda_installation "$root"; then
                return 0
            fi
        done < <(
            find "$scan_base" -maxdepth 3 -type d \
                \( -name "anaconda" -o -name "anaconda3" -o -name "miniconda" -o -name "miniconda3" -o -name "miniforge" -o -name "miniforge3" -o -name "mambaforge" \) \
                2>/dev/null
        )

        while IFS= read -r root; do
            [[ -n "$root" ]] || continue
            if test_conda_installation "$root"; then
                return 0
            fi
        done < <(
            find "$scan_base" -maxdepth 5 -type f \
                \( -name "conda" -o -name "conda.sh" -o -name "activate" \) \
                2>/dev/null
        )
    done

    return 1
}

get_preferred_conda_path_entry() {
    if [[ -d "$CONDA_ROOT/condabin" ]]; then
        printf "%s\n" "$CONDA_ROOT/condabin"
        return 0
    fi

    printf "%s\n" "$CONDA_ROOT/bin"
}

detect_profile_file() {
    local shell_name=""

    shell_name="$(basename "${SHELL:-zsh}")"
    case "$shell_name" in
        zsh)
            printf "%s\n" "$HOME/.zshrc"
            ;;
        bash)
            if [[ -f "$HOME/.bash_profile" || ! -f "$HOME/.profile" ]]; then
                printf "%s\n" "$HOME/.bash_profile"
            else
                printf "%s\n" "$HOME/.profile"
            fi
            ;;
        *)
            printf "%s\n" "$HOME/.zshrc"
            ;;
    esac
}

ensure_conda_in_profile() {
    local profile_file=""
    local marker_begin="# >>> Conda Jupyter Launcher >>>"
    local marker_end="# <<< Conda Jupyter Launcher <<<"

    profile_file="$(detect_profile_file)"

    if [[ -f "$profile_file" ]] && grep -Fq "$marker_begin" "$profile_file"; then
        return 0
    fi

    if (( DRY_RUN )); then
        printf "%bDry run: would append Conda PATH setup to %s%b\n" "$COLOR_NOTICE" "$profile_file" "$COLOR_RESET"
        return 0
    fi

    {
        printf "\n%s\n" "$marker_begin"
        printf "if [ -d \"%s\" ]; then\n" "$(get_preferred_conda_path_entry)"
        printf "    export PATH=\"%s:\$PATH\"\n" "$(get_preferred_conda_path_entry)"
        printf "fi\n"
        printf "%s\n" "$marker_end"
    } >> "$profile_file" || return 1

    printf "%bConda has been added to %s%b\n" "$COLOR_SUCCESS" "$profile_file" "$COLOR_RESET"
    return 0
}

ensure_conda_available() {
    if resolve_conda_from_path; then
        return 0
    fi

    printf "\n%b%s%b\n" "$COLOR_NOTICE" "Conda is not available in PATH. Trying to locate a local installation..." "$COLOR_RESET"

    if ! find_local_conda_installation; then
        fail "No local Conda installation was found. Please install Anaconda or Miniconda first."
    fi

    printf "%bFound local Conda installation: %s%b\n" "$COLOR_NOTICE" "$CONDA_ROOT" "$COLOR_RESET"

    export PATH="$(get_preferred_conda_path_entry):$PATH"

    if ! ensure_conda_in_profile; then
        printf "%bWarning: could not update your shell profile. Continuing with this run only.%b\n" "$COLOR_NOTICE" "$COLOR_RESET"
    fi
}

load_conda_environments() {
    local json_output=""
    local env_name=""
    local env_path=""
    local env_active=""
    local env_base=""

    if ! json_output="$("$CONDA_BIN" env list --json 2>/dev/null)"; then
        fail "Failed to read the conda environment list."
    fi

    ENV_COUNT=0
    ENV_NAMES=()
    ENV_PATHS=()
    ENV_ACTIVE=()
    ENV_BASE=()

    while IFS=$'\t' read -r env_name env_path env_active env_base; do
        [[ -n "$env_name" ]] || continue
        ENV_NAMES+=("$env_name")
        ENV_PATHS+=("$env_path")
        ENV_ACTIVE+=("$env_active")
        ENV_BASE+=("$env_base")
        ENV_COUNT=$((ENV_COUNT + 1))
    done < <(
        printf "%s" "$json_output" | "$CONDA_ROOT/bin/python" -c '
import json
import os
import sys

root = os.path.normpath(sys.argv[1])
data = json.load(sys.stdin)
details = data.get("envs_details") or {}
current_prefix = os.path.normpath(os.environ.get("CONDA_PREFIX", ""))

for path in data.get("envs", []):
    norm_path = os.path.normpath(path)
    detail = details.get(path) or details.get(norm_path) or {}
    name = detail.get("name")
    if not name:
        if norm_path == root:
            name = "base"
        else:
            name = os.path.basename(norm_path.rstrip(os.sep)) or "base"
    active = bool(detail.get("active")) or (current_prefix and current_prefix == norm_path)
    base = bool(detail.get("base")) or (norm_path == root)
    print("\t".join([name, path, "1" if active else "0", "1" if base else "0"]))
' "$CONDA_ROOT"
    )

    return 0
}

ensure_torch_env_exists() {
    local index=0
    local torch_env_path="$CONDA_ROOT/envs/torch_env"
    local create_choice=""

    for ((index = 0; index < ENV_COUNT; index++)); do
        if [[ "${ENV_NAMES[$index]}" == "torch_env" || "${ENV_PATHS[$index]}" == "$torch_env_path" ]]; then
            return 0
        fi
    done

    if (( DRY_RUN )); then
        printf "%b%s%b\n" "$COLOR_NOTICE" "Dry run: would ask whether to create environment 'torch_env' with Python 3.10." "$COLOR_RESET"
        return 0
    fi

    printf "%b%s%b\n" "$COLOR_NOTICE" "Environment 'torch_env' was not found." "$COLOR_RESET"
    while true; do
        printf "Create torch_env now? (y/n): "
        IFS= read -r create_choice

        if [[ "$create_choice" =~ ^[Yy]$ ]]; then
            break
        fi

        if [[ "$create_choice" =~ ^[Nn]$ ]]; then
            printf "%b%s%b\n" "$COLOR_NOTICE" "Skipped creating 'torch_env'." "$COLOR_RESET"
            return 0
        fi

        printf "%b%s%b\n" "$COLOR_NOTICE" "Invalid selection. Please enter y or n." "$COLOR_RESET"
    done

    printf "%b%s%b\n" "$COLOR_NOTICE" "Creating environment 'torch_env' with Python 3.10..." "$COLOR_RESET"
    if ! "$CONDA_BIN" create --yes --name torch_env python=3.10; then
        fail "Failed to create environment 'torch_env'."
    fi

    load_conda_environments
}

select_conda_environment() {
    local index=0
    local max_name_length=0
    local marker=""
    local suffix=""
    local choice=""

    if [[ -n "$REQUESTED_ENV" ]]; then
        for ((index = 0; index < ENV_COUNT; index++)); do
            if [[ "${ENV_NAMES[$index]}" == "$REQUESTED_ENV" || "${ENV_PATHS[$index]}" == "$REQUESTED_ENV" ]]; then
                SELECTED_ENV_NAME="${ENV_NAMES[$index]}"
                SELECTED_ENV_PATH="${ENV_PATHS[$index]}"
                return 0
            fi
        done

        fail "Environment '$REQUESTED_ENV' was not found."
    fi

    printf "\n%b%s%b\n" "$COLOR_TEXT" "Please enter a number to select the corresponding environment" "$COLOR_RESET"
    printf "\n%b%s%b\n" "$COLOR_TEXT" "Available environments" "$COLOR_RESET"
    printf "%b%68s%b\n" "$COLOR_PATH" "" "$COLOR_RESET" | tr ' ' '-'

    for ((index = 0; index < ENV_COUNT; index++)); do
        if [[ "${#ENV_NAMES[$index]}" -gt "$max_name_length" ]]; then
            max_name_length="${#ENV_NAMES[$index]}"
        fi
    done

    DEFAULT_ENV_INDEX=-1

    for ((index = 0; index < ENV_COUNT; index++)); do
        if [[ "${ENV_ACTIVE[$index]}" == "1" ]]; then
            marker=">"
            DEFAULT_ENV_INDEX=$index
        else
            marker=" "
        fi

        printf " %b%s%b " "$COLOR_PATH" "$marker" "$COLOR_RESET"
        printf "%b[%2d]%b " "$COLOR_NUMBER" "$((index + 1))" "$COLOR_RESET"
        printf "%b%b %-*s %b\n" "$COLOR_NAME_BG" "$COLOR_NAME_FG" "$max_name_length" "${ENV_NAMES[$index]}" "$COLOR_RESET"
        printf "      %b%s%b\n\n" "$COLOR_PATH" "${ENV_PATHS[$index]}" "$COLOR_RESET"
    done

    while true; do
        if [[ "$DEFAULT_ENV_INDEX" -ge 0 ]]; then
            printf "Select a number (Enter = %d, q = quit): " "$((DEFAULT_ENV_INDEX + 1))"
        else
            printf "Select a number (q = quit): "
        fi

        IFS= read -r choice

        if [[ -z "$choice" && "$DEFAULT_ENV_INDEX" -ge 0 ]]; then
            SELECTED_ENV_NAME="${ENV_NAMES[$DEFAULT_ENV_INDEX]}"
            SELECTED_ENV_PATH="${ENV_PATHS[$DEFAULT_ENV_INDEX]}"
            return 0
        fi

        if [[ "$choice" =~ ^[Qq]$ ]]; then
            exit 0
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ENV_COUNT )); then
            index=$((choice - 1))
            SELECTED_ENV_NAME="${ENV_NAMES[$index]}"
            SELECTED_ENV_PATH="${ENV_PATHS[$index]}"
            return 0
        fi

        printf "%b%s%b\n" "$COLOR_NOTICE" "Invalid selection. Try again." "$COLOR_RESET"
    done
}

test_python_module_in_environment() {
    local environment_name="$1"
    local module_name="$2"

    "$CONDA_BIN" run -n "$environment_name" python -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('$module_name') else 1)" >/dev/null 2>&1
}

ensure_required_python_packages() {
    local environment_name="$1"
    local labels=("pandas" "scikit-learn" "jupyter notebook" "matplotlib" "torch" "torchvision" "torchaudio")
    local modules=("pandas" "sklearn" "notebook" "matplotlib" "torch" "torchvision" "torchaudio")
    local conda_packages=("pandas" "scikit-learn" "notebook" "matplotlib" "pytorch" "torchvision" "torchaudio")
    local pip_packages=("pandas" "scikit-learn" "notebook" "matplotlib" "torch" "torchvision" "torchaudio")
    local missing_conda_packages=()
    local missing_pip_packages=()
    local missing_labels=()
    local missing_modules=()
    local index=0
    local install_choice=""

    printf "\n%bChecking required packages in environment: %s%b\n" "$COLOR_TEXT" "$environment_name" "$COLOR_RESET"

    for ((index = 0; index < ${#labels[@]}; index++)); do
        printf "%bChecking package: %s%b\n" "$COLOR_PATH" "${labels[$index]}" "$COLOR_RESET"

        if test_python_module_in_environment "$environment_name" "${modules[$index]}"; then
            printf "%bDetected package: %s%b\n" "$COLOR_SUCCESS" "${labels[$index]}" "$COLOR_RESET"
            continue
        fi

        printf "%bPackage not found: %s%b\n" "$COLOR_NOTICE" "${labels[$index]}" "$COLOR_RESET"
        missing_conda_packages+=("${conda_packages[$index]}")
        missing_pip_packages+=("${pip_packages[$index]}")
        missing_labels+=("${labels[$index]}")
        missing_modules+=("${modules[$index]}")
    done

    if [[ "${#missing_conda_packages[@]}" -eq 0 ]]; then
        return 0
    fi

    if (( DRY_RUN )); then
        printf "%bDry run: would ask whether to install missing packages: %s%b\n" "$COLOR_NOTICE" "$(IFS=', '; printf '%s' "${missing_labels[*]}")" "$COLOR_RESET"
        return 0
    fi

    while true; do
        printf "Install missing packages now? (y/n) [%s]: " "$(IFS=', '; printf '%s' "${missing_labels[*]}")"
        IFS= read -r install_choice

        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            break
        fi

        if [[ "$install_choice" =~ ^[Nn]$ ]]; then
            printf "%b%s%b\n" "$COLOR_NOTICE" "Skipped installing missing packages." "$COLOR_RESET"
            return 0
        fi

        printf "%b%s%b\n" "$COLOR_NOTICE" "Invalid selection. Please enter y or n." "$COLOR_RESET"
    done

    printf "%bDownloading and installing missing packages with conda: %s%b\n" "$COLOR_NOTICE" "$(IFS=', '; printf '%s' "${missing_conda_packages[*]}")" "$COLOR_RESET"
    if ! "$CONDA_BIN" install -n "$environment_name" --yes "${missing_conda_packages[@]}"; then
        printf "%bConda install failed. Downloading and installing with pip instead...%b\n" "$COLOR_NOTICE" "$COLOR_RESET"
        if ! "$CONDA_BIN" run -n "$environment_name" python -m pip install "${missing_pip_packages[@]}"; then
            fail "Failed to install required packages: $(IFS=', '; printf '%s' "${missing_labels[*]}")"
        fi
    fi

    for ((index = 0; index < ${#missing_labels[@]}; index++)); do
        if test_python_module_in_environment "$environment_name" "${missing_modules[$index]}"; then
            printf "%bDetected package: %s%b\n" "$COLOR_SUCCESS" "${missing_labels[$index]}" "$COLOR_RESET"
            continue
        fi

        fail "Package verification failed after installation: ${missing_labels[$index]}"
    done
}

start_conda_jupyter() {
    local environment_name="$1"
    local preview_command=""

    if [[ "$CONDA_ACTIVATION_MODE" == "activate" ]]; then
        preview_command="source \"$CONDA_SH\" \"$environment_name\" && cd \"$SCRIPT_DIR\" && python -m notebook || jupyter notebook"
    else
        preview_command="source \"$CONDA_SH\" && conda activate \"$environment_name\" && cd \"$SCRIPT_DIR\" && python -m notebook || jupyter notebook"
    fi

    printf "\n%bSelected environment: %s%b\n" "$COLOR_SUCCESS" "$environment_name" "$COLOR_RESET"
    printf "%bWorking directory: %s%b\n" "$COLOR_PATH" "$SCRIPT_DIR" "$COLOR_RESET"
    printf "%b%s%b\n" "$COLOR_NOTICE" "Waiting for Jupyter Notebook to open..." "$COLOR_RESET"

    if (( DRY_RUN )); then
        printf "%bPreview command: %s%b\n" "$COLOR_PATH" "$preview_command" "$COLOR_RESET"
        return 0
    fi

    if [[ "$CONDA_ACTIVATION_MODE" == "activate" ]]; then
        if ! source "$CONDA_SH" "$environment_name"; then
            fail "Failed to activate Conda environment '$environment_name' from $CONDA_SH."
        fi
    else
        if ! source "$CONDA_SH"; then
            fail "Failed to initialize Conda from $CONDA_SH."
        fi

        if ! conda activate "$environment_name"; then
            fail "Failed to activate Conda environment '$environment_name'."
        fi
    fi

    if ! cd "$SCRIPT_DIR"; then
        fail "Failed to enter the project directory."
    fi

    if ! python -m notebook; then
        if ! jupyter notebook; then
            fail "Failed to start Jupyter Notebook in '$environment_name'. Install notebook or jupyter in that environment and try again."
        fi
    fi

    pause_before_exit
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -EnvName|--env-name)
                if [[ $# -lt 2 ]]; then
                    fail "Missing value after $1."
                fi
                REQUESTED_ENV="$2"
                shift 2
                ;;
            -DryRun|--dry-run)
                DRY_RUN=1
                shift
                ;;
            *)
                shift
                ;;
        esac
    done
}

main() {
    init_colors
    parse_args "$@"
    show_header
    ensure_conda_available
    load_conda_environments
    ensure_torch_env_exists
    select_conda_environment
    ensure_required_python_packages "$SELECTED_ENV_NAME"

    printf "\n%bLaunching Jupyter Notebook with conda environment: %s%b\n" "$COLOR_SUCCESS" "$SELECTED_ENV_NAME" "$COLOR_RESET"
    printf "%bWorking directory: %s%b\n" "$COLOR_PATH" "$SCRIPT_DIR" "$COLOR_RESET"

    start_conda_jupyter "$SELECTED_ENV_NAME"
}

main "$@"
