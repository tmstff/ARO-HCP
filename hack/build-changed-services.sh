#!/bin/bash
#
# For each in-repo service, decides in order:
#
#   1. Locally-built image already in ACR (tag = IMAGE_TAG)?
#      → record-override: use it, no build needed.
#
#   2. Latest CI image matches local source?
#      Queries ACR for the most-recently-pushed CI image, extracts its git
#      commit tag, and verifies no committed or uncommitted changes exist in
#      the service's watch-dirs since that commit.
#      → record-latest-override: use the CI image, no build needed.
#      Note: step 2 handles the "branch behind main" case — even if the branch
#      diverges from the CI commit, step 1 would already have found a
#      previously-built local image.
#
#   3. Neither found → build-and-push + record-override.
#
# Requires IMAGE_TAG and ARO_HCP_REVISION in the environment (personal-dev-env-quick
# exports them before calling here).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# handle_service <svc> <make-dir> <repo-make-var> <gen-repo-make-var> <watch-dirs>
#
#   repo-make-var     — make variable holding the base CI image repository name
#   gen-repo-make-var — make variable holding the user-specific repo name
#                       (test-<user>-<base> for DEPLOY_ENV=pers/swft)
#   watch-dirs        — space-separated dirs to check for source changes (step 2)
handle_service() {
    local svc=$1 make_dir=$2 repo_var=$3 gen_repo_var=$4 watch_dirs=$5
    local override_file="/tmp/_${svc}-override.yaml"
    local abs_make_dir="${REPO_ROOT}/${make_dir}"

    # Resolve ACR name, base CI repo, and user-specific repo from the service's
    # make context.  Three separate calls are used because read only consumes one
    # line; the env file is cached at /tmp/env.*.mk so subsequent calls are fast.
    local acr repo gen_repo
    acr=$(make -C "${abs_make_dir}" -s "print-ARO_HCP_IMAGE_ACR" 2>/dev/null)
    repo=$(make -C "${abs_make_dir}" -s "print-${repo_var}" 2>/dev/null)
    gen_repo=$(make -C "${abs_make_dir}" -s "print-${gen_repo_var}" 2>/dev/null)

    if [[ -z "${acr}" || -z "${repo}" || -z "${gen_repo}" ]]; then
        echo "==> ${svc}: ERROR: empty make variable (acr='${acr}' repo='${repo}' gen_repo='${gen_repo}')" >&2
        exit 1
    fi

    # Step 1: previously-built local image in ACR?
    # IMAGE_TAG encodes the exact git state (commit + dirty flag), so a match
    # means this exact source was already built and pushed.
    if az acr repository show \
            --name "${acr}" \
            --image "${gen_repo}:${IMAGE_TAG}" \
            > /dev/null 2>&1; then
        echo "==> ${svc}: locally-built image found in ACR (tag: ${IMAGE_TAG})"
        make -C "${abs_make_dir}" record-override OVERRIDE_CONFIG_FILE="${override_file}"
        return
    fi

    # Step 2: CI image matches local source?
    # shellcheck disable=SC2086
    if "${SCRIPT_DIR}/check-service-unchanged.sh" "${acr}" "${repo}" ${watch_dirs}; then
        echo "==> ${svc}: unchanged — using CI image"
        make -C "${abs_make_dir}" record-latest-override OVERRIDE_CONFIG_FILE="${override_file}"
        return
    fi

    # Step 3: build and push.
    echo "==> ${svc}: changed — building and pushing"
    make -C "${abs_make_dir}" build-and-push record-override OVERRIDE_CONFIG_FILE="${override_file}"
}

pids=()

# Args: <name> <make-dir> <repo-var> <gen-repo-var> <watch-dirs>
handle_service frontend         frontend                 FRONTEND_IMAGE_REPOSITORY         FRONTEND_GENERATED_IMAGE_REPOSITORY         "frontend internal"                   & pids+=($!)
handle_service backend          backend                  BACKEND_IMAGE_REPOSITORY          BACKEND_GENERATED_IMAGE_REPOSITORY          "backend internal"                    & pids+=($!)
handle_service admin            admin                    ADMIN_API_IMAGE_REPOSITORY        ADMIN_API_GENERATED_IMAGE_REPOSITORY        "admin internal"                      & pids+=($!)
handle_service sessiongate      sessiongate              SESSION_GATE_IMAGE_REPOSITORY     SESSION_GATE_GENERATED_IMAGE_REPOSITORY     "sessiongate internal"                & pids+=($!)
handle_service mgmt-agent       mgmt-agent               MGMT_AGENT_IMAGE_REPOSITORY       MGMT_AGENT_GENERATED_IMAGE_REPOSITORY       "mgmt-agent internal"                 & pids+=($!)
handle_service kube-applier     kube-applier             KUBE_APPLIER_IMAGE_REPOSITORY     KUBE_APPLIER_GENERATED_IMAGE_REPOSITORY     "kube-applier internal"               & pids+=($!)
handle_service fleet            fleet                    FLEET_IMAGE_REPOSITORY            FLEET_GENERATED_IMAGE_REPOSITORY            "fleet internal"                      & pids+=($!)
handle_service aro-hcp-exporter tooling/aro-hcp-exporter ARO_HCP_EXPORTER_IMAGE_REPOSITORY ARO_HCP_EXPORTER_GENERATED_IMAGE_REPOSITORY "tooling/aro-hcp-exporter internal"   & pids+=($!)

failed=0
for pid in "${pids[@]}"; do
    wait "${pid}" || failed=1
done

if [[ "${failed}" -ne 0 ]]; then
    echo "ERROR: one or more service build/override steps failed" >&2
    exit 1
fi
