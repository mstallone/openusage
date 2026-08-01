---
name: release-swift
description: Cut a stable release of Runway (Swift menu-bar app): pick a version, generate a categorized changelog, tag from `main`, and publish the GitHub Release with notes.
---

# Release Swift

Pushing a `v*` tag on `main` runs `.github/workflows/release.yml`, which builds, signs, notarizes, attaches `Runway-<version>.dmg` to the GitHub Release, and updates the Sparkle `appcast.xml` on `update-feed`. The same run's independent **iOS TestFlight** job builds the iOS companion app at the tag's version and uploads it to App Store Connect, where TestFlight distributes it to internal testers automatically after processing; a follow-up **TestFlight External** job then adds the processed build to the external tester group(s) and submits it for Beta App Review. CI creates the release with an EMPTY body, so this skill generates the changelog, records it in `CHANGELOG.md`, and publishes the notes onto the release.

Runway has one stable release channel. Tags use `vMAJOR.MINOR.PATCH`; suffixed prerelease tags are
rejected. The tag is the version (`v0.7.1` becomes `CFBundleShortVersionString = 0.7.1`), and
`CFBundleVersion` is the git commit count. There are no version files to bump.

## Cutting a release

### 1. Choose the version

Propose the next stable version (default bump: patch) and confirm it with the owner before proceeding.

### 2. Generate the changelog

Collect commits since the **previous stable release** and categorize each. The inherited history
contains old beta tags, so do not use the nearest tag blindly: span from the last plain stable tag
(e.g. `v0.7.0...v0.7.1`) so all intervening commits are included.

| Commit prefix | Category |
|---|---|
| `feat`, `feature`, or starts with "Add" | New Features |
| `fix` or starts with "Fix" | Bug Fixes |
| `refactor`, `enhance` | Refactor |
| `chore`, `style`, `docs`, `perf`, `test`, `ci`, `build` | Chores |
| Uncategorized | Bug Fixes |

Author attribution (required on every entry):

- With a PR number `(#123)`, resolve the PR from the commit rather than assuming its repository:

  ```sh
  gh api "repos/mstallone/runway/commits/{full_hash}/pulls" \
    --jq 'map(select(.number == {pr}))[0] |
      if . == null then null else {url: .html_url, author: .user.login} end'
  ```

  Use the returned `url` and `author`. This is required for the first fork release because its range
  contains inherited upstream PRs. The endpoint also returns fork PRs for commits merged in this
  repository, so overlapping PR-number namespaces are handled by commit provenance.
- Without a PR number: `gh api /repos/mstallone/runway/commits/{full_hash} -q '.author.login'`.
- If the PR lookup returns null, omit the PR link and use the commit attribution lookup. If that API
  also returns null, fall back to the git author name.

Output the changelog in a code block (template below) for review.

### 3. Owner approval

Wait for explicit approval of the changelog before changing any files. Accept edits if offered.

### 4. Record it in CHANGELOG.md

Prepend the approved section right after the `# Changelog` header. Commit on `main`:

```sh
git switch main && git pull
git add CHANGELOG.md && git commit -m "docs: changelog for v{version}"
```

### 5. Tag and push

```sh
git tag -a v{version} -m "v{version}"
git push origin main
git push origin v{version}
```

### 6. Publish the notes

CI creates the release with an empty body, so attach the approved notes after it finishes:

```sh
gh run watch
gh release view v{version} >/dev/null 2>&1   # confirm CI created the release
gh release edit v{version} --notes-file /tmp/notes-v{version}.md
```

Never leave a release blank.

A failed first-release run is safe to rerun. If the GitHub Release for the current tag was published
but the appcast was not, the workflow rebuilds the fresh feed only when that tag is the fork's sole
release. If any older release history exists while `appcast.xml` is missing, it aborts rather than
silently dropping prior Sparkle entries.

### 7. Verify (never leave a draft)

