# s3-artifact

Hands build results between jobs and workflows through the bucket `sniffa-ci` on Silo (`https://s3.sniffa.studio`)
instead of GitHub artifacts. GitHub's artifact storage is limited on the Free plan and ran full; Silo is ours and has
no quota. Objects expire after 7 days (bucket lifecycle rule).

Keys: `<repo>/<run_id>/<name>.tar.zst`, or `<repo>/<run_id>/<name>/<file>` with `archive: "false"`.

Every repository that uses it needs the secrets `CI_S3_ACCESS_KEY`, `CI_S3_SECRET_KEY` and the variable
`CI_S3_ENDPOINT`. The key may only read and write `sniffa-ci` (Silo user and policy `sniffa-ci`, keys in
`/opt/silo/clients/sniffa-ci/` on sniffa-base). The action downloads a pinned `mcli` (pgsty/mc) and checks its
checksum; it needs a Linux x64 runner with `zstd` and `jq`.

## Between jobs of one run

```yaml
- uses: sniffa-studio/.github/actions/s3-artifact@main
  with:
    mode: upload
    name: install
    path: build/install
    endpoint: ${{ vars.CI_S3_ENDPOINT }}
    access-key: ${{ secrets.CI_S3_ACCESS_KEY }}
    secret-key: ${{ secrets.CI_S3_SECRET_KEY }}

- uses: sniffa-studio/.github/actions/s3-artifact@main
  with:
    mode: download
    name: install
    path: build/install
    endpoint: ${{ vars.CI_S3_ENDPOINT }}
    access-key: ${{ secrets.CI_S3_ACCESS_KEY }}
    secret-key: ${{ secrets.CI_S3_SECRET_KEY }}
```

A single directory is stored without its own name, so `path` on download is where its contents land. Several paths
or globs keep their paths relative to the workspace. Hidden files and file modes are kept.

| Input | Default | |
|---|---|---|
| `mode` | | `upload` or `download` |
| `name` | | Artifact name. On download `*` and `?` fetch every match into `<path>/<name>/` |
| `path` | `.` | Upload: paths or globs, one per line. Download: target folder |
| `archive` | `true` | `false` stores the files one by one, for direct downloads |
| `link` | `false` | Upload: download links valid for 7 days in the job summary |
| `if-no-files-found` | `error` | `error`, `warn` or `ignore`; on download it applies to a missing artifact |
| `run-id` | current run | Another run, for artifacts of other workflows. Download takes several ids and uses the first run that has the artifact |
| `repository` | current repository | |

Outputs: `key`, `found` and `run-id` (download), `url` (upload with `link`).

## From another workflow

Find the run the usual way and pass its id, or several ids to take the newest run that still has the artifact:

```bash
run=$(gh run list -w api-contract.yml -b main -s success -L 1 --json databaseId -q '.[0].databaseId')
```

```yaml
- uses: sniffa-studio/.github/actions/s3-artifact@main
  with:
    mode: download
    name: openapi-main
    run-id: ${{ steps.find.outputs.run }}
    if-no-files-found: ignore
    ...
```

## By hand

Jars for people get `archive: "false"` and `link: "true"`; the job summary then lists a link per file, valid for
7 days: `curl -fLo <file> '<link>'`.

On sniffa-base without a link, with the copy of `mcli` the org runner keeps after its first use of the action:

```bash
MCLI=/home/github-runner/actions-runner/_work/_tool/sniffa-mcli/RELEASE.2026-10-26T00-00-00Z/mcli
export MC_HOST_ci="https://$(cat /opt/silo/clients/sniffa-ci/access-key):$(cat /opt/silo/clients/sniffa-ci/secret-key)@s3.sniffa.studio"
$MCLI ls -r ci/sniffa-ci/<repo>/<run_id>/
$MCLI cp -r ci/sniffa-ci/<repo>/<run_id>/<name>/ /tmp/<name>/
$MCLI share download --expire 168h ci/sniffa-ci/<repo>/<run_id>/<name>/<file>
```
