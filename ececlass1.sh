#!/usr/bin/env sh

## Creates GCP instances

# -------------- EDIT information below

### ORGANIZATION ###############

source vars

machine_type="n1-standard-8"    # GCP machine type - gcloud compute machine-types list
boot_disk_type="pd-balanced"         # disk type -  gcloud compute disk-types list
label="division=support,org=support,team=support,project=ececlass"

# --------------  Do not edit below

### PERSONAL ###################
gcp_name="$(whoami | sed $'s/[^[:alnum:]\t]//g')-ececlass"

# colors
red=$(tput setaf 1)
green=$(tput setaf 2)
blue=$(tput setaf 14)
reset=$(tput sgr0)

# Function to display help
help() {
  cat << EOF
This script is to stand up a GCP environment in ${gcp_project} Project

${green}Usage:${reset} ./$(basename "$0") COMMAND
${blue}COMMANDS${reset}
  ${green}create${reset} - Creates your GCP environment
  ${green}find${reset}   - Finds info about your GCP environment
  ${green}delete${reset} - Deletes your GCP environment
EOF
}

# Ensure PROJECT_ID is set
check_project_id() {
  if [ -z "${PROJECT_ID}" ]; then
    debugr "${blue}PROJECT_ID${reset} is not set in ${blue}vars${reset}. Please edit ${blue}vars${reset} it first."
    exit 1
  fi
}

# Call check_project_id
check_project_id

# load image list
load_image_list() {
  echo "${green}[DEBUG]${reset} Generating a list of supported images"
  image_list=$(gcloud compute images list --format="table(name, family, selfLink)" --filter="family:(ubuntu-minimal-2004-lts,rocky-linux-8-optimized-gcp) AND NOT family:arm64" | grep "\-cloud" | sort)
  IFS=$'\n' read -r -d '' -a images <<< "$image_list"

  if [ -z "$image_list" ]; then
    echo "${red}[DEBUG]${reset} No images found with the specified filters."
    exit 1
  fi

  families=($(echo "$image_list" | awk '{print $2}' | sort -u))
} # end

select_image() {
  echo "${green}[DEBUG]${reset} Select an image family:"
  original_columns=$COLUMNS
  COLUMNS=1
  select selected_family in "${families[@]}"; do
    if [ -n "$selected_family" ]; then
      selected_image=$(echo "$image_list" | grep "$selected_family" | head -n 1)
      selected_image_name=$(echo "$selected_image" | awk '{print $1}')
      selected_project=$(echo "$selected_image" | awk '{print $3}')
      break
    else
      echo "${red}[DEBUG]${reset} Invalid selection. Please try again."
    fi
  done
  COLUMNS=$original_columns
}

# find
find_instances() {
  instance_count=$(gcloud compute instances list --project "${gcp_project}" --filter="name:${gcp_name}" --format="value(name)" | wc -l)
  if [ "$instance_count" -gt 0 ]; then
    echo "${green}[DEBUG]${reset} Instance(s) found"
    gcloud compute instances list --project "${gcp_project}" --filter="name:${gcp_name}" --format="table[box](name, zone.basename(), machineType.basename(), status, networkInterfaces[0].networkIP, networkInterfaces[0].accessConfigs[0].natIP, disks[0].licenses[0].basename())"
  else
    echo "${red}[DEBUG]${reset} No instances found"
  fi
}

delete_instances() {
  # Fetch list of instances matching the name pattern
  instancelist=$(gcloud compute instances list --filter="name:${gcp_name}" --format="value(name,zone)")

  # Check if any instances were found
  if [ -z "$instancelist" ]; then
    echo "${red}[DEBUG]${reset} No instances found with name ${gcp_name}"
    return 0
  fi

  # Iterate over the list of instances and delete them
  while read -r instance_name instance_zone; do
    echo "${green}[DEBUG]${reset} Deleting instance ${blue}$instance_name${reset} in zone ${blue}${instance_zone}${reset}..."
    gcloud compute instances delete "$instance_name" --zone="$instance_zone" --delete-disks all --quiet
  done <<< "$instancelist"
}

get_random_zone() {
  local zone_array=($zones)
  local zone_count=${#zone_array[@]}
  local random_index=$((RANDOM % zone_count))
  local selected_zone=${zone_array[$random_index]}

  echo $selected_zone
}


create_instances() {
  max=3
  
  load_image_list
  select_image

  zones=$(gcloud compute zones list --filter="region:(${gcp_region})" --format="value(name)")
  
  for count in $(seq 1 "$max"); do
    gcp_zone=$(get_random_zone)
    echo ""
    echo "${green}[DEBUG]${reset} Creating instance ${blue}${gcp_name}-${count}${reset} in zone ${blue}${gcp_zone}${reset} with image ${blue}${selected_image_name}${reset}"
    echo ""
    gcloud compute instances create ${gcp_name}-${count} \
      --quiet \
      --labels ${label} \
      --project=${gcp_project} \
      --zone=${gcp_zone} \
      --machine-type=${machine_type} \
      --network-interface=network-tier=PREMIUM,subnet=default \
      --maintenance-policy=MIGRATE \
      --provisioning-model=STANDARD \
      --create-disk=auto-delete=yes,boot=yes,device-name=${gcp_name}-${count},image=projects/${selected_project}/global/images/${selected_image_name},mode=rw,type=projects/elastic-support/zones/${gcp_zone}/diskTypes/${boot_disk_type} \
      --create-disk=auto-delete=yes,device-name=${gcp_name}-${count}-data,mode=rw,name=${gcp_name}-${count}-data,size=100,type=${boot_disk_type}
      --quiet
  done

  find_instances

}

## main body
case ${1} in
  create|start)
    find_instances
    create_instances
    ;;
  find|info|status|check)
    find_instances
    ;;
  delete|cleanup|stop)
    delete_instances
    ;;
  *)
    help
    ;;
esac
