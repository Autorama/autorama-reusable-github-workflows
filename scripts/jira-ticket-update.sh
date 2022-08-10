#!/bin/bash -ex

# Environment Variables as Input:
#   $APP - app/repository name
#   $ENV - environment
#   $ARTIFACT_TAG - github tag used for deployment (release-5488a22)
#   $JIRA_REF_LIST - comma separated jira ticket ids
#   $JIRA_API_TOKEN - Jira API Token

JIRA_REF_LIST=(${JIRA_REF_LIST})
RELEASE_DATE=$(date +'%Y-%m-%d')

COMPONENT_ID=$(curl --request GET \
    --url 'https://autorama.atlassian.net/rest/api/2/project/DIG/components' \
    --user "devops@vanarama.co.uk:${JIRA_API_TOKEN}" \
    --header 'Accept: application/json' \
        | jq "[ .[] | select(.name == \"${APP}\") ]" \
        | jq '.[0].id' \
        | tr -d \")

for ref in "${JIRA_REF_LIST[@]}"; do

EXISTING_COMPONENTS_JSON=$(curl -s \
    --url "https://autorama.atlassian.net/rest/api/3/issue/${ref}" \
    --user "devops@vanarama.co.uk:${JIRA_API_TOKEN}" \
    --header 'Accept: application/json' \
        | jq -c '.fields.components')

# customfield_10133 - Release Date
# customfield_10132 - Release Environment
# customfield_10114 - Release Tag
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
