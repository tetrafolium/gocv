#!/bin/bash

set -eu

max_incremental=200

GCP_SDK_VERSION="357.0.0"
export GOPATH="$HOME"
export AUTH_TOKEN="$TOKEN"
export PATH="/usr/local/go/bin:${PATH}"

clone_repo () {
    saas="$1"
    owner="$2"
    repo="$3"
    mkdir -p "${GOPATH}/src/${saas}/${owner}/${repo}"
    git clone -q "https://${TOKEN}@${saas}/${owner}/${repo}.git" "${GOPATH}/src/${saas}/${owner}/${repo}"
}

remove_repo () {
    saas="$1"
    owner="$2"
    repo="$3"
    rm -rf "${GOPATH}/src/${saas}/${owner}/${repo}"
}

setup_cloud_sdk () {
    curl -s -o sdk.tgz -L "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-${GCP_SDK_VERSION}-linux-x86_64.tar.gz"
    gzip -dc sdk.tgz | tar xf - -C "${HOME}"
    "${HOME}/google-cloud-sdk/install.sh" -q
    gcloud init
# shellcheck disable=SC2005,SC2046
    echo -e "$(eval echo -e $(cat service_account_tmpl.json))" > "${HOME}/service_account.json"
    gcloud auth activate-service-account test-selection-cron@codelift-staging.iam.gserviceaccount.com --key-file "${HOME}/service_account.json"
    gcloud auth list
    export GOOGLE_APPLICATION_CREDENTIALS="${HOME}/service_account.json"
    gcloud config set account test-selection-cron@codelift-staging.iam.gserviceaccount.com
}

setup_golang () {
    curl -L -o go1.17.1.linux-amd64.tar.gz https://golang.org/dl/go1.17.1.linux-amd64.tar.gz
    sudo tar -C /usr/local -xzf go1.17.1.linux-amd64.tar.gz
    go env -w GO111MODULE=auto
}

valid_svm () {
    owner="$1"
    repo="$2"
    mode="$3"
    fname="github.com_${owner}_${repo}-${mode}.svm.txt"
    if [ "$(wc -l "$fname" | awk '{print $1}')" -eq 1 ]; then
        echo "SKIP EVALUATION: empty ${mode} svm file"
        return 1
    fi
    return 0
}

generate_dataset () {
    subcmd="$1"
    owner="$2"
    repo="$3"
    framework="$4"
    start_job="$5"
    end_job="$6"

    echo ./tools.sh "$subcmd" "$owner" "$repo" "$framework" "$start_job" "$end_job"
    ./tools.sh "$subcmd" "$owner" "$repo" "$framework" "$start_job" "$end_job" || return 1
}

generate_dataset_from_travisci () {
    owner="$1"
    repo="$2"
    endpoint="$3"
    framework="$4"
    start_job="$5"
    end_job="$6"

    case "$endpoint" in
      "https://api.travis-ci.org" ) generate_dataset "generate-dataset-from-travisci" "$owner" "$repo" "$framework" "$start_job" "$end_job" ;;
      "https://api.travis-ci.com" ) generate_dataset "generate-dataset-from-traviscom" "$owner" "$repo" "$framework" "$start_job" "$end_job" ;;
      *                           ) echo "invalid endpoint: ${endpoint}"; exit 1 ;;
    esac
}

generate_dataset_from_circleci () {
    owner="$1"
    repo="$2"
    framework="$3"
    start_job="$4"
    end_job="$5"
    generate_dataset "generate-dataset-from-circleci" "$owner" "$repo" "$framework" "$start_job" "$end_job"
}

setup_python () {
    sudo apt-get install -y -qq python3 python3-distutils python3-dev
    curl -kL https://bootstrap.pypa.io/get-pip.py | python3
    cat > "${HOME}/.local/bin/python" << EOF
#!/bin/bash
exec python3 "\$@"
EOF
    chmod +x "${HOME}/.local/bin/python"
}

setup_git_lfs () {
    curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | sudo bash
    git lfs install
}

setup_travis_cli () {
    sudo gem install travis
    sudo gem cleanup

    travis login --pro --github-token "$TOKEN"
}

build_collector () {
    clone_repo "github.com" "tractrix" "universal-go"

    (cd collector && go get ./... && go build)
}

