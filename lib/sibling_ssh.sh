#!/usr/bin/env bash
# lib/sibling_ssh.sh — per-sibling SSH identity helpers for drydock RW links
#
# Provides: URL parse/rewrite/restore helpers, deploy-key generation wrapper,
# and basename collision check for RW siblings.
#
# Sourced by bin/drydock after lib/paths.sh and lib/compose.sh.
# Requires: sanitize_project_name (lib/compose.sh), _sibling_deploy_key_path,
#           _managed_ssh_config_path (lib/paths.sh), err, warn (lib/common.sh).

# ── URL helpers ───────────────────────────────────────────────────────────────

# _validate_sibling_remote_url(sibling_path, host_alias[, remote_name])
#
# Read-only validation of the sibling's remote URL — DOES NOT MUTATE.
#
# Returns 0 when the URL is acceptable for rewriting:
#   - canonical form `git@github.com:owner/repo[.git]`, OR
#   - already aliased to the SAME alias (idempotent re-link, D11).
# err()s when the URL is unacceptable:
#   - aliased to a DIFFERENT alias (unexpected conflict — D5 hazard),
#   - HTTPS / non-GitHub / malformed (SR-10).
#
# Exists so cmd_link --rw can validate FIRST and only mutate the sibling
# .git/config in the final step, eliminating the partial-link hazard where a
# mid-flow failure (key-gen, SSH config regen) would leave the sibling
# pointing at an alias whose key + Host block do not yet exist.
#
# host_alias is named to avoid shadowing the Bash builtin `alias` — see
# judgment-day Round 1 (Judge B SUGGESTION).
_validate_sibling_remote_url() {
	local sibling="$1"
	local host_alias="$2"
	local remote_name="${3:-origin}"

	local current
	current="$(git -C "$sibling" remote get-url "$remote_name" 2>/dev/null)" ||
		err "sibling has no '$remote_name' remote — cannot rewrite URL"

	local canonical_re='^git@github\.com:([^/]+)/([^/]+?)(\.git)?$'
	local aliased_re='^git@github\.com-([^:]+):([^/]+)/([^/]+?)(\.git)?$'

	if [[ "$current" =~ $aliased_re ]]; then
		local cur_alias="${BASH_REMATCH[1]}"
		if [ "$cur_alias" = "$host_alias" ]; then
			return 0
		fi
		err "sibling URL is aliased to '$cur_alias' but expected '$host_alias' — manual cleanup required: git -C '$sibling' remote set-url $remote_name git@github.com:<owner>/<repo>.git"
	fi

	if [[ ! "$current" =~ $canonical_re ]]; then
		err "sibling remote.$remote_name.url='$current' — only canonical 'git@github.com:owner/repo[.git]' SSH URLs supported (HTTPS / non-GitHub remotes are out of scope)"
	fi
	return 0
}

# _rewrite_sibling_remote_url(sibling_path, host_alias[, remote_name])
#
# Rewrite sibling's remote.<name>.url from canonical github SSH form to the
# aliased form: git@github.com-<alias>:owner/repo[.git]
#
# Canonical form: git@github.com:owner/repo[.git]
# Aliased form:   git@github.com-<alias>:owner/repo[.git]
#
# Rejects: HTTPS URLs, non-GitHub hosts, malformed URLs (SR-10).
# Idempotent: if already aliased to the same alias, returns 0.
# Errors: if aliased to a DIFFERENT alias (unexpected conflict).
#
# Validation is shared with _validate_sibling_remote_url — kept here too so
# direct callers (tests, future code paths) still get the same guarantees.
#
# host_alias is named to avoid shadowing the Bash builtin `alias` — see
# judgment-day Round 1 (Judge B SUGGESTION).
_rewrite_sibling_remote_url() {
	local sibling="$1"
	local host_alias="$2"
	local remote_name="${3:-origin}"

	local current
	current="$(git -C "$sibling" remote get-url "$remote_name" 2>/dev/null)" ||
		err "sibling has no '$remote_name' remote — cannot rewrite URL"

	# Canonical form: git@github.com:owner/repo[.git]
	local canonical_re='^git@github\.com:([^/]+)/([^/]+?)(\.git)?$'
	# Aliased form:   git@github.com-<alias>:owner/repo[.git]
	local aliased_re='^git@github\.com-([^:]+):([^/]+)/([^/]+?)(\.git)?$'

	if [[ "$current" =~ $aliased_re ]]; then
		local cur_alias="${BASH_REMATCH[1]}"
		if [ "$cur_alias" = "$host_alias" ]; then
			# Already aliased to the same alias — idempotent (D11).
			return 0
		fi
		err "sibling URL is aliased to '$cur_alias' but expected '$host_alias' — manual cleanup required: git -C '$sibling' remote set-url $remote_name git@github.com:<owner>/<repo>.git"
	fi

	if [[ ! "$current" =~ $canonical_re ]]; then
		err "sibling remote.$remote_name.url='$current' — only canonical 'git@github.com:owner/repo[.git]' SSH URLs supported (HTTPS / non-GitHub remotes are out of scope)"
	fi

	local owner="${BASH_REMATCH[1]}"
	local repo="${BASH_REMATCH[2]}"
	local dotgit="${BASH_REMATCH[3]:-}"
	local new_url="git@github.com-${host_alias}:${owner}/${repo}${dotgit}"

	git -C "$sibling" remote set-url "$remote_name" "$new_url" ||
		err "git remote set-url failed in $sibling"
}

