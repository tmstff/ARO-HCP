#!/bin/bash
#
# For each in-repo service, determines whether local source code differs from
# the latest CI image and either reuses the CI image or builds a new one.
#
# "Unchanged" means: the latest CI image's git commit tag is in the local
# history AND git-diff shows no committed or uncommitted changes in the
# service's source directories since that commit.  Any doubt → build.
#
# Requires IMAGE_TAG and ARO_HCP_REVISION in the environment when at least one
# service needs to be built (personal-dev-env exports them before calling here).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# handle_service <svc> <make-dir> <repo-make-var> <watch-dirs (space-sep, quoted)>
#
# Calls check-service-unchanged.sh to decide, then either record-latest-override
# (CI image) or build-and-push + record-override (new image).
handle_service() {
    local svc=$1 make_dir=$2 repo_var=$3 watch_dirs=$4
    local override_file="/tmp/_${svc}-override.yaml"
    local abs_make_dir="${REPO_ROOT}/${make_dir}"

    # Resolve the ACR name and image repository from the service's make context.
    # These come from the templatize-generated env file; subsequent calls are
    # instant because the env file is cached at /tmp/env.*.mk.
    local acr repo
    acr=$(make -C "${abs_make_dir}" -s "print-ARO_HCP_IMAGE_ACR" 2>/dev/null)
    repo=$(make -C "${abs_make_dir}" -s "print-${repo_var}" 2>/dev/null)

    # shellcheck disable=SC2086
    if "${SCRIPT_DIR}/check-service-unchanged.sh" "${acr}" "${repo}" ${watch_dirs}; then
        echo "==> ${svc}: unchanged — using CI image"
        make -C "${abs_make_dir}" record-latest-override OVERRIDE_CONFIG_FILE="${override_file}"
    else
        echo "==> ${svc}: changed — building and pushing"
        make -C "${abs_make_dir}" build-and-push record-override OVERRIDE_CONFIG_FILE="${override_file}"
    fi
}

pids=()

# Each line: handle_service <name> <make-dir> <repo-make-var> <watch-dirs>
# watch-dirs includes "internal" because it is a shared library used by all services.
handle_service frontend         frontend                 FRONTEND_IMAGE_REPOSITORY       "frontend internal"               & pids+=($!)
handle_service backend          backend                  BACKEND_IMAGE_REPOSITORY        "backend internal"                & pids+=($!)
handle_service admin            admin                    ADMIN_API_IMAGE_REPOSITORY      "admin internal"                  & pids+=($!)
handle_service sessiongate      sessiongate              SESSION_GATE_IMAGE_REPOSITORY   "sessiongate internal"            & pids+=($!)
handle_service mgmt-agent       mgmt-agent               MGMT_AGENT_IMAGE_REPOSITORY     "mgmt-agent internal"             & pids+=($!)
handle_service kube-applier     kube-applier             KUBE_APPLIER_IMAGE_REPOSITORY   "kube-applier internal"           & pids+=($!)
handle_service fleet            fleet                    FLEET_IMAGE_REPOSITORY          "fleet internal"                  & pids+=($!)
handle_service aro-hcp-exporter tooling/aro-hcp-exporter ARO_HCP_EXPORTER_IMAGE_REPOSITORY "tooling/aro-hcp-exporter internal" & pids+=($!)

failed=0
for pid in "${pids[@]}"; do
    wait "${pid}" || failed=1
done

if [[ "${failed}" -ne 0 ]]; then
    echo "ERROR: one or more service build/override steps failed" >&2
    exit 1
fi
