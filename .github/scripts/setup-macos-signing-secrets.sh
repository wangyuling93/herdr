#!/usr/bin/env bash

# Configure the GitHub environment values used to sign and notarize macOS
# release artifacts. Secret values are read interactively so they do not appear
# in shell history or the process list.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: setup-macos-signing-secrets.sh [options]

Options:
  --apple-id EMAIL        Apple Account email used for notarization.
  --environment NAME     GitHub environment to configure (default: codesigning).
  --p12 PATH             Exported Developer ID Application .p12 file.
  --repo OWNER/REPO      GitHub repository (default: detect from current checkout).
  --team-id TEAM_ID      Apple Developer Team ID (default: detect from .p12).
  --yes                  Skip the final confirmation prompt.
  -h, --help             Show this help.

The script securely prompts for the .p12 password and Apple app-specific
password. It intentionally does not accept those values as command-line
arguments, where they could be exposed in shell history or the process list.
EOF
}

repository=""
environment_name="codesigning"
p12_path=""
apple_id=""
team_id=""
skip_confirmation="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apple-id)
      apple_id="${2:-}"
      shift 2
      ;;
    --environment)
      environment_name="${2:-}"
      shift 2
      ;;
    --p12)
      p12_path="${2:-}"
      shift 2
      ;;
    --repo)
      repository="${2:-}"
      shift 2
      ;;
    --team-id)
      team_id="${2:-}"
      shift 2
      ;;
    --yes)
      skip_confirmation="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This setup script must run on macOS." >&2
  exit 1
fi

for command_name in base64 gh openssl tr; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command was not found: $command_name" >&2
    exit 1
  fi
done

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

if [[ -z "$repository" ]]; then
  if ! repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"; then
    echo "Could not detect the GitHub repository. Pass --repo OWNER/REPO." >&2
    exit 1
  fi
fi

if [[ ! "$repository" =~ ^[^/]+/[^/]+$ ]]; then
  echo "--repo must use the OWNER/REPO format, got: $repository" >&2
  exit 2
fi

if [[ -z "$environment_name" ]]; then
  echo "--environment cannot be empty." >&2
  exit 2
fi

if [[ -z "$p12_path" ]]; then
  if command -v osascript >/dev/null 2>&1; then
    echo "Select the exported Developer ID Application .p12 file."
    if ! p12_path="$(osascript -e 'POSIX path of (choose file with prompt "Select Developer ID Application .p12")')"; then
      echo "No .p12 file was selected." >&2
      exit 1
    fi
  else
    read -r -p "Path to Developer ID Application .p12: " p12_path
  fi
fi

if [[ "$p12_path" == "~/"* ]]; then
  p12_path="${HOME}/${p12_path#\~/}"
fi

if [[ ! -f "$p12_path" ]]; then
  echo ".p12 file does not exist: $p12_path" >&2
  exit 1
fi

if [[ ! -s "$p12_path" ]]; then
  echo ".p12 file is empty: $p12_path" >&2
  exit 1
fi

read -r -s -p "Password used when exporting the .p12: " p12_password
echo
if [[ -z "$p12_password" ]]; then
  echo ".p12 password cannot be empty." >&2
  exit 2
fi

cleanup() {
  if [[ -n "${p12_error_path:-}" ]]; then
    rm -f "$p12_error_path"
  fi
  unset p12_password app_specific_password
}
trap cleanup EXIT

read_certificate_subject() {
  local legacy_mode="$1"
  local -a pkcs12_args
  pkcs12_args=(
    pkcs12
    -in "$p12_path"
    -passin stdin
    -clcerts
    -nokeys
  )
  if [[ "$legacy_mode" == "true" ]]; then
    pkcs12_args+=(-legacy)
  fi

  printf '%s\n' "$p12_password" |
    openssl "${pkcs12_args[@]}" |
    openssl x509 -noout -subject -nameopt RFC2253
}

certificate_subject=""
p12_error_path="$(mktemp -t herdr-p12-error)"
if certificate_subject="$(read_certificate_subject false 2>"$p12_error_path")"; then
  :
