#!/bin/bash

# load vars - Please edit vars file and customize it.
source vars

# set username
USERNAME="$(whoami | sed $'s/[^[:alnum:]\t]//g')"

# colors
red=`tput setaf 1`
green=`tput setaf 2`
blue=`tput setaf 14`
reset=`tput sgr0`

# CHECKS

# ensure gcloud is available and configured
check_gcloud_configured() {
  local default_project=$(gcloud config get-value project --quiet)
  if [[ -z "$default_project" ]]; then
    echo "${red}[DEBUG]${reset} gcloud is not configured with a default project. - Please configure gcloud cli"
    exit 1
  fi
}

if command -v gcloud >/dev/null 2>&1; then
  if check_gcloud_configured; then
    :
  else
    echo "${red}[DEBUG]${reset} Please run 'gcloud init' to configure gcloud."
    exit 1
  fi
else
  echo "${red}[DEBUG]${reset} gcloud command is not available. Please install the Google Cloud SDK."
  echo "Installation instructions: https://cloud.google.com/sdk/docs/install"
fi


# ensure python is available
check_python_version() {
  local version
  version=$("$1" --version 2>&1 | awk '{print $2}')
  if [ "$(echo "$version" | cut -d. -f1)" -ge 3 ]; then
    PYTHON_BIN="$1"
  else
    echo "${red}[DEBUG]${reset} Python version 3 or higher is required."
    exit 1
  fi
}

if command -v python3 &>/dev/null; then
  PYTHON_BIN="python3"
elif command -v python &>/dev/null; then
  check_python_version "python"
else
  echo "${red}[DEBUG]${reset} Python is not installed."
  exit 1
fi

check_pip_version() {
  local pip_version
  pip_version=$("$1" --version | awk '{print $6}' | cut -d. -f1)
  if [ "$pip_version" -ge 3 ]; then
    PIP_BIN="$1"
  else
    echo "${red}[DEBUG]${reset} pip is not associated with Python 3."
    exit 1
  fi
}

if command -v pip3 &>/dev/null; then
  PIP_BIN="pip3"
elif command -v pip &>/dev/null; then
  check_pip_version "pip"
else
  echo "${red}[DEBUG]${reset} pip is not installed."
  exit 1
fi

# ensure terraform is available
command -v terraform &>/dev/null || {
  echo "${red}[DEBUG]${reset} Terraform is not installed."
  exit 1
}

# ensure jq is available
command -v jq &>/dev/null || {
  echo "${red}[DEBUG]${reset} jq is not installed."
  exit 1
}

# ensure ssh key is available
ANSIBLE_CFG="ansible.cfg"
KEY_FILE=$(grep '^private_key_file' "$ANSIBLE_CFG" | awk -F '=' '{print $2}' | xargs)
KEY_FILE=$(eval echo "$KEY_FILE")
if [ ! -f "$KEY_FILE" ]; then
  echo "${red}[DEBUG]${reset} The file $KEY_FILE does not exist. Please update ${blue}private_key_file${reset} in ${blue}ansible.cfg${reset} to ensure that the correct private key is specified."
  exit 1
fi


#--------------------------------------------------

# setup env for ansible 9.8.0
echo "${green}[DEBUG]${reset} Configuring python venv and setting up ansible 9.8.0 - higher ansible versions have issues with EL8"
echo ""
$PYTHON_BIN -m venv ecelab>/dev/null 2>&1
source ecelab/bin/activate >/dev/null 2>&1
$PIP_BIN install --upgrade pip >/dev/null 2>&1
$PIP_BIN install ansible==9.8.0 >/dev/null 2>&1

# function used for version checking and comparing
checkversion() {
  echo "$@" | awk -F. '{ printf("%d%02d%02d%02d\n", $1,$2,$3,$4); }'
} # end of checkversion function

# Save the original COLUMNS value
original_columns=$COLUMNS
COLUMNS=1

# Prompt for Single instance or 3 instance small install
echo "${green}[DEBUG]${reset} Select the size:"
select installtype in "single" "small"; do
  case $installtype in
    "single")
      installtype="single"
      TYPE="n1-highmem-8"
      break;;
    "small")
      installtype="small"
      break;;
    *)
      echo "Invalid option. Please select again."
      ;;
  esac
done

echo ""
echo ""

# Prompt for ECE Version selection
echo "${green}[DEBUG]${reset} Select the OS for the ECE Version:"
select version in "3.3.0" "3.4.0" "3.4.1" "3.5.0" "3.5.1" "3.6.0" "3.6.1" "3.6.2" "3.7.1" "3.7.2"; do
  case $version in
    "3.3.0")
      version="3.3.0"
      break;;
    "3.4.0")
      version="3.4.0"
      break;;
    "3.4.1")
      version="3.4.1"
      break;;
    "3.5.0")
      version="3.5.0"
      break;;
    "3.5.1")
      version="3.5.1"
      break;;
    "3.6.0")
      version="3.6.0"
      break;;
    "3.6.1")
      version="3.6.1"
      break;;
    "3.6.2")
      version="3.6.2"
      break;;
    "3.7.1")
      version="3.7.1"
      break;;
    "3.7.2")
      version="3.7.2"
      break;;
    *)
      echo "Invalid option. Please select again."
      ;;
  esac
