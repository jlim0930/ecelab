# ECELAB via terraform and ansible

This script will create a 3 node ECE cluster in GCP.  It will allow you to install ECE versions 3.3.0 -> 3.7.2 using Rocky 8 or Ubuntu 20.04.  You can select from docker or podman install as well.

## REQUIREMENTS

You will need the following installed and configured:
- Google Cloud SDK with cli - https://cloud.google.com/sdk/docs/install-sdk#mac
- terraform `brew install terraform`
- jq `brew install jq`
- python3 & pip

I created this on my macbook and only tested from the macbook so ymmv with linux/windows.

## INSTALL

- clone the repo `git clone git@github.com:jlim0930/ecelab.git`
- run `gcloud auth application-default login` so that terraform can create GCP resources
- go into the directory `cd ecelab`
- run the install script `./deploy.sh` and select the version and OS
  - the initial install of ECE onto the first host aka `prime` will take a long time.
  - once `prime` is installed you can start logging into ECE Admin UI while the 2ndary nodes are installed

## DELETE

When you are done with your work please delete the environment
- To delete all resources `terraform destroy -auto-approve`


## NOTES

- Why was Rocky 8 chosen instead of CentOS? - CentOS8 was EOL'ed by GCP and no longer available.
- The script will create a python venv and use ansible 9.8.0 instead of the latest.  This is due to an issue with ansible where the latest ansible cannot gather facts or do anything with yum/dnf in EL8 and beyond due to yum/dnf using older python library which is not updated. - https://github.com/ansible/ansible/issues/71668
- According to the Support Matrix Rocky8 is not supported for ECE 3.3->3.6 however it is still possible to install ECE with some massaging.  Same for running Rocky8 with Podman for 3.3-> 3.6



