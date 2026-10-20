# GitHub Secrets Importer

A bash script that imports secrets from a YAML file into a GitHub repository, either as **repository secrets** or **environment secrets** (per environment).

## Prerequisites

- [GitHub CLI](https://cli.github.com/) (`gh`), authenticated (`gh auth login`)
- [`yq`](https://github.com/mikefarah/yq) (mikefarah v4) and [`jq`](https://jqlang.github.io/jq/)
- Admin access to the target repository; environments must already exist

## Configuration

```bash
cp .env.example .env
```

```bash
OWNER="your-github-username"   # Owner used when the repository has no "owner/" prefix
YAML_FILE="secrets.yaml"       # Path to your secrets file
# REPO="your-repo"             # Optional, overrides "repository:" in the YAML
```

## YAML format

```yaml
repository: my-repo   # or owner/repo

repository-secrets:
  - SECRET_1: VALUE_1
  - SECRET_2: VALUE_2

environment-secrets:
  environment-name-1:
    - SECRET_3: VALUE_3
  environment-name-2:
    - SECRET_4: VALUE_4
```

Both sections are optional. A plain map (`SECRET_1: VALUE_1`) is accepted in place of the list form. See `example.secrets.yaml`.

## Usage

```bash
cp example.secrets.yaml secrets.yaml   # then edit
./import_secrets.sh
```

Values are sent to `gh secret set` through stdin. `.env` and `secrets.yaml` are git-ignored; never commit real secrets.

## License

MIT
