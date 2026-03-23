#!/usr/bin/env bash
# ==============================================================================
# ECE Lab Deployment Script
# ==============================================================================
# Automates the installation of Elastic Cloud Enterprise (ECE) on GCP instances
# using Terraform for infrastructure provisioning and Ansible for configuration.
#
# Supports single-node and small (3-node) deployments across multiple OS/container
# runtime combinations. All version and OS data is defined in the 'vars' file.
#
# Usage:
#   ./deploy.sh              # Interactive deployment
#   ./deploy.sh --debug      # Deploy with debug output
#   ./deploy.sh cleanup      # Destroy all resources
#   ./deploy.sh find         # Show existing instances
#
# Compatible with: Linux, macOS, WSL
# ==============================================================================

set -euo pipefail

# --- Constants ---------------------------------------------------------------
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly ANSIBLE_VERSION="9.8.0"
readonly SSH_MAX_RETRIES=30
readonly SSH_RETRY_DELAY=15

# --- Load Configuration -----------------------------------------------------
unset installtype version os 2>/dev/null || true
# shellcheck source=vars
source "${SCRIPT_DIR}/vars"

# --- Platform Detection ------------------------------------------------------
detect_platform() {
  case "$(uname -s)" in
    Linux*)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        PLATFORM="wsl"
      else
        PLATFORM="linux"
      fi
      ;;
    Darwin*) PLATFORM="macos" ;;
    *)       PLATFORM="unknown" ;;
  esac
  readonly PLATFORM
}
detect_platform

# --- Username (truncated to 10 chars for GCP firewall name limits) -----------
readonly USERNAME="$(whoami | tr -cd '[:alnum:]' | cut -c 1-10)"

# --- Timer (convert MAX_RUN_DAYS to seconds) ---------------------------------
readonly TIMER=$(( MAX_RUN_DAYS * 24 * 60 * 60 ))

# --- Color Support -----------------------------------------------------------
setup_colors() {
  if [[ "${FORCE_COLOR:-0}" == "1" ]] || { [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; }; then
    RED=$'\033[31m'
    YELLOW=$'\033[33m'
    GREEN=$'\033[32m'
    BLUE=$'\033[36m'
    RESET=$'\033[0m'
  else
    RED="" YELLOW="" GREEN="" BLUE="" RESET=""
  fi
}
setup_colors

# --- Logging -----------------------------------------------------------------
log_info()  { echo "${GREEN}[INFO]${RESET}  $*"; }
log_warn()  { echo "${YELLOW}[WARN]${RESET}  $*"; }
log_error() { echo "${RED}[ERROR]${RESET} $*" >&2; }
log_debug() { [[ "${DEBUG:-0}" -eq 1 ]] && echo "${BLUE}[DEBUG]${RESET} $*" || true; }

# --- Debug & Argument Parsing ------------------------------------------------
DEBUG=0
CLEANUP_MODE=0
FIND_MODE=0

for arg in "$@"; do
  case "$arg" in
    --debug)        DEBUG=1; export TF_LOG=DEBUG TF_LOG_PATH="terraform_debug.log"; set -x ;;
    cleanup|delete) CLEANUP_MODE=1 ;;
    find|info)      FIND_MODE=1 ;;
  esac
done

# Suppress stderr in non-debug mode
run_cmd() {
  if [[ "${DEBUG}" -eq 1 ]]; then
    "$@"
  else
    "$@" 2>/dev/null
  fi
}

# --- Log File Cleanup --------------------------------------------------------
for _logfile in ecelab.log eceinfo.txt terraform.log terraform_debug.log; do
  [[ -f "$_logfile" ]] && : > "$_logfile" || true
done

# --- Version Comparison Utility ----------------------------------------------
version_to_int() {
  echo "$@" | awk -F. '{ printf("%d%02d%02d%02d\n", $1,$2,$3,$4); }'
}

# ==============================================================================
# Cleanup Functions
# ==============================================================================

cleanup_terraform_files() {
  log_info "Cleaning up local Terraform files..."
  rm -rf .terraform 2>/dev/null || true
  rm -f .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup \
        .terraform.tfstate.lock.info terraform.tfvars main.tf 2>/dev/null || true
  log_info "  Terraform cache, state, and lock files removed."
}