# _restore_canonical_remote_url(sibling_path, expected_alias[, remote_name])
#
# Symmetric to _rewrite_sibling_remote_url. Restores remote.<name>.url from
# the aliased form back to canonical git@github.com:owner/repo[.git].
#
# No-op when:
#   - sibling .git/ is absent
#   - URL is already canonical (not aliased)
#   - URL is aliased to a DIFFERENT alias (warns + returns 0)
_restore_canonical_remote_url() {
	local sibling="$1"
	local expected_alias="$2"
	local remote_name="${3:-origin}"

	[ -d "${sibling}/.git" ] || return 0

	local current
	current="$(git -C "$sibling" remote get-url "$remote_name" 2>/dev/null)" || return 0

	local aliased_re='^git@github\.com-([^:]+):([^/]+)/([^/]+?)(\.git)?$'
	if [[ ! "$current" =~ $aliased_re ]]; then
		# Not aliased — nothing to restore (already canonical or HTTPS or
		# whatever the user changed it to manually). Symmetric no-op.
		return 0
	fi

	local cur_alias="${BASH_REMATCH[1]}"
	if [ "$cur_alias" != "$expected_alias" ]; then
		# URL aliased by a different drydock link or by hand — leave alone.
		warn "sibling URL aliased to '$cur_alias' (expected '$expected_alias') — not restoring; manual cleanup may be needed"
		return 0
	fi

	local owner="${BASH_REMATCH[2]}"
	local repo="${BASH_REMATCH[3]}"
	local dotgit="${BASH_REMATCH[4]:-}"
	local new_url="git@github.com:${owner}/${repo}${dotgit}"

	git -C "$sibling" remote set-url "$remote_name" "$new_url" ||
		warn "git remote set-url failed in $sibling — leaving URL aliased"
}

# ── Key generation ────────────────────────────────────────────────────────────

# _generate_sibling_deploy_key(sibling_basename)
#
# Idempotent: returns the key path; reuses an existing key. Caller checks
# collision separately (D5 — different sibling, same basename).
#
# Output (stdout): the private key path.
_generate_sibling_deploy_key() {
	local sibling_basename="$1"
	local key_path
	key_path="$(_sibling_deploy_key_path "$sibling_basename")"

	if [ -f "$key_path" ]; then
		# Idempotent reuse (D11). Pub may not exist if user deleted it.
		if [ ! -f "${key_path}.pub" ]; then
			warn "private key exists but .pub is missing — regenerating .pub from private key"
			ssh-keygen -y -f "$key_path" >"${key_path}.pub" ||
				err "failed to derive pubkey from $key_path"
			chmod 644 "${key_path}.pub"
		fi
		printf '%s' "$key_path"
		return 0
	fi

	mkdir -p "$(dirname "$key_path")"
	chmod 700 "$(dirname "$key_path")"
	# No passphrase: container has no agent and key is bind-mounted ro
	# under a deny-ruled path. Empty passphrase is the documented
	# primary-key precedent (docker-compose.ssh.yml header).
	ssh-keygen -t ed25519 -f "$key_path" -N "" -C "drydock-${sibling_basename}" \
		>/dev/null 2>&1 || err "ssh-keygen failed for $sibling_basename"
	chmod 600 "$key_path"
	chmod 644 "${key_path}.pub"
	printf '%s' "$key_path"
}

# ── Collision check ───────────────────────────────────────────────────────────

# _check_sibling_basename_collision_rw(canonical, sanitized, list_file)
#
# Defense-in-depth check: if a key file exists at the sibling deploy key path
# and the .list already has an RW entry with the same sanitized basename but a
# DIFFERENT canonical host path, reject with an actionable error.
#
# The layer-1 basename collision check in cmd_link already fires before this;
# this is the RW-specific guard ensuring key ownership is unambiguous.
_check_sibling_basename_collision_rw() {
	local canonical="$1"
	local sanitized="$2"
	local list_file="$3"

	local key_path
	key_path="$(_sibling_deploy_key_path "$sanitized")"

	# No existing key → no collision possible.
	[ -f "$key_path" ] || return 0

	# JD1-X: scan ALL projects' .list files under the links directory, not just
	# the passed list_file. The deploy key path is global; a key created for
	# ~/groupA/lib (project A) conflicts with a new ~/groupB/lib link (project B)
	# even though project B's .list has no entry for that basename.
	local links_dir
	links_dir="$(dirname "$list_file")"
	[ -d "$links_dir" ] || return 0

	local other_list _h _t _f
	for other_list in "$links_dir"/*.list; do
		[ -f "$other_list" ] || continue
		# shellcheck disable=SC2094  # false positive: $other_list is the for-variable, not read+written in same pipeline
		while IFS='|' read -r _h _t _f; do
			[ -z "$_h" ] && continue
			[ "${_f:-}" = "rw" ] || continue
			local _existing_sanitized
			_existing_sanitized="$(sanitize_project_name "$(basename "$_h")")"
			if [ "$_existing_sanitized" = "$sanitized" ] && [ "$_h" != "$canonical" ]; then
				local _other_project
				_other_project="$(basename "$other_list" .list)"
				err "key collision: '$key_path' is already owned by RW sibling '$_h' (project '$_other_project'); cannot also link '$canonical' (same sanitized basename '$sanitized')"
			fi
		done <"$other_list"
	done
	return 0
}
