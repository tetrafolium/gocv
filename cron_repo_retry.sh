#!/bin/bash

set -eu

# This script read and update gs;//${BUCKET_NAME}/retry/${saas}_${owner}_${repo}_$(endpoint}_$(framework).job_id

# Following environmnet variables are required for this script
#
# SAAS
# OWNER
# REPO
# ENDPOINT
# FRAMEWORK

# shellcheck disable=SC2153
saas="$SAAS"
# shellcheck disable=SC2153
owner="$OWNER"
# shellcheck disable=SC2153
repo="$REPO"
# shellcheck disable=SC2153
endpoint="$ENDPOINT"
# shellcheck disable=SC2153
framework="$FRAMEWORK"

AGENT_OWNER="tetrafolium"
DEFAULT_USER_EMAIL="support@rocro.com"
DEFAULT_USER_NAME="Rocro Support"
BUCKET_NAME="test-selection-data"
MAXIMUM_JOBS=20

# shellcheck disable=SC1091
. cron_utils.sh

setup

 git config --global user.email "$DEFAULT_USER_EMAIL"
 git config --global user.name "$DEFAULT_USER_NAME"

get_last_job_id () {
    saas="$1"
    owner="$2"
    repo="$3"
    endpoint="$4"
    framework="$5"

    gsutil cat "gs://${BUCKET_NAME}/retry/${saas}_${owner}_${repo}_${endpoint}_${framework}.job_id" 2>/dev/null || echo "0"
}

put_last_job_id () {
    saas="$1"
    owner="$2"
    repo="$3"
    endpoint="$4"
    framework="$5"
    last_job_id="$6"

    tmpfile=$(mktemp)
    echo "$last_job_id" > "$tmpfile"
    gsutil cp "$tmpfile" "gs://${BUCKET_NAME}/retry/${saas}_${owner}_${repo}_${endpoint}_${framework}.job_id" > /dev/null 2>&1
}

retry_push () {
    job_id="$1"
    commit_id="$2"
    parent="$3"

    git fetch upstream "$parent"
    git reset --hard "$parent"
    short_parent=$(git rev-parse --short "${parent}")
    short_commit_id=$(git rev-parse --short "${commit_id}")
    subject=$(git log --pretty=%s -n 1 "${commit_id}")
    author_name=$(git log --pretty="%an" -n 1 "${commit_id}")
    author_email=$(git log --pretty="%ae" -n 1 "${commit_id}")

    echo "JobID: ${job_id}: ${short_parent} ${short_commit_id}"

    brname="rocro-${job_id}-${short_parent}"
    git push --delete origin "$brname"
    git checkout -b "$brname"
    cp "${HOME}/rocro.yml" .
    git add rocro.yml
    git commit -m "add rocro.yml"
    git merge --no-commit -m "$subject" "$commit_id"
    GIT_AUTHOR_NAME="$author_name" GIT_AUTHOR_EMAIL="$author_email" git commit -m "$subject"
    git push origin "$brname" || return 1
    git reset --hard origin/master
    git clean -xdf
}

retry_commit () {
    saas="$1"
    owner="$2"
    repo="$3"
    endpoint="$4"
    framework="$5"
    job_id="$6"
    commit_id="$7"

    echo "${saas} ${owner} ${repo} ${job_id} ${commit_id}"
    git fetch upstream "$commit_id" > /dev/null 2>&1
    # shellcheck disable=SC2207
    parents=($(git log --pretty=%P -n 1 "$commit_id"))
    for parent in "${parents[@]}"; do
        out=$(retry_push "$job_id" "$commit_id" "$parent"  2>&1) || { echo "$out"; return 1; }
    done
}

retry_repo () {
    saas="$1"
    owner="$2"
    repo="$3"
    endpoint="$4"
    framework="$5"
    last_job_id="$6"

    cd "$HOME"
    if [ -d "${GOPATH}/src/${saas}/${AGENT_OWNER}/${repo}" ]; then
        rm -rf "${GOPATH}/src/${saas}/${AGENT_OWNER}/${repo}"
    fi

    cat > rocro.yml << EOF
inspecode:
  global:
    runtime:
      go: 1.16
  go-test:
    auto-select: true
    timeout: 1h
    thresholds:
      num-issues: 0
    options:
      - -timeout: 60m
EOF

    pre_owner="$owner"
    clone_repo "$saas" "${AGENT_OWNER}" "$repo"
    owner="$pre_owner"
    cd "${GOPATH}/src/${saas}/${AGENT_OWNER}/${repo}"
    git remote add upstream "https://${saas}/${owner}/${repo}.git"
    repodb="${saas}_${owner}_${repo}_${endpoint}_${framework}.db"
    out=$(gsutil cp "gs://${BUCKET_NAME}/dataset/${repodb}" . 2>&1) || { echo "$out"; return 1; }

    n=0
    job_id=0
    while IFS="|" read -ra info; do
        job_id="${info[0]}"
        commit_id="${info[1]//\'/}"
        retry_commit "$saas" "$owner" "$repo" "$endpoint" "$framework" "$job_id" "$commit_id"
        n=$((n+1))
        # Inspecode has a limitation of maximum job: 100
        if [ "$n" -ge "$MAXIMUM_JOBS" ]; then
            break
        fi
        # Because push event from github may overtake the previous job, wait for a while
        sleep 10
    done < <(sqlite3 "$repodb" "SELECT jobs.seq_id, commits.id FROM jobs INNER JOIN commits ON jobs.commit_id = commits._id WHERE jobs.seq_id > ${last_job_id} ORDER BY jobs.seq_id")
    last_job_id="$job_id"
}

last_job_id=$(get_last_job_id "$saas" "$owner" "$repo" "$endpoint" "$framework")
retry_repo "$saas" "$owner" "$repo" "$endpoint" "$framework" "$last_job_id"
if [ "$last_job_id" -eq 0 ]; then
    echo "No new jobs from last execution."
else
    echo "UPDATE last_job_id: $last_job_id"
    put_last_job_id  "$saas" "$owner" "$repo" "$endpoint" "$framework" "$last_job_id"
fi
