#!/usr/bin/env bash
# Create, use and delete the AWS resources for the index lab (task T05).
#
#   lab-aws.sh preflight   # check CLI, identity, region, default VPC; no changes
#   lab-aws.sh up          # create SG, parameter groups, Aurora cluster (writer +
#                          # reader) and an RDS instance; waits until available
#   lab-aws.sh run         # run the lab: Aurora writer (pg_tle install), Aurora
#                          # reader phase, RDS (plain install); reports in lab-out/
#   lab-aws.sh status      # what exists now
#   lab-aws.sh down        # delete everything this script created (no snapshots)
#
# Settings (environment): AWS_PROFILE / AWS_REGION as usual, LAB_PREFIX
# (default pgsiq-lab), LAB_PG_MAJOR (default 17), LAB_AURORA_CLASS
# (db.t4g.medium), LAB_RDS_CLASS (db.t4g.micro), LAB_NO_READER=1 to skip the
# reader instance. Master passwords are managed by RDS in Secrets Manager and
# read only into this process's environment; nothing is written to disk.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
lab="$(cd "$here/.." && pwd)"
repo="$(cd "$lab/../../.." && pwd)"

P="${LAB_PREFIX:-pgsiq-lab}"
MAJOR="${LAB_PG_MAJOR:-17}"
AURORA_CLASS="${LAB_AURORA_CLASS:-db.t4g.medium}"
RDS_CLASS="${LAB_RDS_CLASS:-db.t4g.micro}"
USER_NAME=labadmin
CLUSTER="$P-aurora"
WRITER="$P-aurora-w"
READER="$P-aurora-r"
RDS="$P-rds"
CPG="$P-apg$MAJOR"
RPG="$P-pg$MAJOR"
SG_NAME="$P-sg"
TAGS="Key=project,Value=$P"

aws_() { aws --output text "$@"; }
aurora_instances() { echo "$WRITER"; [ -n "${LAB_NO_READER:-}" ] || echo "$READER"; }
log() { printf '\n=== %s\n' "$*"; }

sg_id() {
  aws_ ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" \
       --query 'SecurityGroups[0].GroupId' 2>/dev/null | grep -v None || true
}

preflight() {
  command -v aws >/dev/null || { echo "aws CLI not found (brew install awscli)"; exit 1; }
  command -v psql >/dev/null || { echo "psql not found"; exit 1; }
  log "identity"
  aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output table
  region="$(aws configure get region || true)"; region="${AWS_REGION:-${region:-}}"
  [ -n "$region" ] || { echo "no region: set AWS_REGION or run aws configure"; exit 1; }
  echo "region: $region"
  log "default VPC"
  vpc="$(aws_ ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId')"
  [ "$vpc" != "None" ] || { echo "no default VPC in $region; create one (aws ec2 create-default-vpc)"; exit 1; }
  echo "$vpc"
  log "engine versions available (latest 3)"
  echo "aurora-postgresql $MAJOR:"; aws_ rds describe-db-engine-versions --engine aurora-postgresql \
       --query "DBEngineVersions[?starts_with(EngineVersion,'$MAJOR.')].EngineVersion" | tr '\t' '\n' | tail -3
  echo "postgres $MAJOR:"; aws_ rds describe-db-engine-versions --engine postgres \
       --query "DBEngineVersions[?starts_with(EngineVersion,'$MAJOR.')].EngineVersion" | tr '\t' '\n' | tail -3
  log "your public IP (the security group will allow only this /32 on 5432)"
  curl -fsS https://checkip.amazonaws.com
  log "existing lab resources"
  status
}

latest_version() {
  aws_ rds describe-db-engine-versions --engine "$1" \
       --query "DBEngineVersions[?starts_with(EngineVersion,'$MAJOR.')].EngineVersion" | tr '\t' '\n' | sort -V | tail -1
}

