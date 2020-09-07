#!/bin/bash

DESTINATION="/backup"

ERROR=0

function minor() {
        echo $(date +'[%Y-%m-%d %H:%M:%S]') "$*"
}

function log() {
        minor "***" $*
}

function error() {
        minor "*!*" $*
        chkerror 1
}

function warning() {
        minor "*W*" $*
}

function logged_command() {
        if [ "$DEBUG" == "yes" ]; then
                minor $* 1>&2
        fi
        eval $*
}

# is_prefix foobar foo == ret 0
function is_prefix() {
        if [ ${1:0:${#2}} = $2 ]; then
                return 0
        else
                return 1
        fi
}

# trim_prefix foobar foo == foo
function trim_prefix() {
        echo ${1:${#2}}
}

# not expression == reverses the sense of the return value
function not() {
        if $*; then
                return 1
        else
                return 0
        fi
}

# clean_old path
# removes enough subdirectories to bring the count down to $COUNT
function clean_old() {
        count=0
        find $1 \
                -mindepth 1 \
                -maxdepth 1 \
                -type d \
                -iname "????-??-??*" | 
                        sort -r | 
                        while read file; do
                                count=$[ $count+1 ]
                                if [ $count -ge $COUNT ]; then
                                        minor Pruning old $file
                                        if [ $BACKUP == "yes" ]; then
                                                rm -rf $file
                                                rm -f $DESTINATION/logs/$HOST/$(basename $file).log
                                        else
                                                minor '(just testing)'
                                        fi
                                fi
                        done
}

# backup user@host source destination
function backup() {
        local newexclude 
        local dryrun
        local new_exclude_file
        newexclude=""
        for i in $EXCLUDE; do
                if is_prefix $i $2; then
                        suffix=/$(trim_prefix $i $2)
                        newexclude="$newexclude --exclude=$suffix"
                fi
                if ! is_prefix $i /; then
                        newexclude="$newexclude --exclude=$i"
                fi
        done
        if [ ! -z "$EXCLUDE_FILE" ]; then
                newexclude="$newexclude --exclude-from=$EXCLUDE_FILE"
        fi
        if [ ! -z "$newexclude" ]; then
                newexclude="$newexclude --delete-excluded"
        fi
        if [ "$BACKUP" = "test" ]; then
                dryrun="--dry-run"
        else
                dryrun=""
        fi
        logged_command rsync \
                $dryrun \
                -v \
                -a \
                --numeric-ids \
                --blocking-io \
                --partial \
                --verbose \
                --delete \
                $newexclude \
                -e "'ssh -i $KEY -o BatchMode=yes'" \
                $1:$2 $3 >> ${DESTINATION}/logs/${HOST}/current.log
        # Ignore error 24 ("File vanished")
        ERRLEV=$?
        if [ $ERRLEV -ne 24 -a $ERRLEV -ne 0 ]; then
                chkerror $ERRLEV
        fi
}

function chkerror() {
        if [ $1 -gt $ERROR ]; then
                ERROR=$1
        fi
}

function parse() {
        unset HOST      # hostname to connect to
        unset COUNT     # number of backups to keep
        unset PATHS     # paths to backup on this host
        unset KEY       # key file to use
        unset USER      # (optional) Username to connect as
        unset EXCLUDE   # excludes
        unset EXCLUDE_FILE # exclude file
        BACKUP=no       # if this machine should be backed up, set to "yes" to
                        # enable.
        if [ ! -r $i ]; then
                error $i is not readable, skipping
                return
        fi
        . $i
        # Validate the config file
        if [ -z "$HOST" ]; then
                error HOST not set in $i, skipping
                BACKUP=no
        fi
        if [ -z "$COUNT" ]; then
                COUNT=10
                warning COUNT not set in $i, assuming $COUNT
        fi
        if [ -z "$PATHS" ]; then
                error PATHS not set in $i, skipping
                BACKUP=no
        fi
        case $BACKUP in 
                yes)
                        if [ "$TEST" = "yes" ]; then
                                BACKUP=test;
                        fi
                        ;;
                test)
                        ;;
                *)
                        log Skipping disabled host $i
                        BACKUP=no
        esac
        if [ -z "$USER" ]; then
                USER=root
        fi
        if [ -z "$KEY" ]; then
                KEY=${DESTINATION}/configs/${HOST}.key
        fi
        if [ -e "${DESTINATION}/configs/${HOST}.excludes" ]; then
                while read exclude; do
                        EXCLUDE="$EXCLUDE $exclude"
                done <${DESTINATION}/configs/${HOST}.excludes
        fi
}

log Backup started

test="no"
hosts=""
while [ "$#" -gt 0 ]; do
        case $1 in
                -t)
                        warning Test mode only\!
                        TEST=yes
                        shift
                        ;;
                -v)
                        warning Debug mode
                        DEBUG=yes
                        shift
                        ;;
                -*)
                        error Unknown command line option $1
                        shift
                        ;;
                *)
                        hosts="$hosts ${DESTINATION}/configs/$1.cfg"
                        shift
                        ;;
        esac
done

if [ -z "$hosts" ]; then
        hosts=${DESTINATION}/configs/*.cfg
fi

log Phase One -- Pruning and Linking
mkdir -p $DESTINATION/logs
for i in $hosts; do
        parse $i
        log $HOST
        if [ $BACKUP = "no" ]; then
                continue
        fi
        # Create the directory tree if it doesn't exist
        mkdir -p ${DESTINATION}/backups/${HOST}
        mkdir -p ${DESTINATION}/logs/${HOST}

        # Remove old unused directories
        clean_old ${DESTINATION}/backups/${HOST}

        # If the destination exists...
        if [ -d ${DESTINATION}/backups/$HOST/current ]; then
                minor Copying old backup
                if [ $BACKUP == "yes" ]; then
                        current_ts=$(date "+%Y-%m-%d.%H:%M:%S" -r "${DESTINATION}/backups/${HOST}/current")
                        cp -laR ${DESTINATION}/backups/$HOST/current \
                                ${DESTINATION}/backups/$HOST/${current_ts}
                        if [ -f "${DESTINATION}/logs/${HOST}/current.log" ]; then
                            mv "${DESTINATION}/logs/${HOST}/current.log" "${DESTINATION}/logs/${HOST}/${current_ts}.log"
                        fi
                else
                        minor "(just pretending)"
                fi
                chkerror $?
        fi

        mkdir -p ${DESTINATION}/backups/${HOST}/current

done
log Phase Two -- Do the backup
for i in $hosts; do
        parse $i

        log $HOST

        if [ $BACKUP = "no" ]; then
                minor Backup disabled by config
                continue
        fi

        for i in $PATHS; do
                dest=${DESTINATION}/backups/${HOST}/current$i
                minor Backing up $i to $dest
                mkdir -p $dest
                backup ${USER}@${HOST} $i/ $dest
        done
        touch ${DESTINATION}/backups/${HOST}/current
done
log Backup complete

echo
df
(
echo -n "$(date +%s) " ; df $DESTINATION | tail -1 | awk '{ print $3,$4,$2 }' 
) >> ${DESTINATION}/usage.log

exit $ERROR