cleanup_gcloud() {
  local prefix="${USERNAME}-ecelab"
  local fw="support-lab-us-ecelab-rules-allow-external-inbound-${USERNAME}"
  local found

  # Instances
  found=$(gcloud compute instances list --project="$PROJECT_ID" \
    --filter="name:${prefix}" --format="value(name,zone)" -q 2>/dev/null) || true

  if [[ -n "$found" ]]; then
    log_info "Deleting instances..."
    while IFS=$'\t' read -r name zone; do
      [[ -z "$name" ]] && continue
      log_info "  ${name} (${zone})"
      gcloud compute instances delete "$name" --zone="$zone" \
        --project="$PROJECT_ID" -q 2>/dev/null \
        && log_info "    deleted." \
        || log_warn "    failed to delete ${name} - may need manual cleanup."
    done <<< "$found"
  else
    log_info "Instances: none found matching ${BLUE}${prefix}*${RESET}"
  fi

  # Disks (may outlive VMs when instance_termination_action is DELETE)
  found=$(gcloud compute disks list --project="$PROJECT_ID" \
    --filter="name:${prefix}" --format="value(name,zone)" -q 2>/dev/null) || true

  if [[ -n "$found" ]]; then
    log_info "Deleting disks..."
    while IFS=$'\t' read -r name zone; do
      [[ -z "$name" ]] && continue
      log_info "  ${name} (${zone})"
      gcloud compute disks delete "$name" --zone="$zone" \
        --project="$PROJECT_ID" -q 2>/dev/null \
        && log_info "    deleted." \
        || log_warn "    failed to delete ${name} - may need manual cleanup."
    done <<< "$found"
  else
    log_info "Disks:     none found matching ${BLUE}${prefix}*${RESET}"
  fi

  # Firewall rule
  if gcloud compute firewall-rules describe "$fw" \
       --project="$PROJECT_ID" -q &>/dev/null 2>&1; then
    log_info "Deleting firewall rule ${BLUE}${fw}${RESET}..."
    gcloud compute firewall-rules delete "$fw" --project="$PROJECT_ID" -q 2>/dev/null \
      && log_info "  deleted." \
      || log_warn "  failed to delete firewall rule - may need manual cleanup."
  else
    log_info "Firewall:  ${BLUE}${fw}${RESET} not found"
  fi
}

run_cleanup() {
  echo ""
  log_info "Starting cleanup of ${RED}${USERNAME}-ecelab${RESET} resources..."
  echo ""

  if [[ -f "main.tf" ]] && [[ -f "terraform.tfstate" || -d ".terraform" ]]; then
    log_info "Attempting ${BLUE}terraform destroy${RESET}..."
    if terraform init -reconfigure &>/dev/null && \
       terraform destroy -auto-approve -no-color &>/dev/null; then
      log_info "Terraform destroy succeeded."
    else
      log_warn "Terraform destroy failed - running gcloud cleanup for each resource type."
      echo ""
      cleanup_gcloud
    fi
  else
    log_info "No Terraform state found - running gcloud cleanup for each resource type."
    echo ""
    cleanup_gcloud
  fi

  echo ""
  cleanup_terraform_files
  echo ""
  log_info "Cleanup complete. Run ${BLUE}./${SCRIPT_NAME}${RESET} to deploy fresh."
}

# --- Handle cleanup mode early -----------------------------------------------
if [[ "${CLEANUP_MODE}" -eq 1 ]]; then
  echo -n "This is a destructive change (Y/n): "
  read -r response
  response="$(echo "$response" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$response" || "$response" == "y" ]]; then
    echo "Proceeding with delete..."
    run_cleanup
    exit 0
  else
    echo "Operation canceled."
    exit 1
  fi
fi

# ==============================================================================
# Find Instances
# ==============================================================================

