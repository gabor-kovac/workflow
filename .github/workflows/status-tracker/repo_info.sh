#!/bin/bash
# Make a json object about the repository

# Fetch all remotes and all tags, silenced output
git fetch --all --tags > /dev/null 2>&1

# Get owner/repo string
OWNER_REPO=$(git config --get remote.origin.url | grep -oP '(?<=github\.com\/).*' | sed 's/\.git$//')

# Repository name
NAME=$(gh api repos/$OWNER_REPO --jq '.name')

# Get project language
LANG=$(gh api repos/$OWNER_REPO --jq 'select(.language? != null) | .language')

SKIP_VERSION=0

# Search for files with these names in the project directory
SEARCH=( "package.json", "*.csproj" )

if [[ -z "$LANG" ]]; then
    echo "Brute force language detection" >&2
    SEARCH=( "package.json", "*.csproj" )
else
    echo "This is a $LANG project" >&2
    if [[ $LANG == *"TypeScript" ]]; then
        # TypeScript project
        SEARCH=( "package.json" )
    elif [[ $LANG == *"C#" ]]; then
        # C# project
        SEARCH=( "*.csproj" )
    else
        echo "Unsupported project language: $LANG, release version will be unavailable" >&2
	    SKIP_VERSION=1
    fi
fi

CURRENT_BRANCH=$(git branch --show-current)

if ! [[ "$CURRENT_BRANCH" == "release" ]]; then
 	echo "Not on release branch, checking out release branch" >&2
    git checkout release > /dev/null 2>&1
    CURRENT_BRANCH=$(git branch --show-current)
    if ! [[ "$CURRENT_BRANCH" == "release" ]]; then
        echo "Release branch does not exist, skipping version detection" >&2
        SKIP_VERSION=1
    fi
fi

if [ "$SKIP_VERSION" == 0 ]; then
	for SEARCH_NAME in "${SEARCH[@]}"; do
		echo "Searching for $SEARCH_NAME files" >&2
		CHECK_FILES=$(find . -name "$SEARCH_NAME")
		echo "Found files: $CHECK_FILES" >&2
		for FILE in $CHECK_FILES; do
			if [ -f "$FILE" ]; then
				echo "Checking file: $FILE" >&2
				if [[ $FILE == *".csproj" ]]; then
					: ${RELEASE:=$(cat $FILE | xq --raw-output 'select(.[].PropertyGroup.AssemblyVersion? != null) | .[].PropertyGroup.AssemblyVersion')}
					: ${RELEASE:=$(cat $FILE | xq --raw-output 'select(.[].PropertyGroup[0]? != null) | select(.[].PropertyGroup[0].ApplicationDisplayVersion? != null) | .[].PropertyGroup[0].ApplicationDisplayVersion')}
				else 
					: ${RELEASE:=$(cat $FILE | jq --raw-output 'select(.version? != null) | .version')}
				fi
			fi
		done
	done
fi

# The list of tags on this repo
TAGS=$(git tag | jq -ncR '[inputs]')

# Release list
RELEASES=$(gh api repos/$OWNER_REPO/releases --jq '.[].tag_name' | jq -Rnc '[inputs]')

# The list of release candidates
RC_LIST=$(git tag -l | grep -E '^(0|[1-9]\d*)\.([1-9]\d*)\.0$' | jq -Rcn '[inputs]')

# List all the branches of this repo excluding main and release
BRANCHES=$(git ls-remote --exit-code --heads origin | awk '{print $2}' | grep -oP '(?<=refs/heads/).*' | grep -v 'main' | grep -v 'release')

# Get the last branch
LAST_BRANCH=$(echo $BRANCHES | awk '{print $NF}')

echo '{'
echo '"name": "'$NAME'",'
if [ -z "$RELEASE" ]; then
	echo '"version": null,'
else
	echo '"version": "'$RELEASE'",'
fi
echo '"updated": '$(date +%s%3N)','
if [ -z "$WIKI_VERSION" ]; then
	echo '"wikiVersion": null,'
else
	echo '"wikiVersion": "'$WIKI_VERSION'",'
fi
echo '"releases": '$RELEASES','
echo '"releaseCandidates": '$RC_LIST','
echo '"tags": '$TAGS','
echo '"features": ['

for BRANCH in $BRANCHES; do
    echo "Checking branch $BRANCH" >&2

	# Checkout the branch, git output is silenced
	git checkout $BRANCH > /dev/null 2>&1

	# Cut 'origin/' from full branch name
	NAME=$(echo $BRANCH | sed 's/origin\///')

	# Get info about last commit
    echo "Reading last commit info..." >&2
	LAST_COMMIT_SHA=$(gh api repos/$OWNER_REPO/branches/$NAME --jq '.commit.sha')
	LAST_COMMIT_MESSAGE=$(gh api repos/$OWNER_REPO/branches/$NAME --jq '.commit.commit.message')
	LAST_COMMIT_DATE=$(gh api repos/$OWNER_REPO/branches/$NAME --jq '.commit.commit.author.date')
	LAST_COMMIT_AUTHOR=$(gh api repos/$OWNER_REPO/branches/$NAME --jq '.commit.commit.author.name')

	# Get the number of open pull requests in a list
    PR_STR="repos/$OWNER_REPO/pulls -f state=open"

    echo "Reading pull requests..." >&2
	PULL_REQUESTS=$(gh api -X GET $PR_STR --jq '.[].number')

	# Get the number of the last open pull request
	LAST_PR=$(echo $PULL_REQUESTS | awk '{print $NF}')
	
	PR_INFO='['

	for PR in $PULL_REQUESTS; do
        echo "Checking pull request: $PR" >&2
		PR_INFO=$PR_INFO'{'
		if [[ "$PR" != "" ]]; then
			PR_TITLE=$(gh pr view $PR --json title | jq -r '.title')

			# Information about the pull request author
			PR_AUTHOR=$(gh pr view $PR --json author | jq -r '.author')

			# When was the pull request created
			PR_CREATED_AT=$(gh pr view $PR --json createdAt | jq -r '.createdAt')

			PR_INFO=$PR_INFO'"number": '$PR', "title": "'$PR_TITLE'", "author": '$PR_AUTHOR', "createdAt": "'$PR_CREATED_AT'"'
		else
			PR_INFO=$PR_INFO'"number": null, "title": null, "author": null, "createdAt": null'
		fi

		# Handle trailing comma
		if [[ "$PR" == "$LAST_PR" ]]; then
			PR_INFO=$PR_INFO'}'
		else
			PR_INFO=$PR_INFO'},'
		fi
	done

	PR_INFO=$PR_INFO']'

	echo '{'
	echo '"branch": "'$NAME'",'
	echo '"lastCommitSha": "'$LAST_COMMIT_SHA'",'
	echo '"lastCommitMessage": "'$LAST_COMMIT_MESSAGE'",'
	echo '"lastCommitDate": "'$LAST_COMMIT_DATE'",'
	echo '"lastCommitAuthor": "'$LAST_COMMIT_AUTHOR'",'
	echo '"pullRequests": '$PR_INFO

	if [[ "$BRANCH" == "$LAST_BRANCH" ]]; then
		echo '}'
	else
		echo '},'
	fi
done

echo ']'
echo '}'
