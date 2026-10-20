#!/bin/bash

# --- Load Configuration from .env file ---
if [ ! -f ".env" ]; then
    echo "Error: .env file not found."
    echo "Please create a .env file. You can copy from .env.example:"
    echo "  cp .env.example .env"
    exit 1
fi

set -a
source .env
set +a

if [ -z "$OWNER" ] || [ -z "$YAML_FILE" ]; then
    echo "Error: OWNER and YAML_FILE must be set in .env file."
    exit 1
fi

for cmd in gh yq jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: '$cmd' is required but not installed."
        exit 1
    fi
done

if [ ! -f "$YAML_FILE" ]; then
    echo "Error: YAML file '$YAML_FILE' not found."
    exit 1
fi

# Repository can come from the YAML ("repository:") or the .env (REPO).
YAML_JSON=$(yq -o=json '.' "$YAML_FILE") || { echo "Error: invalid YAML in '$YAML_FILE'."; exit 1; }
REPO_NAME="${REPO:-$(jq -r '.repository // empty' <<<"$YAML_JSON")}"
if [ -z "$REPO_NAME" ]; then
    echo "Error: no repository specified (set 'repository:' in the YAML file or REPO in .env)."
    exit 1
fi
case "$REPO_NAME" in
    */*) FULL_REPO="$REPO_NAME" ;;
    *)   FULL_REPO="${OWNER}/${REPO_NAME}" ;;
esac

echo "Starting GitHub secrets import..."
echo "Repository: $FULL_REPO"
echo "YAML File: $YAML_FILE"

# Flatten the YAML into one JSON object per secret. Secret groups may be either
# a list of single-key maps (- NAME: value) or a plain map (NAME: value).
ENTRIES=$(jq -c '
    def pairs: if type == "array" then .[] | to_entries[]
               elif type == "object" then to_entries[]
               else empty end;
    ( (.["repository-secrets"] // empty | pairs)
        | {scope: "repository", env: "", name: .key, value: .value} ),
    ( (.["environment-secrets"] // {} | to_entries[])
        | .key as $env | (.value | pairs)
        | {scope: "environment", env: $env, name: .key, value: .value} )
' <<<"$YAML_JSON") || { echo "Error: unexpected YAML structure."; exit 1; }

SUCCESSFUL=()
UNSUCCESSFUL=()

while IFS= read -r ENTRY; do
    [ -z "$ENTRY" ] && continue
    SCOPE=$(jq -r '.scope' <<<"$ENTRY")
    ENV_NAME=$(jq -r '.env' <<<"$ENTRY")
    NAME=$(jq -r '.name' <<<"$ENTRY")
    VALUE=$(jq -j '.value | if type == "string" then . else tojson end' <<<"$ENTRY")

    if [ "$SCOPE" = "repository" ]; then
        LABEL="$NAME (repository)"
        ARGS=(secret set "$NAME" --repo "$FULL_REPO")
    else
        LABEL="$NAME (environment: $ENV_NAME)"
        ARGS=(secret set "$NAME" --repo "$FULL_REPO" --env "$ENV_NAME")
    fi

    echo ""
    echo "Processing: $LABEL"

    if [ "$VALUE" = "null" ] || [ -z "$VALUE" ]; then
        echo "ERROR: empty value for $LABEL."
        UNSUCCESSFUL+=("$LABEL (empty value)")
        continue
    fi

    # Value is passed via stdin so it never appears in the process list.
    if printf '%s' "$VALUE" | gh "${ARGS[@]}"; then
        SUCCESSFUL+=("$LABEL")
    else
        UNSUCCESSFUL+=("$LABEL (gh secret set failed)")
    fi
done <<<"$ENTRIES"

echo ""
echo "=================================================="
echo "Import summary"
echo "Secrets set (${#SUCCESSFUL[@]}):"
if [ ${#SUCCESSFUL[@]} -eq 0 ]; then echo "  None"; else printf '  - %s\n' "${SUCCESSFUL[@]}"; fi
echo "Secrets not set (${#UNSUCCESSFUL[@]}):"
if [ ${#UNSUCCESSFUL[@]} -eq 0 ]; then echo "  None"; else printf '  - %s\n' "${UNSUCCESSFUL[@]}"; fi

[ ${#UNSUCCESSFUL[@]} -eq 0 ]
