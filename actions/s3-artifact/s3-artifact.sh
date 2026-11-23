#!/usr/bin/env bash
set -euo pipefail

MCLI_VERSION=RELEASE.2026-10-26T00-00-00Z
MCLI_TARBALL=mcli_20261026000000.0.0_linux_amd64.tar.gz
MCLI_TARBALL_SHA256=e86295bb11ed59369c0560f030d59abd42fb64a376b1d7e9799ec2e8596ebf64
MCLI_SHA256=8afa1243115737e25746e84a59b37d61a29d5fd6e6b76cc3dbccbff2a20380ba

fail() {
  echo "::error::$1"
  exit 1
}

missing() {
  case "$S3_IF_NONE" in
    ignore) echo "$1" ;;
    warn) echo "::warning::$1" ;;
    *) fail "$1" ;;
  esac
}

urlencode() {
  local s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

human_size() {
  numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 B"
}

install_mcli() {
  [ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || fail "s3-artifact only runs on Linux x64 runners"
  local cache="${RUNNER_TOOL_CACHE:-$RUNNER_TEMP}/sniffa-mcli/$MCLI_VERSION"
  if ! mkdir -p "$cache" 2>/dev/null || [ ! -w "$cache" ]; then
    cache="$RUNNER_TEMP/sniffa-mcli/$MCLI_VERSION"
    mkdir -p "$cache"
  fi
  MCLI="$cache/mcli"
  if echo "$MCLI_SHA256  $MCLI" | sha256sum -c --status 2>/dev/null; then
    return
  fi
  local tmp
  tmp=$(mktemp -d "$RUNNER_TEMP/mcli.XXXXXX")
  curl -fsSL --retry 3 -o "$tmp/$MCLI_TARBALL" \
    "https://github.com/pgsty/mc/releases/download/$MCLI_VERSION/$MCLI_TARBALL"
  echo "$MCLI_TARBALL_SHA256  $tmp/$MCLI_TARBALL" | sha256sum -c --status || fail "checksum of $MCLI_TARBALL does not match"
  tar -xzf "$tmp/$MCLI_TARBALL" -C "$tmp" mcli
  echo "$MCLI_SHA256  $tmp/mcli" | sha256sum -c --status || fail "checksum of mcli does not match"
  mv -f "$tmp/mcli" "$MCLI.$$"
  mv -f "$MCLI.$$" "$MCLI"
  rm -rf "$tmp"
}

mcli() {
  "$MCLI" --no-color --disable-pager "$@" < /dev/null
}

retry() {
  local attempt
  for attempt in 1 2 3 4; do
    if "$@"; then
      return 0
    fi
    [ "$attempt" -eq 4 ] || sleep $((attempt * 2))
  done
  return 1
}

configure() {
  [ -n "$S3_ENDPOINT" ] || fail "endpoint is empty, set the variable CI_S3_ENDPOINT"
  [ -n "$S3_ACCESS_KEY" ] && [ -n "$S3_SECRET_KEY" ] || fail "access-key or secret-key is empty, set the secrets CI_S3_ACCESS_KEY and CI_S3_SECRET_KEY"
  local scheme="${S3_ENDPOINT%%://*}" host="${S3_ENDPOINT#*://}"
  host="${host%/}"
  [ "$scheme" != "$S3_ENDPOINT" ] || { scheme=https; host="${S3_ENDPOINT%/}"; }
  local secret
  secret=$(urlencode "$S3_SECRET_KEY")
  [ "$secret" = "$S3_SECRET_KEY" ] || echo "::add-mask::$secret"
  export MC_CONFIG_DIR="$WORK/config"
  export MC_HOST_ci="$scheme://$(urlencode "$S3_ACCESS_KEY"):$secret@$host"
}

collect() {
  FILES=()
  local line match
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    while IFS= read -r match; do
      [ -n "$match" ] && FILES+=("$match")
    done < <(compgen -G "$line" || true)
  done <<< "$S3_PATH"
}

presign() {
  S3_KEY_PATH="/$S3_BUCKET/$1" python3 -I -c '
import datetime, hashlib, hmac, os, urllib.parse
endpoint = os.environ["S3_ENDPOINT"].rstrip("/")
scheme, host = endpoint.split("://", 1) if "://" in endpoint else ("https", endpoint)
access, secret = os.environ["S3_ACCESS_KEY"], os.environ["S3_SECRET_KEY"]
now = datetime.datetime.now(datetime.timezone.utc)
amz_date, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
scope = f"{day}/us-east-1/s3/aws4_request"
path = urllib.parse.quote(os.environ["S3_KEY_PATH"], safe="/~")
query = "&".join(f"{k}={urllib.parse.quote(v, safe=chr(126))}" for k, v in sorted({
    "X-Amz-Algorithm": "AWS4-HMAC-SHA256",
    "X-Amz-Credential": f"{access}/{scope}",
    "X-Amz-Date": amz_date,
    "X-Amz-Expires": "604800",
    "X-Amz-SignedHeaders": "host",
}.items()))
request = f"GET\n{path}\n{query}\nhost:{host}\n\nhost\nUNSIGNED-PAYLOAD"
to_sign = f"AWS4-HMAC-SHA256\n{amz_date}\n{scope}\n{hashlib.sha256(request.encode()).hexdigest()}"
key = ("AWS4" + secret).encode()
for part in (day, "us-east-1", "s3", "aws4_request"):
    key = hmac.new(key, part.encode(), hashlib.sha256).digest()
signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
print(f"{scheme}://{host}{path}?{query}&X-Amz-Signature={signature}")
'
}

link_line() {
  local key="$1" label="$2" size="$3" url
  url=$(presign "$key") || fail "could not sign a link for $key"
  [ -n "${URL:-}" ] || URL="$url"
  LINES+=("- [$label]($url) ($(human_size "$size"))")
}

summary_links() {
  local key="$1" listing entry
  LINES=()
  if [ "$S3_ARCHIVE" = true ]; then
    link_line "$key" "$(basename "$key")" "$(stat -c %s "$WORK/$S3_NAME.tar.zst")"
  else
    listing=$(retry mcli ls --recursive --json "ci/$S3_BUCKET/$key") || fail "could not list $S3_BUCKET/$key"
    listing=$(jq -c 'select(.type == "file") | [.key, .size]' <<< "$listing")
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      link_line "$key$(jq -r '.[0]' <<< "$entry")" "$(jq -r '.[0]' <<< "$entry")" "$(jq -r '.[1]' <<< "$entry")"
    done <<< "$listing"
  fi
  {
    echo "### Artifact \`$S3_NAME\`"
    echo
    printf '%s\n' "${LINES[@]}"
    echo
    echo "Links are valid for 7 days, until $(date -u -d '+7 days' '+%Y-%m-%d %H:%M UTC'). On sniffa-base: \`$S3_BUCKET/$key\` with the keys in /opt/silo/clients/sniffa-ci."
  } >> "$GITHUB_STEP_SUMMARY"
}

upload() {
  [[ "$S3_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || fail "name $S3_NAME may only contain letters, digits, dot, dash and underscore"
  collect
  if [ ${#FILES[@]} -eq 0 ]; then
    missing "No files found for artifact $S3_NAME in: $S3_PATH"
    return
  fi
  if [ "$S3_ARCHIVE" = true ]; then
    local key="$BASE/$S3_NAME.tar.zst" archive="$WORK/$S3_NAME.tar.zst"
    if [ ${#FILES[@]} -eq 1 ] && [ -d "${FILES[0]}" ]; then
      tar -C "${FILES[0]}" -cf - . | zstd -q -T0 -3 -o "$archive"
    else
      tar -cf - -- "${FILES[@]}" | zstd -q -T0 -3 -o "$archive"
    fi
    retry mcli cp "$archive" "ci/$S3_BUCKET/$key" > /dev/null || fail "could not upload $S3_BUCKET/$key"
    echo "Uploaded $S3_BUCKET/$key ($(human_size "$(stat -c %s "$archive")"))"
    echo "key=$key" >> "$GITHUB_OUTPUT"
    if [ "$S3_LINK" = true ]; then
      summary_links "$key"
    fi
  else
    local prefix="$BASE/$S3_NAME/" entry
    mcli rm --recursive --force "ci/$S3_BUCKET/$prefix" > /dev/null 2>&1 || true
    if [ ${#FILES[@]} -eq 1 ] && [ -d "${FILES[0]}" ]; then
      retry mcli cp --recursive "${FILES[0]%/}/" "ci/$S3_BUCKET/$prefix" > /dev/null || fail "could not upload to $S3_BUCKET/$prefix"
    else
      for entry in "${FILES[@]}"; do
        if [ -d "$entry" ]; then
          retry mcli cp --recursive "${entry%/}/" "ci/$S3_BUCKET/$prefix$(basename "$entry")/" > /dev/null \
            || fail "could not upload $entry"
        else
          retry mcli cp "$entry" "ci/$S3_BUCKET/$prefix$(basename "$entry")" > /dev/null || fail "could not upload $entry"
        fi
      done
    fi
    echo "Uploaded ${#FILES[@]} path(s) to $S3_BUCKET/$prefix"
    echo "key=$prefix" >> "$GITHUB_OUTPUT"
    if [ "$S3_LINK" = true ]; then
      summary_links "$prefix"
    fi
  fi
  if [ -n "${URL:-}" ]; then
    echo "url=$URL" >> "$GITHUB_OUTPUT"
  fi
}

list_run() {
  local answer
  answer=$(retry mcli ls --json "ci/$S3_BUCKET/$BASE/") || answer=""
  ENTRIES=$(jq -r 'select(.status == "success") | .key' <<< "$answer" 2>/dev/null || true)
}

exists() {
  local entry="$1.tar.zst"
  [ "$S3_ARCHIVE" = true ] || entry="$1/"
  grep -qxF -- "$entry" <<< "$ENTRIES"
}

fetch() {
  local name="$1" target="$2"
  mkdir -p "$target"
  if [ "$S3_ARCHIVE" = true ]; then
    local key="$BASE/$name.tar.zst" archive="$WORK/$name.tar.zst"
    retry mcli cp "ci/$S3_BUCKET/$key" "$archive" > /dev/null || fail "could not download $S3_BUCKET/$key"
    zstd -q -dc "$archive" | tar -xf - -C "$target" || fail "could not unpack $S3_BUCKET/$key"
    rm -f "$archive"
    echo "Downloaded $S3_BUCKET/$key into $target"
  else
    local prefix="$BASE/$name/"
    retry mcli cp --recursive "ci/$S3_BUCKET/$prefix" "${target%/}/" > /dev/null || fail "could not download $S3_BUCKET/$prefix"
    echo "Downloaded $S3_BUCKET/$prefix into $target"
  fi
}

download_run() {
  local found=false entry name
  list_run
  if [[ "$S3_NAME" == *[*?]* ]]; then
    while IFS= read -r entry; do
      if [ "$S3_ARCHIVE" = true ]; then
        [[ "$entry" == *.tar.zst ]] || continue
        name="${entry%.tar.zst}"
      else
        [[ "$entry" == */ ]] || continue
        name="${entry%/}"
      fi
      [[ "$name" == $S3_NAME ]] || continue
      fetch "$name" "${S3_PATH%/}/$name"
      found=true
    done <<< "$ENTRIES"
  elif exists "$S3_NAME"; then
    fetch "$S3_NAME" "$S3_PATH"
    found=true
  fi
  [ "$found" = true ]
}

download() {
  [[ "$S3_NAME" =~ ^[A-Za-z0-9._*?-]+$ ]] || fail "name $S3_NAME may only contain letters, digits, dot, dash, underscore, * and ?"
  local id
  for id in "${RUN_IDS[@]}"; do
    BASE="$REPO/$id"
    if download_run; then
      echo "found=true" >> "$GITHUB_OUTPUT"
      echo "run-id=$id" >> "$GITHUB_OUTPUT"
      return
    fi
  done
  echo "found=false" >> "$GITHUB_OUTPUT"
  missing "No artifact $S3_NAME in $S3_BUCKET/$REPO/ for run ${RUN_IDS[*]}"
}

read -r -a RUN_IDS <<< "$(tr -s '[:space:],' ' ' <<< "$S3_RUN_ID")"
[ ${#RUN_IDS[@]} -gt 0 ] || fail "run-id is empty"
for id in "${RUN_IDS[@]}"; do
  [[ "$id" =~ ^[0-9]+$ ]] || fail "run-id $id is not a run id"
done
[ "$S3_MODE" != upload ] || [ ${#RUN_IDS[@]} -eq 1 ] || fail "upload takes exactly one run-id"
REPO="${S3_REPOSITORY:-${GITHUB_REPOSITORY#*/}}"
[[ "$REPO" =~ ^[A-Za-z0-9._-]+$ ]] || fail "repository $REPO is not a repository name"
BASE="$REPO/${RUN_IDS[0]}"
case "$S3_IF_NONE" in error | warn | ignore) ;; *) fail "if-no-files-found must be error, warn or ignore" ;; esac
case "$S3_ARCHIVE" in true | false) ;; *) fail "archive must be true or false" ;; esac

WORK=$(mktemp -d "$RUNNER_TEMP/s3-artifact.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
install_mcli
configure

case "$S3_MODE" in
  upload) upload ;;
  download) download ;;
  *) fail "mode must be upload or download" ;;
esac
