#!/usr/bin/env bash
# Create the GitHub Actions secrets and variables the moks-tech repositories need, at organization level where GitHub
# allows it. Dry run by default: it prints the plan (names, targets, where each value comes from, never a value).
#
#   scripts/setup-github-org.sh                       # plan only
#   scripts/setup-github-org.sh --apply               # set everything required
#   scripts/setup-github-org.sh --apply --optional    # also the optional ones (Argo CD, Cloudflare Access, …)
#   scripts/setup-github-org.sh --apply --only MK4_CI_TOKEN,MK4_CI_APPLY_TOKEN
#
# Where a value comes from, first match wins:
#   1. an environment variable of the same name (HARBOR_PASSWORD=… scripts/setup-github-org.sh --apply)
#   2. MK4_API_SERVER, MK4_CA_DATA: copied from the variables an existing repository already has (gh variable get)
#   3. MK4_CI_TOKEN, MK4_CI_APPLY_TOKEN: read from the cluster, Secrets jithendar/github-ci-deployer-token and
#      jithendar/github-ci-applier-token (kubectl, context KUBE_CONTEXT if set, else the current one after you confirm)
#   4. a hidden prompt (nothing is echoed or logged)
#
# Where it is stored: GitHub Free does not give private repositories access to organization secrets or variables
# (docs.github.com: "Using secrets in GitHub Actions"). So on the Free plan a value goes to the organization for the
# public repositories that use it (visibility "selected") and to each private repository on its own. On a paid plan
# everything goes to the organization. Existing repository secrets are left alone unless --force is given: a
# repository secret wins over an organization secret of the same name.
#
# Needs: gh signed in as an owner of the organization with the admin:org scope (gh auth refresh -h github.com -s admin:org),
# jq, and kubectl for the two cluster tokens. Run it from any directory.
set -euo pipefail

ORG="${ORG:-moks-tech}"
APPLY=0 OPTIONAL=0 FORCE=0 ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --optional) OPTIONAL=1 ;;
    --force) FORCE=1 ;;
    --only) ONLY=",${2:?--only needs a comma-separated list},"; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# name | kind (secret/var) | required/optional | repositories | how to get the value
# Repositories are the ones whose workflows read the name (checked 2026-11-16).
# read -d '': a heredoc inside $(…) with an apostrophe in it trips macOS's bash 3.2.
read -r -d '' CATALOG <<'EOF' || true
HARBOR_USERNAME|secret|required|jithendar.com moks-cms practice-programming moks-sre roboshop-ai aws-vpc ansible kubernetes tools|Harbor robot robot$jithendar+jithendar-com (kubernetes repo: deploy/minikube/harbor/registry.py ci-robots)
HARBOR_PASSWORD|secret|required|jithendar.com moks-cms practice-programming moks-sre roboshop-ai aws-vpc ansible kubernetes tools|that robot's secret
MK4_CI_TOKEN|secret|required|jithendar.com practice-programming|cluster: jithendar/github-ci-deployer-token
MK4_CI_APPLY_TOKEN|secret|required|jithendar.com practice-programming|cluster: jithendar/github-ci-applier-token
MK4_API_SERVER|var|required|jithendar.com practice-programming kubernetes tools|copied from an existing repository variable
MK4_CA_DATA|var|required|jithendar.com practice-programming kubernetes tools|copied from an existing repository variable
MINIKUBE_DEPLOY|var|required|jithendar.com|true: deploy-kubernetes.yml applies manifests
PRACTICE_EXECUTOR_DEPLOY|var|required|practice-programming|true: practice CI deploys the executor
RELEASE_NOTIFY_REPOS|var|required|moks-cms|moks-tech/jithendar.com (site repositories told about moks-cms releases)
RELEASE_NOTIFY_TOKEN|secret|required|moks-cms|fine-grained token, owner moks-tech, repository jithendar.com, Contents: read and write
DOCKER_USERNAME|secret|required|kubernetes moks-sre roboshop-ai|Docker Hub user (pulls without rate limits)
DOCKER_PASSWORD|secret|required|kubernetes moks-sre roboshop-ai|Docker Hub access token
AWS_ROLE_ARN|secret|optional|moks-sre roboshop-ai aws-vpc ansible kubernetes tools|arn of the GitHub OIDC role (tools/infrastructure/github-oidc-role.tf)
ARGOCD_AUTH_TOKEN|secret|optional|moks-sre|Argo CD token for project role moks/ci (moks-sre scripts/setup-argocd-ci.sh)
ARGOCD_SERVER|var|optional|moks-sre|Argo CD host
MK4_DEPLOY|var|optional|moks-sre|true: moks-sre CI deploys through Argo CD
CF_ACCESS_CLIENT_ID|secret|optional|moks-sre|Cloudflare Access service token id (Argo CD behind Access)
CF_ACCESS_CLIENT_SECRET|secret|optional|moks-sre|Cloudflare Access service token secret
MINIKUBE_READ_TOKEN|secret|optional|roboshop-ai|fine-grained token, read access to moks-tech/kubernetes
MK4_TERRAFORM_TOKEN|secret|optional|kubernetes|token for the Terraform runs on mk4
DOCKERHUB_USERNAME|secret|optional|kubernetes tools|Docker Hub user (older workflows)
DOCKERHUB_TOKEN|secret|optional|kubernetes tools|Docker Hub token (older workflows)
EOF

