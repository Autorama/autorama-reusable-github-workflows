#!/bin/bash

# Environment Variables as Input:
#   $APP - app/repository name
#   $ENV - environment
#   $ARTIFACT_TAG - github tag used for deployment (release-5488a22)
#   $JIRA_REF_LIST - whitespace separated jira ticket ids
#   $JIRA_API_TOKEN - Jira API Token
#   $DEPLOYED_BRANCH - deployed branch
#   $JIRA_ENDPOINT - Autotrader jira endpoint
#   $JIRA_CUSTOMFIELD_JSON_STRING  - jira customfields json string

JIRA_ENDPOINT=https://autotrader-sandbox-655.atlassian.net
JIRA_CUSTOMFIELD_JSON_STRING='{"RELEASE_DATE":"customfield_11047","RELEASE_ENV":"customfield_11046","RELEASE_TAG":"customfield_11039","BRANCH":"customfield_11054"}'

JIRA_REF_LIST_ARRAY=($(echo $JIRA_REF_LIST))
RELEASE_DATE=$(date +'%Y-%m-%d')

# Convert JSON string back to JSON object
JIRA_CUSTOMFIELD_JSON=$(echo "$JIRA_CUSTOMFIELD_JSON_STRING" | jq '.')

for ref in "${JIRA_REF_LIST_ARRAY[@]}"; do

PROJECT_ID="${ref%%-*}"

COMPONENT_ID=$(curl --request GET \
    --url "$JIRA_ENDPOINT/rest/api/2/project/$PROJECT_ID/components" \
    --user "devops@vanarama.co.uk:${JIRA_API_TOKEN}" \
    --header 'Accept: application/json' \
        | jq "[ .[] | select(.name == \"${APP}\") ]" \
        | jq '.[0].id' \
        | tr -d \")
        
curl -s \
    --url "$JIRA_ENDPOINT/rest/api/3/issue/${ref}" \
    --user "devops@vanarama.co.uk:${JIRA_API_TOKEN}" \
    --header 'Accept: application/json' > jira_issue_response.json

EXISTING_COMPONENTS_JSON=$(cat jira_issue_response.json \
    | jq -c '.fields.components')

EXISTING_BRANCHES_JSON=$(cat jira_issue_response.json \
    | jq -c '.fields.customfield_11054')

# customfield_11047 - Release Date
# customfield_11046 - Release Environment
# customfield_11039 - Release Tag
# customfield_11054 - Branches

if [[ -z $DEPLOYED_BRANCH ]]; then
    BRANCH_LIST_JSON=$(echo ${EXISTING_BRANCHES_JSON} | jq -c )
else
    BRANCH_LIST_JSON=$(echo ${EXISTING_BRANCHES_JSON} | jq -c ". |= . + [\"${DEPLOYED_BRANCH}\"]")
fi

# Get values using jq
RELEASE_DATE_CUSTOMFIELD_ID=$(echo "$JIRA_CUSTOMFIELD_JSON" | jq -r '.RELEASE_DATE')
RELEASE_ENV_CUSTOMFIELD_ID=$(echo "$JIRA_CUSTOMFIELD_JSON" | jq -r '.RELEASE_ENV')
RELEASE_TAG_CUSTOMFIELD_ID=$(echo "$JIRA_CUSTOMFIELD_JSON" | jq -r '.RELEASE_TAG')
BRANCH_CUSTOMFIELD_ID=$(echo "$JIRA_CUSTOMFIELD_JSON" | jq -r '.BRANCH')

jira_payload() {
cat <<EOF
{
    "update": {
        "$RELEASE_DATE_CUSTOMFIELD_ID": [{"set":"$RELEASE_DATE"}],
        "$RELEASE_ENV_CUSTOMFIELD_ID": [
            {
                "set": [
                    {
                        "value": "${ENV}"
                    }
                ]
            }
        ],
        "$RELEASE_TAG_CUSTOMFIELD_ID": [
            {
                "set": "${ARTIFACT_TAG}"
            }
        ],
        "components": [
            {
                "set": $(echo ${EXISTING_COMPONENTS_JSON} | jq ". |= . + [{\"id\": \"${COMPONENT_ID}\"}]")
            }
        ],
        "$BRANCH_CUSTOMFIELD_ID": [
            {
                "set": $(echo $BRANCH_LIST_JSON)
            }
        ]
    }
}
EOF
}


response_code=$(curl --location --request PUT "$JIRA_ENDPOINT/rest/api/3/issue/$ref" \
    --header "Accept: application/json" \
    --user "devops@vanarama.co.uk:${JIRA_API_TOKEN}" \
    --header 'Content-Type: application/json' \
    --data-raw "$(jira_payload)" \
    -s -o /dev/null \
    -w "%{http_code}")

if [[ $response_code != 2* ]]; then
    echo "Error: Non-200 response received. HTTP status code: $response_code"
    exit 1
fi

done