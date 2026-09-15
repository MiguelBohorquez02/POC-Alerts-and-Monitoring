#!/usr/bin/env bash
# Terraform external data source: lists every Pub/Sub topic in the project.
# Filtering (which topics count as "prod", which are excluded) happens in
# Terraform via topic_include_regex/topic_exclude_regex, not here - keeps
# the include/exclude logic in one versioned place instead of split
# between a shell script and .tf files.
set -euo pipefail

PROJECT_ID=$(jq -r '.project_id' <<<"$(cat)")

NAMES=$(gcloud pubsub topics list --project="$PROJECT_ID" --format="value(name)" \
  | sed 's#.*/##' \
  | paste -sd, -)

jq -n --arg names "$NAMES" '{"names": $names}'
