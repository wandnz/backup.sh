#!/bin/bash

FILENAME=$(tempfile)
TO="<me@example.org>"
FROM="<root@example.org>"

$* &>$FILENAME
ERROR=$?

if [ $ERROR -gt 0 ]; then
        echo \*\!\* Exit code: $ERROR >>$FILENAME
        STATUS=FAILED
else
        STATUS=SUCCESS
fi

(
        echo "From: $FROM"
        echo "To: $TO"
        echo "Subject: ${STATUS}: $*"
        echo
        cat $FILENAME
) | sendmail $TO

rm -f $FILENAME
