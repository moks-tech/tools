#!/usr/bin/env bash
# Create the GitHub Actions secrets and variables the moks-tech repositories need, at organization level where GitHub
# allows it. Dry run by default: it prints the plan (names, targets, where each value comes from, never a value).
#
#   scripts/setup-github-org.sh                       # plan only
#   scripts/setup-github-org.sh --apply               # set everything required
#   scripts/setup-github-org.sh --apply --optional    # also the optional ones (Argo CD, Cloudflare Access, …)
#   scripts/setup-github-org.sh --apply --only MK4_CI_TOKEN,MK4_CI_APPLY_TOKEN
#   scripts/setup-github-org.sh --apply --remove-repo-copies   # then delete the per-repository duplicates
#
# Where a value comes from, first match wins:
#   1. an environment variable of the same name (HARBOR_PASSWORD=… scripts/setup-github-org.sh --apply)
#   2. MK4_API_SERVER, MK4_CA_DATA: copied from the variables an existing repository already has (gh variable get)
#   3. MK4_CI_TOKEN, MK4_CI_APPLY_TOKEN: read from the cluster, Secrets jithendar/github-ci-deployer-token and
#      jithendar/github-ci-applier-token (kubectl, context KUBE_CONTEXT if set, else the current one after you confirm)
#   4. a hidden prompt (nothing is echoed or logged)
#
# Where it is stored: once, in the organization (Settings → Secrets and variables → Actions), shared with the
# repositories that use it (visibility "selected"). That is the single place to change a value.
#
# Two GitHub rules shape the rest:
# - A repository secret or variable wins over an organization one of the same name. --remove-repo-copies deletes
#   those duplicates, so the organization value is the one used.
# - On GitHub Free, private repositories cannot read organization secrets or variables (docs.github.com: "Using
#   secrets in GitHub Actions"). While the plan is Free, the private repositories that use a value (jithendar.com,
#   moks-cms, practice-programming, ansible) also keep a repository copy, which --remove-repo-copies never deletes.
#   After an upgrade to GitHub Team, run --apply --remove-repo-copies again: everything is then in one place.
#
# Needs: gh signed in as an owner of the organization with the admin:org scope (gh auth refresh -h github.com -s admin:org),
# jq, and kubectl for the two cluster tokens. Run it from any directory.
set -euo pipefail

ORG="${ORG:-moks-tech}"
APPLY=0 OPTIONAL=0 PRUNE=0 ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --optional) OPTIONAL=1 ;;
    --remove-repo-copies) PRUNE=1 ;;
    --only) ONLY=",${2:?--only needs a comma-separated list},"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# name | kind (secret/var) | required/optional | repositories | how to get the value
# Repositories are the moks-tech ones whose workflows read the name (checked 2026-11-16). moks-sre and roboshop-ai
# stay under mrjithendar and keep their own repository secrets.
# read -d '': a heredoc inside $(…) with an apostrophe in it trips macOS's bash 3.2.
read -r -d '' CATALOG <<'EOF' || true
HARBOR_USERNAME|secret|required|jithendar.com moks-cms practice-programming aws-vpc ansible kubernetes tools|Harbor robot robot$jithendar+jithendar-com (kubernetes repo: deploy/minikube/harbor/registry.py ci-robots)
HARBOR_PASSWORD|secret|required|jithendar.com moks-cms practice-programming aws-vpc ansible kubernetes tools|that robot's secret
MK4_CI_TOKEN|secret|required|jithendar.com practice-programming|cluster: jithendar/github-ci-deployer-token
MK4_CI_APPLY_TOKEN|secret|required|jithendar.com practice-programming|cluster: jithendar/github-ci-applier-token
MK4_API_SERVER|var|required|jithendar.com practice-programming kubernetes tools|copied from an existing repository variable
MK4_CA_DATA|var|required|jithendar.com practice-programming kubernetes tools|copied from an existing repository variable
MINIKUBE_DEPLOY|var|required|jithendar.com|true: deploy-kubernetes.yml applies manifests
PRACTICE_EXECUTOR_DEPLOY|var|required|practice-programming|true: practice CI deploys the executor
RELEASE_NOTIFY_REPOS|var|required|moks-cms|moks-tech/jithendar.com (site repositories told about moks-cms releases)
RELEASE_NOTIFY_TOKEN|secret|required|moks-cms|fine-grained token, owner moks-tech, repository jithendar.com, Contents: read and write
DOCKER_USERNAME|secret|required|kubernetes|Docker Hub user (pulls without rate limits)
DOCKER_PASSWORD|secret|required|kubernetes|Docker Hub access token
AWS_ROLE_ARN|secret|optional|aws-vpc ansible kubernetes tools|arn of the GitHub OIDC role (tools/infrastructure/github-oidc-role.tf)
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
echo "Organization $ORG, plan $plan_name: every value in the organization$( ((free)) && echo "; private repositories also keep a copy until the plan is Team or higher")"
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