build_poc () {
    clone_repo "github.com" "tractrix" "universal-go"
    clone_repo "github.com" "tractrix" "common-go"
    clone_repo "github.com" "tractrix" "yaml"

    (cd poc && go get ./... && go build)
}

setup () {
    echo "install packages"

    output="$(sudo dpkg --configure -a)" || { echo "$output"; return 1; }

    output="$(sudo apt-get update -qq && sudo apt-get install -y -qq curl build-essential ruby git-lfs sqlite3 golang-glide pkg-config bc jq dnsutils)" || { echo "$output"; return 1; }

    echo "setup python"
    output="$(setup_python 2>&1)" || { echo "$output"; return 1; }

    echo "setup cloud sdk"
    output="$(setup_cloud_sdk 2>&1)" || { echo "$output"; return 1; }
    export GOOGLE_APPLICATION_CREDENTIALS="${HOME}/service_account.json"

    # setup parallel composite upload
    output="$(python3 -m pip install -U crcmod 2>&1)" || { echo "$output"; return 1; }
    cp .boto "$HOME"
    output="$(gsutil version -l)" || { echo "$output"; return 1; }
    echo "$output" | grep "compiled crcmod: True" > /dev/null 2>&1 || { echo "$output"; return 1; }

    echo "setup golang"
    output="$(setup_golang 2>&1)" || { echo "$output"; return 1; }

    echo "setup git lfs"
    output="$(setup_git_lfs 2>&1)" || { echo "$output"; return 1; }

    echo "setup travis cli"
    output="$(setup_travis_cli 2>&1)" || { echo "$output"; return 1; }

    echo "setup done"
}

last_job () {
    dbname="$1"
    job_id="$(sqlite3 "$dbname" "SELECT MAX(seq_id) FROM jobs" 2> /dev/null || echo 0)"
    if [ "$job_id" = "" ]; then
        job_id=0
    fi
    echo "$job_id"
}

gcs_get_meta () {
    url="$1"
    key="$2"

    finfo=$(gsutil ls -L "$url" 2>&1 || true)
    out=$(echo "$finfo"  | grep "${key}:" | awk '{print $2}')
    if [ "$out" = "" ]; then
        if ! grep "Content-Length:" <<< "$finfo"; then
            if ! grep "One or more URLs matched no objects." <<< "$finfo" > /dev/null; then
                out="-1"
            else
                out="0"
            fi
        else
            out="0"
        fi
    fi
    echo "$out"
}

expand_job_range () {
    local_start="$1"
    local_end="$2"
    remote_start="$3"
    remote_end="$4"

    if [ "$remote_start" -eq -1 ] || [ "$remote_end" -eq -1 ]; then
        return 1
    fi
    if [ "$remote_start" -eq 0 ] || [ "$remote_end" -eq 0 ]; then
        return 0
    fi
    if [ "$local_start" -lt "$remote_start" ] || [ "$local_end" -gt "$remote_end" ]; then
        return 0
    fi
    return 1
}

