#!/bin/bash
#
# Push /var/log/manta/upload/... log files up to Manta.
#

echo ""   # blank line in log file helps scroll btwn instances
set -o errexit
export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -o xtrace



## Environment setup

export PATH=/opt/local/bin:$PATH



## Global variables

# Immutables

SSH_KEY=/root/.ssh/id_rsa

MANTA_KEY_ID=$(ssh-keygen -l -f $SSH_KEY.pub | awk '{print $2}')
MANTA_URL=$(json -f /opt/smartdc/common/etc/config.json manta.url)
MANTA_USER=poseidon
rejectUnauthorized=$(json -f /opt/smartdc/common/etc/config.json manta.rejectUnauthorized)
if [[ $rejectUnauthorized = "true" ]]; then
    MANTA_TLS_INSECURE=0
else
    MANTA_TLS_INSECURE=1
fi

AUTHZ_HEADER="keyId=\"/$MANTA_USER/keys/$MANTA_KEY_ID\",algorithm=\"rsa-sha256\""
DIR_TYPE='application/json; type=directory'
LOG_TYPE='text/plain'

# Mutables

NOW=""
SIGNATURE=""



## Functions

function fail() {
    echo "$*" >&2
    exit 1
}


function sign() {
    NOW=$(date -u "+%a, %d %h %Y %H:%M:%S GMT")
    SIGNATURE=$(echo "date: $NOW" | tr -d '\n' | openssl dgst -sha256 -sign $SSH_KEY | openssl enc -e -a | tr -d '\n') \
	|| fail "unable to sign data"
}


function manta_put() {
    sign || fail "unable to sign"
    curl -fisSk \
        -X PUT\
        -H "Date: $NOW" \
        -H "Authorization: Signature $AUTHZ_HEADER,signature=\"$SIGNATURE\"" \
        -H "Connection: close" \
        -H "Content-Type: $2" \
        $MANTA_URL/$MANTA_USER/stor$1 $3 || fail "unable to upload $1"
}


# $1 -> service
# $2 -> YYYY/MM/DD/HH
function mkdirp() {
    local year=$(echo $2 | awk -F / '{print $1}')
    local month=$(echo $2 | awk -F / '{print $2}')
    local day=$(echo $2 | awk -F / '{print $3}')
    local hour=$(echo $2 | awk -F / '{print $4}')

    manta_put "/logs" "$DIR_TYPE"
    manta_put "/logs/$1" "$DIR_TYPE"
    manta_put "/logs/$1/$year" "$DIR_TYPE"
    manta_put "/logs/$1/$year/$month" "$DIR_TYPE"
    manta_put "/logs/$1/$year/$month/$day" "$DIR_TYPE"
    manta_put "/logs/$1/$year/$month/$day/$hour" "$DIR_TYPE"
}



## Mainline

# Files look like this:
#     muskie_0db94777-555d-4f1a-a87f-b1e2ee13c025_2012-10-17T21:00:00.log
# And we transform them to this in manta:
#     /poseidon/stor/logs/muskie/2012/10/17/20/0db94777.log

for f in $(ls /var/log/manta/upload/*.log)
do
    service=$(echo $f | cut -d _ -f 1 | cut -d / -f 6)
    zone=$(echo $f | cut -d _ -f 2 | cut -d - -f 1)
    logtime=$(echo $f | cut -d _ -f 3 | sed 's|.log||')
    time=$(date -d \@$(( $(date -d $logtime "+%s") - 3600 )) "+%Y/%m/%d/%H")
    key="/logs/$service/$time/$zone.log"
    mkdirp $service $time
    manta_put "$key" "$LOG_TYPE" "-T $f"
    rm $f
done