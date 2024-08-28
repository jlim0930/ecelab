#!/bin/bash

### load vars - Please edit vars file and customize it.
source vars

### set username
USERNAME="$(whoami | tr -cd '[:alnum:]\t')"

### colors
red=$(tput setaf 1)
green=$(tput setaf 2)
blue=$(tput setaf 14)
reset=$(tput sgr0)

# Helper function to display debug messages
debug() {
  echo "${green}[DEBUG]${reset} $1"
}

debugr() {
  echo "${red}[DEBUG]${reset} $1"
}
### CHECKS

# Check for updates from git repository
check_for_updates() {
  git fetch origin &>/dev/null
  local changed_files
  changed_files=$(git diff --name-only origin/main | grep -vE '^vars$')

  if [[ -n "$changed_files" ]]; then
    debugr "Updates available for the following files:"
    echo "$changed_files"
    debugr "Please run ${blue}git pull${reset} again to update the files above."
    echo ""
  fi
}

# Call self-update check
check_for_updates

# Ensure PROJECT_ID is set
check_project_id() {
  if [ -z "${PROJECT_ID}" ]; then
    debugr "${blue}PROJECT_ID${reset} is not set in ${blue}vars${reset}. Please configure it first."
    exit 1
  fi
}

# Call check_project_id
check_project_id

# Check if gcloud is installed and configured
check_gcloud() {
  if ! command -v gcloud &>/dev/null; then
    debugr "${blue}gcloud${reset} command is not available. Please install the Google Cloud SDK."
    debugr "Installation instructions: https://cloud.google.com/sdk/docs/install"
    exit 1
  fi

  local default_project
  default_project=$(gcloud config get-value project --quiet)
  if [[ -z "$default_project" ]]; then
    echo "gcloud is not configured with a default project. Please configure gcloud CLI."
    exit 1
  fi
}

# Call check_gcloud
check_gcloud

# Check for Python and its version
check_python() {
  if command -v python3 &>/dev/null; then
    PYTHON_BIN="python3"
  elif command -v python &>/dev/null; then
    local version
    version=$(python --version 2>&1 | awk '{print $2}')
    if [[ "$(echo "$version" | cut -d. -f1)" -ge 3 ]]; then
      PYTHON_BIN="python"
    else
      debugr "Python version 3 or higher is required."
      exit 1
    fi
  else
    debugr "Python is not installed."
    exit 1
  fi
}

# Call check_python
check_python

# Check for pip and its version
check_pip() {
  if command -v pip3 &>/dev/null; then
    PIP_BIN="pip3"
  elif command -v pip &>/dev/null; then
    local pip_version
    pip_version=$(pip --version | awk '{print $6}' | cut -d. -f1)
    if [[ "$pip_version" -ge 3 ]]; then
      PIP_BIN="pip"
    else
      debugr "pip is not associated with Python 3."
      exit 1
    fi
  else
    debugr "pip is not installed."
    exit 1
  fi
}

# Call check_pip
check_pip

# Check for required commands
check_command() {
  local cmd=$1
  local error_message=$2

  if ! command -v "$cmd" &>/dev/null; then
    debugr "$error_message"
    exit 1
  fi
}

check_command "terraform" "Terraform is not installed."
check_command "jq" "jq is not installed."

# Ensure SSH key is available
KEY_FILE=$(grep '^private_key_file' ansible.cfg | awk -F '=' '{print $2}' | xargs)
KEY_FILE=$(eval echo "$KEY_FILE")

if [ ! -f "$KEY_FILE" ]; then
  debugr "The file ${blue}$KEY_FILE${reset} does not exist. Please update ${blue}private_key_file${reset} in ${blue}ansible.cfg${reset} to ensure that the correct private key is specified."
  exit 1
fi

# Function for version comparison
checkversion() {
  echo "$@" | awk -F. '{ printf("%d%02d%02d%02d\n", $1,$2,$3,$4); }'
}

### Setup venv for ansible 9.8.0

debug "Configuring python venv and setting up ansible 9.8.0 - higher ansible versions have issues with EL8"
$PYTHON_BIN -m venv ecelab &>/dev/null
source ecelab/bin/activate &>/dev/null
$PIP_BIN install --upgrade pip &>/dev/null
$PIP_BIN install ansible==9.8.0 &>/dev/null

### Prompts for selections

# Save and restore the original COLUMNS value
original_columns=$COLUMNS
COLUMNS=1

# Prompt for installation type
debug "Select the size:"
select installtype in "single" "small"; do
  case $installtype in
    "single" | "small")
      break;;
    *)
      debugr "Invalid option. Please select again."
      ;;
  esac