for tool in gh jq; do command -v "$tool" >/dev/null || { echo "needs $tool" >&2; exit 1; }; done
gh api "orgs/$ORG" >/dev/null || { echo "organization $ORG not found, or gh is not signed in" >&2; exit 1; }
plan_name="$(gh api "orgs/$ORG" --jq '.plan.name // "unknown"')"
free=0; [[ "$plan_name" == free ]] && free=1
# "name visibility" per line (no associative arrays: macOS ships bash 3.2).
REPO_VIS="$(gh repo list "$ORG" --limit 200 --json name,visibility --jq '.[] | "\(.name) \(.visibility | ascii_downcase)"')"
visibility_of() { awk -v r="$1" '$1 == r { print $2 }' <<<"$REPO_VIS"; }
echo "Organization $ORG, plan $plan_name: $( ((free)) && echo "private repositories get their own copies" || echo "everything at organization level")"
((APPLY)) && { gh api "orgs/$ORG/actions/secrets/public-key" >/dev/null 2>&1 || { echo "gh lacks the admin:org scope: gh auth refresh -h github.com -s admin:org" >&2; exit 1; }; }

# --- cluster tokens ---------------------------------------------------------------------------------------------------
KCTX=""
cluster_token() { # <secret name> → token on stdout
  if [[ -z "$KCTX" ]]; then
    command -v kubectl >/dev/null || { echo "kubectl not found: set MK4_CI_TOKEN / MK4_CI_APPLY_TOKEN in the environment" >&2; return 1; }
    KCTX="${KUBE_CONTEXT:-$(kubectl config current-context)}"
    kubectl config get-contexts "$KCTX" >/dev/null 2>&1 || { echo "kube context $KCTX does not exist" >&2; return 1; }
    if [[ -z "${KUBE_CONTEXT:-}" ]]; then
      read -r -p "Read the CI tokens from kube context '$KCTX' ($(kubectl config view -o jsonpath="{.clusters[?(@.name==\"$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$KCTX\")].context.cluster}")\")].cluster.server}"))? [y/N] " ok </dev/tty
      [[ "$ok" == y || "$ok" == Y ]] || return 1
    fi
  fi
  kubectl --context "$KCTX" -n jithendar get secret "$1" -o jsonpath='{.data.token}' | base64 -d
}

existing_var() { # <name> → the value of that variable in the first repository that has it
  local r
  for r in moks-cms jithendar.com kubernetes tools; do
    gh variable get "$1" -R "$ORG/$r" 2>/dev/null && return 0
  done
  return 1
}

