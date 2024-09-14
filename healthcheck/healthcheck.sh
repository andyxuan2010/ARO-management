#!/bin/bash

# Author : Andy Xuan

# export PATH=/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin
# export OCP_USERNAME=kubeadmin
# export OCP_URL=https://api.example.com:6443
# export SERVER_ARGUMENTS="--server=${OCP_URL}"
# export LOGIN_ARGUMENTS="--username=${OCP_USERNAME} --password=${OCP_PASSWORD}"

# export PROJECT_CPD_INST_OPERANDS="cpd-operands"
# export PROJECT_CPD_INST_OPERATORS="cpd-operators"
# export PROJECT_OADP_OPERATOR="oadp-operator"

# export SMTP=smtp.example.com
export MAIL_ID_LIST="user@example.com"
# export MAIL_ID_LIST="user@example.com"
# export CURRENT_DATE=$(date +"%Y%m%d%H%M")
# export LOG_FILE="/tmp/healthcheck_log_$(date +%Y%m%d%H%M%S).txt"
export LOG_FILE="/tmp/healthcheck_log_$(date +%Y%m%d%H%M%S).txt"
# export CPD_CLI_DIR=/tmp/cp4d-install/cpd-cli-linux-EE-13.1.0-79
# export OC_PATH=/tmp/cp4d-install

cluster_login() {
    log_message "Trying to login to OCP." "INFO"
    oc_login=$(oc login ${OCP_URL} ${LOGIN_ARGUMENTS})
    local failed_login="Login failed"
    if [[ $oc_login =~ $failed_login ]]; then
        log_message "$oc_login" "ERROR"
        log_message "Failed to login to OCP. Exiting..." "ERROR"
        send_mail_notification "Backup failed: Failed to login to OCP."
        exit 1
    else
        log_message "$oc_login" "INFO"
        log_message "Successfully logged on to OCP." "INFO"
    fi

    log_message "Trying to login to cpd-cli." "INFO"
    cpd_cli_login=$(${CPD_CLI_DIR}/cpd-cli manage login-to-ocp ${SERVER_ARGUMENTS} ${LOGIN_ARGUMENTS})
    if [[ $cpd_cli_login =~ $failed_login ]]; then
        log_message "$cpd_cli_login" "ERROR"
        log_message "Failed to login to cpd-cli. Exiting..." "ERROR"
        send_mail_notification "Backup failed: Failed to login to cpd-cli."
        exit 1
    else
        log_message "$cpd_cli_login" "INFO"
        log_message "Successfully logged on to cpd-cli." "INFO"
    fi

}

log_message() {
    local log_message="$1"
    local log_level="$2"

    echo "$(date) ${log_level}: ${log_message}"
    #sleep 1
}

send_mail_notification() {
    /usr/bin/tar -czf "${LOG_FILE}.tar.gz" "${LOG_FILE}"
    cat "${LOG_FILE}" | mailx -v -S smtp=smtp.example.com -s "$1" -r "no-reply-nonprod-cpdadmin@example.com" -a "${LOG_FILE}.tar.gz" $MAIL_ID_LIST
}

get_cr_status() {
    #	${CPD_CLI_DIR}/cpd-cli manage get-cr-status --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS}
    all_completed=true
    ${CPD_CLI_DIR}/cpd-cli manage get-cr-status --cpd_instance_ns=${PROJECT_CPD_INST_OPERANDS} | sed -n '/\[INFO\] Output the result in the JSON format:/,/^\[/{:a;n;p;ba}' | sed '2!d' >/tmp/output.json
    jq -r '.[] | .[] | "\(.["CR-name"]) \(.Status)"' /tmp/output.json | while read -r line; do

        # Extract the CR-name and Status from the line
        CR_NAME=$(echo "$line" | cut -d ' ' -f1)
        STATUS=$(echo "$line" | cut -d ' ' -f2-)
        # Check if the status is not Completed
        if [[ ! "$STATUS" == "Completed" && ! "$STATUS" == "Succeeded" ]]; then
            log_message "$CR_NAME  is not completed, current status: $STATUS" "INFO"
            all_completed=false
        else
            log_message "$CR_NAME  is  completed, current status: $STATUS" "INFO"

        fi
    done

    # Check the overall status after going through all components
    if [ "$all_completed" = true ]; then
        log_message "All components are in Completed state." "INFO"
        return 0
    else
        log_message "Some components are not in Completed state." "WARNING"
        return 1
    fi
}

