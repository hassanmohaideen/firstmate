#!/usr/bin/env bash

fm_github_remote_destination_url() {
  local project=$1 capability=$2 urls
  case "$capability" in
    push) urls=$(git -C "$project" remote get-url --push --all origin 2>/dev/null) || return 1 ;;
    fetch|api-org-membership) urls=$(git -C "$project" remote get-url --all origin 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac
  [ -n "$urls" ] || return 1
  case "$urls" in *$'\n'*) return 2 ;; esac
  printf '%s' "$urls"
}

fm_github_validate_hostname() {
  local host=$1 remaining label first last
  [ -n "$host" ] && [ "${#host}" -le 253 ] || return 1
  case "$host" in *[!a-z0-9.-]*|.*|*.|*..*) return 1 ;; esac
  remaining=$host
  while :; do
    case "$remaining" in
      *.*) label=${remaining%%.*}; remaining=${remaining#*.} ;;
      *) label=$remaining; remaining= ;;
    esac
    [ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
    first=${label%"${label#?}"}
    last=${label#"${label%?}"}
    case "$first$last" in *[!a-z0-9]*) return 1 ;; esac
    case "$label" in *[!a-z0-9-]*) return 1 ;; esac
    [ -n "$remaining" ] || break
  done
}

fm_github_http_remote_host() {
  local url=$1 authority userinfo host port normalized_port
  case "$url" in
    https://*/*|http://*/*) authority=${url#*://}; authority=${authority%%/*} ;;
    *) return 1 ;;
  esac
  case "$authority" in
    ''|*@*@*) return 1 ;;
    *@*)
      userinfo=${authority%%@*}
      authority=${authority#*@}
      case "$userinfo" in ''|*[!A-Za-z0-9._~-]*) return 1 ;; esac
      ;;
  esac
  case "$authority" in
    *:*)
      host=${authority%:*}
      port=${authority##*:}
      case "$host" in ''|*:*) return 1 ;; esac
      case "$port" in ''|*[!0-9]*) return 1 ;; esac
      normalized_port=$port
      while [ "${normalized_port#0}" != "$normalized_port" ]; do normalized_port=${normalized_port#0}; done
      [ -n "$normalized_port" ] || return 1
      [ "${#normalized_port}" -lt 6 ] && [ "$normalized_port" -le 65535 ] || return 1
      ;;
    *) host=$authority ;;
  esac
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  fm_github_validate_hostname "$host" || return 1
  printf '%s' "$host"
}