done

echo ""
echo ""

if [ $(checkversion $version) -ge $(checkversion "3.7.0") ]; then
  # Prompt user for OS selection
  echo "${green}[DEBUG]${reset} Select the OS for the GCP instances:"
  select os in "Rocky 8 - Podman" "Ubuntu 20.04 - Docker 24.0"; do
    case $os in
      "Rocky 8 - Podman")
        image="rocky-linux-cloud/rocky-linux-8-optimized-gcp"
        container="podman"
        break
        ;;
      "Ubuntu 20.04 - Docker 24.0")
        image="ubuntu-os-cloud/ubuntu-minimal-2004-lts"
        container="docker"
        dockerversion="24.0"
        break
        ;;
      *)
        echo "Invalid option. Please select 1 or 2."
        ;;
    esac
  done
elif [ $(checkversion $version) -lt $(checkversion "3.7.0") ]; then
  # Prompt user for OS selection
  echo "${green}[DEBUG]${reset} Select the OS for the GCP instances:"
  select os in "Rocky 8 - Podman" "Rocky 8 - Docker 20.10" "Ubuntu 20.04 - Docker 20.10"; do
    case $os in
      "Rocky 8 - Podman")
        image="rocky-linux-cloud/rocky-linux-8-optimized-gcp"
        container="podman"
        break
        ;;
      "Rocky 8 - Docker 20.10")
        image="rocky-linux-cloud/rocky-linux-8-optimized-gcp"
        container="docker"
        dockerversion="20.10"
        break
        ;;
      "Ubuntu 20.04 - Docker 20.10")
        image="ubuntu-os-cloud/ubuntu-minimal-2004-lts"
        container="docker"
        dockerversion="20.10"
        break
        ;;
      *)
        echo "Invalid option. Please select 1 or 2."
        ;;
    esac
  done
fi

# Restore the original COLUMNS value
COLUMNS=$original_columns

# Confirm the variables
echo ""
echo "${green}[DEBUG]${reset} Using Project: ${blue}$PROJECT_ID${reset}, Region: ${blue}$REGION${reset}, MachineType: ${blue}$TYPE${reset}"
echo "${green}[DEBUG]${reset} ECE version: ${blue}${version}${reset} OS: ${blue}${os}${reset} Install Type: ${blue}${installtype}${reset}"
echo ""

# terraform -----------------------------------------------
#
# Generate Terraform script
echo "${green}[DEBUG]${reset} Creating TFs"
echo ""

if [ ${installtype} == "small" ]; then
  cat > main.tf << EOL
provider "google" {
  project = "$PROJECT_ID"
  region  = "$REGION"
}

data "google_compute_zones" "available" {
  region = "$REGION"
}

resource "random_shuffle" "zone_selection" {
  input        = data.google_compute_zones.available.names
  result_count = 3
}

resource  "google_compute_disk" "data_disk" {
  labels = {
    division = "support"
    org      = "support"
    team     = "support"
    project  = "$USERNAME-ecelab"
  }

  count = 3
  name = "$USERNAME-ecelab-data-disk-\${count.index + 1}"
  type = "pd-standard"
  zone  = random_shuffle.zone_selection.result[count.index]
  size = 150
}