else
  standard_error="$(<"$p12_error_path")"
  if certificate_subject="$(read_certificate_subject true 2>"$p12_error_path")"; then
    echo "The .p12 uses legacy encryption; compatibility mode succeeded."
  else
    legacy_error="$(<"$p12_error_path")"
    if [[ "$standard_error" == *"invalid password"* || "$legacy_error" == *"invalid password"* ]]; then
      echo "The .p12 rejected the supplied password." >&2
    else
      echo "Could not extract a certificate from the .p12." >&2
    fi
    echo "OpenSSL diagnostic:" >&2
    printf '%s\n' "$legacy_error" >&2
    echo "Try exporting the Developer ID Application certificate from Xcode again." >&2
    exit 1
  fi
fi

if [[ "$certificate_subject" != *"CN=Developer ID Application:"* ]]; then
  echo "The selected .p12 does not contain a Developer ID Application certificate." >&2
  echo "Certificate subject: $certificate_subject" >&2
  exit 1
fi

if [[ -z "$team_id" ]]; then
  team_id="$(printf '%s\n' "$certificate_subject" | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p')"
fi

if [[ -n "$team_id" && ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Apple Team ID must be 10 uppercase letters or digits, got: $team_id" >&2
  exit 2
fi

if [[ -z "$team_id" ]]; then
  read -r -p "Apple Developer Team ID: " team_id
fi

if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Apple Team ID must be 10 uppercase letters or digits." >&2
  exit 2
fi

if [[ -z "$apple_id" ]]; then
  read -r -p "Apple Account email used for notarization: " apple_id
fi

if [[ -z "$apple_id" || "$apple_id" != *@* ]]; then
  echo "A valid Apple Account email is required." >&2
  exit 2
fi

read -r -s -p "Apple app-specific password for notarization: " app_specific_password
echo
if [[ -z "$app_specific_password" ]]; then
  echo "Apple app-specific password cannot be empty." >&2
  exit 2
fi

echo
echo "GitHub repository:  $repository"
echo "GitHub environment: $environment_name"
echo "Apple Account:      $apple_id"
echo "Apple Team ID:      $team_id"
echo "Certificate:        $certificate_subject"
echo

if [[ "$skip_confirmation" != "true" ]]; then
  read -r -p "Upload these signing settings to GitHub? [y/N] " confirmation
  case "$confirmation" in
    y|Y|yes|YES) ;;
    *)
      echo "Cancelled. No GitHub settings were changed."
      exit 0
      ;;
  esac
fi

echo "Creating GitHub environment '$environment_name' if necessary..."
gh api \
  --method PUT \
  "repos/${repository}/environments/${environment_name}" \
  >/dev/null

echo "Uploading Developer ID certificate..."
base64 <"$p12_path" |
  tr -d '\r\n' |
  gh secret set APPLE_DEVELOPER_ID_P12 \
    --env "$environment_name" \
    --repo "$repository"

printf '%s' "$p12_password" |
  gh secret set APPLE_DEVELOPER_ID_P12_PASSWORD \
    --env "$environment_name" \
    --repo "$repository"

echo "Uploading notarization credential..."
printf '%s' "$app_specific_password" |
  gh secret set APPLE_APP_SPECIFIC_PASSWORD \
    --env "$environment_name" \
    --repo "$repository"

echo "Setting non-secret Apple account metadata..."
printf '%s' "$apple_id" |
  gh variable set APPLE_ID \
    --env "$environment_name" \
    --repo "$repository"

printf '%s' "$team_id" |
  gh variable set APPLE_TEAM_ID \
    --env "$environment_name" \
    --repo "$repository"

echo
echo "Configured GitHub secrets:"
gh secret list --env "$environment_name" --repo "$repository"
echo
echo "Configured GitHub variables:"
gh variable list --env "$environment_name" --repo "$repository"
echo
echo 'macOS signing settings are ready for the "Release macOS arm64 signed DMG" workflow.'
