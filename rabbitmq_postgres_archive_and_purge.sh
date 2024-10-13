#!/bin/bash

# Script to check that RabbitMQ queues have drained before running postgres archive and purge.
# Single Node & High Availability Cluster RabbitMQ compatible.
# Example  command --> ./rabbitmq_postgres_archive_and_purge.sh 192.168.100.200 /postgres-backup-logs/2024-09-27.log 24 admin:password \
# "192.168.0.10, 192.168.1.25, 192.168.2.50" 3 /rabbitmq-postgres-archive-and-purge-logs/2024-09-27.log /rabbitmq-node-message-queue-logs/2024-09-27.log 7 10m   

DATE=`date +%Y-%m-%d`                     # todays date  
NOW=`date -u +"%Y-%m-%d %H:%M:%S"`        # todays date & time in UTC
PG_HOST_NAME=$1                        # << postgres-ip-address-or-dns-name >>
PG_BACKUP_LOG=$2                       # << location-of-pg-backup-log >>
CHECK_TIME=$3                          # << number-in-hours >> 
RABBIT_CREDS=$4                        # << rabbit-username:password >>
RABBIT_NODE_ADDR=$5                    # << node/s-ip-address-or-dns-name >>
MAX_RETRIES=$6                         # << number-of-retry-attempts >>
LOG_OUTPUT=$7                          # << log-output-for-this-script >>
RABBITMQ_LOG_OUTPUT=$8                 # << log-output-for-the-rabbit-node-api-queues >> 
RABBIT_LOGS_DIR=$9                     # << directory-location-of-the-$RABBITMQ_LOG_OUTPUT-log-files >>
LOG_FILE_BACKUP_RETENTION=${10}        # << retention-period-of-$RABBITMQ_LOG_OUTPUT-log-files-in-days >>
RABBIT_QUEUE_CHECK_INTERVALS=${11}     # << sleep-duration-between-rabbit-node-queue-checks-in-seconds/minutes/hours >>
RETXT="$PG_HOST_NAME-Archive-Purge-Successful"
LAST_BACKUP=`cat $PG_BACKUP_LOG | grep "Backup-Successful" | tail -1 | sed 's/postgres_backup-Successful//'`


# Date of the last successful backup.
DT1="$LAST_BACKUP"