done

# Prompt for ECE Version selection
debug "Select the ECE Version:"
select version in "3.3.0" "3.4.0" "3.4.1" "3.5.0" "3.5.1" "3.6.0" "3.6.1" "3.6.2" "3.7.1" "3.7.2"; do
  case $version in
    "3.3.0" | "3.4.0" | "3.4.1" | "3.5.0" | "3.5.1" | "3.6.0" | "3.6.1" | "3.6.2" | "3.7.1" | "3.7.2")
      break;;
    *)
      debugr "Invalid option. Please select again."
      ;;
  esac
done

# Determine OS and container options based on version
# Function to select OS and set relevant variables
select_os_and_container() {
  local os_choices=("$@")
  debug "Select the OS for the GCP instances:"
  select os in "${os_choices[@]}"; do
    case $os in
      "Rocky 8 - Podman - x86_64")
        image="rocky-linux-cloud/rocky-linux-8-optimized-gcp"
        container="podman"
        DISK2="sdb"
        if [ ${installtype} == "single" ]; then
          TYPE="n1-highmem-8"
        else
          TYPE="n1-standard-8"
        fi
        break
        ;;
      "Rocky 8 - Podman - arm64")
        image="rocky-linux-cloud/rocky-linux-8-optimized-gcp-arm64"
        container="podman"
        DISK2="nvme0n2"
        if [ ${installtype} == "single" ]; then
          TYPE="t2a-standard-16"
        else
          TYPE="t2a-standard-8"
        fi
        break
        ;;
      "Ubuntu 20.04 - Docker 24.0 - x86_64")
        image="ubuntu-os-cloud/ubuntu-minimal-2004-lts"
        container="docker"
        dockerversion="24.0"
        DISK2="sdb"
        if [ ${installtype} == "single" ]; then
          TYPE="n1-highmem-8"
        else
          TYPE="n1-standard-8"
        fi
        break
        ;;
      "Ubuntu 20.04 - Docker 24.0 - arm64")
        image="ubuntu-os-cloud/ubuntu-minimal-2004-lts-arm64"
        container="docker"
        dockerversion="24.0"
        DISK2="nvme0n2"
        if [ ${installtype} == "single" ]; then
          TYPE="t2a-standard-16"
        else
          TYPE="t2a-standard-8"
        fi
        break
        ;;
      "Rocky 8 - Docker 20.10 - x86_64")
        image="rocky-linux-cloud/rocky-linux-8-optimized-gcp"
        container="docker"
        dockerversion="20.10"
        DISK2="sdb"
        if [ ${installtype} == "single" ]; then
          TYPE="n1-highmem-8"
        else
          TYPE="n1-standard-8"
        fi
        break
        ;;
      "Rocky 8 - Docker 20.10 - arm64")
        image="rocky-linux-cloud/rocky-linux-8-optimized-gcp-arm64"
        container="docker"
        dockerversion="20.10"
        DISK2="nvme0n2"
        if [ ${installtype} == "single" ]; then
          TYPE="t2a-standard-16"
        else
          TYPE="t2a-standard-8"
        fi
        break
        ;;
      "Ubuntu 20.04 - Docker 20.10 - x86_64")
        image="ubuntu-os-cloud/ubuntu-minimal-2004-lts"
        container="docker"
        dockerversion="20.10"
        DISK2="sdb"
        if [ ${installtype} == "single" ]; then
          TYPE="n1-highmem-8"
        else
          TYPE="n1-standard-8"
        fi
        break
        ;;
      "Ubuntu 20.04 - Docker 20.10 - arm64")
        image="ubuntu-os-cloud/ubuntu-minimal-2004-lts-arm64"
        container="docker"
        dockerversion="20.10"
        DISK2="nvme0n2"
        if [ ${installtype} == "single" ]; then
          TYPE="t2a-standard-16"
        else
          TYPE="t2a-standard-8"
        fi
        break
        ;;
      *)
        debugr "Invalid option. Please try again."
        ;;
    esac
  done
}

if [ $(checkversion $version) -ge $(checkversion "3.7.0") ]; then
  select_os_and_container "Rocky 8 - Podman - x86_64" "Rocky 8 - Podman - arm64" "Ubuntu 20.04 - Docker 24.0 - x86_64" "Ubuntu 20.04 - Docker 24.0 - arm64"
else
  select_os_and_container "Rocky 8 - Podman - x86_64" "Rocky 8 - Podman - arm64" "Rocky 8 - Docker 20.10 - x86_64" "Rocky 8 - Docker 20.10 - arm64" "Ubuntu 20.04 - Docker 20.10 - x86_64" "Ubuntu 20.04 - Docker 20.10 - arm64"