find_instances() {
  local instance_count
  instance_count=$(gcloud compute instances list --project "${PROJECT_ID}" \
    --filter="name:${USERNAME}-ecelab" --format="value(name)" -q 2>/dev/null | wc -l)

  if [[ "$instance_count" -gt 0 ]]; then
    {
      echo ""
      gcloud compute instances list --project "${PROJECT_ID}" \
        --filter="name:${USERNAME}-ecelab" \
        --format="table[box](name:sort=1, zone.basename(), machineType.basename():label=\"MACHINE TYPE\", networkInterfaces[0].networkIP:label=\"INTERNAL IP\", networkInterfaces[0].accessConfigs[0].natIP:label=\"PUBLIC IP\", disks[0].licenses[0].basename():label=\"OS\", status)" -q
      echo ""
      echo "SSH: ${BLUE}gcloud compute ssh NAME [--zone ZONE] [--project ${PROJECT_ID}]${RESET}"
      echo "     ${BLUE}ssh -i ~/.ssh/google_compute_engine USERNAME@PUBLICIP${RESET}"
      echo ""
      if [[ -n "${version:-}" ]]; then
        echo "ECE version: ${version}"
      fi
      echo "GUI: Adminconsole    https://<ANY PUBLIC IP>:12443"
      if [[ -f "bootstrap-secrets.local.json" ]]; then
        echo "GUI: admin password: $(jq -r .adminconsole_root_password bootstrap-secrets.local.json 2>/dev/null || echo 'N/A')"
      fi
      echo ""
    } | tee eceinfo.txt
  else
    log_warn "No instances found"
  fi
}

# --- Handle find mode --------------------------------------------------------
if [[ "${FIND_MODE}" -eq 1 ]]; then
  find_instances
  exit 0
fi

# ==============================================================================
# Prerequisite Checks
# ==============================================================================

check_for_updates() {
  if ! git rev-parse --git-dir &>/dev/null; then
    return 0
  fi
  git fetch origin &>/dev/null || return 0
  local changed_files
  changed_files=$(git diff --name-only origin/main 2>/dev/null | grep -vE '^vars$') || true
  if [[ -n "$changed_files" ]]; then
    log_warn "Updates available for the following files:"
    echo "$changed_files"
    log_warn "Please run ${BLUE}git pull${RESET} to update."
    echo ""
  fi
}

check_required_tool() {
  local cmd="$1"
  local msg="${2:-${cmd} is not installed.}"
  if ! command -v "$cmd" &>/dev/null; then
    log_error "$msg"
    exit 1
  fi
}

check_project_id() {
  if [[ -z "${PROJECT_ID:-}" ]]; then
    log_error "${BLUE}PROJECT_ID${RESET} is not set in ${BLUE}vars${RESET}. Please configure it first."
    exit 1
  fi
}

check_gcloud() {
  check_required_tool "gcloud" \
    "gcloud command is not available. Install: https://cloud.google.com/sdk/docs/install"
  local default_project
  default_project="$(gcloud config get-value project --quiet 2>/dev/null)"
  if [[ -z "$default_project" ]]; then
    log_error "gcloud is not configured with a default project. Run: gcloud init"
    exit 1
  fi
}

check_python() {
  if command -v python3 &>/dev/null; then
    PYTHON_BIN="python3"
  elif command -v python &>/dev/null && \
       [[ "$(python --version 2>&1 | awk '{print $2}' | cut -d. -f1)" -ge 3 ]]; then
    PYTHON_BIN="python"
  else
    log_error "Python 3 is required but not found."
    exit 1
  fi
}

check_pip() {
  if command -v pip3 &>/dev/null; then
    PIP_BIN="pip3"
  elif command -v pip &>/dev/null && \
       [[ "$(pip --version 2>&1 | awk '{print $6}' | cut -d. -f1)" -ge 3 ]]; then
    PIP_BIN="pip"
  else
    log_error "pip (Python 3) is required but not found."
    exit 1
  fi
}

check_ssh_key() {
  local key_file
  key_file="$(grep '^private_key_file' ansible.cfg | awk -F '=' '{print $2}' | xargs)"
  key_file="$(eval echo "$key_file")"
  if [[ ! -f "$key_file" ]]; then
    log_error "SSH key ${BLUE}${key_file}${RESET} does not exist."
    log_error "Update ${BLUE}private_key_file${RESET} in ${BLUE}ansible.cfg${RESET}."
    exit 1
  fi
  KEY_FILE="$key_file"
}

# Run all checks
check_for_updates
check_project_id
check_gcloud
check_python
check_pip
check_required_tool "terraform" "Terraform is not installed. Install: brew install terraform"
check_required_tool "jq"        "jq is not installed. Install: brew install jq"
check_ssh_key

# ==============================================================================
# Python Virtual Environment & Ansible
# ==============================================================================

log_info "Configuring Python venv and installing Ansible ${ANSIBLE_VERSION}..."
run_cmd "${PYTHON_BIN}" -m venv ecelab &>/dev/null || true
# shellcheck source=/dev/null
source ecelab/bin/activate 2>/dev/null || true
run_cmd "${PIP_BIN}" install --upgrade pip &>/dev/null || true
run_cmd "${PIP_BIN}" install "ansible==${ANSIBLE_VERSION}" &>/dev/null || true