up() {
  vpc="$(aws_ ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId')"
  ip="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  apg_ver="$(latest_version aurora-postgresql)"
  pg_ver="$(latest_version postgres)"
  echo "Aurora PostgreSQL $apg_ver: $(aurora_instances | tr '\n' ' ')($AURORA_CLASS); RDS PostgreSQL $pg_ver ($RDS_CLASS); access from $ip/32"

  log "security group"
  sg="$(sg_id)"
  if [ -z "$sg" ]; then
    sg="$(aws_ ec2 create-security-group --group-name "$SG_NAME" --vpc-id "$vpc" \
           --description "index lab: postgres from one IP" \
           --tag-specifications "ResourceType=security-group,Tags=[{Key=project,Value=$P}]" --query GroupId)"
  fi
  aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port 5432 --cidr "$ip/32" >/dev/null 2>&1 || true
  echo "$sg"

  log "parameter groups"
  aws rds create-db-cluster-parameter-group --db-cluster-parameter-group-name "$CPG" \
      --db-parameter-group-family "aurora-postgresql$MAJOR" --description "index lab" --tags "$TAGS" >/dev/null 2>&1 || true
  aws rds modify-db-cluster-parameter-group --db-cluster-parameter-group-name "$CPG" --parameters \
      "ParameterName=shared_preload_libraries,ParameterValue='pg_stat_statements,pg_tle',ApplyMethod=pending-reboot" \
      "ParameterName=aurora_compute_plan_id,ParameterValue=on,ApplyMethod=pending-reboot" >/dev/null
  aws rds create-db-parameter-group --db-parameter-group-name "$RPG" \
      --db-parameter-group-family "postgres$MAJOR" --description "index lab" --tags "$TAGS" >/dev/null 2>&1 || true
  aws rds modify-db-parameter-group --db-parameter-group-name "$RPG" --parameters \
      "ParameterName=shared_preload_libraries,ParameterValue='pg_stat_statements,pg_tle',ApplyMethod=pending-reboot" >/dev/null

  log "Aurora cluster $CLUSTER"
  aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" >/dev/null 2>&1 ||
    aws rds create-db-cluster --db-cluster-identifier "$CLUSTER" --engine aurora-postgresql \
        --engine-version "$apg_ver" --master-username "$USER_NAME" --manage-master-user-password \
        --db-cluster-parameter-group-name "$CPG" --vpc-security-group-ids "$sg" \
        --backup-retention-period 1 --no-deletion-protection --storage-encrypted --tags "$TAGS" >/dev/null
  for inst in $(aurora_instances); do
    aws rds describe-db-instances --db-instance-identifier "$inst" >/dev/null 2>&1 ||
      aws rds create-db-instance --db-instance-identifier "$inst" --db-cluster-identifier "$CLUSTER" \
          --engine aurora-postgresql --db-instance-class "$AURORA_CLASS" --publicly-accessible \
          --no-auto-minor-version-upgrade --tags "$TAGS" >/dev/null
    [ "$inst" = "$WRITER" ] && aws rds wait db-instance-available --db-instance-identifier "$WRITER"
  done

  log "RDS instance $RDS"
  aws rds describe-db-instances --db-instance-identifier "$RDS" >/dev/null 2>&1 ||
    aws rds create-db-instance --db-instance-identifier "$RDS" --engine postgres --engine-version "$pg_ver" \
        --db-instance-class "$RDS_CLASS" --allocated-storage 20 --storage-type gp3 \
        --master-username "$USER_NAME" --manage-master-user-password \
        --db-parameter-group-name "$RPG" --vpc-security-group-ids "$sg" --publicly-accessible \
        --backup-retention-period 0 --no-multi-az --no-deletion-protection --storage-encrypted \
        --no-auto-minor-version-upgrade --tags "$TAGS" >/dev/null

  log "waiting for instances (10-20 minutes)"
  for inst in $(aurora_instances) "$RDS"; do
    aws rds wait db-instance-available --db-instance-identifier "$inst"; echo "$inst available"
  done
  # Instances start with the parameter group "pending-reboot"; reboot once so
  # shared_preload_libraries and aurora_compute_plan_id apply.
  log "reboot to apply parameter groups"
  for inst in $(aurora_instances) "$RDS"; do
    aws rds reboot-db-instance --db-instance-identifier "$inst" >/dev/null
  done
  sleep 30
  for inst in $(aurora_instances) "$RDS"; do
    aws rds wait db-instance-available --db-instance-identifier "$inst"; echo "$inst available"
  done
  status
}

secret_password() {  # $1 = secret ARN
  aws_ secretsmanager get-secret-value --secret-id "$1" --query SecretString |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])'
}