fi

# Restore the original COLUMNS value
COLUMNS=$original_columns

# Confirm the variables
debug "Using Project: ${blue}${PROJECT_ID}${reset}, Region: ${blue}${REGION}${reset}, MachineType: ${blue}${TYPE}${reset}"
debug "ECE version: ${blue}${version}${reset} OS: ${blue}${os}${reset} Install Type: ${blue}${installtype}${reset}"
echo ""
sleep 2

# Terraform setup and execution
setup_terraform() {
  debug "Creating list of ${blue}zones${reset} from ${blue}${REGION}${reset} where ${blue}${TYPE}${reset} is available."

  # Get a list of available zones for the specified region and machine type
  ZONES=$(gcloud compute zones list --filter="region:(${REGION})" --format="value(name)")
  VALID_ZONES=()

  for ZONE in $ZONES; do
    if gcloud compute machine-types describe "${TYPE}" --zone "$ZONE" &>/dev/null; then
      VALID_ZONES+=("$ZONE")
    fi
  done

  # Create a comma-separated list of valid zones for use in Terraform
  VALID_ZONES_STRING=$(printf ",\"%s\"" "${VALID_ZONES[@]}")
  VALID_ZONES_STRING=${VALID_ZONES_STRING:1} # Remove the leading comma

  # Output valid zones to a Terraform variable file
  echo "valid_zones = [$VALID_ZONES_STRING]" > terraform.tfvars

  debug "Creating Terraform configuration files..."

  # Create Terraform main configuration file based on installation type
  if [ "${installtype}" == "small" ]; then
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
  result_count = 3
}

resource "google_compute_disk" "data_disk" {
  labels = {
    division = "support"
    org      = "support"
    team     = "support"
    project  = "${USERNAME}-ecelab"
  }

  count = 3
  name  = "${USERNAME}-ecelab-data-disk-\${count.index + 1}"
  type  = "pd-standard"
  zone  = random_shuffle.zone_selection.result[count.index]
  size  = 150
}

resource "google_compute_instance" "vm_instance" {
  count        = 3
  name         = "${USERNAME}-ecelab-\${count.index + 1}"
  machine_type = "${TYPE}"
  zone         = random_shuffle.zone_selection.result[count.index]

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
    network = "default"

    access_config {
    }
  }
}

output "instance_ips" {
  value       = google_compute_instance.vm_instance[*].network_interface[0].access_config[0].nat_ip
  description = "The external IP addresses of the instances"
}
EOL
  else
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
  result_count = 1
}

resource "google_compute_disk" "data_disk" {
  labels = {
    division = "support"
    org      = "support"
    team     = "support"
    project  = "${USERNAME}-ecelab"
  }

  count = 1
  name  = "${USERNAME}-ecelab-data-disk-\${count.index + 1}"
  type  = "pd-standard"
  zone  = random_shuffle.zone_selection.result[count.index]
  size  = 150
}

resource "google_compute_instance" "vm_instance" {
  count        = 1
  name         = "${USERNAME}-ecelab-\${count.index + 1}"
  machine_type = "${TYPE}"
  zone         = random_shuffle.zone_selection.result[count.index]

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
    network = "default"

    access_config {
    }
  }
}

output "instance_ips" {
  value       = google_compute_instance.vm_instance[*].network_interface[0].access_config[0].nat_ip
  description = "The external IP addresses of the instances"
}
EOL
  fi

  # Check if Terraform output indicates existing resources
  output=$(terraform output -json)
  if echo "${output}" | grep -q '"instance_ips"'; then
    debugr "Previous instances found in Terraform output. Proceeding to destroy existing resources..."
    # terraform destroy -auto-approve &>/dev/null
    debugr "Please remove the previous install by running ${blue}terraform destroy -auto-approve${reset}"
    exit 1
  fi

  # Initialize Terraform
  debug "Initializing Terraform..."
  terraform init &>/dev/null
  if [ $? -ne 0 ]; then
    debugr "Terraform initialization failed. Exiting."
    exit 1
  fi

  # Apply Terraform configuration
  debug "Applying Terraform configuration..."
  terraform apply -auto-approve &>/dev/null
  if [ $? -ne 0 ]; then
    debugr "Terraform apply failed. Exiting."
    exit 1
  fi

  debug "Terraform apply completed successfully."
}

setup_terraform

