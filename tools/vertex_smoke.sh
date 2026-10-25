#!/usr/bin/env bash
# Usage: tools/vertex_smoke.sh [MODEL_ID]   (default: GEMMA_MODEL_ID from Config/Config.xcconfig)
# Exit codes: 0 text received, 1 request/API failure, 2 key missing, 3 no text in a 200 response.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
secrets="$root/Config/Secrets.xcconfig"
config="$root/Config/Config.xcconfig"

xcconfig_value() {
  local name="$1" file="$2" line value
  [ -f "$file" ] || return 0
  line="$(grep -E "^[[:space:]]*${name}[[:space:]]*=" "$file" | tail -n 1 || true)"
  value="${line#*=}"
  value="${value%%//*}"
  value="$(printf '%s' "$value" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/')"
  printf '%s' "$value"
}

key="$(xcconfig_value VERTEX_API_KEY "$secrets")"
if [ -z "$key" ]; then
  echo "VERTEX_API_KEY is missing or empty in Config/Secrets.xcconfig (copy Config/Secrets.example.xcconfig and paste the key)." >&2
  exit 2
fi

model="${1:-$(xcconfig_value GEMMA_MODEL_ID "$config")}"
if [ -z "$model" ]; then
  echo "No model id: pass one as an argument or set GEMMA_MODEL_ID in Config/Config.xcconfig." >&2
  exit 1
fi

redact() {
  local text="$1"
  printf '%s' "${text//"$key"/[REDACTED]}"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/request.json" <<'JSON'
{
  "contents": [
    {"role": "user", "parts": [{"text": "In one short sentence, what is the constellation Orion known for?"}]}
  ],
  "generationConfig": {"maxOutputTokens": 512, "temperature": 0.2}
}
JSON

project="$(xcconfig_value GCP_PROJECT_ID "$config")"
location="$(xcconfig_value GEMMA_LOCATION "$config")"
if [ "$model" = "$(xcconfig_value GEMMA_MODEL_ID "$config")" ] && [ -n "$project" ] && [ -n "$location" ]; then
  url="https://aiplatform.googleapis.com/v1/projects/${project}/locations/${location}/publishers/google/models/${model}:streamGenerateContent?alt=sse"
else
  url="https://aiplatform.googleapis.com/v1/publishers/google/models/${model}:streamGenerateContent?alt=sse"
fi
echo "Model: $model"

set +e
status="$(curl --silent --show-error --max-time 90 \
  --output "$tmp/body.txt" --write-out '%{http_code}' \
  -H @<(printf 'x-goog-api-key: %s\n' "$key") \
  -H 'Content-Type: application/json' \
  --data-binary @"$tmp/request.json" \
  "$url" 2> "$tmp/curl.err")"
curl_exit=$?
set -e

if [ "$curl_exit" -ne 0 ]; then
  echo "curl failed (exit $curl_exit): $(redact "$(cat "$tmp/curl.err")")" >&2
  exit 1
fi

body="$(cat "$tmp/body.txt")"
if [ "$status" != "200" ]; then
  echo "HTTP $status" >&2
  redact "$body" >&2
  echo >&2
  exit 1
fi

text=""
while IFS= read -r line; do
  line="${line%$'\r'}"
  case "$line" in
    "data: "*) json="${line#data: }" ;;
    *) continue ;;
  esac
  printf '%s' "$json" > "$tmp/event.json"
  i=0
  # plutil appends one newline to raw output; the trailing "x" keeps $(...) from also eating newlines in the text.
  while part_text="$(plutil -extract "candidates.0.content.parts.$i.text" raw -o - "$tmp/event.json" 2>/dev/null && printf x)"; do
    part_text="${part_text%x}"
    part_text="${part_text%$'\n'}"
    if [ "$(plutil -extract "candidates.0.content.parts.$i.thought" raw -o - "$tmp/event.json" 2>/dev/null || echo false)" != "true" ]; then
      text+="$part_text"
    fi
    i=$((i + 1))
  done
  if error_message="$(plutil -extract error.message raw -o - "$tmp/event.json" 2>/dev/null)"; then
    echo "Stream error: $(redact "$error_message")" >&2
    exit 1
  fi
done < "$tmp/body.txt"

if [ -z "$text" ]; then
  echo "HTTP 200 but no text in the stream. Raw body:" >&2
  redact "$body" >&2
  echo >&2
  exit 3
fi

printf '%s\n' "$text"
