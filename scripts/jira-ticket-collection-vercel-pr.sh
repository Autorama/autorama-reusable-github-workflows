#!/bin/bash -ex

# Environment Variables as Input:
#   $ENV - environment
#   $DEPLOYED_BRANCH - github branch deployed (dev, uat, preprod, main)
#   $JIRA_API_TOKEN - Jira API Token

# Environment Variables as Output:
#   $JIRA_TICKETS - string of whitespace separated multiple JIRA tickets (e.g. "DIG-1 DIG-2 DIG-3")

declare -A environments
environments=([dev]=1 [uat]=2 [pre-prod]=3 [prod]=4)

# extract jira tickets from branch name

JIRA_TICKET_NUMBERS=($(echo ${DEPLOYED_BRANCH} | grep -P '(?i)DIG[-\s][\d]+' -o))
jira_refs_list_unique=($(printf '%s\n' "${JIRA_TICKET_NUMBERS[@]}" | sort -u))

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
