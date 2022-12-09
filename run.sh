#!/bin/sh

set -eux

EXIT_CODE=0
QUEUED=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs?status=queued" | jq -cr '.workflow_runs[].id')
for WORKFLOW_ID in $QUEUED; do
  JOB_DATA=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs/${WORKFLOW_ID}/jobs" | jq -cr '.')

  if [ "$(echo "${JOB_DATA}" | jq -cr '.jobs | length')" != "1" ]; then
    echo "TODO: more than one job is not supported"
    EXIT_CODE=1
    continue
  fi

  JOB_LABELS=$(echo "${JOB_DATA}" | jq -cr '.jobs[].labels')
  # skip if not self hosted
  echo "${JOB_LABELS}" | grep 'self-hosted' || continue

  JOB_ATTEMPTS=$(echo "${JOB_DATA}" | jq -cr '.jobs[].run_attempt')
  INSTANCE_TYPE=$(echo "${JOB_LABELS}" | jq -cr '.[2]')
  TAG="${REPO}-${WORKFLOW_ID}"
  INSTANCES_STATUS=$(aws ec2 describe-spot-instance-requests --filters "Name=tag:Name,Values=${TAG}" | jq -cr '.SpotInstanceRequests[].State')
  # just in case we somehow ended up with multiple machines with the same id
  if [ "${INSTANCES_STATUS}" != "" ] && [ "$(echo "${INSTANCES_STATUS}" | grep -q -E '(open|active)'; echo "$?")" = "0" ]; then
    echo 'already deployed'
    continue
  fi

  echo 'deploying'
  RUNNER_LABELS=$(echo "${JOB_LABELS}" | jq -cr 'join(",")')
  USER_DATA=$(cat cloud-init.sh | sed -e "s#__REPO__#${REPO}#" -e "s/__RUNNER_LABELS__/${RUNNER_LABELS}/" -e "s/__GITHUB_TOKEN__/${GH_PAT}/" | base64 -w 0)
  JSON=$(
cat | jq -cr '.' << EOF
{
  "UserData": "${USER_DATA}",
  "SecurityGroupIds": ["${SECURITY_GROUP_ID}"],
  "SubnetId": "${SUBNET_ID}",
  "ImageId": "${IMAGE_ID}",
  "InstanceType": "${INSTANCE_TYPE}",
  "KeyName": "${KEY_NAME}",
  "BlockDeviceMappings": [
    { "DeviceName": "/dev/sda1", "Ebs": { "VolumeSize": 64, "DeleteOnTermination": true } }
  ],
  "EbsOptimized": true
}
EOF
)

  # continue on error
  aws ec2 request-spot-instances \
    --type one-time \
    --instance-interruption-behavior terminate \
    --instance-count 1 \
    --tag-specification "ResourceType=spot-instances-request,Tags=[{Key=Name,Value=${TAG}}]" \
    --client-token "${TAG}-${JOB_ATTEMPTS}" \
    --launch-specification "${JSON}" || EXIT_CODE=1
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

exit "${EXIT_CODE}"
