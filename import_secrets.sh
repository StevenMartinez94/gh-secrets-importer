#!/bin/bash

# --- Load Configuration from .env file (optional if variables are already exported) ---
if [ -f ".env" ]; then
    set -a
    source .env
    set +a
fi

if [ -z "$OWNER" ] || [ -z "$YAML_FILE" ]; then
    echo "Error: OWNER and YAML_FILE must be set (in .env or the environment)."
    echo "You can copy .env.example: cp .env.example .env"
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

echo "Starting GitHub configuration import..."
echo "Repository: $FULL_REPO"
echo "YAML File: $YAML_FILE"

# Flatten YAML groups into one JSON object per item. Groups may be either a list
# of single-key maps (- NAME: value) or a plain map (NAME: value).
ENTRIES=$(jq -c '
    def pairs: if type == "array" then .[] | to_entries[]
               elif type == "object" then to_entries[]
               else empty end;
    ( (.["repository-secrets"] // empty | pairs)
        | {kind: "secret", scope: "repository", env: "", name: .key, value: .value} ),
    ( (.["repository-variables"] // empty | pairs)
        | {kind: "variable", scope: "repository", env: "", name: .key, value: .value} ),
    ( (.["environment-secrets"] // {} | to_entries[])
        | .key as $env | (.value | pairs)
        | {kind: "secret", scope: "environment", env: $env, name: .key, value: .value} ),
    ( (.["environment-variables"] // {} | to_entries[])
        | .key as $env | (.value | pairs)
        | {kind: "variable", scope: "environment", env: $env, name: .key, value: .value} )
' <<<"$YAML_JSON") || { echo "Error: unexpected YAML structure."; exit 1; }

SUCCESSFUL=()
UNSUCCESSFUL=()
SEEN_ENVS=" "
FAILED_ENVS=" "

# Create (or update, idempotently) an environment before setting its items.
ensure_environment() {
    local env_name="$1" encoded
    encoded=$(jq -rn --arg e "$env_name" '$e | @uri')
    SEEN_ENVS+="$env_name "
    if gh api --method PUT "repos/${FULL_REPO}/environments/${encoded}" --silent; then
        echo "Environment ready: $env_name"
    else
        echo "ERROR: could not create environment '$env_name'."
        FAILED_ENVS+="$env_name "
    fi
}

while IFS= read -r ENTRY; do
    [ -z "$ENTRY" ] && continue
    SCOPE=$(jq -r '.scope' <<<"$ENTRY")
    KIND=$(jq -r '.kind' <<<"$ENTRY")
    ENV_NAME=$(jq -r '.env' <<<"$ENTRY")
    NAME=$(jq -r '.name' <<<"$ENTRY")
    VALUE=$(jq -j '.value | if type == "string" then . else tojson end' <<<"$ENTRY")
    IS_NULL=$(jq -r '.value == null' <<<"$ENTRY")

    if [ "$SCOPE" = "repository" ]; then
        LABEL="$NAME (repository $KIND)"
        ARGS=("$KIND" set "$NAME" --repo "$FULL_REPO")
    else
        LABEL="$NAME (environment: $ENV_NAME, $KIND)"
        ARGS=("$KIND" set "$NAME" --repo "$FULL_REPO" --env "$ENV_NAME")
        case "$SEEN_ENVS" in *" $ENV_NAME "*) ;; *) ensure_environment "$ENV_NAME" ;; esac
    fi

    echo ""
    echo "Processing: $LABEL"

    if [ "$SCOPE" = "environment" ] && [[ "$FAILED_ENVS" == *" $ENV_NAME "* ]]; then
        UNSUCCESSFUL+=("$LABEL (environment could not be created)")
        continue
    fi

    if [ "$IS_NULL" = "true" ] || { [ "$KIND" = "secret" ] && [ -z "$VALUE" ]; }; then
        echo "ERROR: empty value for $LABEL."
        UNSUCCESSFUL+=("$LABEL (null value or empty secret)")
        continue
    fi

    # Values are passed via stdin so they never appear in the process list.
    if printf '%s' "$VALUE" | gh "${ARGS[@]}"; then
        SUCCESSFUL+=("$LABEL")
    else
        UNSUCCESSFUL+=("$LABEL (gh secret set failed)")
    fi
done <<<"$ENTRIES"

echo ""
echo "=================================================="
echo "Import summary"
echo "Items set (${#SUCCESSFUL[@]}):"
if [ ${#SUCCESSFUL[@]} -eq 0 ]; then echo "  None"; else printf '  - %s\n' "${SUCCESSFUL[@]}"; fi
echo "Items not set (${#UNSUCCESSFUL[@]}):"
if [ ${#UNSUCCESSFUL[@]} -eq 0 ]; then echo "  None"; else printf '  - %s\n' "${UNSUCCESSFUL[@]}"; fi

[ ${#UNSUCCESSFUL[@]} -eq 0 ]