build_dataset () {
    saas="$1"
    owner="$2"
    repo="$3"
    target="$4"
    endpoint="$5"
    framework="$6"
    start_job="$7"
    end_job="$8"

    ep=$(echo "$endpoint" | sed "s/https:\/\///")

    dbname="${saas}_${owner}_${repo}.db"
    dbname_cloud="${saas}_${owner}_${repo}_${ep}_${framework}.db"
    repotop="${GOPATH}/src/${saas}/${owner}/${repo}"
    repodb="gs://test-selection-data/dataset/${dbname_cloud}"

    clone_repo "$saas" "$owner" "$repo"

    # shellcheck disable=SC2164
    (cd "$repotop" && if [ -f go.mod ]; then go mod tidy; elif [ -f glide.yaml ]; then glide install; fi && go get -d ./...) > /dev/null 2>&1

    rm -f "poc/${dbname}"
    out=$(gsutil cp "$repodb" "poc/${dbname}" 2>&1 || true)
    if ! grep "One or more URLs matched no objects." <<< "$out"; then
        echo "gsutil cp ${repodb} poc/${dbname}"
        echo "$out"
        echo "Skip ${saas} ${owner} ${repo} ${target} ${endpoint} ${framework} ${start_job} ${end_job}"
        return 1
    fi

    last=$(last_job "poc/${dbname}")
    if [ "$last" -lt "$start_job" ]; then
        last=$((start_job-1))
    fi
    jobs=$((end_job-last+1))
    if [ "$jobs" -gt "$max_incremental" ]; then
        end_job=$((last+max_incremental))
        echo "WARNING: limit number of jobs to ${max_incremental} (${last})"
    fi

    (cd poc && case "$target" in
      "travis-ci" ) generate_dataset_from_travisci "$owner" "$repo" "$endpoint" "$framework" "$start_job" "$end_job" ;;
      "circleci"  ) generate_dataset_from_circleci "$owner" "$repo" "$framework" "$start_job" "$end_job" ;;
      *           ) echo "invalid target: ${target}"; exit 1 ;;
    esac)

    if [ "$repo" = "boltons" ]; then
      cat poc/github.com_mahmoud_boltons.log || true
    fi

    sqlite3 "poc/${dbname}" "SELECT MIN(seq_id),MAX(seq_id) FROM jobs"
    sqlite3 "poc/${dbname}" "SELECT 'failed jobs',COUNT(DISTINCT test_results.job_id),'total jobs',COUNT(jobs.seq_id) FROM test_results INNER JOIN jobs ON test_results.job_id = jobs.seq_id AND test_results.succeeded = true"

    remote_start=$(gcs_get_meta "$repodb" "start-job")
    remote_end=$(gcs_get_meta "$repodb" "end-job")
    if [ "$remote_start" -eq -1 ] || [ "$remote_end" -eq -1 ]; then
        echo "Fail to get metadata for ${repodb}"
        return 1
    fi
    if expand_job_range "$start_job" "$end_job" "$remote_start" "$remote_end"; then
        gsutil -h "x-goog-meta-start-job:${start_job}" -h "x-goog-meta-end-job:${end_job}" cp "poc/${dbname}" "$repodb" || true
    else
        echo "No copy to remote. ${start_job}/${end_job}, ${remote_start}/${remote_end}"
        ls -l "poc/${dbname}"
    fi

    remove_repo "$saas" "$owner" "$repo"
}

valid_evaluation_target() {
    slug="$1"
    valid="$2"
    framework="$3"
    start_job="$4"
    end_job="$5"

    if [ "$valid" -eq 0 ]; then
        echo "SKIP: ${slug}: repository is not valid"
        return 1
    fi

    if [ "$framework" = "" ]; then
        echo "SKIP: ${slug}: no test framework specified"
        return 1
    fi

    if [ $((end_job-start_job+1)) -lt 100 ]; then
        echo "SKIP: ${slug}: number of jobs is less than 100"
        return 1
    fi

    # blacklist:
    # github.com/libgit2/git2go
    # github.com/nats-io/nats-server
    # github.com/nats-io/nats.go
    case "$repo" in
      "git2go" )      return 1 ;;
      "nats-server" ) return 1 ;;
      "nats.go" )     return 1 ;;
    esac

    return 0
}

validate_pkg_domain() {
    pkg="$1"

    if [ "$pkg" == "" ]; then
        return 0
    fi

    IFS='/' read -r -a p <<< "$pkg"
    saas="${p[0]}"

    if [ "${saas// /}" != "$saas" ]; then
        return 1
    fi
    nslookup "$saas" > /dev/null 2>&1 || return 1

    return 0
}

validate_nospace() {
    name="$1"

    if [ "${name// /}" != "$name" ]; then
        echo "error: contains space: \"${name}\""
        return 1
    fi
    return 0
}

validate_database() {
    dbpath="$1"

    tables=( "test_results" "test_results_for_func" )
    for table in "${tables[@]}"; do
        while read -r line; do
            validate_pkg_domain "$line" || echo "error: package in ${table}: ${dbpath}"
            validate_nospace "$line" || echo "error: package in ${table}: ${dbpath}"
        done < <(sqlite3 "$dbpath" "SELECT DISTINCT package FROM ${table}" 2> /dev/null || echo "")
    done

    while read -r line; do
        validate_nospace "$line" || echo "error: func in test_results_for_func: ${dbpath}"
    done < <(sqlite3 "$dbpath" "SELECT DISTINCT func FROM test_results_for_func" 2> /dev/null || echo "")
}
