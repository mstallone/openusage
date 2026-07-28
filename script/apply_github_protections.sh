#!/usr/bin/env bash
set -euo pipefail

# Applies the branch/tag protections this repo uses on GitHub. GitHub gates these features on private repos
# (free plan), so run this once after the repo goes public:
#
#   ./script/apply_github_protections.sh
#
# Requires: gh CLI authenticated as a repo admin.

REPO="${REPO:-mstallone/openusage}"

# No visibility pre-check: a private repo on a paid plan supports these
# settings, so let GitHub be the judge and surface its error if not.
echo "==> Branch protection on main (required CI check, 2 approvals, code owners, conversation resolution; admins exempt)"
BRANCH_PROTECTION='{
  "required_status_checks": {"strict": true, "contexts": ["Build and Test"]},
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "require_last_push_approval": false,
    "required_approving_review_count": 2
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}'
if ! echo "$BRANCH_PROTECTION" | gh api -X PUT "repos/$REPO/branches/main/protection" --input - >/dev/null; then
  echo "    Could not apply — GitHub's error above says why. The usual cause: these features are"
  echo "    unavailable on private free-plan repos. Make the repo public (or upgrade), then re-run."
  exit 1
fi
echo "    applied."

# Convergent like the branch-protection PUT above: creates the ruleset if
# missing, otherwise overwrites it by id so a re-run reconciles any drift.
apply_ruleset() {
  local name="$1" payload="$2"
  local existing_id
  existing_id="$(gh api "repos/$REPO/rulesets" --jq "[.[] | select(.name==\"$name\") | .id] | first // empty")"
  if [[ -n "$existing_id" ]]; then
    echo "$payload" | gh api -X PUT "repos/$REPO/rulesets/$existing_id" --input - >/dev/null
    echo "    \"$name\" updated to match."
  else
    echo "$payload" | gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null
    echo "    \"$name\" created."
  fi
}

# The bypass actor is the repo-admin role because rulesets have no per-user
# actor type; on a user-owned repo collaborators top out at write, so the
# owner is the only admin and the bypass is owner-only in practice. This
# keeps release tags owner-only.
echo "==> Tag ruleset: only the repo owner can create/update/delete v* release tags"
apply_ruleset "Release tags owner only" '{
  "name": "Release tags owner only",
  "target": "tag",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
  "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}],
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]
}'

echo "==> Branch ruleset: automatic Copilot review on PRs to main"
apply_ruleset "Copilot review for default branch" '{
  "name": "Copilot review for default branch",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "copilot_code_review", "parameters": {"review_on_push": false, "review_draft_pull_requests": false}}],
  "bypass_actors": []
}'

echo "Done."
