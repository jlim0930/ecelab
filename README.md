# ECE Lab — Automated Elastic Cloud Enterprise Deployment

Automates the provisioning and installation of Elastic Cloud Enterprise (ECE) on Google Cloud Platform using Terraform and Ansible. Deploy a single-node or 3-node (small) ECE cluster in minutes — either through an interactive CLI or a browser-based Web UI.

## Features

- **Two deployment methods** — CLI (`deploy.sh`) for power users and terminal workflows, Web UI (`web.sh`) for a visual, browser-based experience
- **ECE 3.3.0 through 4.1.0+** — full version coverage with easy extension via the `vars` file
- **Multiple OS/runtime combinations** — Rocky 8/9 (Podman), Ubuntu 22.04/24.04 (Docker), x86_64 and arm64
- **SELinux support** — optional enforcing mode for Rocky-based deployments (ECE ≥ 3.7.1)
- **Auto-termination** — GCP instances automatically deleted after a configurable number of days
- **Post-install optimization** — automatic API calls to resize system deployments to 2 zones
- **Cross-platform** — runs on Linux, macOS, and WSL
- **Data-driven configuration** — all version lists and OS mappings live in `vars` for easy maintenance

## Requirements

Install and configure the following before running:

| Tool | Install | Notes |
|------|---------|-------|
| Google Cloud SDK | [Install Guide](https://cloud.google.com/sdk/docs/install-sdk) | Must be authenticated with `gcloud auth application-default login` |
| Terraform | `brew install terraform` | Infrastructure provisioning |
| jq | `brew install jq` | JSON processing |
| Python 3 + pip | System package manager | Ansible dependency |
| SSH key | `~/.ssh/google_compute_engine` | Must grant access to GCP instances. Edit `ansible.cfg` if using a different path |
| Node.js 18+ | `brew install node` | **Web UI only** — not needed for CLI usage |

## Quick Start

```bash
# 1. Clone the repository
git clone git@github.com:jlim0930/ecelab.git
cd ecelab

# 2. Configure your environment
#    Edit 'vars' to set PROJECT_ID, REGION, and MAX_RUN_DAYS

# 3. Authenticate with GCP
gcloud auth application-default login

# 4. Deploy — pick one:
./deploy.sh          # CLI: interactive terminal prompts
./web.sh             # Web UI: opens browser at http://localhost:3000
```

---

## Method 1: CLI (`deploy.sh`)

The CLI method runs entirely in your terminal with interactive selection menus.

### Deploy (Interactive)

```bash
./deploy.sh
```

You'll be guided through three selections:
1. **Deployment size** — `single` (1 node) or `small` (3 nodes)
2. **ECE version** — e.g., `3.8.4`, `4.0.3`, `4.1.0`
3. **OS/runtime** — filtered based on your ECE version selection

Example session:

```
[INFO]  Select the deployment size:
1) single
2) small
#? 2
[INFO]  Select the ECE Version:
 1) 3.3.0    5) 3.5.1    9) 3.7.3   13) 3.8.4   17) 4.0.3
 2) 3.4.0    6) 3.6.0   10) 3.8.0   14) 4.0.0   18) 4.1.0
 3) 3.4.1    7) 3.6.1   11) 3.8.1   15) 4.0.1
 4) 3.5.0    8) 3.6.2   12) 3.8.2   16) 4.0.2
#? 14
[INFO]  Select the OS for the GCP instances:
 1) Rocky 8 - Podman - x86_64
 2) Rocky 8 - Podman - x86_64 - selinux
 3) Rocky 8 - Podman - arm64
 ...
#? 1
[INFO]  Using Project: elastic-support, Region: us-central1, MachineType: n1-highmem-8
[INFO]  ECE version: 4.0.0 OS: Rocky 8 - Podman - x86_64 Install Type: small
```

### Deploy (Non-Interactive / Preselected)

Edit the `vars` file and uncomment the `PRESELECTED_*` variables:

```bash
PRESELECTED_installtype="single"
PRESELECTED_version="4.0.0"
PRESELECTED_os="Rocky 8 - Podman - x86_64"
```

Then run `./deploy.sh` — it will skip all prompts and deploy immediately.

### Debug Mode

```bash
./deploy.sh --debug
```

Enables shell tracing (`set -x`), Terraform debug logs, and verbose stderr output.

### Find Existing Instances

```bash
./deploy.sh find
```

Displays a table of your running instances, SSH commands, the ECE admin console URL, and the admin password.

### Cleanup / Delete

```bash
./deploy.sh cleanup
# or
./deploy.sh delete
```

Destroys all GCP resources (instances, disks, firewall rules) and cleans up local Terraform state.

Example cleanup output:

```
This is a destructive change (Y/n): Y
Proceeding with delete...
[INFO]  Starting cleanup of user-ecelab resources...
[INFO]  Attempting terraform destroy...
[INFO]  Terraform destroy succeeded.
[INFO]  Cleaning up local Terraform files...
[INFO]  Cleanup complete. Run ./deploy.sh to deploy fresh.
```

---

## Method 2: Web UI (`web.sh`)

The Web UI provides a browser-based interface for deploying and managing ECE clusters. It runs a local Next.js server that calls `deploy.sh` under the hood.

### Starting the Web UI

```bash
./web.sh             # Start on default port 3000
./web.sh 8080        # Start on custom port
```

The script will:
1. Check for Node.js 18+
2. Install npm dependencies (first run only)
3. Start the Next.js dev server
4. Open your browser automatically

### Deploying via Web UI

1. Open the UI at `http://localhost:3000`
2. Select **Deployment Size** (Single Node or Small Cluster)
3. Choose an **ECE Version** from the dropdown
4. Pick an **Operating System** (options filter based on the selected version)
5. Optionally enable **Debug output**
6. Click **Deploy**

The UI shows:
- **Real-time progress bar** tracking each deployment stage (Prerequisites → Environment → Infrastructure → Connectivity → Installation → Complete)
- **Colorized log output** streamed live from `deploy.sh`
- **Cancel button** to abort a running deployment and auto-clean up
- **Deployment info panel** showing version, platform, creation date, and auto-delete warning

### Viewing Deployment Details (Web UI)

After a successful deploy, the UI displays:
- Admin console links (clickable, one per node)
- Admin password with a copy button
- Instance table with name, public/private IPs, zone, machine type, and status
- Deployment creation date and auto-delete countdown

### Cleanup via Web UI

Click the **Cleanup** button (available in the form view or after deployment). A confirmation modal will appear before any resources are destroyed. The cleanup progress is shown with its own step bar and live log output.

### Theme Toggle

Use the sun/moon icons in the top-right corner to switch between dark and light modes.

---

## Configuration

All configuration lives in the `vars` file:

| Variable | Default | Description |
|----------|---------|-------------|
| `PROJECT_ID` | `elastic-support` | GCP project ID |
| `REGION` | `us-central1` | GCP region (use `us-central1` or `us-east1` due to VPC) |
| `DISK_TYPE` | `pd-balanced` | Data disk type (`pd-ssd` for faster bootstrap, `pd-balanced` for lower cost) |
| `MAX_RUN_DAYS` | `7` | Auto-terminate instances after this many days |
| `ECE_VERSIONS` | *(array)* | List of ECE versions shown in menus |
| `OS_OPTIONS_V4` | *(array)* | OS choices for ECE ≥ 4.0.0 |
| `OS_OPTIONS_V38` | *(array)* | OS choices for ECE 3.8.x |
| `OS_OPTIONS_V37` | *(array)* | OS choices for ECE 3.7.x |
| `OS_OPTIONS_V3` | *(array)* | OS choices for ECE < 3.7.0 |

### Adding a New ECE Version

1. Add the version string to the `ECE_VERSIONS` array in `vars`
2. If the new version requires new OS options, add entries to the appropriate `OS_OPTIONS_V*` array (or create a new one)
3. If a new OS array is needed, update the version-range logic in both `deploy.sh` (`get_os_options_for_version`) and `web/lib/vars-parser.js` (`getOsOptionsForVersion`)

### Adding a New OS Option

Add a pipe-delimited entry to the appropriate `OS_OPTIONS_V*` array:

```
"Display Name|gcp-image|container|version|disk_x86|disk_arm|selinux|type_single_x86|type_small_x86|type_single_arm|type_small_arm"
```

Example:

```
"Rocky 9 - Podman - x86_64|rocky-linux-cloud/rocky-linux-9-optimized-gcp|podman|5|sdb|nvme0n2|none|n1-highmem-8|n1-standard-8|t2a-standard-16|t2a-standard-8"
```

## Project Structure

```
ecelab/
├── deploy.sh              # Main deployment script (CLI)
├── web.sh                 # Web UI launcher
├── vars                   # Configuration: versions, OS mappings, GCP settings
├── ansible.cfg            # Ansible SSH and logging configuration
├── combined.yml           # Playbook: preinstall + ECE install (both roles)
├── preinstall.yml         # Playbook: OS preparation only
├── eceinstall.yml         # Playbook: ECE installation only
├── roles/
│   ├── preinstall/        # OS configuration role
│   │   ├── defaults/      #   Default variables
│   │   ├── vars/          #   OS-specific package versions
│   │   ├── tasks/         #   Main tasks and subtasks
│   │   │   ├── subtasks/  #     Modular config tasks
│   │   │   ├── Ubuntu-*/  #     Ubuntu-specific tasks
│   │   │   └── Rocky-*/   #     Rocky-specific tasks
│   │   ├── handlers/      #   Ansible handlers
│   │   └── templates/     #   Jinja2 templates
│   └── eceinstall/        # ECE installation role
│       ├── defaults/      #   Default variables (memory, URLs)
│       └── tasks/         #   Primary and secondary install tasks
│           ├── primary/   #     Primary node installation
│           └── secondary/ #     Secondary node enrollment
├── web/                   # Web UI (Next.js 14 + React 18)
│   ├── package.json       #   Dependencies
│   ├── next.config.mjs    #   Next.js configuration
│   ├── app/
│   │   ├── layout.jsx     #   Root layout (favicon, title)
│   │   ├── globals.css    #   Elastic-themed dark/light CSS
│   │   ├── page.jsx       #   Main UI component (form, log viewer, panels)
│   │   └── api/
│   │       ├── deploy/    #     POST to deploy, GET for SSE log stream
│   │       ├── cancel/    #     POST to cancel deploy + auto-cleanup
│   │       ├── cleanup/   #     POST to start cleanup
│   │       ├── instances/ #     GET instance data from deploy.sh find
│   │       ├── options/   #     GET versions and OS options from vars
│   │       └── status/    #     GET git status and deployment state
│   └── lib/
│       ├── process-manager.js  # Singleton: spawns/manages deploy.sh subprocess
│       └── vars-parser.js      # Parses the bash vars file for the web UI
└── README.md
```

## How It Works

1. **Prerequisites** — checks for gcloud, terraform, jq, python3, pip, SSH key
2. **Python venv** — creates a virtual environment with Ansible 9.8.0
3. **Interactive selection** — deployment size, ECE version, OS/runtime (CLI prompts or Web UI form)
4. **Terraform** — provisions GCP compute instances, disks, and firewall rules
5. **SSH verification** — waits for all instances to be reachable
6. **Ansible preinstall** — configures the OS (packages, Docker/Podman, kernel, filesystem, users)
7. **Ansible ECE install** — installs ECE on the primary node, then enrolls secondary nodes
8. **Post-install** — sets cluster CNAME, accepts EULA, resizes system deployments to 2 zones
9. **Output** — displays instance info, admin console URL, and admin password

The Web UI wraps the same `deploy.sh` script — the Node.js server spawns `deploy.sh` as a child process, sets `PRESELECTED_*` environment variables to bypass interactive prompts, and streams stdout/stderr back to the browser via Server-Sent Events (SSE).

## Troubleshooting

### Terraform apply fails
- Check `terraform.log` for detailed error messages
- Ensure `gcloud auth application-default login` has been run recently
- Verify your GCP project has the required APIs enabled (Compute Engine)
- Run `./deploy.sh cleanup` and try again

### SSH connectivity timeout
- GCP instances can take 2-5 minutes to become reachable after creation
- The script retries for up to 7.5 minutes (30 retries × 15 seconds)
- Check your SSH key path in `ansible.cfg`
- Verify GCP firewall rules allow port 22

### Ansible playbook failures
- Check `ecelab.log` for detailed Ansible output
- Ensure the Python venv is active: `source ecelab/bin/activate`
- For package installation failures, the target OS may have stale repo caches

### ECE primary installation is slow
- The primary installation is expected to take 20-40 minutes
- The script monitors `bootstrap.log` and polls every 60 seconds
- Docker/Podman image pulls are the main bottleneck

### Previous deployment still exists
- Run `./deploy.sh cleanup` (or click Cleanup in the Web UI) to destroy all resources before redeploying
- If cleanup fails, manually delete via the GCP console

### Web UI won't start
- Ensure Node.js 18+ is installed: `node -v`
- Delete `web/node_modules` and re-run `./web.sh` to reinstall dependencies
- Check that the default port (3000) is not already in use — `web.sh` will try alternative ports automatically

### Web UI log output stops scrolling
- During long Ansible tasks (e.g., "Wait for primary installation"), Ansible buffers output per task — this is expected behavior. Output will resume when the task completes.
- The Web UI uses `stdbuf` for line-buffered output and `PYTHONUNBUFFERED=1` to minimize buffering.

### "Python 3 is required" on macOS
- Install via Homebrew: `brew install python3`
- Or use the system Python: ensure `/usr/bin/python3` exists

### Ansible errors about EL8 facts
- This is why the script pins Ansible 9.8.0 — newer versions have issues gathering facts on EL8
- The Python venv isolates this from your system Ansible installation

## FAQ

**Q: Why Rocky Linux instead of CentOS?**
CentOS 8 was EOL'd by GCP and is no longer available as a base image.

**Q: Why is Ansible pinned to 9.8.0?**
Newer Ansible versions cannot gather facts or manage packages on EL8 due to Python library compatibility issues.

**Q: What's the difference between CLI and Web UI?**
Both run the exact same `deploy.sh` script. The Web UI adds a visual interface with dropdowns, progress bars, and live colorized log output. Use whichever you prefer.

**Q: Can I use Rocky 8 with ECE versions before 3.7?**
Technically yes — the script supports it — but the official support matrix does not list Rocky 8 for ECE 3.3-3.6.

**Q: Can I run additional Ansible playbooks after deployment?**
Yes — activate the venv first: `source ecelab/bin/activate`, then run your playbooks against `inventory.yml`.

**Q: How do I extend the instance lifetime?**
Edit `MAX_RUN_DAYS` in `vars` before deploying. The auto-termination timer is set at instance creation time and cannot be changed after.

**Q: What happens when instances auto-terminate?**
GCP deletes the instances after `MAX_RUN_DAYS`. Terraform state and other local artifacts remain — run `./deploy.sh cleanup` (or click Cleanup in the Web UI) before deploying again.

**Q: I use a custom SSH key, not the default `google_compute_engine` key. How do I configure it?**
Edit `ansible.cfg` and update the `private_key_file` setting to point to your key:
```ini
private_key_file = ~/.ssh/my_custom_key
```
Note: SSH keys with passphrases are not supported. The key must be passphrase-free for Ansible to connect non-interactively.

## Notes

- GCP instances are named `USERNAME-ecelab-{1|2|3}` where USERNAME is your login truncated to 10 characters
- The firewall rule name includes your username to avoid conflicts with other users
- The script excludes `us-central1-a` zone due to known capacity issues
- All Ansible playbooks use fully qualified collection names (FQCNs) for forward compatibility
- Container runtime (Docker/Podman) installation runs asynchronously to speed up the preinstall phase
