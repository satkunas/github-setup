#!/usr/bin/env bash
#set -x

# Cleanup function to kill background processes
cleanup() {
    # Kill any background processes from this script
    jobs -p | xargs -r kill 2>/dev/null || true
}

# Set up trap handlers for cleanup
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# A token exported by setup.sh must win over the value in `defaults`,
# which is only a placeholder until the user edits it.
GH_TOKEN_FROM_ENV="${GIT_TOKEN:-}"

GH_SCRIPT=$(realpath "$0")
GH_SCRIPTPATH=$(dirname "$GH_SCRIPT")

if [[ ! -f "$GH_SCRIPTPATH/defaults" && -f "$GH_SCRIPTPATH/defaults.example" ]]; then
  cp -p "$GH_SCRIPTPATH/defaults.example" "$GH_SCRIPTPATH/defaults"
fi

if [[ -f "$GH_SCRIPTPATH/defaults" ]]; then
  source "$GH_SCRIPTPATH/defaults"
elif [[ -f "$PWD/defaults" ]]; then
  source "$PWD/defaults"
fi

if [[ -n $GH_TOKEN_FROM_ENV ]]; then
  GIT_TOKEN="$GH_TOKEN_FROM_ENV"
fi

# Color codes
GREEN=$'\033[0;32m'
RED=$'\033[0;31m'
NC=$'\033[0m'

# Detect if running as root - only use sudo if not root
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

install_package() {
    local package="$1"
    if command -v apt-get >/dev/null; then
        if ! dpkg -l | grep -q "^ii  $package "; then
            echo "Installing $package..."
            $SUDO apt-get update -qq && $SUDO apt-get install -y "$package"
        fi
    elif command -v yum >/dev/null; then
        if ! rpm -q "$package" >/dev/null 2>&1; then
            echo "Installing $package..."
            $SUDO yum install -y "$package"
        fi
    else
        echo "Warning: No supported package manager found. Please install $package manually."
    fi
}

# "gh version 2.63.2 (2024-11-20)" -> 2.63.2
get_gh_version() {
    gh --version 2>/dev/null | head -n1 | awk '{print $3}'
}

gh_version_at_least() {
    local want_major=$1 want_minor=$2
    local ver major minor
    ver=$(get_gh_version)
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    [[ -z $major || $major == "gh" ]] && return 1
    [[ $major -gt $want_major ]] && return 0
    [[ $major -eq $want_major && $minor -ge $want_minor ]] && return 0
    return 1
}

gh_supports_flag() {
    gh auth login --help 2>/dev/null | grep -q -- "$1"
}

# Git resolves credential.helper=<name> to git-credential-<name>, searching
# `git --exec-path` first and then $PATH - checking only $PATH is not enough.
git_credential_helper_exists() {
    local name="$1"
    [[ -x "$(git --exec-path 2>/dev/null)/git-credential-$name" ]] && return 0
    command -v "git-credential-$name" >/dev/null 2>&1
}

# Remove a globally configured credential helper that cannot possibly run.
# git-credential-netrc is not packaged as an executable on Debian/Ubuntu, so a
# stale `credential.helper = netrc` prints an error on every authenticated git
# operation. Only the exact broken value is removed - a deliberately configured
# helper (store/cache/manager/osxkeychain) is left untouched.
remove_broken_credential_helper() {
    local name="$1"
    local rc

    git_credential_helper_exists "$name" && return 0

    if ! git config --global --get-all credential.helper 2>/dev/null | grep -qx "$name"; then
        return 0
    fi

    git config --global --unset-all credential.helper "^${name}\$"
    rc=$?
    if [[ $rc -eq 0 || $rc -eq 5 ]]; then
        echo "Removed broken global credential.helper=$name (git-credential-$name is not installed)"
    else
        echo "ERROR: could not remove global credential.helper=$name (git config exit $rc)"
    fi
}

install_gh_apt() {
    install_package "wget"
    $SUDO mkdir -p -m 755 /etc/apt/keyrings

    local tmp_keyring
    tmp_keyring=$(mktemp) || return 1
    if ! wget -qO "$tmp_keyring" https://cli.github.com/packages/githubcli-archive-keyring.gpg; then
        echo "ERROR: failed to download GitHub CLI keyring from cli.github.com"
        rm -f "$tmp_keyring"
        return 1
    fi
    $SUDO install -o root -g root -m 644 "$tmp_keyring" \
        /etc/apt/keyrings/githubcli-archive-keyring.gpg
    rm -f "$tmp_keyring"

    local arch
    arch=$(dpkg --print-architecture)
    echo "deb [arch=$arch signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null

    $SUDO apt-get update -qq && $SUDO apt-get install -y gh
}

install_gh_rpm() {
    if command -v dnf >/dev/null; then
        $SUDO dnf install -y 'dnf-command(config-manager)' >/dev/null 2>&1
        # dnf4 syntax first, dnf5 syntax as fallback
        $SUDO dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo 2>/dev/null \
          || $SUDO dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo
        $SUDO dnf install -y gh
    elif command -v yum >/dev/null; then
        $SUDO yum install -y yum-utils
        $SUDO yum-config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
        $SUDO yum install -y gh
    else
        return 1
    fi
}

