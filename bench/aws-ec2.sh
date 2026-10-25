#!/usr/bin/env bash
# Publishable overhead benchmark (T03) on a dedicated EC2 instance.
#
#   bench/aws-ec2.sh up      # key pair, SG (your IP /32 on 22), instance; waits for setup
#   bench/aws-ec2.sh push    # copy this checkout (git archive HEAD), build, install
#   bench/aws-ec2.sh run     # start bench/run.sh --wide in the background (~1.5 h)
#   bench/aws-ec2.sh status  # tail of the remote log
#   bench/aws-ec2.sh fetch   # copy bench/results/*.md back into bench/results/
#   bench/aws-ec2.sh down    # terminate instance, delete SG and key pair
#
# Settings: AWS_PROFILE / AWS_REGION, BENCH_TYPE (default c7gd.xlarge: 4
# Graviton3 vCPU, non-burstable, local NVMe), BENCH_PG (default 17),
# BENCH_ARGS (bench/run.sh arguments, default --wide), BENCH_LABEL_SUFFIX.
# The private key goes to ~/.ssh/pgsiq-bench.pem (mode 600) and is deleted by down.
set -euo pipefail

TYPE="${BENCH_TYPE:-c7gd.xlarge}"
PGV="${BENCH_PG:-17}"
NAME=pgsiq-bench
KEY="$HOME/.ssh/$NAME.pem"
repo="$(cd "$(dirname "$0")/.." && pwd)"
aws_() { aws --output text "$@"; }
log() { printf '\n=== %s\n' "$*"; }

instance_id() {
  aws_ ec2 describe-instances --filters "Name=tag:Name,Values=$NAME" \
       "Name=instance-state-name,Values=pending,running,stopping,stopped" \
       --query 'Reservations[0].Instances[0].InstanceId' | grep -v None || true
}
host() { aws_ ec2 describe-instances --instance-ids "$(instance_id)" --query 'Reservations[0].Instances[0].PublicIpAddress'; }
ssh_() { ssh -i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.ssh/$NAME.known_hosts" \
             -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "ubuntu@$(host)" "$@"; }

up() {
  vpc="$(aws_ ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId')"
  ip="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  ami="$(aws_ ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id --query Parameter.Value)"
  log "key pair"
  mkdir -p -m 700 "$HOME/.ssh"
  if [ ! -f "$KEY" ]; then
    aws_ ec2 create-key-pair --key-name "$NAME" --key-type ed25519 --query KeyMaterial \
        --tag-specifications "ResourceType=key-pair,Tags=[{Key=project,Value=pgsiq-lab}]" > "$KEY"
    chmod 600 "$KEY"
  fi
  log "security group"
  sg="$(aws_ ec2 describe-security-groups --filters "Name=group-name,Values=$NAME-sg" --query 'SecurityGroups[0].GroupId' | grep -v None || true)"
  if [ -z "$sg" ]; then
    sg="$(aws_ ec2 create-security-group --group-name "$NAME-sg" --vpc-id "$vpc" --description "pgsiq bench: ssh from one IP" \
           --tag-specifications "ResourceType=security-group,Tags=[{Key=project,Value=pgsiq-lab}]" --query GroupId)"
  fi
  aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 22 --cidr "$ip/32" >/dev/null 2>&1 || true
  log "instance $TYPE ($ami)"
  if [ -z "$(instance_id)" ]; then
    # Setup: PGDG PostgreSQL $PGV + build deps; local NVMe (if any) at /mnt/nvme for the bench cluster.
    ud="$(mktemp)"
    cat > "$ud" <<EOF
#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates gnupg build-essential libkrb5-dev libzstd-dev liblz4-dev libssl-dev libreadline-dev zlib1g-dev
install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt noble-pgdg main" > /etc/apt/sources.list.d/pgdg.list
apt-get update
apt-get install -y postgresql-$PGV postgresql-server-dev-$PGV postgresql-contrib-$PGV
systemctl disable --now postgresql || true
dev=\$(lsblk -dpno NAME,MODEL | awk '/Instance Storage/ {print \$1; exit}')
if [ -n "\$dev" ]; then mkfs.ext4 -q -F "\$dev"; mkdir -p /mnt/nvme; mount -o noatime "\$dev" /mnt/nvme; chown ubuntu: /mnt/nvme; fi
touch /var/lib/cloud/pgsiq-ready
EOF
    aws ec2 run-instances --image-id "$ami" --instance-type "$TYPE" --key-name "$NAME" \
        --security-group-ids "$sg" --associate-public-ip-address --user-data "file://$ud" \
        --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}' \
        --instance-initiated-shutdown-behavior terminate \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=project,Value=pgsiq-lab}]" \
                             "ResourceType=volume,Tags=[{Key=project,Value=pgsiq-lab}]" >/dev/null
    rm -f "$ud"
  fi
  aws ec2 wait instance-running --instance-ids "$(instance_id)"
  echo "running: $(instance_id) $(host)"
  log "waiting for setup (PostgreSQL $PGV install)"
  for _ in $(seq 1 60); do
    ssh_ -n test -f /var/lib/cloud/pgsiq-ready 2>/dev/null && { echo ready; return; }
    sleep 10
  done
  echo "setup not finished after 10 minutes; check: ssh_ sudo tail /var/log/cloud-init-output.log" >&2
  exit 1
}

