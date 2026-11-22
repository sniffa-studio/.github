#!/usr/bin/env bash
set -uo pipefail

webhook="${DEPLOY_WEBHOOK:-}"
unset DEPLOY_WEBHOOK
repo="${GITHUB_REPOSITORY#*/}"
name="${INPUT_NAME:-$repo}"
environment="${INPUT_ENVIRONMENT:-prod}"
status="${INPUT_STATUS:-unknown}"
api_url="${GITHUB_API_URL:-https://api.github.com}"
repo_url="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY"
run_url="$repo_url/actions/runs/$GITHUB_RUN_ID"
if [ "${GITHUB_RUN_ATTEMPT:-1}" != 1 ]; then
  run_url="$run_url/attempts/$GITHUB_RUN_ATTEMPT"
fi
sha="${INPUT_SHA:-$GITHUB_SHA}"
kind="${INPUT_KIND:-deploy}"
short="${sha::7}"
branch="$GITHUB_REF_NAME"
log="${INPUT_LOG:-${RUNNER_TEMP:-/tmp}/sniffa-deploy.log}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

github() {
  curl -fsS --max-time 10 -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" "$api_url/$1"
}

jar_version() {
  local base
  base=$(basename "$1" .jar)
  base="${base%-all}"
  base="${base%-plain}"
  printf '%s' "$base" | sed -nE 's/^.*-([0-9]+\.[0-9]+([.+-].*)?)$/\1/p'
}

