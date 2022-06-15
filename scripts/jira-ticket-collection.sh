#!/bin/bash -ex

# Environment Variables as Input:
#   $APP - app/repository name
#   $ENV - environment
#   $GITHUB_API_URL - github repository url
#   $ARTIFACT_TAG - github tag used for deployment (release-5488a22)
#   $GITHUB_PAT - github PAT token
#   $JIRA_API_TOKEN - Jira API Token

# Environment Variables as Output:
#   $JIRA_TICKETS - string of whitespace separated multiple JIRA tickets (e.g. "DIG-1 DIG-2 DIG-3")

JIRA_TICKETS_ARRAY=()

declare -A environments
environments=([dev]=1 [uat]=2 [pre-prod]=3 [prod]=4)

# Extract Jira ticket numbers from commits between $ARTIFACT_TAG and previous tag

previous_commit_sha=$(curl \
    --location --request POST 'https://api.github.com/graphql' \
    --header "Authorization: token ${GITHUB_PAT}" \
    --header 'Content-Type: application/json' \
    --data-raw "{\"query\":\"query {\r\n    repository (owner: \\\"Autorama\\\", name: \\\"$APP\\\") {\r\n        deployments (last: 20, environments: [\\\"$ENV\\\"]) {\r\n            nodes {\r\n                id\r\n                commitOid\r\n                environment\r\n                payload\r\n                latestStatus {\r\n                    state\r\n                    }\r\n            createdAt\r\n            }\r\n        }\r\n    }\r\n}\",\"variables\":{}}" \
        | jq ".data.repository.deployments.nodes" \
        | jq '[.[] | select(.payload != null)]' \
        | jq '[.[] | select(.latestStatus.state == "SUCCESS" or .latestStatus.state == "INACTIVE")]' \
        | jq '. | group_by(.payload) | map({id: .[-1].id, payload: .[-1].payload, createdAt: .[-1].createdAt, commitOid: .[-1].commitOid})' \
        | jq '. | sort_by(.createdAt) | reverse' \
        | jq '.[1].commitOid' \
        | tr -d \")

# extract jira refs from commits betweeen $previous_tag_name and $ARTIFACT_TAG

ARTIFACT_TAG_SHORT_SHA=$(echo $ARTIFACT_TAG | cut -d'-' -f2)
PREVIOUS_TAG_SHORT_SHA=${previous_commit_sha:0:7}
echo Comparing $PREVIOUS_TAG_SHORT_SHA...$ARTIFACT_TAG_SHORT_SHA

JIRA_TICKET_NUMBERS=($(curl -s \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Authorization: token $GITHUB_PAT" \
    "$GITHUB_API_URL/compare/$PREVIOUS_TAG_SHORT_SHA...$ARTIFACT_TAG_SHORT_SHA" \
    | jq '.commits' | jq '.[].commit.message' | tr -d \" | cut -d'\' -f1 \
    | grep -P '(?i)DIG[-\s][\d]+' -o | grep -P '[\d]+' -o)) || true

for jira_ticket_number in "${JIRA_TICKET_NUMBERS[@]}"; do
    JIRA_TICKETS_ARRAY+=("DIG-$jira_ticket_number")
done

jira_refs_list_unique=($(printf '%s\n' "${JIRA_TICKETS_ARRAY[@]}" | sort -u))

# filter non-existing jira tickets

existing_jira_refs=()

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
        echo "will not override $issue_id from $env_in_jira to $ENV"
    else
        existing_jira_refs+=($issue_id)
    fi
done


# export output variables
export JIRA_TICKETS_STRING=${existing_jira_refs[*]}