get_pod_status() {

    output=$(oc get pod -A -o wide --no-headers | grep -Ev '([[:digit:]])/\1.*R' | grep -Ev 'Completed|env-spec-sync-job')
    if [ -z "$output" ]; then
        log_message "All pods are running fine." "INFO"
        return 0
    else
        log_message "$output" "ERROR"
        return 1
    fi
}

get_cluster_status() {
    # Check status of the installed components
    get_cr_status
    CR_STATUS=$?
    if [ $CR_STATUS -eq 0 ]; then
        log_message "All CS status is fine." "INFO"
    else
        log_message "All CS status is ERROR." "ERROR"
        return 1
    fi

    get_pod_status
    POD_STATUS=$?
    if [ $POD_STATUS -eq 0 ]; then
        log_message "Cluster health is good. Proceeding with backup" "INFO"
        return 0
    else
        log_message "Cluster health doesn't look good. Verify before proceeding" "ERROR"
        return 1
    fi

}

zen_metastore_edb_status() {
    log_message "Checking zen-metastore-edb cluster state" "INFO"
    cluster_status=$(oc cnp status zen-metastore-edb -n ${PROJECT_CPD_INST_OPERANDS} --verbose)

    if [[ "$cluster_status" == *"Cluster in healthy state"* ]]; then
        log_message "Cluster zen-metastore-edb is healthy" "INFO"
        primary_pod=$(oc cnp status zen-metastore-edb -n ${PROJECT_CPD_INST_OPERANDS} | tail -n 2 | awk '{print $1}' | head -1)
        secondary_pod=$(oc cnp status zen-metastore-edb -n ${PROJECT_CPD_INST_OPERANDS} | tail -n 2 | awk '{print $1}' | tail -1)
        log_message "Primary pod: $primary_pod" "INFO"
        log_message "Secondary pod: $secondary_pod" "INFO"
    else
        log_message "Cluster zen-metastore-edb is unhealthy. Exiting..." "ERROR"
        #        send_mail_notification "Backup Failed: zen-metastore-edb is unhealthy."
        exit 1
    fi
}

########################################################
###  start to main
########################################################

# Redirect stdout and stderr to log file
exec >"${LOG_FILE}" 2>&1
log_message "Starting CPD Health check Execution $(date)" "INFO"

# Login to cluster
cluster_login
#Check cluster health before doing backup
# Initialize loop counter
COUNTER=0
# Maximum number of attempts
MAX_ATTEMPTS=5
# Time to wait before retrying (in seconds)
WAIT_TIME=120

while [ $COUNTER -lt $MAX_ATTEMPTS ]; do
    get_cluster_status
    CLUSTER_STATUS=$?
    # Check the exit status of the command
    if [ $CLUSTER_STATUS -eq 0 ]; then
        echo "Command succeeded on attempt $((COUNTER + 1))"
        break
    else
        echo "Command failed on attempt $((COUNTER + 1))"
        sleep $WAIT_TIME
        COUNTER=$((COUNTER + 1))
    fi
done

if [ $CLUSTER_STATUS -ne 0 ]; then
    echo "Command failed on attempt $((COUNTER + 1))"
    send_mail_notification "CLUSTER HEALTH CHECK: cluster/pod is UNHEALTHY."
    exit 1
fi

COUNTER=0

while [ $COUNTER -lt $MAX_ATTEMPTS ]; do
    # Check zen_metastore_edb pods are in sync
    zen_metastore_edb_status
    EDB_STATUS=$?
    # Check the exit status of the command
    if [ $EDB_STATUS -eq 0 ]; then
        echo "Command succeeded on attempt $((COUNTER + 1))"
        break
    else
        echo "Command failed on attempt $((COUNTER + 1))"
        sleep $WAIT_TIME
        COUNTER=$((COUNTER + 1))
    fi
done
if [ $EDB_STATUS -ne 0 ]; then
    echo "Command failed on attempt $((COUNTER + 1))"
    send_mail_notification "EDB HEALTH CHECK: zen-metastore-edb is UNHEALTHY."
    exit 1
fi


log_message "CPD Offline Health check Execution Completed $(date)" "INFO"