# Function to check if the backup dates are in the UTC format. 
check_backup_utc_format() {
    BACKUP_DATE="$DT1"
    
    # Regular expression for UTC format (ISO 8601 with 'Z' timezone).
    if [[ "$BACKUP_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        echo "Valid Backup UTC format" >> "$LOG_OUTPUT"
    else
        echo "Invalid Valid Backup UTC format" >> "$LOG_OUTPUT"
        RETVAL="1"
        exit
    fi
}

check_backup_utc_format


# Compute the time since the last successful backup in seconds.
TD1=$(date -u --date="$DT1" +%s)


# Date right now in UTC.
DT2="$NOW"


# Compute the time since the current time and date in seconds i.e 0.
TD2=$(date -u --date="$DT2" +%s)


# Compute the difference between the last successful backup and the current time and date.
let "TDiff=$TD1-$TD2"


# Convert the time difference from seconds to hours.
let "HDiff=$TDiff/3600"


echo "The last successful backup was $HDiff hours ago" >> "$LOG_OUTPUT"


# Check if the most recent postgres backup was successful in the last $CHECK_TIME hours by reading the postgres_backup.log file.
if [ $HDiff -lt "$CHECK_TIME" ]; then
   RETVAL="0"
   echo "$NOW $PG_HOST_NAME last backup successful proceeding to archive and purge" >> "$LOG_OUTPUT" 
fi


# Check if the most recent postgres backup failed in the last $CHECK_TIME hours by reading the postgres_backup.log file, if failed cancels archive and purge.
if [ $HDiff -gt $CHECK_TIME ]; then
    echo "$PG_HOST_NAME postgres_backup_failed therefore archive and purge was cancelled" >> "$LOG_OUTPUT"
    RETVAL="1"
    exit
fi


# Create a function to write the message queues of the rabbit nodes into the RabbitMQ logfile.
rabbit_api_queue_check () {
    
    # Log the start of the rabbitmq queue checks.
    echo "$NOW-queue_check" > "$RABBITMQ_LOG_OUTPUT-$DATE"
        
    # Define an array of queue names
    RABBIT_NODE_QUEUE_LIST=("RabbitMQ-Queue-1", "RabbitMQ-Queue-2", "RabbitMQ-Queue-3"
                           )

    # Split the RABBIT_NODE_QUEUE_LIST into an array based on commas using Internal Field Separator. 
    IFS=',' read -ra QUEUES <<< "$RABBIT_NODE_QUEUE_LIST"

    # Remove spaces and split RABBIT_NODE_ADDR inputs into an array based on commas using Internal Field Separator.
    IFS=',' read -ra RABBIT_NODES <<< "$RABBIT_NODE_ADDR"

        # Iterate over each rabbit node
        for NODE in "${RABBIT_NODES[@]}"; do
            NODE=$(echo "$NODE" | tr -d ' ')  # Strip any spaces.
            echo "Processing node: $NODE"
            
            # Loop over each queue for the current rabbit node.
            for QUEUE in "${QUEUES[@]}"; do
                QUEUE=$(echo "$QUEUE" | tr -d ' ')  # Strip any spaces.
                echo "Processing queue: $QUEUE"
               
            # Loop over each rabbit node & queue and make the queue api call.
            curl -u $RABBIT_CREDS "http://$NODE:15672/api/queues/?page=1&page_size=100&name=%5E${QUEUE}&use_regex=true&pagination=true" >> "$RABBITMQ_LOG_OUTPUT-$DATE"
            done
        done
}


check_rabbitmq_queue_status() {
    local MAX_RETRIES=$1   # Number of times to repeat the check.
    local RETRY=0          # Starting retry counter.

    # Call rabbit_api_queue_check function to check current api queue status. 
    rabbit_api_queue_check

    while [ "$RETRY" -lt "$MAX_RETRIES" ]; do
        # Parse the RabbitMQ log queue api data.
        RABBITMQ_QUEUE_CHECK=`cat "$RABBITMQ_LOG_OUTPUT-$DATE" | tr -s ',' '\n' | grep -v "messages_" | grep -v "message_" | grep message | awk -F ":" '{print $2}' | grep -E '[1-9]+' | head -1`

        # Set the RABBITMQ_QUEUE_CHECK variable to 0 if no values are returned, this occurs when there are no messages in any of the queues.  
        local RABBITMQ_QUEUE_CHECK=${RABBITMQ_QUEUE_CHECK:-0}

        # If the number of messages in the queue is greater than 0.
        if [ "$RABBITMQ_QUEUE_CHECK" -gt 0 ]; then
            echo "There are $RABBITMQ_QUEUE_CHECK RabbitMQ messages in queue. Sleeping and checking again in $RABBIT_QUEUE_CHECK_INTERVALS seconds $((RETRY + 1))/$MAX_RETRIES." >> "$LOG_OUTPUT"
            sleep "$RABBIT_QUEUE_CHECK_INTERVALS"
        else
            echo "No messages in RabbitMQ queue on attempt $((RETRY + 1))/$MAX_RETRIES. Exiting check." >> "$LOG_OUTPUT"
            break  # Exit the loop if no messages are in the queue.
        fi
        
        RETRY=$((RETRY + 1))  # Increase the retry counter.
    done

    # If retries exceed max retry count value exit and cancel script.
    if [ "$RETRY" -eq "$MAX_RETRIES" ]; then
        echo "Max retries ($MAX_RETRIES) reached, Exiting and cancelling archive and purge." >> "$LOG_OUTPUT"
        RETVAL="1"
        exit
    fi
}


# Run Archive and Purge. 
if [ $RETVAL == "0" ]; then
   ./archive_and_purge.py >> $LOG_OUTPUT; status_check=$?
fi


# Check if the previous archive & purge was successful.
if [ $status_check -ne 0 ]; then
   RETXT="$NOW $PG_HOST_NAME-Archive and purge failed"
   echo $RETXT >> "$LOG_OUTPUT"
   exit
fi


# Find old RabbitMQ logfiles are remove them.
find "$RABBIT_LOGS_DIR" -name "$RABBITMQ_LOG_OUTPUT-*" -mtime +$LOG_FILE_BACKUP_RETENTION -exec rm {} \; >> "$LOG_OUTPUT"


# Write Archive and Purge success status to logfile.
echo $RETXT >> "$LOG_OUTPUT"
exit