# Real tokens are long: classic ghp_ + 36 chars, fine-grained github_pat_ + ~82.
# defaults.example ships the bare prefix `github_pat_`.
gh_token_is_usable() {
    local t="$1"
    t="${t//[$'\r\n\t ']/}"
    [[ -z $t ]] && return 1
    case "$t" in
        github_pat_|ghp_|gho_|ghs_|ghu_|github_pat_xxx*|ghp_xxx*|"<token>"|"your-token-here") return 1 ;;
    esac
    [[ ${#t} -lt 20 ]] && return 1
    return 0
}

echo "=== GitHub CLI Setup ==="

# Step 1: install or upgrade gh
GH_READY=false
if command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI already installed: $(get_gh_version)"
    GH_READY=true
    if ! gh_version_at_least 2 40; then
        echo "This looks like a distro package (Debian 12 ships gh 2.23.0 from 2023)."
        read -p "${GREEN}Upgrade gh from the official cli.github.com repo? (Y/[n]): ${NC}" -n 1 -r gh_upgrade_choice
        echo
        if [[ $gh_upgrade_choice =~ ^[Yy]$ ]]; then
            if command -v apt-get >/dev/null; then
                install_gh_apt
            else
                install_gh_rpm
            fi
            echo "GitHub CLI now: $(get_gh_version)"
        fi
    fi
else
    read -p "${GREEN}Install the GitHub CLI (gh)? ([Y]/n): ${NC}" -n 1 -r gh_install_choice
    echo
    if [[ -z $gh_install_choice || $gh_install_choice =~ ^[Yy]$ ]]; then
        echo "Installing GitHub CLI (gh)..."
        if command -v apt-get >/dev/null; then
            install_gh_apt
        elif command -v dnf >/dev/null || command -v yum >/dev/null; then
            install_gh_rpm
        else
            echo "Warning: No supported package manager found."
            echo "Please install gh manually: https://github.com/cli/cli#installation"
        fi

        if command -v gh >/dev/null 2>&1; then
            GH_READY=true
            echo "Installed gh $(get_gh_version)"
        else
            echo "ERROR: gh installation failed"
        fi
    fi
fi

if [[ $GH_READY != true ]]; then
    echo "=== GitHub CLI Setup Incomplete ==="
    exit 1
fi

# Step 2: check for an existing login
if [[ -n ${GH_TOKEN:-}${GITHUB_TOKEN:-} ]]; then
    echo "Warning: GH_TOKEN/GITHUB_TOKEN is set in the environment."
    echo "         gh will use it and refuse 'gh auth login'."
    echo "         Unset it and re-run to store credentials instead."
fi

GH_AUTHED=false
if gh auth status --hostname github.com >/dev/null 2>&1; then
    gh_login=$(gh api user -q .login 2>/dev/null)
    echo "Already authenticated to github.com${gh_login:+ as $gh_login}"
    GH_AUTHED=true
    read -p "${GREEN}Re-authenticate github.com? (Y/[n]): ${NC}" -n 1 -r gh_reauth_choice
    echo
    if [[ $gh_reauth_choice =~ ^[Yy]$ ]]; then
        GH_AUTHED=false
    fi
fi

# Step 3: resolve a usable token
GIT_TOKEN="${GIT_TOKEN//[$'\r\n\t ']/}"

GH_PREFER_WEB=false

if [[ $GH_AUTHED != true ]]; then
    if gh_token_is_usable "$GIT_TOKEN"; then
        echo "Using GIT_TOKEN from defaults (${GIT_TOKEN:0:7}...${GIT_TOKEN: -4})"
        if [[ -t 0 ]]; then
            echo "A browser login grants gh's standard scopes (repo, read:org, gist)."
            echo "A fine-grained PAT cannot reach some endpoints - 'gh status' fails on it."
            read -p "${GREEN}Authenticate in a browser instead of using this token? (Y/[n]): ${NC}" -n 1 -r gh_prefer_web_choice
            echo
            if [[ $gh_prefer_web_choice =~ ^[Yy]$ ]]; then
                GH_PREFER_WEB=true
            fi
        fi
        if [[ $GH_PREFER_WEB != true ]]; then
            read -p "${GREEN}Use a different token? (Y/[n]): ${NC}" -n 1 -r gh_token_change
            echo
            if [[ $gh_token_change =~ ^[Yy]$ ]]; then
                read -s -p "${RED}GitHub PAT (input hidden, leave empty to skip): ${NC}" gh_token_input
                echo
                [[ -n $gh_token_input ]] && GIT_TOKEN="$gh_token_input"
            fi
        fi
    else
        echo "No usable GIT_TOKEN found in defaults (value is the placeholder '${GIT_TOKEN}')."
        read -s -p "${RED}GitHub PAT (input hidden, leave empty to use browser login): ${NC}" gh_token_input
        echo
        GIT_TOKEN="$gh_token_input"
    fi
fi

# Step 4: authenticate
# gh cannot authenticate with an SSH or GPG key - the GitHub API is token-only.
# --git-protocol ssh only decides the protocol for remotes gh creates, and
# --skip-ssh-key stops gh uploading a second key (setup.sh already uploads one).
GH_AUTH_OK=false
GH_LOGIN_OUTPUT=""

if [[ $GH_AUTHED == true ]]; then
    GH_AUTH_OK=true
elif [[ $GH_PREFER_WEB != true ]] && gh_token_is_usable "$GIT_TOKEN"; then
    echo "Authenticating gh with the supplied token..."
    login_args=(--hostname github.com --with-token --git-protocol ssh)
    gh_supports_flag "--skip-ssh-key" && login_args+=(--skip-ssh-key)

    GH_LOGIN_OUTPUT=$(printf '%s' "$GIT_TOKEN" | gh auth login "${login_args[@]}" 2>&1)
    GH_LOGIN_RC=$?

    if [[ $GH_LOGIN_RC -eq 0 ]]; then
        GH_VERIFY_OUTPUT=$(gh api user -q .login 2>&1)
        GH_VERIFY_RC=$?
        if [[ $GH_VERIFY_RC -eq 0 && -n $GH_VERIFY_OUTPUT ]]; then
            echo "Authenticated to github.com as $GH_VERIFY_OUTPUT"
            GH_AUTH_OK=true
        else
            GH_LOGIN_OUTPUT="$GH_VERIFY_OUTPUT"
        fi
    fi
fi

if [[ $GH_AUTH_OK != true && -n $GH_LOGIN_OUTPUT ]]; then
    if echo "$GH_LOGIN_OUTPUT" | grep -qi "missing required scope"; then
        echo "ERROR: gh rejected the token. Classic PATs must include the 'read:org' scope;"
        echo "       fine-grained PATs are often rejected here. Use browser login instead."
    elif echo "$GH_LOGIN_OUTPUT" | grep -qiE "bad credentials|HTTP 401"; then
        echo "ERROR: gh login failed: the token is invalid, revoked or expired."
    elif echo "$GH_LOGIN_OUTPUT" | grep -qi "SAML enforcement"; then
        echo "ERROR: gh login failed: an organization requires SAML SSO authorization for this token."
        echo "       Authorize it at https://github.com/settings/tokens then re-run."
    elif echo "$GH_LOGIN_OUTPUT" | grep -qiE "HTTP 403|resource not accessible"; then
        echo "ERROR: gh login failed: the token lacks the permissions gh needs."
    elif echo "$GH_LOGIN_OUTPUT" | grep -qiE "no such host|dial tcp|connection refused|timeout|TLS|certificate"; then
        echo "ERROR: gh login failed: cannot reach github.com (network/proxy/TLS problem)."
    else
        echo "ERROR: gh login failed: $GH_LOGIN_OUTPUT"
    fi
fi

# Step 5: browser (device code) fallback
if [[ $GH_AUTH_OK != true ]]; then
    if [[ ! -t 0 ]]; then
        echo "ERROR: browser login requires an interactive terminal. Re-run from a TTY."
    else
        gh_web_choice="y"
        if [[ $GH_PREFER_WEB != true ]]; then
            read -p "${GREEN}Authenticate gh in a browser instead (device flow)? (Y/[n]): ${NC}" -n 1 -r gh_web_choice
            echo
        fi
        if [[ $gh_web_choice =~ ^[Yy]$ ]]; then
            echo "gh will print a one-time code and a URL (https://github.com/login/device)."
            echo "Open it on any machine with a browser and enter the code."
            web_args=(--hostname github.com --web --git-protocol ssh)
            gh_supports_flag "--skip-ssh-key" && web_args+=(--skip-ssh-key)
            if gh auth login "${web_args[@]}"; then
                gh_login=$(gh api user -q .login 2>/dev/null)
                echo "Authenticated to github.com${gh_login:+ as $gh_login}"
                GH_AUTH_OK=true
            else
                echo "ERROR: browser authentication failed or was cancelled."
            fi
        fi
    fi
fi

# Clear token from memory
GIT_TOKEN=""
gh_token_input=""

# Step 6: let gh serve git credentials for HTTPS GitHub URLs
if [[ $GH_AUTH_OK == true ]]; then
    remove_broken_credential_helper "netrc"

    if gh auth setup-git --hostname github.com; then
        echo "git configured to use gh as the credential helper for github.com (HTTPS URLs)"
    else
        echo "ERROR: 'gh auth setup-git' failed; HTTPS git operations will prompt for credentials."
    fi

    echo
    echo "=== GitHub CLI Summary ==="
    echo "Version:   $(get_gh_version)"
    echo "Account:   $(gh api user -q .login 2>/dev/null)"
    echo "Protocol:  $(gh config get git_protocol 2>/dev/null)"
    echo "Storage:   system keyring if available, otherwise ~/.config/gh/hosts.yml"
    echo
    echo "Credentials persist across logins - no ~/.bashrc hook is needed."
    echo "=== GitHub CLI Setup Complete ==="
else
    echo "=== GitHub CLI Setup Incomplete (not authenticated) ==="
fi