# Ansible setup and SSH checks
setup_ansible() {
  debug "Creating ${blue}inventory.yml${reset} for Ansible..."

  # Retrieve IPs of the instances from Terraform output
  ips=($(terraform output -json instance_ips | jq -r '.[]'))

  # Availability zones corresponding to each IP address (hard-coded for simplicity)
  availability_zones=("zone-1" "zone-2" "zone-3")

  # Define groups for inventory
  groups=("primary" "secondary" "tertiary")

  # Create the inventory.yml file for Ansible
  cat <<EOL > inventory.yml
all:
  vars:
    ansible_become: yes
    device_name: ${DISK2}
    outside_ip: "{{ groups['primary'][0] }}"
  children:
EOL

  # Get the number of IPs (assuming all arrays are of the same length)
  length=${#ips[@]}

  # Loop through the IPs and corresponding zones to populate the inventory file
  for ((i=0; i<$length; i++)); do
    cat <<EOL >> inventory.yml
    ${groups[$i]}:
      hosts:
        ${ips[$i]}:
          availability_zone: ${availability_zones[$i]}
EOL
  done

  # If single instance, add empty groups for secondary and tertiary
  if [ $length = 1 ]; then
    cat <<EOL >> inventory.yml
    secondary:
      hosts: {}  # Empty group for secondary
    tertiary:
      hosts: {}  # Empty group for tertiary
EOL
  fi

  debug "inventory.yml created successfully."

  # Function to get the private key file from ansible.cfg
  get_private_key_file() {
    grep -E '^private_key_file\s*=' ansible.cfg | awk -F '=' '{print $2}' | xargs
  }

  # Function to check SSH connectivity
  check_ssh() {
    local ip=$1
    local retries=30
    local delay=15

    debug "Checking SSH connectivity for ${blue}${ip}${reset}..."

    for ((i=1; i<=retries; i++)); do
      # Check SSH connection on port 22
      #if echo "" > /dev/tcp/$ip/22 2>/dev/null; then
      echo "" > /dev/tcp/$ip/22 2>/dev/null
      if [[ $? -eq 0 ]]; then
        debug "${blue}${ip}${reset} is reachable via SSH."
        return 0
      else
        debugr "${blue}${ip}${reset} is not reachable via SSH. Retrying in $delay seconds..."
        sleep $delay
      fi
    done

    debugr "Failed to connect to ${blue}${ip}${reset} via SSH after $((retries * delay)) seconds."
    exit 1
  }

  # Retrieve the private key file path
  private_key_file=$(get_private_key_file)
  if [ -z "$private_key_file" ]; then
    debugr "Error: ${blue}private_key_file${reset} not found in ansible.cfg"
    exit 1
  fi

  # Loop through each IP and check SSH connectivity
  for ip in "${ips[@]}"; do
    check_ssh "${ip}"
  done
  sleep 3
  debug "All hosts are reachable via SSH. Proceeding with further actions..."
}

setup_ansible


# Run Ansible playbooks
run_ansible_playbooks() {
  debug "Running ansible scripts"
  sleep 5
  ansible-playbook -i inventory.yml combined.yml --extra-vars "crt=${container} ece_version=${version}"

  if [ $? -eq 0 ]; then
    debug "And we are done! The URL and the password are listed above."
    debug "Installed ECE: ${blue}${version}${reset} on ${blue}${os}${reset}"
    debug "When you are done, and want to delete the workload, run ${blue}terraform destroy -auto-approve${reset}"
  else
    debug "Something went wrong... exiting. Please look in ${blue}ecelab.log${reset} for issues. Please remember to run ${blue}terraform destroy -auto-approve${reset} to delete the environment."
    exit 1
  fi
}

# run_ansible_playbooks() {
#   debug "Running ansible scripts for preinstall"
#   sleep 5
#   ansible-playbook -i inventory.yml preinstall.yml --extra-vars "crt=${container} ece_version=${version}"

#   if [ $? -eq 0 ]; then
#     debug "Running ansible scripts for ECE install - Primary install does take a while..."
#     sleep 5
#     ansible-playbook -i inventory.yml eceinstall.yml --extra-vars "crt=${container} ece_version=${version}"

#     if [ $? -eq 0 ]; then
#       debug "And we are done! The URL and the password are listed above."
#       debug "Installed ECE: ${blue}${version}${reset} on ${blue}${os}${reset}"
#       debug "When you are done, and want to delete the workload, run ${blue}terraform destroy -auto-approve${reset}"
#     else
#       debug "Something went wrong... exiting. Please remember to run ${blue}terraform destroy -auto-approve${reset} to delete the environment."
#       exit 1
#     fi
#   else
#     debug "Something went wrong... exiting. Please remember to run ${blue}terraform destroy -auto-approve${reset} to delete the environment."
#     exit 1
#   fi
# }

run_ansible_playbooks
