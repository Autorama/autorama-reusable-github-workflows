#!/bin/bash

# Environment Variables as Input:
#   $APP - app/repository name
#   $ENV - environment
#   $ARTIFACT_TAG - github tag used for deployment (release-5488a22)
#   $JIRA_REF_LIST - whitespace separated jira ticket ids
#   $JIRA_API_TOKEN - Jira API Token
#   $DEPLOYED_BRANCH - deployed branch

JIRA_REF_LIST_ARRAY=($(echo $JIRA_REF_LIST))
RELEASE_DATE=$(date +'%Y-%m-%d')



for ref in "${JIRA_REF_LIST_ARRAY[@]}"; do

PROJECT_ID="${ref%%-*}"

COMPONENT_ID=$(curl --request GET \
    --url "https://autorama.atlassian.net/rest/api/2/project/$PROJECT_ID/components" \
    --user "devops@vanarama.co.uk:${JIRA_API_TOKEN}" \
    --header 'Accept: application/json' \
        | jq "[ .[] | select(.name == \"${APP}\") ]" \
        | jq '.[0].id' \
        | tr -d \")
        
curl -s \
    --url "https://autorama.atlassian.net/rest/api/3/issue/${ref}" \
    --user "devops@vanarama.co.uk:${JIRA_API_TOKEN}" \
    --header 'Accept: application/json' > jira_issue_response.json

EXISTING_COMPONENTS_JSON=$(cat jira_issue_response.json \
    | jq -c '.fields.components')

EXISTING_BRANCHES_JSON=$(cat jira_issue_response.json \
    | jq -c '.fields.customfield_10147')

# customfield_10133 - Release Date
# customfield_10132 - Release Environment
# customfield_10114 - Release Tag
# customfield_10147 - Branches

if [[ -z $DEPLOYED_BRANCH ]]; then
    BRANCH_LIST_JSON=$(echo ${EXISTING_BRANCHES_JSON} | jq -c )
else
    BRANCH_LIST_JSON=$(echo ${EXISTING_BRANCHES_JSON} | jq -c ". |= . + [\"${DEPLOYED_BRANCH}\"]")
fi

jira_payload() {
cat <<EOF
{
    "update": {
        "customfield_10133": [{"set":"$RELEASE_DATE"}],
        "customfield_10132": [
            {
                "set": [
                    {
                        "value": "${ENV}"
                    }
                ]
            }
        ],
        "customfield_10114": [
            {
                "set": "${ARTIFACT_TAG}"
            }
        ],
        "components": [
            {
                "set": $(echo ${EXISTING_COMPONENTS_JSON} | jq ". |= . + [{\"id\": \"${COMPONENT_ID}\"}]")
            }
        ],
        "customfield_10147": [
            {
                "set": $(echo $BRANCH_LIST_JSON)
            }
        ]
    }
}
EOF
}

curl --location --request PUT "https://autorama.atlassian.net/rest/api/3/issue/$ref" \
    --header "Accept: application/json" \
    --user "devops@vanarama.co.uk:${JIRA_API_TOKEN}" \
    --header 'Content-Type: application/json' \
    --data-raw "$(jira_payload)"

done