connect_env() {  # $1 = cluster|rds, $2 = writer|reader
  if [ "$1" = cluster ]; then
    arn="$(aws_ rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].MasterUserSecret.SecretArn')"
    if [ "$2" = reader ]; then
      host="$(aws_ rds describe-db-instances --db-instance-identifier "$READER" --query 'DBInstances[0].Endpoint.Address')"
    else
      host="$(aws_ rds describe-db-instances --db-instance-identifier "$WRITER" --query 'DBInstances[0].Endpoint.Address')"
    fi
  else
    arn="$(aws_ rds describe-db-instances --db-instance-identifier "$RDS" --query 'DBInstances[0].MasterUserSecret.SecretArn')"
    host="$(aws_ rds describe-db-instances --db-instance-identifier "$RDS" --query 'DBInstances[0].Endpoint.Address')"
  fi
  export PGHOST="$host" PGPORT=5432 PGUSER="$USER_NAME" PGSSLMODE=require
  PGPASSWORD="$(secret_password "$arn")"; export PGPASSWORD
}

run() {
  out="$repo/lab-out"
  stamp="$(date -u +%Y%m%d-%H%M)"
  ver="$(aws_ rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].EngineVersion')"
  rver="$(aws_ rds describe-db-instances --db-instance-identifier "$RDS" --query 'DBInstances[0].EngineVersion')"

  log "Aurora $ver writer (pg_tle install)"
  connect_env cluster writer
  psql -X -d postgres -Atc "SELECT 'connected: ' || version()"
  "$lab/run.sh" "aurora-$ver-writer-$stamp" --pg-tle --keep --out "$out/aurora-$ver-$stamp" || echo "writer run exited $?"

  if [ -z "${LAB_NO_READER:-}" ]; then
    log "Aurora $ver reader phase"
    connect_env cluster reader
    "$lab/run.sh" "aurora-$ver-reader-$stamp" --reader --out "$out/aurora-$ver-$stamp" || echo "reader run exited $?"
  fi
  connect_env cluster writer
  "$lab/run.sh" x --teardown

  log "RDS $rver (plain install)"
  connect_env rds writer
  psql -X -d postgres -Atc "SELECT 'connected: ' || version()"
  "$lab/run.sh" "rds-$rver-$stamp" --out "$out/rds-$rver-$stamp" || echo "rds run exited $?"
  unset PGPASSWORD
  log "reports"
  ls -1 "$out"/*-"$stamp"/*.md
}

status() {
  aws_ rds describe-db-clusters --query "DBClusters[?starts_with(DBClusterIdentifier,'$P')].[DBClusterIdentifier,EngineVersion,Status]" 2>/dev/null || true
  aws_ rds describe-db-instances --query "DBInstances[?starts_with(DBInstanceIdentifier,'$P')].[DBInstanceIdentifier,DBInstanceClass,EngineVersion,DBInstanceStatus]" 2>/dev/null || true
  sg="$(sg_id)"; [ -n "$sg" ] && echo "security group $SG_NAME $sg"
  true
}

down() {
  log "deleting instances"
  for inst in "$READER" "$WRITER" "$RDS"; do
    aws rds delete-db-instance --db-instance-identifier "$inst" --skip-final-snapshot \
        --delete-automated-backups >/dev/null 2>&1 && echo "deleting $inst" || true
  done
  for inst in "$READER" "$WRITER" "$RDS"; do
    aws rds wait db-instance-deleted --db-instance-identifier "$inst" 2>/dev/null || true
  done
  log "deleting cluster"
  aws rds delete-db-cluster --db-cluster-identifier "$CLUSTER" --skip-final-snapshot >/dev/null 2>&1 && echo "deleting $CLUSTER" || true
  aws rds wait db-cluster-deleted --db-cluster-identifier "$CLUSTER" 2>/dev/null || true
  log "deleting parameter groups and security group"
  aws rds delete-db-cluster-parameter-group --db-cluster-parameter-group-name "$CPG" 2>/dev/null || true
  aws rds delete-db-parameter-group --db-parameter-group-name "$RPG" 2>/dev/null || true
  sg="$(sg_id)"; [ -n "$sg" ] && aws ec2 delete-security-group --group-id "$sg" || true
  log "left over (should be empty)"
  status
}

case "${1:-}" in
  preflight) preflight ;;
  up) up ;;
  run) run ;;
  status) status ;;
  down) down ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
