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

# Environment Variables as Output:
#   $JIRA_TICKETS - string of whitespace separated multiple JIRA tickets (e.g. "DIG-1 DIG-2 DIG-3")

JIRA_TICKETS_ARRAY=()

declare -A environments
environments=([dev]=1 [uat]=2 [pre-prod]=3 [prod]=4)

# since vercel creates github deployment objects under "Preview" environment for dev, uat and pre-prod
# instead of getting deployment objects from github, query vercel deployment objects for a branch (dev, uat, pre-prod or main)
curl -X GET "https://api.vercel.com/v6/deployments?projectId=${VERCEL_PROJECT_ID}&teamId=${VERCEL_TEAM_ID}&app=${APP}&state=READY&limit=100" \
    -H "Authorization: Bearer ${{ secrets.GRID_VERCEL_TOKEN }}" \
    | jq -c "[.deployments[] | select(.meta.githubCommitRef == \"${DEPLOYED_BRANCH}\")]" > list_of_deployments.json

# cleanup deployment json to remove escape characters if any
sed -i 's/\\n/ /g' list_of_deployments.json
sed -i 's/ //g' list_of_deployments.json

# extract the previous deployed commit sha

current_deployment_index=$(cat list_of_deployments.json \
    | jq "map(.meta.githubCommitSha==\"$current_deployment_sha\") | index(true)")

((previous_deployment_index=current_deployment_index+1))
previous_deployment_sha=$(cat list_of_deployments.json | jq -c ".[$previous_deployment_index].meta.githubCommitSha" | tr -d \")

# extract jira tickets between commits previous_deployment_sha and current_deployment_sha

echo Comparing $previous_deployment_sha...$current_deployment_sha

JIRA_TICKET_NUMBERS=($(curl -s \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Authorization: token ${{secrets.GRID_GIT_TOKEN}}" \
    "${{ steps.variables.outputs.repo }}/compare/$previous_deployment_sha...$current_deployment_sha" \
    | jq '.commits' | jq '.[].commit.message' | tr -d \" | cut -d'\' -f1 \
    | grep -P '(?i)DIG[-\s][\d]+' -o | grep -P '[\d]+' -o)) || true

for jira_ticket_number in "${JIRA_TICKET_NUMBERS[@]}"; do
    JIRA_TICKETS_ARRAY+=("DIG-$jira_ticket_number")
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
    elif [[ "$(echo $issue_api_response | jq '.fields.project.key' | tr -d \")" != "DIG" ]]; then
        echo "Issue do not exist in Digital project - $issue_id"
        echo "issue belongs to project: $(echo $issue_api_response | jq '.fields.project')"
    elif [[ "$env_in_jira" != "null" ]] && [ ${environments[$ENV]} -lt ${environments[$env_in_jira]} ]; then
        echo "will not override $issue_id to lower environment from $env_in_jira to $ENV"
    else
        jira_refs_to_update+=($issue_id)
    fi
done


# export output variables
export JIRA_TICKETS_STRING=${jira_refs_to_update[*]}