# ==============================================================================
# Interactive Selection Menus
# ==============================================================================

# Preserve COLUMNS for select menus
_orig_columns="${COLUMNS:-}"
COLUMNS=1

# --- Select Installation Type ------------------------------------------------
if [[ -n "${PRESELECTED_installtype:-}" ]]; then
  installtype="${PRESELECTED_installtype}"
else
  log_info "Select the deployment size:"
  select installtype in "single" "small"; do
    [[ -n "$installtype" ]] && break
    log_warn "Invalid option. Please select again."
  done
fi

# --- Select ECE Version ------------------------------------------------------
if [[ -n "${PRESELECTED_version:-}" ]]; then
  version="${PRESELECTED_version}"
else
  log_info "Select the ECE Version:"
  select version in "${ECE_VERSIONS[@]}"; do
    [[ -n "$version" ]] && break
    log_warn "Invalid option."
  done
fi

# --- Determine OS Options Based on Version -----------------------------------
get_os_options_for_version() {
  local ver_num
  ver_num="$(version_to_int "$version")"

  if [[ "$ver_num" -ge "$(version_to_int '4.0.0')" ]]; then
    os_option_entries=("${OS_OPTIONS_V4[@]}")
  elif [[ "$ver_num" -ge "$(version_to_int '3.8.0')" ]]; then
    os_option_entries=("${OS_OPTIONS_V38[@]}")
  elif [[ "$ver_num" -ge "$(version_to_int '3.7.0')" ]]; then
    os_option_entries=("${OS_OPTIONS_V37[@]}")
  else
    os_option_entries=("${OS_OPTIONS_V3[@]}")
  fi
}

# Parse an OS option entry (pipe-delimited) and set global variables
parse_os_entry() {
  local entry="$1"
  IFS='|' read -r _display image container cversion _disk2_x86 _disk2_arm SELINUX \
    _type_single_x86 _type_small_x86 _type_single_arm _type_small_arm <<< "$entry"

  # Determine architecture-specific values
  if [[ "$_display" == *"arm64"* ]]; then
    DISK2="$_disk2_arm"
    TYPE=$([[ "$installtype" == "single" ]] && echo "$_type_single_arm" || echo "$_type_small_arm")
  else
    DISK2="$_disk2_x86"
    TYPE=$([[ "$installtype" == "single" ]] && echo "$_type_single_x86" || echo "$_type_small_x86")
  fi
}

# --- Select OS ---------------------------------------------------------------
declare -a os_option_entries
get_os_options_for_version

# Build display names array
declare -a os_display_names
for entry in "${os_option_entries[@]}"; do
  os_display_names+=("${entry%%|*}")
done

if [[ -n "${PRESELECTED_os:-}" ]]; then
  os="${PRESELECTED_os}"
  # Find matching entry
  local_matched=0
  for entry in "${os_option_entries[@]}"; do
    if [[ "${entry%%|*}" == "$os" ]]; then
      parse_os_entry "$entry"
      local_matched=1
      break
    fi
  done
  if [[ "$local_matched" -eq 0 ]]; then
    log_error "Preselected OS '${os}' not found in options for ECE ${version}."
    exit 1
  fi
else
  echo ""
  log_info "Select the OS for the GCP instances:"
  select os in "${os_display_names[@]}"; do
    if [[ -n "$os" ]]; then
      # Find the matching full entry
      for entry in "${os_option_entries[@]}"; do
        if [[ "${entry%%|*}" == "$os" ]]; then
          parse_os_entry "$entry"
          break
        fi
      done
      break
    else
      log_warn "Invalid option. Please try again."
    fi
  done
fi

# Restore COLUMNS
COLUMNS="${_orig_columns:-}"

# --- Confirm Selections ------------------------------------------------------
echo ""
log_info "Using Project: ${BLUE}${PROJECT_ID}${RESET}, Region: ${BLUE}${REGION}${RESET}, MachineType: ${BLUE}${TYPE}${RESET}"
log_info "ECE version: ${BLUE}${version}${RESET} OS: ${BLUE}${os}${RESET} Install Type: ${BLUE}${installtype}${RESET}"
echo ""
sleep 2

