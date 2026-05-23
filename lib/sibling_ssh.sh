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

# _restore_canonical_remote_url(sibling_path, expected_alias[, remote_name])
#
# Restores remote.<name>.url from the legacy v0.2.1 aliased form back to the
# canonical form git@github.com:owner/repo[.git].
#
# History: v0.2.1 mutated the sibling's .git/config to inject an SSH alias
# (e.g. git@github.com-<sibling>:owner/repo.git) so the container's managed
# SSH config could route per-sibling deploy keys. That broke the host's
# `git fetch` because the alias only resolved inside the container.
#
# #89 fix: routing moved to url.insteadOf in a container-only gitconfig so
# the sibling .git/config never has to be touched (INV-1 extended — host
# gitconfig non-contamination). This helper survives as the startup-migration
# entry point (invoked from export_compose_env) AND as the unlink-time safety
# net for any aliased URL that slipped past migration.
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

# ── Per-project gitconfig generation (issue #89) ──────────────────────────────

# _regenerate_session_gitconfig(primary_project, list_file) → config_path
#
# Issue #89: write a per-project gitconfig at ~/.config/drydock/gitconfig-<primary>
# containing:
#   [include]
#     path = ~/.gitconfig                  ← user identity passthrough
#   [url "git@github.com-<alias>:owner/repo[.git]"]
#     insteadOf = git@github.com:owner/repo[.git]   ← one block per RW sibling
#
# The container points GIT_CONFIG_GLOBAL at this file, so git inside the
# container rewrites canonical GitHub URLs to the aliased form on the fly —
# without ever mutating the sibling's .git/config (INV-1).
#
# Behaviour:
#   - Atomic mv + chmod 600 (same pattern as _regenerate_managed_ssh_config).
#   - Insertion order from .list preserved (NO sort).
#   - Sibling with non-canonical URL (HTTPS, non-GitHub, malformed) is SKIPPED
#     with a warn — does NOT abort drydock run. Per-sibling failure must not
#     block the whole startup flow.
#   - Sibling whose .git/ is missing is skipped silently (D10 — link is just a
#     mount in that case, no SSH routing involved).
#   - Always writes the [include] block, even when there are zero RW siblings,
#     so a minimal pass-through gitconfig works as the activation default.
#   - Returns the config path on stdout.
_regenerate_session_gitconfig() {
	local primary="$1"
	local list_file="$2"
	local config_path
	config_path="$(_session_gitconfig_path "$primary")"
	mkdir -p "$(dirname "$config_path")"

	local tmp
	tmp="$(mktemp "${config_path}.XXXXXX")" || err "mktemp failed for managed gitconfig"

	{
		printf '# drydock-managed — regenerated on every drydock run. Do not edit.\n'
		printf '# Source of truth: %s\n' "$list_file"
		printf '# Issue #89: routes per-sibling SSH aliases via url.insteadOf so the\n'
		printf '#           container can use deploy keys without mutating the host\n'
		printf '#           sibling .git/config (INV-1).\n\n'
		# Identity passthrough — user.name, user.email, aliases, signingkey, etc.
		printf '[include]\n'
		printf '\tpath = ~/.gitconfig\n\n'

		if [ -f "$list_file" ]; then
			local _host _target _flags _name _current _owner _repo _dotgit
			local _canonical_re='^git@github\.com:([^/]+)/([^/]+?)(\.git)?$'
			local _aliased_re='^git@github\.com-([^:]+):([^/]+)/([^/]+?)(\.git)?$'
			while IFS='|' read -r _host _target _flags; do
				[ -z "$_host" ] && continue
				[ "${_flags:-}" = "rw" ] || continue
				# Sibling without .git/ — no SSH routing needed (D10).
				[ -d "${_host}/.git" ] || continue
				_name="$(sanitize_project_name "$(basename "$_host")")"
				_current="$(git -C "$_host" remote get-url origin 2>/dev/null)" || continue
				# Accept canonical OR aliased-to-same-alias (legacy v0.2.1 state).
				# In the aliased case, parse owner/repo and emit the insteadOf
				# block as if the URL were canonical — the startup migration
				# (export_compose_env) restores the sibling to canonical separately.
				if [[ "$_current" =~ $_canonical_re ]]; then
					_owner="${BASH_REMATCH[1]}"
					_repo="${BASH_REMATCH[2]}"
					_dotgit="${BASH_REMATCH[3]:-}"
				elif [[ "$_current" =~ $_aliased_re ]]; then
					# Only same-alias counts — foreign aliases mean the user
					# wired this manually; do not second-guess.
					[ "${BASH_REMATCH[1]}" = "$_name" ] || {
						warn "sibling $_host has URL aliased to '${BASH_REMATCH[1]}' (expected '$_name') — skipping url.insteadOf entry"
						continue
					}
					_owner="${BASH_REMATCH[2]}"
					_repo="${BASH_REMATCH[3]}"
					_dotgit="${BASH_REMATCH[4]:-}"
				else
					warn "sibling $_host remote.origin.url='$_current' — only canonical 'git@github.com:owner/repo[.git]' SSH URLs are routable; skipping url.insteadOf entry"
					continue
				fi
				printf '[url "git@github.com-%s:%s/%s%s"]\n' "$_name" "$_owner" "$_repo" "$_dotgit"
				printf '\tinsteadOf = git@github.com:%s/%s%s\n\n' "$_owner" "$_repo" "$_dotgit"
			done <"$list_file"
		fi
	} >"$tmp" || {
		rm -f "$tmp"
		err "failed to write managed gitconfig"
	}

	# 600: gitconfig may carry signingkey hints; keep it owner-only just like
	# the managed SSH config (and the host's ~/.gitconfig is typically 644 but
	# the managed copy is drydock-internal and not shared).
	if ! chmod 600 "$tmp"; then
		rm -f "$tmp"
		err "chmod 600 failed on managed gitconfig"
	fi
	if ! mv -f "$tmp" "$config_path"; then
		rm -f "$tmp"
		err "atomic mv failed for managed gitconfig"
	fi

	printf '%s' "$config_path"
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
