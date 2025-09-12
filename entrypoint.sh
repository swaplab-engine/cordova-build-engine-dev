#!/bin/bash
# entrypoint.sh

# Exit immediately if a command exits with a non-zero status.
set -e

# ===================================================================
# HELPER FUNCTIONS
# ===================================================================
# Function to send status/log updates back to your server
report_status() {
    local PAYLOAD="$1"
    curl --fail -X POST \
        -H "Content-Type: application/json" \
        -H "X-Build-Secret: ${INPUT_WEBHOOKSECRET}" \
        -d "${PAYLOAD}" \
        "${INPUT_APPBASEURL}/api/github-webhook" || true
}

# Function to handle script failure
fail_handler() {
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    report_status "{\"buildId\":\"${INPUT_BUILDID}\",\"userId\":\"${INPUT_USERID}\",\"status\":\"log_update\",\"message\":\"Build failed. Preparing logs for upload...\"}"

    # Combine all logs into one file
    cat npm_install_log.txt build_log.txt > final_log.txt 2>/dev/null || cat build_log.txt > final_log.txt 2>/dev/null || echo "Build failed during initial setup. No logs generated." > final_log.txt

    # Upload logs to R2
    local R2_LOG_FILENAME="${INPUT_BUILDID}.log"
    local R2_LOG_OBJECT_KEY="logs/${INPUT_USERID}/${R2_LOG_FILENAME}"
    aws s3 cp final_log.txt "s3://${INPUT_R2BUCKETNAME}/${R2_LOG_OBJECT_KEY}" --endpoint-url "$R2_ENDPOINT"

    local LOG_URL="${INPUT_R2PUBLICURL}/${R2_LOG_OBJECT_KEY}"
    local LOG_SNIPPET=$(tail -n 20 final_log.txt | sed 's|/github/workspace/[^ ]*|[PROJECT_PATH]|g' | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')

    # Report final failure status
    local FAILURE_PAYLOAD="{\"buildId\":\"${INPUT_BUILDID}\",\"userId\":\"${INPUT_USERID}\",\"status\":\"failed\",\"durationSeconds\":\"${duration}\",\"logUrl\":\"${LOG_URL}\",\"logSnippet\":\"${LOG_SNIPPET}\",\"ciProvider\":\"github\"}"
    report_status "$FAILURE_PAYLOAD"
    exit 1
}

# Trap ERR signals to call the fail_handler function
trap fail_handler ERR

# ===================================================================
# MAIN BUILD LOGIC
# ===================================================================
start_time=$(date +%s)

# Configure AWS CLI for R2
export AWS_ACCESS_KEY_ID=${INPUT_R2ACCESSKEYID}
export AWS_SECRET_ACCESS_KEY=${INPUT_R2SECRETACCESSKEY}
R2_ENDPOINT="https://${INPUT_R2ACCOUNTID}.r2.cloudflarestorage.com"

# 1. Report Start
report_status "{\"buildId\":\"${INPUT_BUILDID}\",\"userId\":\"${INPUT_USERID}\",\"status\":\"log_update\",\"message\":\"Starting build process in secure container...\"}"
report_status "{\"buildId\":\"${INPUT_BUILDID}\",\"userId\":\"${INPUT_USERID}\",\"status\":\"in_progress\",\"ciProvider\":\"github\",\"runId\":\"${GITHUB_RUN_ID}\"}"

# 2. Download and Unzip Project
report_status "{\"buildId\":\"${INPUT_BUILDID}\",\"userId\":\"${INPUT_USERID}\",\"status\":\"log_update\",\"message\":\"Downloading and extracting project from storage...\"}"
curl -L -o cordovaProject.zip "${INPUT_PROJECTURL}"
mkdir -p cordova-project
unzip -q cordovaProject.zip -d cordova-project

# 3. Prepare Signing Configuration (if release build)
if [[ "${INPUT_BUILDTYPE}" == "release-apk" || "${INPUT_BUILDTYPE}" == "release-aab" ]]; then
    report_status "{\"buildId\":\"${INPUT_BUILDID}\",\"userId\":\"${INPUT_USERID}\",\"status\":\"log_update\",\"message\":\"Preparing release configuration (keystore)...\"}"
    cd cordova-project
    curl -L -o release.jks "${INPUT_KEYSTOREURL}"
    PACKAGE_TYPE="apk"
    if [[ "${INPUT_BUILDTYPE}" == "release-aab" ]]; then
        PACKAGE_TYPE="bundle"
    fi
    printf '%s\n' "{\"android\":{\"release\":{\"keystore\":\"release.jks\",\"storePassword\":\"${INPUT_KEYSTOREPASSWORD}\",\"alias\":\"${INPUT_KEYALIAS}\",\"password\":\"${INPUT_KEYPASSWORD}\",\"packageType\":\"$PACKAGE_TYPE\"}}}" > build.json
    cd ..
fi

# 4. Install Dependencies and Build
cd cordova-project
report_status "{\"buildId\":\"${INPUT_BUILDID}\",\"userId\":\"${INPUT_USERID}\",\"status\":\"log_update\",\"message\":\"Installing project dependencies (npm)...\"}"
npm install > ../npm_install_log.txt 2>&1

report_status "{\"buildId\":\"${INPUT_BUILDID}\",\"userId\":\"${INPUT_USERID}\",\"status\":\"log_update\",\"message\":\"Starting Android compilation (this may take a while)...\"}"
{
    echo "--- Preparing Android Platform & Building ---"
    cordova platform add android
    if [[ "${INPUT_BUILDTYPE}" == "debug-apk" ]]; then
        cordova build android --debug -- --gradleArg=--no-daemon
    else
        cordova build android --release --buildConfig=build.json -- --gradleArg=--no-daemon
    fi
    echo "--- Cordova Build Finished ---"
} > ../build_log.txt 2>&1
cd ..

# 5. Find and Upload Artifact
report_status "{\"buildId\":\"${INPUT_BUILDID}\",\"userId\":\"${INPUT_USERID}\",\"status\":\"log_update\",\"message\":\"Finalizing and uploading build results...\"}"

ARTIFACT_PATH=""
ARTIFACT_EXT=""
if [[ "${INPUT_BUILDTYPE}" == "release-aab" ]]; then
    ARTIFACT_PATH=$(find cordova-project/platforms/android/app/build/outputs/bundle/release -name "*.aab" | head -n 1)
    ARTIFACT_EXT="aab"
elif [[ "${INPUT_BUILDTYPE}" == "release-apk" ]]; then
    ARTIFACT_PATH=$(find cordova-project/platforms/android/app/build/outputs/apk/release -name "*.apk" | head -n 1)
    ARTIFACT_EXT="apk"
else
    ARTIFACT_PATH=$(find cordova-project/platforms/android/app/build/outputs/apk/debug -name "*.apk" | head -n 1)
    ARTIFACT_EXT="apk"
fi

if [ -z "$ARTIFACT_PATH" ]; then
    echo "::error::Build artifact not found!"
    # The trap will catch this exit and trigger the fail_handler
    exit 1
fi

R2_FILENAME="${INPUT_BUILDTYPE}-${INPUT_BUILDID}.${ARTIFACT_EXT}"
R2_OBJECT_KEY="builds/${INPUT_USERID}/${R2_FILENAME}"
aws s3 cp "${ARTIFACT_PATH}" "s3://${INPUT_R2BUCKETNAME}/${R2_OBJECT_KEY}" --endpoint-url "$R2_ENDPOINT"
DOWNLOAD_URL="${INPUT_R2PUBLICURL}/${R2_OBJECT_KEY}"

# 6. Report Success
end_time=$(date +%s)
duration=$((end_time - start_time))
SUCCESS_PAYLOAD="{\"buildId\":\"${INPUT_BUILDID}\",\"userId\":\"${INPUT_USERID}\",\"status\":\"complete\",\"durationSeconds\":\"${duration}\",\"downloadUrl\":\"${DOWNLOAD_URL}\",\"ciProvider\":\"github\"}"
report_status "$SUCCESS_PAYLOAD"

echo "--- Build process completed successfully! ---"
