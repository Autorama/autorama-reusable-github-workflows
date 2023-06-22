#!/bin/bash -ex

# Environment Variables as Input:
#   $APP - app/repository name
#   $ENV - environment
#   $GITHUB_API_URL - github repository url
#   $DEPLOYED_SHA - github commit sha deployed
#   $DEPLOYED_BRANCH - github branch deployed (dev, uat, preprod, main)
#   $GITHUB_PAT - github PAT token
#   $JIRA_API_TOKEN - Jira API Token
#   $VERCEL_PROJECT_ID - Vercel project ID
#   $VERCEL_TEAM_ID - Vercel team ID
#   $GRID_VERCEL_TOKEN - Vercel token

# Environment Variables as Output:
#   $JIRA_TICKETS - string of whitespace separated multiple JIRA tickets (e.g. "DIG-1 DIG-2 DIG-3")

JIRA_TICKETS_ARRAY=()

JIRA_PROJECTS_IDS=("DIG" "PD")

declare -A environments
environments=([dev]=1 [uat]=2 [pre-prod]=3 [prod]=4)

# pagination parameters for vercel rest api
MAX_LIMIT=100
UNTIL_TIMESTAMP=

echo "[]" > list_of_deployments.json

# since vercel creates github deployment objects under "Preview" environment for dev, uat and pre-prod
# instead of getting deployment objects from github, query vercel deployment objects for a branch (dev, uat, pre-prod or main)
# iterate over the paginated list of deployment objects from vercel rest api until we find the currently deployed and previous deployed commit hash
while true; do

    # get the paginated list of deployments from vercel
    URL="https://api.vercel.com/v6/deployments?projectId=${VERCEL_PROJECT_ID}&teamId=${VERCEL_TEAM_ID}&app=${APP}&state=READY&limit=${MAX_LIMIT}"
    
    if [ -n "$UNTIL_TIMESTAMP" ]; then
        URL="${URL}&until=${UNTIL_TIMESTAMP}"
    fi

    # store the curretly fetched list of deployment in a temporary file
    curl -X GET "${URL}" -H "Authorization: Bearer ${GRID_VERCEL_TOKEN}" | jq '.deployments' > list_of_deployments_tmp.json

    # extract the timestamp of last object in the list of deployments required for next set of paginated results
    UNTIL_TIMESTAMP=$(cat list_of_deployments_tmp.json | jq ".[-1].createdAt")

    # filter the list of deployments that relates to the DEPLOYED_BRANCH and append the list to list_of_deployments.json
    jq -c "[.[] | select(.meta.githubCommitRef == \"${DEPLOYED_BRANCH}\")]" list_of_deployments_tmp.json > list_of_deployments_filtered.json
    jq -s '.[0] + .[1]' list_of_deployments.json list_of_deployments_filtered.json > combined_deployments.json
    mv combined_deployments.json list_of_deployments.json

    if [[ $(jq 'length' list_of_deployments.json) == 0 ]]; then
        continue
    fi

    # check if the currently deployed object exist in the list of deployment
    current_deployment_index=$(cat list_of_deployments.json | jq "map(.meta.githubCommitSha==\"$DEPLOYED_SHA\") | index(true)")

    if [[ $current_deployment_index != null ]]; then
        # previously deployed index is the next deployment object in the list
        ((previous_deployment_index=current_deployment_index+1))

        # get previously deployed commit hash
        previous_deployment_sha=$(cat list_of_deployments.json | jq -c ".[$previous_deployment_index].meta.githubCommitSha" | tr -d \")
        
        if [[ $previous_deployment_sha != null ]]; then
            break
        fi
    fi    
done

# extract jira tickets between commits previous_deployment_sha and DEPLOYED_SHA

current_deployment_index=$(cat list_of_deployments.json \
    | jq "map(.meta.githubCommitSha==\"$DEPLOYED_SHA\") | index(true)")

((previous_deployment_index=current_deployment_index+1))
previous_deployment_sha=$(cat list_of_deployments.json | jq -c ".[$previous_deployment_index].meta.githubCommitSha" | tr -d \")

# extract jira tickets between commits previous_deployment_sha and DEPLOYED_SHA

echo Comparing $previous_deployment_sha...$DEPLOYED_SHA

found_current_deployment_index=false
echo "[]" > list_of_commits_tmp.json
echo "[]" > list_of_commits.json
page_number=1


# loop through the paginated response of github rest api to list commits for a given branch
# store the list of commits in a json file `list_of_commits.json`

while true; do
    response=$(curl -s -L \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_PAT}" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -o tmp.json \
        https://api.github.com/repos/Autorama/${APP}/commits?sha=${DEPLOYED_BRANCH}\&per_page=100\&page=${page_number})
    
    # cleanup \n
    sed -i 's/\\n/ /g' tmp.json

    current_deployment_index=$(jq ". | map(.sha == \"$DEPLOYED_SHA\") | index(true)" tmp.json)

    if [ "$current_deployment_index" != "null" ]; then
        found_current_deployment_index=true
    fi

    if [ "$found_current_deployment_index" = "true" ]; then
        previous_deployment_sha_index=$(jq ". | map(.sha == \"$previous_deployment_sha\") | index(true)" tmp.json)

        if [ "$current_deployment_index" = "null" ]; then
            current_deployment_index="0"
        fi

        if [ "previous_deployment_sha_index" = "null" ]; then
            previous_deployment_sha_index=""
        fi

        jq ".[$current_deployment_index:$previous_deployment_sha_index]" tmp.json > list_of_commits_tmp.json
        jq -s '.[0] + .[1]' "list_of_commits.json" "list_of_commits_tmp.json" > list_of_commits.json

        if [ "$previous_deployment_sha_index" != "" ]; then
            break
        fi
    fi

    page_number=`expr $page_number + 1`

done

for str in ${JIRA_PROJECTS_IDS[@]}; do

    JIRA_TICKET_NUMBERS_FROM_BRANCH=($(jq '.' list_of_commits.json | jq '.[].commit.message' | tr -d \" | cut -d'\' -f1 \
        | grep -P '(?i)'$str'[-\s][\d]+' -o | grep -P '[\d]+' -o)) || true

    for jira_ticket_number in "${JIRA_TICKET_NUMBERS_FROM_BRANCH[@]}"; do
        JIRA_TICKETS_ARRAY+=("$str-$jira_ticket_number")
    done

    JIRA_TICKET_NUMBERS_FROM_COMPARE=($(curl -s \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Authorization: token ${GITHUB_PAT}" \
        "${GITHUB_API_URL}/compare/$previous_deployment_sha...$DEPLOYED_SHA" \
        | jq '.commits' | jq '.[].commit.message' | tr -d \" | cut -d'\' -f1 \
        | grep -P '(?i)'$str'[-\s][\d]+' -o | grep -P '[\d]+' -o)) || true
    
    for jira_ticket_number in "${JIRA_TICKET_NUMBERS_FROM_COMPARE[@]}"; do
        JIRA_TICKETS_ARRAY+=("$str-$jira_ticket_number")
    done
done

jira_refs_list_unique=($(printf '%s\n' "${JIRA_TICKETS_ARRAY[@]}" | sort -u))

# filter non-existing jira tickets

jira_refs_to_update=()

for issue_id in "${jira_refs_list_unique[@]}"; do

    issue_api_response=$(curl -s \
        --url "https://autorama.atlassian.net/rest/api/3/issue/$issue_id" \
        --user "devops@vanarama.co.uk:${JIRA_API_TOKEN}" \
        --header 'Accept: application/json')

    env_in_jira=$(curl -s \
        --url "https://autorama.atlassian.net/rest/api/3/issue/$issue_id" \
        --user "devops@vanarama.co.uk:${JIRA_API_TOKEN}" \
        --header 'Accept: application/json' \
            | jq '.fields.customfield_10132[0].value' \
            | tr -d \" \
            | tr '[:upper:]' '[:lower:]')

    if [[ "$(echo $issue_api_response | jq 'has("errorMessages")')" == "true" ]]; then
        echo "Issue do not exist: $issue_id; $issue_api_response"
    elif [[ "$env_in_jira" != "null" ]] && [ ${environments[$ENV]} -lt ${environments[$env_in_jira]} ]; then
        echo "will not override $issue_id to lower environment from $env_in_jira to $ENV"
    else
        jira_refs_to_update+=($issue_id)
    fi
done


# export output variables
echo "Jira tickets fetched: ${JIRA_TICKETS_STRING}"
export JIRA_TICKETS_STRING=${jira_refs_to_update[*]}