push() {
  log "copy checkout $(git -C "$repo" rev-parse --short HEAD) and build"
  git -C "$repo" archive --format=tar HEAD | ssh_ 'rm -rf ~/src && mkdir ~/src && tar -x -C ~/src'
  ssh_ -n "cd ~/src && make PG_CONFIG=/usr/lib/postgresql/$PGV/bin/pg_config COPT=-Werror >/dev/null && sudo make PG_CONFIG=/usr/lib/postgresql/$PGV/bin/pg_config install >/dev/null && echo built"
}

run() {
  log "start bench (background; ~1.5 h)"
  note="$(ssh_ -n "lscpu | awk -F: '/Model name|^CPU\\(s\\)/ {gsub(/^ +/,\"\",\$2); printf \"%s; \", \$2}'; free -g | awk '/Mem:/ {printf \"%s GB RAM; \", \$2}'; lsblk -dno MODEL /dev/nvme1n1 2>/dev/null | tr -d '\\n'; echo '; '; uname -r")"
  ssh_ -n "nohup bash -c 'cd ~/src && export TMPDIR=\$( [ -d /mnt/nvme ] && echo /mnt/nvme || echo /tmp ) PG_CONFIG=/usr/lib/postgresql/$PGV/bin/pg_config PATH=/usr/lib/postgresql/$PGV/bin:\$PATH && \
        ./bench/run.sh ${BENCH_ARGS:---wide} --label aws-$TYPE-pg$PGV${BENCH_LABEL_SUFFIX:-} --note \"AWS $TYPE ap-southeast-2, data on local NVMe; $note\"' > ~/bench.log 2>&1 < /dev/null & echo started"
}

status() { ssh_ -n 'tail -5 ~/bench.log; ls ~/src/bench/results/'; }

fetch() {
  log "results"
  scp -i "$KEY" -o UserKnownHostsFile="$HOME/.ssh/$NAME.known_hosts" "ubuntu@$(host):src/bench/results/*aws-*.md" "$repo/bench/results/"
  ls -1 "$repo"/bench/results/*aws-*.md
}

down() {
  id="$(instance_id)"
  if [ -n "$id" ]; then
    aws ec2 terminate-instances --instance-ids "$id" >/dev/null; echo "terminating $id"
    aws ec2 wait instance-terminated --instance-ids "$id"
  fi
  sg="$(aws_ ec2 describe-security-groups --filters "Name=group-name,Values=$NAME-sg" --query 'SecurityGroups[0].GroupId' | grep -v None || true)"
  [ -n "$sg" ] && aws ec2 delete-security-group --group-id "$sg" && echo "deleted $sg"
  aws ec2 delete-key-pair --key-name "$NAME" >/dev/null 2>&1 && echo "deleted key pair"
  rm -f "$KEY" "$HOME/.ssh/$NAME.known_hosts"
  log "left over (should be empty)"
  aws_ ec2 describe-instances --filters "Name=tag:project,Values=pgsiq-lab" "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId'
}

case "${1:-}" in
  up|push|run|status|fetch|down) "$1" ;;
  *) sed -n '2,14p' "$0"; exit 2 ;;
esac
