#!/bin/bash
# cloud-init user data: install tools, kcat and rpk. Rendered by templatefile();
# log: /var/log/cloud-init-output.log.
set -euxo pipefail

if [ -n "${apt_mirror}" ]; then
  sed -i -E 's#http://[a-z0-9-]+\.ec2\.archive\.ubuntu\.com/ubuntu/?#${apt_mirror}#' \
    /etc/apt/sources.list.d/ubuntu.sources
fi

export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 install -y unzip curl netcat-openbsd jq kcat bash-completion

curl -fsSL -o /tmp/rpk.zip "${rpk_url}"
unzip -o /tmp/rpk.zip -d /usr/local/bin/
rpk generate shell-completion bash >/etc/bash_completion.d/rpk
rpk version
