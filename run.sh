#!/bin/sh

set -eux

EXIT_CODE=0
QUEUED=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs?status=queued" | jq -cr '.workflow_runs[].id')
for WORKFLOW_ID in $QUEUED; do

  JOB_DATA=$(curl -H "authorization: token ${GH_PAT}" "https://api.github.com/repos/${REPO}/actions/runs/${WORKFLOW_ID}/jobs" | jq -cr '.')

  echo 'deploying'

  JOB_LABELS=$(echo "${JOB_DATA}" | jq -cr '.jobs[].labels')
  # skip if not self hosted
  echo "${JOB_LABELS}" | grep 'self-hosted' || continue

  JOB_ATTEMPTS=$(echo "${JOB_DATA}" | jq -cr '.jobs[].run_attempt')
  INSTANCE_TYPE=$(echo "${JOB_LABELS}" | jq -cr '.[2]')
  TAG="${REPO}-${WORKFLOW_ID}"
  RUNNER_LABELS=$(echo "${JOB_LABELS}" | jq -cr 'join(",")')

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

exit "${EXIT_CODE}"