value_for() { # <name> <kind> <how> → value on stdout
  local name="$1" kind="$2" how="$3" v=""
  if [[ -n "${!name:-}" ]]; then printf '%s' "${!name}"; return; fi
  case "$name" in
    MK4_API_SERVER|MK4_CA_DATA) existing_var "$name" && return ;;
    MK4_CI_TOKEN) cluster_token github-ci-deployer-token && return ;;
    MK4_CI_APPLY_TOKEN) cluster_token github-ci-applier-token && return ;;
    MINIKUBE_DEPLOY|PRACTICE_EXECUTOR_DEPLOY) printf true; return ;;
    RELEASE_NOTIFY_REPOS) printf '%s' "$ORG/jithendar.com"; return ;;
  esac
  if [[ "$kind" == secret ]]; then read -r -s -p "$name ($how): " v </dev/tty; echo >&2
  else read -r -p "$name ($how): " v </dev/tty; fi
  printf '%s' "$v"
}

has_repo_secret() { gh secret list -R "$ORG/$1" --json name --jq '.[].name' 2>/dev/null | grep -qx "$2"; }
has_repo_var() { gh variable list -R "$ORG/$1" --json name --jq '.[].name' 2>/dev/null | grep -qx "$2"; }

set_value() { # <kind> <name> <value> <org|repo> <targets…>
  local kind="$1" name="$2" value="$3" where="$4"; shift 4
  local cmd=(secret); [[ "$kind" == var ]] && cmd=(variable)
  if [[ "$where" == org ]]; then
    printf '%s' "$value" | gh "${cmd[@]}" set "$name" --org "$ORG" --visibility selected --repos "$(IFS=,; echo "$*")" >/dev/null
  else
    local r; for r in "$@"; do printf '%s' "$value" | gh "${cmd[@]}" set "$name" -R "$ORG/$r" >/dev/null; done
  fi
}

status=0
while IFS='|' read -r name kind need repos how; do
  [[ -z "$ONLY" || "$ONLY" == *",$name,"* ]] || continue
  [[ "$need" == required || $OPTIONAL -eq 1 || -n "$ONLY" ]] || { echo "  skip  $name (optional; --optional to set it)"; continue; }
  org_targets=() repo_targets=() kept=()
  for r in $repos; do
    vis="$(visibility_of "$r")"
    [[ -n "$vis" ]] || { echo "  warn  $name: repository $ORG/$r not found" >&2; continue; }
    if [[ $FORCE -eq 0 ]] && { { [[ "$kind" == secret ]] && has_repo_secret "$r" "$name"; } || { [[ "$kind" == var ]] && has_repo_var "$r" "$name"; }; }; then
      kept+=("$r"); continue
    fi
    if (( free )) && [[ "$vis" == private ]]; then repo_targets+=("$r"); else org_targets+=("$r"); fi
  done
  line="$name ($kind, $need)"
  ((${#org_targets[@]})) && line+=" org→ ${org_targets[*]};"
  ((${#repo_targets[@]})) && line+=" repo→ ${repo_targets[*]};"
  ((${#kept[@]})) && line+=" already set in: ${kept[*]};"
  if (( ${#org_targets[@]} + ${#repo_targets[@]} == 0 )); then echo "  ok    $line"; continue; fi
  if (( ! APPLY )); then echo "  plan  $line  value: $how"; continue; fi
  if ! value="$(value_for "$name" "$kind" "$how")" || [[ -z "$value" ]]; then
    echo "  FAIL  $name: no value" >&2; status=1; continue
  fi
  ((${#org_targets[@]})) && set_value "$kind" "$name" "$value" org "${org_targets[@]}"
  ((${#repo_targets[@]})) && set_value "$kind" "$name" "$value" repo "${repo_targets[@]}"
  unset value
  echo "  set   $line"
done <<<"$CATALOG"

(( APPLY )) || echo "Dry run: nothing was changed. Run again with --apply."
exit "$status"
