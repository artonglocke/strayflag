#!/usr/bin/env bash
# Entry point for the GitHub Action (action.yml). Builds the CLI from this
# checkout, runs it and exposes outputs. Exit code is the CLI's exit code.
set -uo pipefail

: "${GITHUB_ACTION_PATH:?}" "${RUNNER_TEMP:?}" "${GITHUB_OUTPUT:?}"
bin="$RUNNER_TEMP/strayflag-bin/strayflag"
if [[ ! -x "$bin" ]]; then
  mkdir -p "$(dirname "$bin")"
  (cd "$GITHUB_ACTION_PATH" && dart pub get --no-precompile >/dev/null && dart compile exe bin/strayflag.dart -o "$bin" >/dev/null) || {
    echo "::error::strayflag: could not build the CLI"; exit 2; }
fi

# Expand a glob such as build/ios/ipa/*.ipa; it must match exactly one artifact.
shopt -s nullglob
# shellcheck disable=SC2206
matches=($SF_PATH)
shopt -u nullglob
if [[ ${#matches[@]} -ne 1 ]]; then
  echo "::error::strayflag: path '$SF_PATH' matched ${#matches[@]} files; it must match exactly one artifact."
  exit 2
fi
artifact="${matches[0]}"

report="$RUNNER_TEMP/strayflag-report.json"
args=(scan "$artifact" --no-color --json-out "$report")
[[ -n "${SF_CONFIG:-}" ]] && args+=(--config "$SF_CONFIG")
[[ -n "${SF_BASELINE:-}" ]] && args+=(--baseline "$SF_BASELINE")
[[ -n "${SF_FAIL_ON:-}" ]] && args+=(--fail-on "$SF_FAIL_ON")
[[ -n "${SF_MIN_SEVERITY:-}" ]] && args+=(--min-severity "$SF_MIN_SEVERITY")
[[ "${SF_DEEP:-false}" == "true" ]] && args+=(--deep)
[[ -n "${SF_NOTES_OUT:-}" ]] && args+=(--notes-out "$SF_NOTES_OUT")
[[ "${SF_SUMMARY:-true}" == "true" && -n "${GITHUB_STEP_SUMMARY:-}" ]] && args+=(--markdown-out "$GITHUB_STEP_SUMMARY")

"$bin" "${args[@]}"
code=$?

if [[ -f "$report" ]]; then
  findings=$(sed -n 's/^  "finding_count": \([0-9]*\).*/\1/p' "$report")
  result=$([[ $code -eq 0 ]] && echo pass || echo fail)
  {
    echo "result=$result"
    echo "findings=$findings"
    echo "report=$report"
  } >> "$GITHUB_OUTPUT"
fi
if [[ $code -eq 1 ]]; then
  echo "::error::strayflag found undeclared debug/mock/unlock strings in $artifact. See the job summary."
fi
exit $code