resource "google_compute_instance" "vm_instance" {
  count        = 3
  name         = "$USERNAME-ecelab-\${count.index + 1}"
  machine_type = "$TYPE"
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

# Define outputs to capture the IP addresses of the instances
output "instance_ips" {
  value = google_compute_instance.vm_instance[*].network_interface[0].access_config[0].nat_ip
  description = "The external IP addresses of the instances"
}
EOL
else
  cat > main.tf << EOL
provider "google" {
  project = "$PROJECT_ID"
  region  = "$REGION"
}

data "google_compute_zones" "available" {
  region = "$REGION"
}

resource "random_shuffle" "zone_selection" {
  input        = data.google_compute_zones.available.names
  result_count = 1
}

resource  "google_compute_disk" "data_disk" {
  labels = {
    division = "support"
    org      = "support"
    team     = "support"
    project  = "$USERNAME-ecelab"
  }

  count = 1
  name = "$USERNAME-ecelab-data-disk-\${count.index + 1}"
  type = "pd-standard"
  zone  = random_shuffle.zone_selection.result[count.index]
  size = 150
}

resource "google_compute_instance" "vm_instance" {
  count        = 1
  name         = "$USERNAME-ecelab-\${count.index + 1}"
  machine_type = "$TYPE"
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

# Define outputs to capture the IP addresses of the instances
output "instance_ips" {
  value = google_compute_instance.vm_instance[*].network_interface[0].access_config[0].nat_ip
  description = "The external IP addresses of the instances"
}
EOL
fi

output=$(terraform output -json)
if echo "$output" | grep -q '"instance_ips"'; then
  echo "${red}[DEBUG]${reset} Previous instances found in Terraform output. Proceeding to destroy existing resources..."
  terraform destroy -auto-approve >/dev/null 2>&1
fi

# Initialize and apply Terraform script
echo "${green}[DEBUG]${reset} Initializing Terraform..."
terraform init >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "${red}[DEBUG]${reset} Terraform initialization failed. Exiting."
  exit 1
fi

# Run terraform apply and suppress output
echo "${green}[DEBUG]${reset} Applying Terraform configuration..."
terraform apply -auto-approve >/dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "${red}[DEBUG]${reset} Terraform apply failed. Exiting."
  exit 1
fi

echo "${green}[DEBUG]${reset} Terraform apply completed successfully."


# create ansible items ---------------------------------------------------
#
# Create inventory.yml
# Parse the JSON, remove quotes, and format it as a space-separated list
echo "${green}[DEBUG]${reset} Creating instance.yml"
echo ""

ips=($(terraform output -json instance_ips | jq -r '.[]'))

# Availability zones corresponding to each IP address
availability_zones=("zone-1" "zone-2" "zone-3")

# Define the groups
groups=("primary" "secondary" "tertiary")


# Initialize the inventory file
cat <<EOL > inventory.yml
all:
  vars:
    ansible_become: yes
    device_name: sdb
  children:
EOL

# Get the number of elements (assuming all arrays are of the same length)
length=${#ips[@]}

# Loop through the IPs and corresponding zones
for ((i=0; i<$length; i++)); do
# Append the information to the inventory file
  cat <<EOL >> inventory.yml
    ${groups[$i]}:
      hosts:
        ${ips[$i]}:
          availability_zone: ${availability_zones[$i]}
EOL
  if [ $length = 1 ]; then
    break
  fi
done

get_private_key_file() {
  local config_file="ansible.cfg"
  grep -E '^private_key_file\s*=' "$config_file" | awk -F '=' '{print $2}' | xargs
}

# Function to check SSH connectivity
check_ssh() {
  local ip=$1
  local private_key_file=$2
  local retries=30
  local delay=15

  echo "${green}[DEBUG]${reset} Checking SSH connectivity for $ip..."

  for ((i=1; i<=retries; i++)); do
    #if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -i "$private_key_file" "$ip" exit 2>/dev/null; then
    if echo "" > /dev/tcp/$ip/22; then
      echo "${green}[DEBUG]${reset} $ip is reachable via SSH."
      return 0
    else
      echo "${red}[DEBUG]${reset} $ip is not reachable via SSH. Retrying in $delay seconds..."
      sleep $delay
    fi
  done

  echo "${red}[DEBUG]${reset} Failed to connect to $ip via SSH after $((retries * delay)) seconds."
  exit 1
}

private_key_file=$(get_private_key_file)
if [ -z "$private_key_file" ]; then
  echo "${red}[DEBUG]${reset} Error: private_key_file not found in ansible.cfg"
  exit 1
fi

# Loop through each IP and check SSH connectivity
for ip in "${ips[@]}"; do
  while ! check_ssh "$ip" "$private_key_file"; do
    echo "${red}[DEBUG]${reset} Retrying connection to $ip..."
  done
done

echo "${green}[DEBUG]${reset} All hosts are reachable via SSH. Proceeding with further actions..."


# Run Ansible playbook
#
echo "${green}[DEBUG]${reset} Running ansible scripts for preinstall"
echo ""
sleep 5
ansible-playbook -i inventory.yml preinstall.yml --tags preinstall  --extra-vars "crt=${container} ece_version=${version}"

if [ $? -eq 0 ]; then
  echo "${green}[DEBUG]${reset} Running ansible scripts for ECE install - Primary install does take a while......"
  echo ""
else
  echo "${red}[DEBUG]${reset} Something went wrong... exiting please remember to run ${blue}terraform destroy -auto-approve${reset} to delete the environment"
  exit 1
fi

sleep 5
ansible-playbook -i inventory.yml eceinstall.yml --tags ece  --extra-vars "crt=${container} ece_version=${version} installtype=${installtype}"

if [ $? -eq 0 ]; then
  echo ""
  echo "${green}[DEBUG]${reset} And we are done! the URL and the password is listed above"
  echo "${green}[DEBUG]${reset} Installed ECE: ${blue}${version}${reset} on ${blue}${os}${reset}"
  echo ""
  echo "${green}[DEBUG]${reset} When you are done and want to delete the workload come back to this directory and run ${blue}terraform destroy -auto-approve${reset}"
  echo ""
else
  echo "${red}[DEBUG]${reset} Something went wrong... exiting please remember to run ${blue}terraform destroy -auto-approve${reset} to delete the environment"
  exit 1
fi