```sh
gh release view v{version} --json isDraft,isPrerelease,assets,body \
  --jq '{isDraft, isPrerelease, assets:[.assets[].name], bodyLen:(.body|length)}'
git fetch origin update-feed && git show origin/update-feed:appcast.xml | grep -F "Runway-{version}.dmg"
curl -s "https://mstallone.github.io/runway/appcast.xml" | grep -F "Runway-{version}.dmg"
```

The second check matters: publishing is two hops — Release (or pricing-supplement) pushes `appcast.xml` to the **`update-feed` branch**, then **`.github/workflows/deploy-update-feed.yml` on `main`** deploys that branch to the live site (Pages source is "GitHub Actions", not legacy branch deploy). Auto deploy runs on `workflow_run` after Release completes; GitHub sometimes returns **"Deployment failed, try again later"** even though `update-feed` is already correct. If the branch has the version but the live URL does not after ~10 minutes, check `gh run list --workflow=deploy-update-feed.yml` and re-run **`gh workflow run deploy-update-feed.yml --ref main`** (must use `main` — the workflow file is not on `update-feed`). Sparkle clients only see the live URL.

Require `isDraft=false`, `isPrerelease=false`, `Runway-<version>.dmg` and
`Runway-<version>.dmg.sha256` assets, `bodyLen>0`, and the version present in the appcast.

Also confirm the two iOS jobs in the same run succeeded (`gh run view` shows all jobs):

- **iOS TestFlight** green means the build was uploaded; TestFlight pushes it to internal testers
  on its own once Apple finishes processing (minutes).
- **TestFlight External** green means the processed build was added to the external group(s) and
  submitted for Beta App Review — external testers receive it when Apple approves (hours to ~a
  day; visible in App Store Connect → TestFlight). Approval is Apple-side; nothing to babysit.

An iOS-only failure does not invalidate the Mac release: fix the cause and rerun just the failed
job (`gh run rerun <run-id> --failed`). That is always safe for **TestFlight External** (it is
idempotent), but for **iOS TestFlight** only if the upload itself never happened — a rerun after
a successful upload is rejected as a duplicate build number, and the fix then ships with the next
tag instead. If a
draft was left behind, migrate its notes/assets onto the published release, then delete it — but only
once a separate PUBLISHED release for the tag already exists:

```sh
tag="v{version}"
if [ "$(gh release view "$tag" --json isDraft --jq '.isDraft')" = "false" ]; then
  gh api repos/mstallone/runway/releases --paginate \
    --jq '.[] | select(.draft and .tag_name=="'"$tag"'") | .id' \
    | xargs -I{} gh api -X DELETE repos/mstallone/runway/releases/{}
else
  echo "No published release for $tag yet - publish it first; do NOT delete the draft."
fi
```

## Changelog template

Only include category sections that have entries.

~~~markdown
## v{version}

### New Features
- {message} ([#{pr}]({pr_url})) by @{author}

### Bug Fixes
- {message} ([#{pr}]({pr_url})) by @{author}

### Refactor
- {message} by @{author}

### Chores
- {message} by @{author}

---

### Changelog
**Full Changelog**: [{prev_tag}...v{version}](https://github.com/mstallone/runway/compare/{prev_tag}...v{version})

- [{short_hash}](https://github.com/mstallone/runway/commit/{full_hash}) {commit message} by @{author}
~~~

`{prev_tag}` is the previous plain stable release tag. Ignore inherited suffixed beta tags when
selecting it.

## Rules

- 7-char short commit hashes; tags always prefixed with `v`.
- Release tags are plain `vMAJOR.MINOR.PATCH`; never create a suffixed prerelease tag.
- Changelogs span the previous stable release to the new stable release.
- Never push or tag automatically — ask the owner first.
- Always publish notes to the GitHub Release — never blank.
- The version is the tag; never edit version files.
- The appcast is append-only so older installs keep working; the workflow aborts rather than shrink it.

Release secrets and one-time setup live in the README under [Release setup](../../../README.md#release-setup-one-time).