first_file() {
  local pattern="$1" f
  for f in $pattern; do
    [ -f "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

duration_text() {
  local s="$1"
  if [ "$s" -ge 3600 ]; then
    printf '%d h %d min' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then
    printf '%d min %d s' $((s / 60)) $((s % 60))
  else
    printf '%d s' "$s"
  fi
}

commit_json=$(github "repos/$GITHUB_REPOSITORY/commits/$sha" 2> /dev/null || echo '{}')
message=$(jq -r '.commit.message // empty' <<< "$commit_json")
if [ -z "$message" ] && [ "$sha" = "$GITHUB_SHA" ]; then
  message="${HEAD_COMMIT_MESSAGE:-}"
fi
subject=$(printf '%s\n' "$message" | head -1)
if [[ "$subject" =~ ^Merge\ pull\ request\ \#([0-9]+) ]]; then
  pr="${BASH_REMATCH[1]}"
  title=$(printf '%s\n' "$message" | tail -n +2 | sed '/^[[:space:]]*$/d' | head -1)
  [ -n "$title" ] && subject="$title (#$pr)"
fi
[ -n "$subject" ] || subject="(keine Commit-Nachricht)"
[ "${#subject}" -le 180 ] || subject="${subject::177}..."

author_login=$(jq -r '.author.login // empty' <<< "$commit_json")
author_name=$(jq -r '.commit.author.name // empty' <<< "$commit_json")
actor="${GITHUB_TRIGGERING_ACTOR:-$GITHUB_ACTOR}"
if [ -n "$author_login" ]; then
  author="[$author_login](https://github.com/$author_login)"
else
  author="${author_name:-[$actor](https://github.com/$actor)}"
fi
if [ "$GITHUB_EVENT_NAME" = workflow_dispatch ] && [ "$actor" != "$author_login" ]; then
  author="$author · ausgelöst von [$actor](https://github.com/$actor)"
fi
who="$actor"
if [ "$GITHUB_EVENT_NAME" != workflow_dispatch ] && [ -n "$author_login" ]; then
  who="$author_login"
fi

version="${INPUT_VERSION:-}"
if [ -z "$version" ] && [ -n "${INPUT_JAR:-}" ]; then
  jar=$(first_file "$INPUT_JAR") && version=$(jar_version "$jar")
fi
[ -n "$version" ] || version="r${GITHUB_RUN_NUMBER}-${short}"

modules=()
while IFS= read -r entry; do
  entry="${entry#"${entry%%[![:space:]]*}"}"
  entry="${entry%"${entry##*[![:space:]]}"}"
  [ -n "$entry" ] || continue
  if [[ "$entry" == *.jar ]]; then
    for f in $entry; do
      [ -f "$f" ] || continue
      v=$(jar_version "$f")
      n=$(basename "$f" .jar)
      n="${n%-all}"
      n="${n%-"$v"}"
      if [ -n "$v" ] && [ "$v" != "$version" ]; then
        modules+=("$n \`$v\`")
      else
        modules+=("$n")
      fi
    done
  else
    modules+=("$(sed -E 's/\b([0-9a-f]{7})[0-9a-f]{33}\b/\1/g' <<< "$entry")")
  fi
done <<< "${INPUT_MODULES:-}"

secs=""
started=$(github "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/${GITHUB_RUN_ATTEMPT:-1}" 2> /dev/null \
  | jq -r '.run_started_at // empty' 2> /dev/null)
if [ -n "$started" ]; then
  secs=$(($(date +%s) - $(date -d "$started" +%s)))
else
  pid=$$
  while [ "$pid" -gt 1 ] 2> /dev/null; do
    if [ "$(cat "/proc/$pid/comm" 2> /dev/null)" = Runner.Worker ]; then
      secs=$(ps -o etimes= -p "$pid" | tr -d ' ')
      break
    fi
    pid=$(awk '{print $4}' "/proc/$pid/stat" 2> /dev/null || echo 1)
  done
fi
duration="unbekannt"
if [ -n "$secs" ]; then
  duration=$(duration_text "$secs")
  [ -n "$started" ] || duration="$duration (nur Deploy-Job)"
fi

outcome="$status"
if [ "$status" = failure ] && [ -f "$log" ]; then
  if grep -qiE 'not healthy either|not ready either|does not connect either' "$log"; then
    outcome=rollback-failed
  elif grep -qiE 'rolling back|rolled back|restoring the previous' "$log"; then
    outcome=rolled-back
  fi
fi

if [ "$kind" = rollback ]; then
  case "$outcome" in
    success) outcome=manual-rollback ;;
    rolled-back) outcome=rollback-reverted ;;
    rollback-failed|cancelled) ;;
    *) outcome=rollback-error ;;
  esac
fi

case "$outcome" in
  manual-rollback)
    title="↩️ $name $environment zurückgerollt"; verb="zurückgerollt"; color=15844367
    state="↩️ manuell zurückgerollt" ;;
  rollback-reverted)
    title="❌ $name $environment Rollback fehlgeschlagen"; verb="Rollback fehlgeschlagen"; color=15158332
    state="❌ Ziel nicht gesund, die vorher laufende Version läuft wieder" ;;
  rollback-error)
    title="❌ $name $environment Rollback fehlgeschlagen"; verb="Rollback fehlgeschlagen"; color=15158332
    state="❌ Rollback fehlgeschlagen"
    [ -f /etc/sniffa/freeze ] && state="❌ Event-Freeze aktiv, nichts geändert" ;;
  success)
    title="🚀 $name $environment deployed"; verb="deployed"; color=3066993; state="✅ erfolgreich" ;;
  rolled-back)
    title="↩️ $name $environment zurückgerollt"; verb="zurückgerollt"; color=15844367
    state="↩️ Health-Check fehlgeschlagen, vorherige Version läuft wieder" ;;
  rollback-failed)
    title="❌ $name $environment fehlgeschlagen"; verb="fehlgeschlagen"; color=15158332
    state="❌ fehlgeschlagen, Rollback ebenfalls nicht gesund" ;;
  cancelled)
    title="❌ $name $environment abgebrochen"; verb="abgebrochen"; color=15158332; state="⏹️ abgebrochen" ;;
  *)
    title="❌ $name $environment fehlgeschlagen"; verb="fehlgeschlagen"; color=15158332; state="❌ fehlgeschlagen"
    [ -f /etc/sniffa/freeze ] && state="❌ Event-Freeze aktiv, nichts deployt" ;;
esac

