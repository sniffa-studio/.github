#!/usr/bin/env bash
set -euo pipefail

requested="${INPUT_SHA:-}"
requested="${requested// /}"
api_url="${GITHUB_API_URL:-https://api.github.com}"

github() {
  curl -fsS --max-time 15 -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" "$api_url/$1"
}

if [ -z "$requested" ]; then
  sha="$GITHUB_SHA"
  was_requested=false
else
  if ! [[ "$requested" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    echo "::error::sha $requested is not a commit hash (7 to 40 hex characters)"
    exit 1
  fi
  requested="${requested,,}"
  if ! sha=$(github "repos/$GITHUB_REPOSITORY/commits/$requested" | jq -er '.sha'); then
    echo "::error::sha $requested does not exist in $GITHUB_REPOSITORY"
    exit 1
  fi
  status=$(github "repos/$GITHUB_REPOSITORY/compare/$BRANCH...$sha" | jq -r '.status // empty') || status=""
  case "$status" in
    identical|behind) ;;
    *)
      echo "::error::sha $requested is not on $BRANCH (compare: ${status:-unknown})"
      exit 1
      ;;
  esac
  was_requested=true
  echo "Deploying the requested commit $sha from $BRANCH"
fi

{
  echo "sha=$sha"
  echo "short=${sha::7}"
  echo "requested=$was_requested"
} >> "$GITHUB_OUTPUT"
