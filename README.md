# ECELAB via terraform and ansible

This script will create a single node or 3 node(small) ECE cluster in GCP.  It will allow you to install ECE versions 3.3.0 -> 3.7.2 using Rocky 8 or Ubuntu 20.04.  You can select from docker or podman install as well.

## REQUIREMENTS

You will need the following installed and configured:
- Google Cloud SDK with cli - https://cloud.google.com/sdk/docs/install-sdk#mac
- terraform `brew install terraform`
- jq `brew install jq`
- python3 & pip
- ensure that you have `~/.ssh/google_compute_engine` ssh keys that will get you into the GCP hosts - if this is named something else you will need to edit `ansible.cfg`

I created this on my macbook and only tested from the macbook so ymmv with linux

## INSTALL

- ensure you have all the software required
- run `gcloud auth application-default login` so that terraform can create GCP resources
- clone the repo `git clone git@github.com:jlim0930/ecelab.git`
- go into the directory `cd ecelab`
- edit `vars` to make the environment closer to you

## USAGE

- go into the directory `cd ecelab`
- run the install script `./deploy.sh` and select the version and OS
  - the initial install of ECE onto the first host aka `primary` does take a long time.
  - once `primary` is installed you can start logging into ECE Admin UI while the 2ndary nodes are installed. the URL and the admin users password will be displayed on the screen as the playbook runs
 
```
$ ./deploy.sh
[DEBUG] Using Project: elastic-support, Region: us-central1, Zone: us-central1-b, MachineType: n1-standard-8

[DEBUG] Configuring python venv and setting up ansible 9.8.0 - higher ansible versions have issues with EL8

[DEBUG] Select the OS for the ECE Version:
 1) 3.3.0
 2) 3.4.0
 3) 3.4.1
 4) 3.5.0
 5) 3.5.1
 6) 3.6.0
 7) 3.6.1
 8) 3.6.2
 9) 3.7.1
10) 3.7.2
#? 3
[DEBUG] Select the OS for the GCP instances:
1) Rocky 8 - Podman
2) Rocky 8 - Docker 20.10
3) Ubuntu 20.04 - Docker 20.10
#? 3
[DEBUG] ECE version: 3.4.1 OS: Ubuntu 20.04 - Docker 20.10

[DEBUG] Creating TFs

[DEBUG] Applying TF to create GCP instances

[DEBUG] Creating instance.yml

[DEBUG] Running ansible scripts for preinstall

[WARNING]: file /Users/jlim/ecelab/roles/eceinstall/tasks/postinstall/main.yml is empty and had no tasks to include

PLAY [all] *********************************************************************************************************************************

TASK [Gathering Facts] *********************************************************************************************************************
ok: [34.44.17.214]
ok: [104.154.63.110]
ok: [34.123.168.105]

TASK [eceinstall : Include OS specific vars] ***********************************************************************************************
ok: [34.44.17.214] => (item=/Users/jlim/ecelab/roles/eceinstall/vars/os_Ubuntu_20.yml)
ok: [104.154.63.110] => (item=/Users/jlim/ecelab/roles/eceinstall/vars/os_Ubuntu_20.yml)
ok: [34.123.168.105] => (item=/Users/jlim/ecelab/roles/eceinstall/vars/os_Ubuntu_20.yml)

TASK [eceinstall : Check that OS is supported] *********************************************************************************************
skipping: [34.44.17.214]
skipping: [104.154.63.110]
skipping: [34.123.168.105]

...

TASK [eceinstall : debug] ******************************************************************************************************************
ok: [104.154.63.110] => {
    "msg": "Adminconsole is reachable at: https://34.44.17.214:12443"
}
ok: [34.123.168.105] => {
    "msg": "Adminconsole is reachable at: https://34.44.17.214:12443"
}

TASK [eceinstall : debug] ******************************************************************************************************************
ok: [104.154.63.110] => {
    "msg": "Adminconsole password is: AuR1TETBRWjQPPaFJnEsPwzWWlmre2eE9nlJbGmNn5w"
}
ok: [34.123.168.105] => {
    "msg": "Adminconsole password is: AuR1TETBRWjQPPaFJnEsPwzWWlmre2eE9nlJbGmNn5w"
}

TASK [eceinstall : include_tasks] **********************************************************************************************************
skipping: [104.154.63.110]
skipping: [34.123.168.105]

PLAY RECAP *********************************************************************************************************************************
104.154.63.110             : ok=14   changed=4    unreachable=0    failed=0    skipped=10   rescued=0    ignored=0
34.123.168.105             : ok=14   changed=4    unreachable=0    failed=0    skipped=10   rescued=0    ignored=0
34.44.17.214               : ok=16   changed=4    unreachable=0    failed=0    skipped=9    rescued=0    ignored=0

$
```


### SIDE NOTES
- The gcp instances will be named `USERNAME-ecelab-{1|2|3}` and you should be able to ssh to it.
- if you want to run additional ansible playbooks make sure to activate the venv environment first by `source ecelab/bin/activate`

## DELETE

When you are done with your work please delete the environment
- To delete all resources `terraform destroy -auto-approve`


## NOTES

- Why was Rocky 8 chosen instead of CentOS? - CentOS8 was EOL'ed by GCP and no longer available.
- The script will create a python venv and use ansible 9.8.0 instead of the latest.  This is due to an issue with ansible where the latest ansible cannot gather facts or do anything with yum/dnf in EL8 and beyond due to yum/dnf using older python library which is not updated. - https://github.com/ansible/ansible/issues/71668
- According to the Support Matrix Rocky8 is not supported for ECE 3.3->3.6 however it is still possible to install ECE with some massaging.  Same for running Rocky8 with Podman for 3.3-> 3.6