case "$GITHUB_EVENT_NAME" in
  push) trigger="Push" ;;
  workflow_dispatch) trigger="manuell" ;;
  schedule) trigger="Zeitplan" ;;
  *) trigger="$GITHUB_EVENT_NAME" ;;
esac

module_text=""
if [ "${#modules[@]}" -gt 0 ]; then
  shown=("${modules[@]:0:8}")
  module_text=$(printf '• %s\n' "${shown[@]}")
  if [ "${#modules[@]}" -gt 8 ]; then
    module_text="$module_text"$'\n'"+$((${#modules[@]} - 8)) weitere"
  fi
fi

content="$who — $name $environment $verb: $version (<$run_url>)"

jq -n \
  --arg content "$content" \
  --arg title "$title" \
  --arg url "$run_url" \
  --argjson color "$color" \
  --arg version "\`$version\`" \
  --arg environment "$environment" \
  --arg state "$state" \
  --arg branch "[$branch]($repo_url/tree/$branch)" \
  --arg commit "[\`$short\`]($repo_url/commit/$sha) $subject" \
  --arg author "$author" \
  --arg build "[#$GITHUB_RUN_NUMBER]($run_url) · $trigger" \
  --arg duration "$duration" \
  --arg image "${INPUT_IMAGE:-}" \
  --arg modules "$module_text" \
  --arg modules_name "Module (${#modules[@]})" \
  --arg footer "$GITHUB_REPOSITORY · ${WORKFLOW_NAME:-}" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    content: $content,
    allowed_mentions: {parse: []},
    embeds: [{
      title: $title,
      url: $url,
      color: $color,
      fields: ([
        {name: "Version", value: $version, inline: true},
        {name: "Umgebung", value: $environment, inline: true},
        {name: "Status", value: $state, inline: true},
        {name: "Branch", value: $branch, inline: true},
        {name: "Autor", value: $author, inline: true},
        {name: "Build", value: $build, inline: true},
        {name: "Commit", value: $commit, inline: false},
        {name: "Dauer", value: $duration, inline: true}
      ]
      + (if $image != "" then [{name: "Image", value: ("`" + $image + "`"), inline: true}] else [] end)
      + (if $modules != "" then [{name: $modules_name, value: $modules, inline: false}] else [] end)),
      footer: {text: $footer},
      timestamp: $timestamp
    }]
  }' > "$work/payload.json" || { echo "::warning::Could not build the Discord message"; exit 0; }

{
  echo "### Discord #deploys"
  echo
  echo "$content"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

if [ -z "$webhook" ]; then
  echo "No webhook set (DISCORD_DEPLOY_WEBHOOK), dry run. This would be posted:"
  jq . "$work/payload.json"
  echo "_Dry run: no webhook set._" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  exit 0
fi

target="$webhook"
case "$target" in
  *\?*) target="$target&wait=true" ;;
  *) target="$target?wait=true" ;;
esac

send() {
  curl -sS --max-time 15 -o "$work/response.json" -w '%{http_code}' \
    -H 'Content-Type: application/json' --data-binary @"$work/payload.json" "$target" 2> "$work/curl.err" || echo 000
}

code=$(send)
if [ "$code" = 429 ]; then
  wait=$(jq -r '.retry_after // 2' "$work/response.json" 2> /dev/null | cut -d. -f1)
  [ "${wait:-2}" -le 10 ] 2> /dev/null || wait=10
  sleep "$((wait + 1))"
  code=$(send)
fi

if [[ "$code" == 2* ]]; then
  id=$(jq -r '.id // empty' "$work/response.json" 2> /dev/null)
  echo "Posted to Discord #deploys (message $id): $content"
  echo "message-id=$id" >> "${GITHUB_OUTPUT:-/dev/null}"
else
  echo "::warning::Discord answered HTTP $code, the deploy itself is not affected"
  jq -r '.message // empty' "$work/response.json" 2> /dev/null | head -c 300
  sed 's#https://[^ ]*#<url>#g' "$work/curl.err" 2> /dev/null | head -c 300
fi
exit 0
