#!/bin/bash
#
# Checks whether local source matches the latest CI image for a service.
#
# Queries ACR for the most-recently-pushed image, extracts its git commit hash
# from the image tag, then runs git-diff to confirm no committed or uncommitted
# changes exist in the watched directories since that commit.
#
# Exits 0 (unchanged) when all three hold:
#   1. Latest image tag is a resolvable git commit in the local history.
#   2. git diff <ci-commit> HEAD -- <watch-dirs> is empty.
#   3. git diff HEAD -- <watch-dirs> is empty.
# Exits 1 otherwise (caller should build the service).
#
# Usage: check-service-unchanged.sh <acr-name> <repository> <watch-dir> [<watch-dir> ...]

set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <acr-name> <repository> <watch-dir> [<watch-dir> ...]" >&2
    exit 1
fi

ACR_NAME=$1
REPOSITORY=$2
shift 2
# Remaining positional args are watch directories.

# Query ACR for the first tag of the latest image.
# CI builds tag images with the short git commit hash (7 chars).
CI_TAG=$(az acr manifest list-metadata \
    --registry "${ACR_NAME}" \
    --name "${REPOSITORY}" \
    --orderby time_desc --top 1 \
    --query '[0].tags[0]' -o tsv 2>/dev/null) || {
    echo "check-service-unchanged: ACR query failed for ${REPOSITORY} in ${ACR_NAME}" >&2
    exit 1
}

if [[ -z "${CI_TAG}" || "${CI_TAG}" == "None" ]]; then
    echo "check-service-unchanged: no tagged image found for ${REPOSITORY}" >&2
    exit 1
fi

# Verify the tag resolves to a known commit in the local git history.
# git rev-parse --verify handles abbreviated hashes; git cat-file -e does not.
if ! git rev-parse --verify "${CI_TAG}^{commit}" > /dev/null 2>&1; then
    echo "check-service-unchanged: CI tag '${CI_TAG}' not in local git history (run: git fetch)" >&2
    exit 1
fi

# Fail if there are committed changes in these dirs since the CI commit.
if [[ -n "$(git diff "${CI_TAG}" HEAD -- "$@")" ]]; then
    exit 1
fi

# Fail if there are uncommitted changes in these dirs.
if [[ -n "$(git diff HEAD -- "$@")" ]]; then
    exit 1
fi

exit 0
