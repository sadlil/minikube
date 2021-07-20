#!/bin/bash

# Copyright 2021 The Kubernetes Authors All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Creates a comment on the provided PR number, using the provided gopogh summary
# to list out the flake rates of all failing tests.
# Example usage: ./report_flakes.sh 11602 gopogh.json Docker_Linux

set -eu -o pipefail

if [ "$#" -ne 3 ]; then
  echo "Wrong number of arguments. Usage: report_flakes.sh <PR number> <short commit> <environment list file>" 1>&2
  exit 1
fi

PR_NUMBER=$1
SHORT_COMMIT=$2
ENVIRONMENT_LIST=$3

# To prevent having a super-long comment, add a maximum number of tests to report.
MAX_REPORTED_TESTS=30

DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

TMP_DATA=$(mktemp)
# 1) Process the ENVIRONMENT_LIST to turn them into valid GCS URLs.
# 2) Check to see if the files are present. Ignore any missing files.
# 3) Cat the gopogh summaries together.
# 4) Process the data in each gopogh summary.
# 5) Filter tests to only include failed tests (and only get their names and environment).
# 6) Sort by environment, then test name.
# 7) Store in file $TMP_DATA.
< "${ENVIRONMENT_LIST}" sed -r "s/^/gs:\\/\\/minikube-builds\\/logs\\/${PR_NUMBER}\\/${SHORT_COMMIT}\\//; s/$/_summary.json/" \
  | (xargs gsutil ls || true) \
  | xargs gsutil cat \
  | "$DIR/process_data.sh" \
  | sed -n -r -e "s/[0-9a-f]*,[0-9-]*,([a-zA-Z\/_0-9-]*),([a-zA-Z\/_0-9-]*),Failed,[.0-9]*/\1:\2/p" \
  | sort \
  > "$TMP_DATA"

# Download the precomputed flake rates from the GCS bucket into file $TMP_FLAKE_RATES.
TMP_FLAKE_RATES=$(mktemp)
gsutil cp gs://minikube-flake-rate/flake_rates.csv "$TMP_FLAKE_RATES"

TMP_FAILED_RATES="$TMP_FLAKE_RATES\_filtered"
# 1) Parse the flake rates to only include the environment, test name, and flake rates.
# 2) Sort the flake rates based on environment+test name.
# 3) Join the flake rates with the failing tests to only get flake rates of failing tests.
# 4) Sort failed test flake rates based on the flakiness of that test - stable tests should be first on the list.
# 5) Store in file $TMP_FAILED_RATES.
< "$TMP_FLAKE_RATES" sed -n -r -e "s/([a-zA-Z0-9_-]*),([a-zA-Z\/0-9_-]*),([.0-9]*),[.0-9]*/\1:\2,\3/p" \
  | sort -t, -k1,1 \
  | join -t , -j 1 "$TMP_DATA" - \
  | sort -g -t, -k2,2 \
  > "$TMP_FAILED_RATES"

FAILED_RATES_LINES=$(wc -l < "$TMP_FAILED_RATES")
if [[ "$FAILED_RATES_LINES" -eq 0 ]]; then
  echo "No failed tests! Aborting without commenting..." 1>&2
  exit 0
fi

# Create the comment template.
TMP_COMMENT=$(mktemp)
printf "These are the flake rates of all failed tests.\n|Environment|Failed Tests|Flake Rate (%%)|\n|---|---|---|\n" > "$TMP_COMMENT"
# 1) Get the first $MAX_REPORTED_TESTS lines.
# 2) Print a row in the table with the environment, test name, flake rate, and a link to the flake chart for that test.
# 3) Append these rows to file $TMP_COMMENT.
< "$TMP_FAILED_RATES" head -n $MAX_REPORTED_TESTS \
  | sed -n -r -e "s/([a-zA-Z\/0-9_-]*):([a-zA-Z\/0-9_-]*),([.0-9]*)/|[\1](https:\/\/storage.googleapis.com\/minikube-flake-rate\/flake_chart.html?env=\1))|\2|\3 ([chart](https:\/\/storage.googleapis.com\/minikube-flake-rate\/flake_chart.html?env=\1\&test=\2))|/p" \
  >> "$TMP_COMMENT"

# If there are too many failing tests, add an extra row explaining this, and a message after the table.
if [[ "$FAILED_RATES_LINES" -gt 30 ]]; then
  printf "|More tests...|Continued...|\n\nToo many tests failed - See test logs for more details." >> "$TMP_COMMENT"
fi

printf "\n\nTo see the flake rates of all tests by environment, click [here](https://minikube.sigs.k8s.io/docs/contrib/test_flakes/)." >> "$TMP_COMMENT"

# install gh if not present
"$DIR/../installers/check_install_gh.sh"

gh pr comment "https://github.com/kubernetes/minikube/pull/$PR_NUMBER" --body "$(cat $TMP_COMMENT)"