fm_github_remote_urls_include_host() {
  local project=$1 capability=$2 expected_host=$3 urls url host
  case "$capability" in
    push) urls=$(git -C "$project" remote get-url --push --all origin 2>/dev/null) || return 1 ;;
    fetch|api-org-membership) urls=$(git -C "$project" remote get-url --all origin 2>/dev/null) || return 1 ;;
    *) return 1 ;;
  esac
  while IFS= read -r url; do
    case "$url" in
      https://*/*|http://*/*) host=$(fm_github_http_remote_host "$url") || continue ;;
      ssh://*/*) host=${url#ssh://}; host=${host#*@}; host=${host%%[:/]*} ;;
      git@*:*/*) host=${url#git@}; host=${host%%:*} ;;
      *) continue ;;
    esac
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    fm_github_validate_hostname "$host" || continue
    [ "$host" = "$expected_host" ] && return 0
  done <<EOF
$urls
EOF
  return 1
}

fm_github_remote_destination_host() {
  local project=$1 capability=$2 url host
  url=$(fm_github_remote_destination_url "$project" "$capability") || return $?
  case "$url" in
    https://*/*|http://*/*) host=$(fm_github_http_remote_host "$url") || return 1 ;;
    ssh://*/*) host=${url#ssh://}; host=${host#*@}; host=${host%%[:/]*} ;;
    git@*:*/*) host=${url#git@}; host=${host%%:*} ;;
    *) return 1 ;;
  esac
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  fm_github_validate_hostname "$host" || return 1
  printf '%s' "$host"
}

fm_github_remote_destination_repository() {
  local project=$1 capability=$2 url path owner repository
  url=$(fm_github_remote_destination_url "$project" "$capability") || return $?
  case "$url" in
    https://*/*|http://*/*)
      fm_github_http_remote_host "$url" >/dev/null || return 1
      path=${url#*://}; path=${path#*/}
      ;;
    ssh://*/*) path=${url#ssh://}; path=${path#*/} ;;
    git@*:*/*) path=${url#*:} ;;
    *) return 1 ;;
  esac
  path=${path%.git}
  case "$path" in */*) owner=${path%%/*}; repository=${path#*/} ;; *) return 1 ;; esac
  case "$owner" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  case "$repository" in ''|*/*|*[!A-Za-z0-9_.-]*) return 1 ;; esac
  printf '%s/%s' "$owner" "$repository"
}

fm_github_auth_probe_failure() {
  local diagnostic=$1 capability=$2 target=$3 normalized
  normalized=$(printf '%s' "$diagnostic" | tr '[:upper:]' '[:lower:]')
  case "$normalized" in
    *"could not resolve host"*|*"connection refused"*|*"connection reset"*|*"network is unreachable"*|*"no route to host"*|*"operation timed out"*|*"context deadline exceeded"*|*"tls handshake timeout"*)
      echo "GH_AUTH_INDETERMINATE: GitHub network probe did not complete"; return 2 ;;
    *"failed to read"*"keychain"*|*"failed to read"*"keyring"*|*"could not access"*"keychain"*|*"could not access"*"keyring"*|*"credential store"*"failed"*|*"failed to read"*"config"*|*"could not read"*"config"*|*"error parsing"*|*"invalid config"*|*"malformed config"*)
      echo "GH_AUTH_INDETERMINATE: local GitHub credential storage or configuration failed"; return 2 ;;
    *"not logged into"*|*"no oauth token found"*|*"no token found"*|*"token"*" is invalid"*|*"token"*" has expired"*|*"authentication token"*"invalid"*|*"http 401"*)
      echo "NEEDS_GH_AUTH"; return 1 ;;
    *"resource not accessible"*|*"insufficient"*"scope"*|*"permission denied"*|*"write access"*"not granted"*)
      echo "GITHUB_ACCESS_REQUIRED: GitHub $capability access to $target"; return 1 ;;
    *"http 404"*|*"not found"*)
      echo "GH_AUTH_INDETERMINATE: GitHub $capability-access probe for $target failed without concrete authentication or authorization evidence"; return 2 ;;
    *)
      if [ "$capability" = authentication ]; then
        echo "GH_AUTH_INDETERMINATE: gh auth status failed without concrete signed-out or invalid-credential evidence"
      else
        echo "GH_AUTH_INDETERMINATE: GitHub $capability-access probe for $target failed without concrete authentication or authorization evidence"
      fi
      return 2 ;;
  esac
}

fm_github_auth_probe() {
  local host=$1 capability=$2 target=$3 organization=${4:-} diagnostic result
  command -v gh >/dev/null 2>&1 || return 2
  if ! gh auth status --help 2>&1 | grep -q -- '--active'; then
    echo "GH_AUTH_INDETERMINATE: installed gh cannot isolate the selected active account"
    return 2
  fi
  if ! diagnostic=$(gh auth status --active --hostname "$host" 2>&1); then
    fm_github_auth_probe_failure "$diagnostic" authentication "$host"
    return $?
  fi
  case "$capability" in
    fetch)
      if ! diagnostic=$(gh api --hostname "$host" "repos/$target" --silent 2>&1); then
        fm_github_auth_probe_failure "$diagnostic" read "$target"
        return $?
      fi
      ;;
    api-org-membership)
      if ! diagnostic=$(gh api --hostname "$host" "user/memberships/orgs/$organization" --silent 2>&1); then
        fm_github_auth_probe_failure "$diagnostic" organization-membership "$organization"
        return $?
      fi
      ;;
    push)
      if ! result=$(gh api --hostname "$host" "repos/$target" --jq '.permissions.push == true' 2>&1); then
        fm_github_auth_probe_failure "$result" write "$target"
        return $?
      fi
      case "$result" in
        true) ;;
        false) echo "GITHUB_ACCESS_REQUIRED: GitHub write access to $target"; return 1 ;;
        *) echo "GH_AUTH_INDETERMINATE: GitHub write-access probe for $target returned an invalid response"; return 2 ;;
      esac
      ;;
    *) return 2 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Authentication-context lifecycle owner.
#
# This is the SINGLE owner of the GitHub launch-verification decision. Every
# driver (fm-spawn intake and relaunch, fm-promote) resolves a selection with
# fm_github_ctx_intake, then gates the launch with fm_github_ctx_gate. No driver
# re-implements the decision, so the split-authority erase-then-bypass class that
# a per-driver re-implementation produced cannot recur.
#
# The gate keys on IMMUTABLE task scope (kind/mode for a push, the recorded
# authentication requirement for a scout read) plus an AFFIRMATIVE verified
# destination tuple that must byte-equal the currently observed destination. A
# missing, dropped, partial, or mismatched field can only move the gate toward
# BLOCK; erasure is never a bypass. The verified tuple is written only by a
# successful probe of the selected destination, so a legacy or corrupted record
# with no matching tuple always re-probes (fail-closed migration).
# ---------------------------------------------------------------------------

# A push (ship) task is in gated scope from its immutable kind/mode; a scout is
# in scope only when it recorded an authentication requirement. Anything else,
# including local-only ship work, is out of scope.
fm_github_ctx_scope() {
  local kind=$1 mode=$2 auth_required=${3:-}
  case "$kind" in
    ship) [ "$mode" != local-only ] ;;
    scout) [ -n "$auth_required" ] && [ "$auth_required" != 0 ] ;;
    *) return 1 ;;
  esac
}

# The probe capability for a gated task.
fm_github_ctx_capability() {
  local kind=$1 auth_capability=${2:-}
  case "$kind" in
    ship) printf 'push' ;;
    scout)
      case "$auth_capability" in
        organization-membership-read) printf 'api-org-membership' ;;
        private-repository-read) printf 'fetch' ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# The canonical verified-destination tuple. Every field is charset-constrained
# (forge is a literal, host is a validated lowercase DNS name, target is an
# owner/repo or an org, capability is an enum), so '|' cannot appear inside a
# field and the join is unambiguous.
fm_github_ctx_dest_tuple() {
  printf '%s|%s|%s|%s|%s' "$1" "$2" "$3" "$4" "$5"
}

# Resolve the authoritative GitHub selection at intake (a fresh spawn, a relaunch
# with no recorded selection, or a promotion).
#   stdout on success: <selected_host>\t<target_kind>\t<target>   (return 0)
#   return 3: not an authoritative GitHub target (no --github-host assertion and
#             the single clean destination is not github.com); the caller decides
#             (no gate for a ship push, a hard error for an authentication scout)
#   return 1: the asserted --github-host does not match the destination, or a
#             required organization is missing (hard configuration error)
#   return 2: ambiguous, mixed, malformed, or otherwise indeterminate -> block
# github.com is GitHub's own canonical host, so it is auto-selected without an
# assertion; an arbitrary or Enterprise host is never inferred without one.
fm_github_ctx_intake() {
  local project=$1 capability=$2 asserted=$3 organization=${4:-} obs_host obs_repo st
  if [ -n "$asserted" ]; then
    fm_github_validate_hostname "$asserted" || { echo "error: --github-host must be a canonical lowercase hostname" >&2; return 1; }
  fi
  obs_host=$(fm_github_remote_destination_host "$project" "$capability" 2>/dev/null)
  st=$?
  if [ "$st" -eq 2 ]; then
    if [ -n "$asserted" ] || fm_github_remote_urls_include_host "$project" "$capability" github.com; then
      echo "GH_AUTH_INDETERMINATE: multiple or mixed GitHub destinations cannot establish one authoritative target" >&2
      return 2
    fi
    return 3
  elif [ "$st" -ne 0 ] || [ -z "$obs_host" ]; then
    if [ -n "$asserted" ]; then
      echo "GH_AUTH_INDETERMINATE: the selected project has no unambiguous GitHub destination for the asserted host" >&2
      return 2
    fi
    return 3
  fi
  if [ -n "$asserted" ]; then
    [ "$obs_host" = "$asserted" ] || {
      echo "error: --github-host '$asserted' does not match the project's canonical destination host '$obs_host'" >&2
      return 1
    }
  elif [ "$obs_host" != github.com ]; then
    return 3
  fi
  if [ "$capability" = api-org-membership ]; then
    [ -n "$organization" ] || { echo "error: organization-membership selection requires --github-organization" >&2; return 1; }
    printf '%s\torganization\t%s' "$obs_host" "$organization"
  else
    obs_repo=$(fm_github_remote_destination_repository "$project" "$capability" 2>/dev/null) || {
      echo "GH_AUTH_INDETERMINATE: the selected project has no unambiguous GitHub repository" >&2
      return 2
    }
    printf '%s\trepository\t%s' "$obs_host" "$obs_repo"
  fi
}

# The launch gate. Given a resolved selection and the recorded verified tuple,
# decide whether the worker may launch against the CURRENT destination.
#   ALLOW: prints the verified destination tuple to stdout, returns 0. The caller
#          persists that tuple so a later relaunch of the unchanged destination is
#          trusted without re-probing.
#   BLOCK: prints a diagnostic to stderr, returns 1 (concrete auth/access failure)
#          or 2 (indeterminate/retryable). The caller must not launch.
# The gate probes the SELECTED host only; a changed observed host is never
# adopted, so a repointed remote stays blocked until the destination is
# re-selected.
fm_github_ctx_gate() {
  local project=$1 forge=$2 selected_host=$3 target_kind=$4 target=$5 capability=$6 organization=${7:-} recorded=${8:-}
  local obs_host obs_repo obs_target obs_tuple probe_target probe_out st
  [ "$forge" = github ] || { echo "GH_AUTH_INDETERMINATE: no authoritative GitHub forge is recorded for this task" >&2; return 2; }
  fm_github_validate_hostname "$selected_host" || { echo "GH_AUTH_INDETERMINATE: the recorded GitHub host is not a canonical hostname" >&2; return 2; }
  obs_host=$(fm_github_remote_destination_host "$project" "$capability" 2>/dev/null)
  st=$?
  if [ "$st" -eq 2 ]; then
    echo "GH_AUTH_INDETERMINATE: multiple or mixed GitHub destinations cannot establish one authoritative target" >&2
    return 2
  elif [ "$st" -ne 0 ] || [ -z "$obs_host" ]; then
    echo "GH_AUTH_INDETERMINATE: the selected project has no unambiguous GitHub destination" >&2
    return 2
  fi
  [ "$obs_host" = "$selected_host" ] || {
    echo "GH_AUTH_INDETERMINATE: the current GitHub destination host does not match the recorded selection" >&2
    return 2
  }
  if [ "$target_kind" = repository ]; then
    obs_repo=$(fm_github_remote_destination_repository "$project" "$capability" 2>/dev/null) || {
      echo "GH_AUTH_INDETERMINATE: the selected project has no unambiguous GitHub repository" >&2
      return 2
    }
    [ "$obs_repo" = "$target" ] || {
      echo "GH_AUTH_INDETERMINATE: the current GitHub repository does not match the recorded selection" >&2
      return 2
    }
    obs_target=$obs_repo
    probe_target=$obs_repo
  else
    [ -n "$organization" ] || { echo "GH_AUTH_INDETERMINATE: no organization is recorded for an organization-membership task" >&2; return 2; }
    obs_target=$organization
    probe_target=$organization
  fi
  obs_tuple=$(fm_github_ctx_dest_tuple "$forge" "$obs_host" "$target_kind" "$obs_target" "$capability")
  if [ -n "$recorded" ] && [ "$recorded" = "$obs_tuple" ]; then
    printf '%s' "$obs_tuple"
    return 0
  fi
  # `st=$?` must be the FIRST statement of the else branch: after a whole
  # `if cmd; then ...; fi` with no else, `$?` is the if-statement's own status
  # (0 when the condition is false), not the probe's, which would turn a probe
  # failure into a launch.
  if probe_out=$(fm_github_auth_probe "$selected_host" "$capability" "$probe_target" "$organization"); then
    printf '%s' "$obs_tuple"
    return 0
  else
    st=$?
    [ -z "$probe_out" ] || printf '%s\n' "$probe_out" >&2
    return "$st"
  fi
}
