#!/bin/bash

# load vars
source vars

# set username
USERNAME="$(whoami | sed $'s/[^[:alnum:]\t]//g')"

# colors
red=`tput setaf 1`
green=`tput setaf 2`
blue=`tput setaf 14`
reset=`tput sgr0`

# Confirm the variables
echo "${green}[DEBUG]${reset} Using Project: ${blue}$PROJECT_ID${reset}, Region: ${blue}$REGION${reset}, Zone: ${blue}$ZONE${reset}, MachineType: ${blue}$TYPE${reset}"
echo ""

#--------------------------------------------------

# setup env for ansible 9.8.0
echo "${green}[DEBUG]${reset} Configuring python venv and setting up ansible 9.8.0 - higher ansible versions have issues with EL8"
echo ""
python3 -m venv ecelab>/dev/null 2>&1
source ecelab/bin/activate >/dev/null 2>&1
pip install --upgrade pip >/dev/null 2>&1
pip install ansible==9.8.0 >/dev/null 2>&1

# function used for version checking and comparing
checkversion() {
  echo "$@" | awk -F. '{ printf("%d%02d%02d%02d\n", $1,$2,$3,$4); }'
} # end of checkversion function

# Save the original COLUMNS value
original_columns=$COLUMNS
COLUMNS=1

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

echo "${green}[DEBUG]${reset} ECE version: ${blue}${version}${reset} OS: ${blue}${os}${reset}"
echo ""

# terraform -----------------------------------------------
#
# Generate Terraform script
echo "${green}[DEBUG]${reset} Creating TFs"
echo ""

cat > main.tf << EOL
provider "google" {
  project = "$PROJECT_ID"
  region  = "$REGION"
}

resource  "google_compute_disk" "data_disk" {
  count = 3
  name = "$USERNAME-ecelab-data-disk-\${count.index + 1}"
  type = "pd-standard"
  zone = "$ZONE"
  size = 150
}

resource "google_compute_instance" "vm_instance" {
  count        = 3
  name         = "$USERNAME-ecelab-\${count.index + 1}"
  machine_type = "$TYPE"
  zone         = "$ZONE"

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

# Initialize and apply Terraform script
echo "${green}[DEBUG]${reset} Applying TF to create GCP instances"
echo ""

terraform init >/dev/null 2>&1
terraform apply -auto-approve >/dev/null 2>&1

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
done

# Run Ansible playbook
#
echo "${green}[DEBUG]${reset} Running ansible scripts for preinstall"
echo ""
sleep 30
ansible-playbook -i inventory.yml preinstall.yml --tags preinstall  --extra-vars "crt=${container} ece_version=${version}"

echo "${green}[DEBUG]${reset} Running ansible scripts for ECE install - Primary install does take a while......"
echo ""
sleep 10
ansible-playbook -i inventory.yml eceinstall.yml --tags ece  --extra-vars "crt=${container} ece_version=${version}"

echo ""
echo "${green}[DEBUG]${reset} And we are done! the URL and the password is listed above"
echo ""
echo "${gree}[DEBUG]${reset} When you are done and want to delete the workload come back to this directory and run ${blue}terraform destroy -auto-approve${reset}"
echo ""
