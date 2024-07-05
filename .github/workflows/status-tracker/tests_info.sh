#!/bin/bash
# Scans repository for test results in releases

# Timekeep functions
function getNow () {
    echo $(date +'%s')
}

START=$(getNow)

function printElapsed () {
    local NOW=$(getNow)
    echo "::debug::L$1: elapsed $(( $NOW - $START ))s" >&2
}

if [[ -z "$GH_TOKEN" ]]; then
    echo "Missing <GH_TOKEN> from env, exiting" >&2
    exit 1
fi

OUTPUT="assets" # Where to output files

# Fetch all remotes and all tags, silenced output
git fetch --all --tags > /dev/null 2>&1
printElapsed ${LINENO}

# Get name from git remote url
NAME=$(basename -s .git $(git config --get remote.origin.url))
printElapsed ${LINENO}

# Get owner/repo string
OWNER_REPO=$(git config --get remote.origin.url | grep -oP '(?<=https://github.com/).*' | sed 's/\.git$//')
printElapsed ${LINENO}

RELEASES=$(gh release list | cut -f3)
printElapsed ${LINENO}

if [[ "$RELEASES" == *"no releases"* || -z "$RELEASES" ]]; then
    echo "Repository has no releases, writing null" >&2
    echo "[]"
    exit 0
fi

LAST_RELEASE=$(echo "$RELEASES" | tail -1)

echo "["

for RELEASE in $RELEASES; do
    echo "{"
    echo "\"release\": \"$RELEASE\","
    echo "Checking release $RELEASE" >&2
    
    ALL_ASSETS=$(gh release view $RELEASE --json assets --jq '.assets')
    ASSET_COUNT=$(echo $ALL_ASSETS | jq -r '. | length')
    echo "\"assetCount\": $ASSET_COUNT,"
    #Check only last 10 releases
    ASSETS=$(echo $ALL_ASSETS | jq -r '. | sort_by(.name) | reverse[0:10] | reverse[].name')
    printElapsed ${LINENO}
    LAST_ASSET=$(echo "$ASSETS" | tail -1)
    echo "\"tests\": ["
    if [[ -z "$ASSETS" ]]; then
        echo "$RELEASE has no assets, continuing" >&2
    else
        echo "$RELEASE has assets" >&2
        for ASSET in $ASSETS; do
            echo "Checking asset $ASSET" >&2
            if [[ "$ASSET" == *".trx"* ]]; then
                echo "{"
                # Download test asset into $OUTPUT directory
                gh release download $RELEASE --repo $OWNER_REPO --pattern "$ASSET" -O "$OUTPUT/$ASSET"
                printElapsed ${LINENO}
                # Get test summary from test asset
                SUMMARY=$(cat "$OUTPUT/$ASSET" | xq --raw-output '.[].ResultSummary | {"@outcome": .["@outcome"], "Counters": .Counters }')
                printElapsed ${LINENO}
                echo "\"testFile\": \"$ASSET\"",
                echo "\"summary\": $SUMMARY"
                if [[ "$ASSET" != "$LAST_ASSET" ]]; then
                    echo "},"
                else
                    echo "}"
                fi
            else
                echo "Asset $ASSET is not a .trx file, continuing" >&2
            fi
        done
    fi
    echo "]"
    
    if [[ "$RELEASE" == "$LAST_RELEASE" ]]; then
        echo "}"
    else
        echo "},"
    fi
done

echo "]"

# Cleanup
echo "Deleting test files" >&2
rm $OUTPUT/* && rmdir $OUTPUT && echo "Deleted files" >&2
echo "Finished executing" >&2