has_repo_value() { # <kind> <repo> <name>
  local cmd=secret; [[ "$1" == var ]] && cmd=variable
  gh "$cmd" list -R "$ORG/$2" --json name --jq '.[].name' 2>/dev/null | grep -qx "$3"
}
has_org_value() { # <kind> <name>
  local path=secrets; [[ "$1" == var ]] && path=variables
  gh api "orgs/$ORG/actions/$path/$2" >/dev/null 2>&1
}
set_org() { # <kind> <name> <value> <repos…>
  local kind="$1" name="$2" value="$3" cmd=secret; shift 3; [[ "$kind" == var ]] && cmd=variable
  printf '%s' "$value" | gh "$cmd" set "$name" --org "$ORG" --visibility selected --repos "$(IFS=,; echo "$*")" >/dev/null
}
set_repo() { # <kind> <name> <value> <repo>
  local cmd=secret; [[ "$1" == var ]] && cmd=variable
  printf '%s' "$3" | gh "$cmd" set "$2" -R "$ORG/$4" >/dev/null
}
delete_repo() { # <kind> <name> <repo>
  local cmd=secret; [[ "$1" == var ]] && cmd=variable
  gh "$cmd" delete "$2" -R "$ORG/$3" >/dev/null
}

status=0
while IFS='|' read -r name kind need repos how; do
  [[ -n "$name" ]] || continue
  [[ -z "$ONLY" || "$ONLY" == *",$name,"* ]] || continue
  [[ "$need" == required || $OPTIONAL -eq 1 || -n "$ONLY" ]] || { echo "  skip  $name (optional; --optional to set it)"; continue; }
  targets=() need_copy=() drop=() keep=()
  for r in $repos; do
    vis="$(visibility_of "$r")"
    [[ -n "$vis" ]] || { echo "  warn  $name: repository $ORG/$r not found" >&2; continue; }
    targets+=("$r")
    reads_org=1; (( free )) && [[ "$vis" == private ]] && reads_org=0
    if has_repo_value "$kind" "$r" "$name"; then
      if (( reads_org )); then drop+=("$r"); else keep+=("$r"); fi
    elif (( ! reads_org )); then
      need_copy+=("$r")
    fi
  done
  ((${#targets[@]})) || continue
  in_org=0; has_org_value "$kind" "$name" && in_org=1
  line="$name ($kind, $need) org → ${targets[*]}"
  (( in_org )) && line+=" [exists]"
  ((${#need_copy[@]})) && line+="; private copy (Free plan) → ${need_copy[*]}"
  ((${#keep[@]})) && line+="; private copy kept: ${keep[*]}"
  ((${#drop[@]})) && line+="; duplicate in: ${drop[*]}$( ((PRUNE)) && echo " (removed)" || echo " (--remove-repo-copies)")"
  if (( ! APPLY )); then echo "  plan  $line  value: $how"; continue; fi
  # The value is asked for once; an organization value that exists is replaced only when it is given again.
  if (( ! in_org || ${#need_copy[@]} )) || [[ -n "${!name:-}" ]]; then
    if ! value="$(value_for "$name" "$kind" "$how")" || [[ -z "$value" ]]; then
      echo "  FAIL  $name: no value" >&2; status=1; continue
    fi
    set_org "$kind" "$name" "$value" "${targets[@]}"
    for r in ${need_copy[@]+"${need_copy[@]}"}; do set_repo "$kind" "$name" "$value" "$r"; done
    unset value
  else
    # Only the list of repositories that may read it is refreshed: re-set the visibility without a new value.
    gh api -X PUT "orgs/$ORG/actions/$( [[ "$kind" == var ]] && echo variables || echo secrets )/$name/repositories" \
      --input <(jq -n --argjson ids "$(for r in "${targets[@]}"; do gh api "repos/$ORG/$r" --jq .id; done | jq -s .)" '{selected_repository_ids: $ids}') >/dev/null
  fi
  if (( PRUNE )); then for r in ${drop[@]+"${drop[@]}"}; do delete_repo "$kind" "$name" "$r"; done; fi
  echo "  set   $line"
done <<<"$CATALOG"

(( APPLY )) || echo "Dry run: nothing was changed. Run again with --apply."
exit "$status"