# ==============================================================================
# Terraform Setup & Execution
# ==============================================================================

setup_terraform() {
  log_info "Finding available zones in ${BLUE}${REGION}${RESET} for ${BLUE}${TYPE}${RESET}..."

  local zones valid_zones=()
  zones="$(gcloud compute zones list --filter="region:(${REGION})" --format="value(name)" -q)"

  while IFS= read -r zone; do
    # Skip us-central1-a (known issues)
    [[ "$zone" == "us-central1-a" ]] && continue
    if gcloud compute machine-types describe "${TYPE}" --zone "$zone" -q &>/dev/null; then
      valid_zones+=("$zone")
    fi
  done <<< "$zones"

  if [[ ${#valid_zones[@]} -eq 0 ]]; then
    log_error "No valid zones found for machine type ${TYPE} in region ${REGION}."
    exit 1
  fi

  # Write Terraform tfvars
  local zones_str
  zones_str="$(printf ',"%s"' "${valid_zones[@]}")"
  echo "valid_zones = [${zones_str:1}]" > terraform.tfvars

  log_info "Creating Terraform configuration..."

  local count
  count=$([[ "${installtype}" == "small" ]] && echo 3 || echo 1)

  cat > main.tf << EOL
provider "google" {
  project = "${PROJECT_ID}"
  region  = "${REGION}"
}

variable "valid_zones" {
  description = "List of zones where the machine type is available"
  type        = list(string)
}

resource "random_shuffle" "zone_selection" {
  input        = var.valid_zones
  result_count = ${count}
}

resource "google_compute_disk" "data_disk" {
  labels = {
    division = "support"
    org      = "support"
    team     = "support"
    project  = "${USERNAME}-ecelab"
  }

  count = ${count}
  name  = "${USERNAME}-ecelab-data-disk-\${count.index + 1}"
  type  = "${DISK_TYPE}"
  zone  = random_shuffle.zone_selection.result[count.index]
  size  = 150
}

resource "google_compute_firewall" "custom_rule" {
  name    = "support-lab-us-ecelab-rules-allow-external-inbound-${USERNAME}"
  network = "projects/elastic-support/global/networks/support-lab-vpc-us"

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443", "636", "5000", "5601", "8080", "8081", "9200", "9243", "9300", "9343", "9900", "12300", "12343", "12400", "12443", "22400", "22443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ecelab"]
}

resource "google_compute_instance" "vm_instance" {
  labels = {
    division = "support"
    org      = "support"
    team     = "support"
    project  = "${USERNAME}-ecelab"
  }

  count        = ${count}
  name         = "${USERNAME}-ecelab-\${count.index + 1}"
  machine_type = "${TYPE}"
  zone         = random_shuffle.zone_selection.result[count.index]
  tags         = ["ecelab"]

  boot_disk {
    initialize_params {
      image = "${image}"
    }
  }

  attached_disk {
    source      = google_compute_disk.data_disk[count.index].id
    device_name = "data-disk-\${count.index + 1}"
  }

  network_interface {
    subnetwork = "projects/elastic-support/regions/us-central1/subnetworks/support-lab-vpc-us-sub1"
    access_config {}
  }

  scheduling {
    max_run_duration {
      seconds = "${TIMER}"
    }
    instance_termination_action = "DELETE"
  }
}

output "instance_ips" {
  value       = google_compute_instance.vm_instance[*].network_interface[0].access_config[0].nat_ip
  description = "The external IP addresses of the instances"
}
EOL

  # Check for existing resources
  local tf_output
  tf_output="$(terraform output -json 2>/dev/null)" || true
  if echo "${tf_output}" | grep -q '"instance_ips"' 2>/dev/null; then
    log_warn "Previous instances found in Terraform state."
    log_warn "Run ${BLUE}./${SCRIPT_NAME} cleanup${RESET} to remove them before deploying again."
    exit 1
  fi

  log_info "Initializing Terraform..."
  if ! run_cmd terraform init >/dev/null; then
    log_error "Terraform initialization failed."
    exit 1
  fi

  log_info "Applying Terraform configuration..."
  if ! terraform apply -auto-approve -no-color > terraform.log 2>&1; then
    log_error "Terraform apply failed. Check ${BLUE}terraform.log${RESET} for details."
    exit 1
  fi

  log_info "Terraform apply completed successfully."
}

setup_terraform

# ==============================================================================
# Ansible Inventory & SSH Connectivity
# ==============================================================================

setup_ansible() {
  log_info "Creating ${BLUE}inventory.yml${RESET} for Ansible..."

  # Retrieve IPs from Terraform output (avoid mapfile for macOS bash 3.2 compat)
  local -a ips=()
  while IFS= read -r _ip; do
    [[ -n "$_ip" ]] && ips+=("$_ip")
  done < <(terraform output -json instance_ips | jq -r '.[]')

  local -a availability_zones=("zone-1" "zone-2" "zone-3")
  local -a groups=("primary" "secondary" "tertiary")
  local length="${#ips[@]}"

  # Generate inventory
  cat > inventory.yml <<EOL
all:
  vars:
    ansible_become: yes
    device_name: ${DISK2}
    outside_ip: "{{ groups['primary'][0] }}"
    ansible_ssh_timeout: 120
  children:
EOL

  for (( i = 0; i < length; i++ )); do
    cat >> inventory.yml <<EOL
    ${groups[$i]}:
      hosts:
        ${ips[$i]}:
          availability_zone: ${availability_zones[$i]}
EOL
  done

  # Add empty groups for single-node deployments
  if [[ "$length" -eq 1 ]]; then
    cat >> inventory.yml <<EOL
    secondary:
      hosts: {}
    tertiary:
      hosts: {}
EOL
  fi

  log_info "inventory.yml created successfully."

  # SSH connectivity check using nc/bash for cross-platform compatibility
  check_ssh() {
    local ip="$1"
    local i

    log_info "Checking SSH connectivity for ${BLUE}${ip}${RESET}..."

    for (( i = 1; i <= SSH_MAX_RETRIES; i++ )); do
      # Cross-platform SSH port check
      if (echo > "/dev/tcp/${ip}/22") 2>/dev/null; then
        log_info "${BLUE}${ip}${RESET} is reachable via SSH."
        return 0
      elif command -v nc &>/dev/null && nc -z -w5 "$ip" 22 2>/dev/null; then
        log_info "${BLUE}${ip}${RESET} is reachable via SSH."
        return 0
      else
        log_warn "${BLUE}${ip}${RESET} not reachable via SSH. Retry ${i}/${SSH_MAX_RETRIES} in ${SSH_RETRY_DELAY}s..."
        sleep "${SSH_RETRY_DELAY}"
      fi
    done

    log_error "Failed to connect to ${BLUE}${ip}${RESET} via SSH after $(( SSH_MAX_RETRIES * SSH_RETRY_DELAY ))s."
    exit 1
  }

  for ip in "${ips[@]}"; do
    check_ssh "$ip"
  done

  sleep 5
  log_info "All hosts are reachable via SSH."
}

setup_ansible

# ==============================================================================
# Run Ansible Playbooks
# ==============================================================================

run_ansible_playbooks() {
  log_info "Running Ansible playbooks..."

  # Wait for SSH key authentication to be ready on all hosts
  # GCP metadata (including SSH keys) can take a few seconds to propagate after the VM is reachable
  log_info "Verifying SSH key authentication on all hosts..."
  local ip
  for ip in $(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' inventory.yml); do
    local attempt
    for attempt in 1 2 3 4 5; do
      if ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o ConnectTimeout=10 -o BatchMode=yes "$ip" true 2>/dev/null; then
        break
      fi
      if [[ "$attempt" -eq 5 ]]; then
        log_warn "SSH key auth not ready on ${BLUE}${ip}${RESET} after 5 attempts. Proceeding anyway."
      else
        sleep 3
      fi
    done
  done

  if ansible-playbook -i inventory.yml combined.yml \
       --extra-vars "crt=${container} ece_version=${version} selinuxmode=${SELINUX} package=${cversion}"; then
    echo ""
    log_info "ECE installation complete!"
    log_info "Installed ECE: ${BLUE}${version}${RESET} on ${BLUE}${os}${RESET}"
    log_info "To ${RED}delete${RESET} the environment: ${BLUE}./${SCRIPT_NAME} cleanup${RESET}"
  else
    log_error "Ansible playbook failed. Check ${BLUE}ecelab.log${RESET} for details."
    log_error "To delete the environment: ${BLUE}./${SCRIPT_NAME} cleanup${RESET}"
    exit 1
  fi
}

run_ansible_playbooks

# ==============================================================================
# Display Instance Information
# ==============================================================================

find_instances
