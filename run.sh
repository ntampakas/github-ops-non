#!/bin/sh
# Drill
# Drill
# Drill

set -eux

EXIT_CODE=0
QUEUED=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs?status=queued" | jq -cr '.workflow_runs[].id')
for WORKFLOW_ID in $QUEUED; do

  JOB_DATA=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs/${WORKFLOW_ID}/jobs" | jq -cr '.')

#  if [ "$(echo "${JOB_DATA}" | jq -cr '.jobs | length')" != "1" ]; then
#    echo "TODO: more than one job is not supported"
#    EXIT_CODE=1
#    continue
#  fi
  echo 'deploying'

  JOB_LABELS=$(echo "${JOB_DATA}" | jq -cr '.jobs[].labels')
  # skip if not self hosted
  echo "${JOB_LABELS}" | grep 'self-hosted' || continue

  JOB_ATTEMPTS=$(echo "${JOB_DATA}" | jq -cr '.jobs[].run_attempt')
  INSTANCE_TYPE=$(echo "${JOB_LABELS}" | jq -cr '.[2]')
  TAG="${REPO}-${WORKFLOW_ID}"
  RUNNER_LABELS=$(echo "${JOB_LABELS}" | jq -cr 'join(",")')

    INSTANCES_STATUS=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${TAG}" | jq -cr '.Reservations[].Instances[].State.Name')
    # just in case we somehow ended up with multiple machines with the same id
    #if [ "${INSTANCES_STATUS}" != "" ] && [ $(echo "${INSTANCES_STATUS}" | grep -v terminated) ]; then
    #  echo 'already deployed'
    #  continue
    #fi

    # continue on error
    cat cloud-init.sh | sed -e "s#__REPO__#${REPO}#" -e "s/__RUNNER_LABELS__/${RUNNER_LABELS}/" -e "s/__GITHUB_TOKEN__/${GH_PAT}/" > .startup.sh
    aws ec2 run-instances \
      --user-data "file://.startup.sh" \
      --block-device-mapping "[ { \"DeviceName\": \"/dev/sda1\", \"Ebs\": { \"VolumeSize\": 64, \"DeleteOnTermination\": true } } ]" \
      --ebs-optimized \
      --instance-initiated-shutdown-behavior terminate \
      --instance-type "${INSTANCE_TYPE}" \
      --image-id "${IMAGE_ID}" \
      --key-name "${KEY_NAME}" \
      --subnet-id "${SUBNET_ID}" \
      --security-group-id "${SECURITY_GROUP_ID}" \
      --tag-specification "ResourceType=instance,Tags=[{Key=Name,Value=${TAG}}]" || EXIT_CODE=1
done

# cleanup if no jobs are in progress nor queued
RES=$(aws ec2 describe-spot-instance-requests --filters "Name=tag:Name,Values=${REPO}-*" | jq -cr '.SpotInstanceRequests[] | [.InstanceId, .SpotInstanceRequestId, .Tags[0].Value, .State]')
for VAL in $RES; do
  INSTANCE_ID=$(echo "${VAL}" | jq -cr '.[0]')
  SPOT_ID=$(echo "${VAL}" | jq -cr '.[1]')
  TAG=$(echo "${VAL}" | jq -cr '.[2]')
  STATE=$(echo "${VAL}" | jq -cr '.[3]')
  WORKFLOW_ID=$(echo "${TAG}" | awk -F '-' '{ print $NF }')
  JOB_STATUS=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs/${WORKFLOW_ID}" | jq -cr '.status')
  if [ "${JOB_STATUS}" != "queued" ] && [ "${JOB_STATUS}" != "in_progress" ]; then
    if [ "${STATE}" != "cancelled" ] && [ "${STATE}" != "closed" ]; then
      aws ec2 cancel-spot-instance-requests --spot-instance-request-ids "${SPOT_ID}" || EXIT_CODE=1
    fi
    if [ "${INSTANCE_ID}" != "null" ]; then
      aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" || EXIT_CODE=1
    fi
  fi
done

# cleanup for non-spot instances
RES=$(aws ec2 describe-instances --filters "Name=tag:Name,Values=${REPO}-*" "Name=instance-state-name,Values=running" | jq -cr '.Reservations[].Instances[] | [.InstanceId, .Tags[0].Value]')
for VAL in $RES; do
  ID=$(echo "${VAL}" | jq -cr '.[0]')
  TAG=$(echo "${VAL}" | jq -cr '.[1]')
  WORKFLOW_ID=$(echo "${TAG}" | awk -F '-' '{ print $NF }')
  JOB_STATUS=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs/${WORKFLOW_ID}" | jq -cr '.status')
  if [ "${JOB_STATUS}" != "queued" ] && [ "${JOB_STATUS}" != "in_progress" ]; then
    aws ec2 terminate-instances --instance-ids "${ID}"
  fi
done

exit "${EXIT_CODE}"
