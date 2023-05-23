#!/bin/bash -e

if [[ -e "./build-env-var.linux-amd64" ]]; then
    eval "$(./build-env-var.linux-amd64 -ssmPrefix=/$ENV/grid/$APP -pathLookup -envStdout)"
fi

if [[ $CI == true ]]; then
    ENVFILE='ci'
else
    ENVFILE=$ENV
fi

curl \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Authorization: token $GIT_TOKEN" \
    https://api.github.com/repos/Autorama/autorama-app-config/contents/env/$APP/.env.$ENVFILE?ref=master \
     > .tmp_curl