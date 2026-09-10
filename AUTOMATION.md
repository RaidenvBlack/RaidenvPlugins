# Dalamud release automation

This repository contains the shared release implementation for the private
Dalamud plugin repositories. Plugin source remains in each private repository;
this repository receives only the validated release ZIPs, `repo.json`, icons,
and the small amount of automation/documentation required to publish them.

## Architecture

Each plugin repository has a small caller workflow. It invokes the reusable
workflow in `.github/workflows/dalamud-release.yml` by immutable commit SHA.
The reusable workflow delegates the implementation to the composite action in
`.github/actions/dalamud-release`.

The release sequence is:

1. Check out the exact event commit (or the released tag), never a moving branch
   tip.
2. Detect and validate the project, manifest, target framework, Dalamud SDK,
   Dalamud API level, and DalamudPackager configuration.
3. For a publishing run, calculate the requested version increment in memory.
4. Install the matching .NET SDK and download the official Dalamud development
   archive used by the official SamplePlugin workflow.
5. Restore with the committed NuGet lock file, build in `Release`, and run any
   configured console test projects.
6. Locate DalamudPackager's `latest.zip`, rename it to the configured ZIP name,
   and validate its paths, DLL, manifest, InternalName, assembly version,
   Dalamud API level, size, and SHA-256 hash.
7. Upload the validated ZIP as a workflow artifact, even for validation-only
   runs.
8. For a publishing run, commit the version files back to the source branch.
   A rerun recognizes an identical version commit from an earlier partial run.
9. Check out this central repository, replace the plugin ZIP, update only the
   release-managed fields in `repo.json`, validate the result, commit, and push.

Pull requests are validation-only. Pushes to the configured default branch and
published GitHub releases publish automatically. `workflow_dispatch` supports
an explicit manual run.

## Versioning

Automatic releases use a PATCH increment. Versions are stored in the .NET and
Dalamud-compatible form `MAJOR.MINOR.PATCH.0`; for example, `1.4.8.0` becomes
`1.4.9.0`. Existing non-zero fourth components are treated as legacy revisions
and reset to zero on the next semantic PATCH, MINOR, or MAJOR release.

Manual runs may select `patch`, `minor`, `major`, or `none`. Commit-message
inference (`fix`/`feat`/breaking change) is intentionally not enabled yet, so a
normal code push can never raise MINOR or MAJOR unexpectedly.

The package is rejected unless these values agree:

- project/assembly version;
- packaged Dalamud manifest `AssemblyVersion`;
- central `repo.json` `AssemblyVersion`;
- packaged and central `DalamudApiLevel`.

If the source manifest already contains `AssemblyVersion`, the workflow updates
it together with the project file. Otherwise DalamudPackager generates it from
the assembly. A source version commit uses `github-actions[bot]`, includes
`[skip ci]`, and is pushed with the repository `GITHUB_TOKEN`; GitHub does not
start another push workflow for that token, preventing release loops.

## Required secret

Every private plugin repository needs this Actions secret:

`CENTRAL_REPO_TOKEN`

Create a fine-grained personal access token under GitHub **Settings → Developer
settings → Personal access tokens → Fine-grained tokens** with:

- Resource owner: `RaidenvBlack`
- Repository access: **Only select repositories** → `RaidenvPlugins`
- Repository permission: **Contents: Read and write**
- All other optional repository and account permissions: **No access**
- A practical expiration date and rotation reminder

Then add it separately to each private plugin repository under **Settings →
Secrets and variables → Actions → New repository secret** using the exact name
`CENTRAL_REPO_TOKEN`. Do not put the token in source code, workflow YAML, an
issue, a pull request, or workflow input.

The caller's ordinary `GITHUB_TOKEN` is restricted to its own repository. It
needs `contents: write` only so a successful publishing run can store the
version bump. The cross-repository token can write only `RaidenvPlugins`; it
does not need Actions, Issues, Pull requests, Administration, or Packages
permission.

## Adding another plugin

The plugin must have a numeric `<Version>` in its `.csproj`, a valid Dalamud
manifest, and a working DalamudPackager configuration. Prefer
`Dalamud.NET.Sdk`. Commit `packages.lock.json` when the project uses NuGet lock
files.

Copy an existing caller workflow and change only these values in the common
case:

- `project-path`
- `internal-name`
- `zip-name`
- optional `test-projects`

Add `CENTRAL_REPO_TOKEN` to the new private repository. The first successful
publish adds a missing `repo.json` entry from the packaged manifest. Review that
new entry once to add or refine repository-only fields such as `IconUrl`, tags,
or custom description text.

## Manual release

Open the plugin repository's **Actions** tab, select **Build and publish
Dalamud plugin**, choose **Run workflow**, and select the default branch.

- Leave `publish` enabled for a real release.
- Choose `patch` for the normal release.
- Choose `minor` or `major` only intentionally.
- Choose `none` to rebuild the exact version, such as for a GitHub release tag.

Publishing a GitHub Release also builds the released tag with `bump: none` and
updates this repository after all validations pass. The central updater rejects
version downgrades, so publishing an older tag cannot roll the repository back.

## Failed runs

Open **Actions**, select the failed run, inspect the failed step, and choose
**Re-run failed jobs** after correcting the cause. Common failures are reported
explicitly: restore/build/test errors, missing `latest.zip`, inconsistent
versions or API levels, malformed manifests, missing credentials, and a central
push race. A push race is safe to rerun because the exact original source commit
is built again, an already-pushed source version is reused, and the ZIP/metadata
update is idempotent.

If branch protection is enabled later, allow GitHub Actions to write the version
commit or change the release process to a version-bump pull request. The current
plugin default branches are unprotected.

## Outputs and central metadata

Every successful build uploads one artifact named
`InternalName-Version`; it contains the final configured ZIP. Publishing copies
that same validated file to the root of `RaidenvPlugins`.

For an existing plugin, the automation preserves author, description, tags,
icons, visibility flags, counts, and other custom fields. It changes only:

- `AssemblyVersion`
- `DalamudApiLevel`
- `DownloadLinkInstall`
- `DownloadLinkUpdate`
- `DownloadLinkTesting`, when already present
- `TestingAssemblyVersion`, when already present

Download URLs use the canonical raw GitHub URL for the configured central
branch. The workflow verifies the copied ZIP hash and reparses `repo.json`
before it commits anything.

`.github/workflows/dalamud-automation-test.yml` checks PATCH calculation,
source-manifest consistency, preservation of non-release metadata, canonical
download links, ZIP hashes, and downgrade rejection on every relevant central
pull request.

## Managed repositories

| Plugin | Setup source → default | Baseline | .NET / API | Extra validation | Central ZIP |
|---|---|---|---|---|---|
| BlackjackSolver | `new1.6.2` → `master` | `1.6.2.0` | .NET 10 / API 15 | 34 recognition + 6 replay tests | `BlackjackSolver.zip` |
| LazyKindness | `Api15` → `master` | `1.0.3.5` | .NET 10 / API 15 | package validation | `Lazy.zip` |
| ZeroTweaks | `newnewera` → `main` | `1.1.0.10` | .NET 10 / API 15 | parser smoke test | `zero.zip` |

All three projects use `Dalamud.NET.Sdk/15.0.0`, its existing
DalamudPackager integration, and committed NuGet lock files. No project has a
`global.json` or shared `Directory.Build.props`, so the workflow derives the
.NET SDK channel directly from each target framework.

`EasyProfitGamble` and `DcNotify` remain unmanaged because no corresponding
source repository is available to the connected GitHub account. Their ZIPs and
metadata are left untouched.
