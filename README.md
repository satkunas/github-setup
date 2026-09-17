# github-setup

This script configures GPG and SSH for GIT, and optionally the GitHub CLI (`gh`), for the current user on the local host.

## Create GIT_TOKEN

 * Visit https://github.com/settings/personal-access-tokens/new
 * Expiration: Any - this token will only be used once and can be removed after setup.
 * Account Permissions:
   * GPG keys: Read & Write
   * Git SSH keys: Read & Write
   * SSH Signing keys: Read & Write

`gh` is stricter than the REST uploads this script performs. A **classic** PAT must
include the `read:org` scope or `gh auth login --with-token` rejects it outright, and a
**fine-grained** PAT may be rejected or only partly functional. If the token is refused,
`setup-gh-client.sh` offers browser (device-code) login instead, which needs no token.

![Screenshot 2025-07-07 at 3 34 41 PM](https://github.com/user-attachments/assets/c1e84ab2-1a89-4a65-9ee8-2ebcaf78b3e1)

## Configure

Copy the example defaults, and enter your `GIT_EMAIL`, `GIT_NAME` and `GIT_TOKEN`.

```bash
cp -p defaults.example defaults
vi defaults
```

## Usage

```bash
bash setup.sh
```

The GitHub CLI is the final optional step of `setup.sh`, and can also be run on its own:

```bash
bash setup-gh-client.sh
```

## GitHub CLI (gh)

`setup-gh-client.sh` adds the official `cli.github.com` package repository (Debian 12's own
package is gh 2.23.0, from 2023), installs or upgrades `gh`, authenticates it, and runs
`gh auth setup-git`.

**`gh` cannot authenticate with an SSH or GPG key.** GitHub's API is token-only, so `gh`
uses the `GIT_TOKEN` from `defaults` or a browser device-code flow. `--git-protocol ssh`
only chooses the protocol for remotes `gh` creates - it is not an authentication method,
and GPG keys have no authentication role at all. The script passes `--skip-ssh-key`
because `setup.sh` already generates *and* uploads the SSH key.

### Fine-grained PAT limits

A fine-grained PAT authenticates `gh` and works for most commands, but some GitHub REST
endpoints accept **classic** tokens only. The notifications API is one, so `gh status`
fails even though the login itself is fine:

```bash
gh status
could not load notifications: could not get notifications: HTTP 403:
Resource not accessible by personal access token
```

There is no fine-grained permission that enables this - the endpoints
["only support authentication using a personal access token (classic)"](https://docs.github.com/en/rest/activity/notifications)
and require the `notifications` or `repo` scope. Either ignore it (everything else works),
or re-authenticate with the browser flow, which grants `gh`'s standard scopes
(`repo`, `read:org`, `gist`):

```bash
gh auth login --hostname github.com --git-protocol ssh --skip-ssh-key --web
```

That replaces the stored token for `gh` only - `defaults` and the GPG/SSH key uploads,
which do need the fine-grained permissions, are unaffected.

**Authentication persists across logins with no shell hook.** `gh` stores credentials in
the system keyring when one is available, otherwise in `~/.config/gh/hosts.yml` (mode 600).
Nothing is appended to `~/.bashrc` and `GH_TOKEN` does not need to be exported. If
`GH_TOKEN` or `GITHUB_TOKEN` *is* set in the environment, `gh` uses it and refuses
`gh auth login`.

```bash
gh auth status
gh auth logout --hostname github.com
```

## Credential helper

Earlier versions of `setup.sh` set `credential.helper = netrc` globally. Debian and Ubuntu
ship `git-credential-netrc` only as Perl source under `/usr/share/doc/git/contrib`, never as
an executable, so every authenticated git operation printed:

```
git: 'credential-netrc' is not a git command. See 'git --help'.
```

Both scripts now remove that specific value when the helper binary is absent from
`git --exec-path` and `$PATH`; a deliberately configured helper (`store`, `cache`,
`manager`, `osxkeychain`) is left alone.

## GIT Remote

The git remote for the repo must use `ssh` rather than `https`.

```bash
git remote -v
origin  ssh://github.com/satkunas/github-setup.git (fetch)
origin  ssh://github.com/satkunas/github-setup.git (push)

# change
git remote set-url origin ssh://github.com/satkunas/github-setup.git
```

`gh auth setup-git` affects `https://github.com/...` URLs only - SSH remotes never consult a
credential helper, so this requirement is unchanged.

## SAML

If SAML is required, click "Configure SSO" on the newly created SSH key.

A SAML-protected organization also requires authorizing the *token*, not just the SSH key,
before `gh` API calls succeed. `setup-gh-client.sh` surfaces this as
`ERROR: ... requires SAML SSO authorization`.

See: https://docs.github.com/en/enterprise-cloud@latest/authentication/authenticating-with-saml-single-sign-on/authorizing-an-ssh-key-for-use-with-saml-single-sign-on
