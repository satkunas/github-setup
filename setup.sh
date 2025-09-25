#!/usr/bin/env bash
#set -x
if [[ ! -f defaults ]]; then
  cp -p defaults.example defaults
fi
source $PWD/defaults

GIT_DOTDIR=$PWD/.git
HOSTNAME=$(hostname)

if [[ $# -gt 0 ]]; then
  SCRIPT=$(realpath "$0")
  SCRIPTPATH=$(dirname "$SCRIPT")
  GIT_DOTDIR=$SCRIPTPATH/.git
fi

if [[ ! -d $GIT_DOTDIR ]]; then
  echo "Not a GIT directory $GIT_DOTDIR"
  exit
fi

echo "Using GIT directory $GIT_DOTDIR"
git config core.editor "vi"

read -e -p "GIT email: " -i $GIT_EMAIL GIT_EMAIL
read -e -p "GIT name: " -i $GIT_NAME GIT_NAME
# write:gpg_key
read -e -p "GIT fine-grained PAT: " -i $GIT_TOKEN GIT_TOKEN

# Function to install packages based on OS
install_package() {
    local package="$1"
    if command -v apt-get >/dev/null; then
        # Debian/Ubuntu
        if ! dpkg -l | grep -q "^ii  $package "; then
            echo "Installing $package..."
            sudo apt-get update -qq && sudo apt-get install -y "$package"
        fi
    elif command -v yum >/dev/null; then
        # RHEL/CentOS
        if ! rpm -q "$package" >/dev/null 2>&1; then
            echo "Installing $package..."
            sudo yum install -y "$package"
        fi
    else
        echo "Warning: No supported package manager found. Please install $package manually."
    fi
}

# Install required packages
install_package "gpg"
install_package "git"

# Function to check available entropy
check_entropy() {
    if [[ -r /proc/sys/kernel/random/entropy_avail ]]; then
        cat /proc/sys/kernel/random/entropy_avail
    else
        echo "1000"  # assume sufficient entropy if can't check
    fi
}

# Function to improve entropy for older GPG versions
improve_entropy_for_old_gpg() {
    local version=$(gpg --version | head -n1 | sed 's/gpg (GnuPG) //')
    local major=$(echo $version | cut -d. -f1)
    local minor=$(echo $version | cut -d. -f2)

    # Only improve entropy for older GPG versions that use --gen-key
    if [[ $major -lt 2 ]] || [[ $major -eq 2 && $minor -eq 0 ]]; then
        local entropy=$(check_entropy)
        if [[ $entropy -lt 1000 ]]; then
            echo "Low entropy ($entropy) detected for older GPG version. Improving entropy..."

            # Try multiple entropy improvement methods
            if command -v apt-get >/dev/null; then
                # Install haveged for better entropy generation
                if ! dpkg -l | grep -q "^ii  haveged "; then
                    echo "Installing haveged..."
                    sudo apt-get update -qq && sudo apt-get install -y haveged >/dev/null 2>&1
                    sudo service haveged start >/dev/null 2>&1
                fi

                # Also install rng-tools as backup
                if ! dpkg -l | grep -q "^ii  rng-tools "; then
                    echo "Installing rng-tools..."
                    sudo apt-get install -y rng-tools >/dev/null 2>&1
                fi
                sudo rngd -r /dev/urandom >/dev/null 2>&1 &
            elif command -v yum >/dev/null; then
                if ! rpm -q haveged >/dev/null 2>&1; then
                    echo "Installing haveged..."
                    sudo yum install -y haveged >/dev/null 2>&1
                    sudo service haveged start >/dev/null 2>&1
                fi
                if ! rpm -q rng-tools >/dev/null 2>&1; then
                    echo "Installing rng-tools..."
                    sudo yum install -y rng-tools >/dev/null 2>&1
                fi
                sudo rngd -r /dev/urandom >/dev/null 2>&1 &
            fi

            # Generate some entropy manually
            echo "Generating additional entropy..."
            dd if=/dev/urandom of=/dev/random count=1 bs=4096 >/dev/null 2>&1 &

            # Wait longer for entropy to build up
            local max_wait=30
            local waited=0
            while [[ $waited -lt $max_wait ]]; do
                local current_entropy=$(check_entropy)
                echo "Current entropy: $current_entropy (waiting for >1000)"
                if [[ $current_entropy -gt 1000 ]]; then
                    echo "Sufficient entropy achieved: $current_entropy"
                    break
                fi
                sleep 2
                waited=$((waited + 2))
            done
        fi
    fi
}

# Function to get GPG version and determine appropriate command
get_gpg_command() {
    local version=$(gpg --version | head -n1 | sed 's/gpg (GnuPG) //')
    local major=$(echo $version | cut -d. -f1)
    local minor=$(echo $version | cut -d. -f2)
    local patch=$(echo $version | cut -d. -f3)

    # Version comparison logic
    if [[ $major -lt 2 ]]; then
        # GPG 1.x
        echo "--gen-key"
    elif [[ $major -eq 2 && $minor -eq 0 ]]; then
        # GPG 2.0.x
        echo "--gen-key"
    elif [[ $major -eq 2 && $minor -eq 1 ]]; then
        if [[ ${patch:-0} -lt 17 ]]; then
            # GPG 2.1.0 - 2.1.16
            echo "--full-gen-key"
        else
            # GPG 2.1.17+
            echo "--full-generate-key"
        fi
    else
        # GPG 2.2+ (assume supports --full-generate-key)
        echo "--full-generate-key"
    fi
}

# Function to generate GPG configuration based on version
generate_gpg_config() {
    local version=$(gpg --version | head -n1 | sed 's/gpg (GnuPG) //')
    local major=$(echo $version | cut -d. -f1)
    local minor=$(echo $version | cut -d. -f2)

    cat >~/.gnupg/conf <<EOF
%echo GPG generating...
Key-Type: RSA
Key-Length: 2048
Subkey-Type: RSA
Subkey-Length: 2048
Name-Real: $GIT_NAME
Name-Comment: $GIT_NAME
Name-Email: $GIT_EMAIL
Expire-Date: 0
Passphrase:
EOF

    # Add version-specific configuration for older GPG
    if [[ $major -lt 2 ]] || [[ $major -eq 2 && $minor -eq 0 ]]; then
        cat >>~/.gnupg/conf <<EOF
%no-protection
EOF
    fi

    # Add version-specific keyring configuration
    if [[ $major -lt 2 ]] || [[ $major -eq 2 && $minor -eq 0 ]]; then
        # GPG 1.x and 2.0.x use separate pub/sec rings
        cat >>~/.gnupg/conf <<EOF
%pubring pubring.gpg
%secring secring.gpg
EOF
    else
        # GPG 2.1+ uses keybox format, no secring
        cat >>~/.gnupg/conf <<EOF
%pubring pubring.kbx
EOF
    fi

    cat >>~/.gnupg/conf <<EOF
%commit
%echo GPG done
EOF
}

# Initialize GPG directory and trustdb
initialize_gpg() {
    mkdir -p ~/.gnupg
    chmod 700 ~/.gnupg

    # Remove corrupted trustdb if it exists
    if [[ -f ~/.gnupg/trustdb.gpg ]]; then
        echo "Removing existing trustdb..."
        rm -f ~/.gnupg/trustdb.gpg
    fi

    # Initialize trustdb
    gpg --check-trustdb 2>/dev/null || true
}

gpg --list-keys
initialize_gpg
cd ~/.gnupg/

###
# https://www.gnupg.org/documentation/manuals/gnupg-devel/Unattended-GPG-key-generation.html
###
generate_gpg_config
# Generate GPG key with version-appropriate command and fallback
generate_gpg_key() {
    # Improve entropy before generation if using older GPG version
    improve_entropy_for_old_gpg

    local commands=("$(get_gpg_command)" "--full-generate-key" "--full-gen-key" "--gen-key")

    for cmd in "${commands[@]}"; do
        echo "Trying GPG command: $cmd"

        # Use timeout to prevent hanging
        if timeout 300 gpg --verbose $cmd --batch ~/.gnupg/conf; then
            echo "Successfully generated GPG key using: $cmd"
            return 0
        else
            local exit_code=$?
            if [[ $exit_code -eq 124 ]]; then
                echo "Command $cmd timed out after 5 minutes"
            else
                echo "Command $cmd failed with exit code $exit_code"
            fi
            echo "Trying next command..."
        fi
    done

    echo "ERROR: All GPG key generation commands failed"
    echo "This might be due to insufficient entropy. Try running the script again or install additional entropy sources."
    exit 1
}

generate_gpg_key

GPG_SIGNINGKEY=$(gpg --list-secret-keys --keyid-format=long| sed -En 's/sec\s+.*\/([0-9A-F]+)\s+.*/\1/p')
GPG_PUBLICKEY=$(gpg --armor --export $GPG_SIGNINGKEY)
GPG_PUBLICKEY_ESCAPED=${GPG_PUBLICKEY//$'\n'/\\n}

curl -L \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GIT_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/user/gpg_keys \
  --data @<(cat <<EOF
  {
    "name":"GPG Key: $HOSTNAME",
    "armored_public_key":"$GPG_PUBLICKEY_ESCAPED"
  }
EOF
)

cat << EOF > ~/.gitconfig
[credential]
  helper = netrc

[user]
  email = $GIT_EMAIL
  name = $GIT_NAME
  signingkey = $GPG_SIGNINGKEY

[pull]
  ff = only

[alias]
  up = "!git remote update -p; git merge --ff-only @{u}"
  ready = rebase -i @{u}

[commit]
  gpgSign = true

[gpg]
  program = gpg

[format]
  signoff = true
EOF

touch ~/.bashrc
if [[ -z $(grep "export GPG_TTY=\$(tty)" ~/.bashrc) ]]; then
  echo "export GPG_TTY=\$(tty)" >> ~/.bashrc
fi
if [[ -z $(grep "export HISTFILESIZE=" ~/.bashrc) ]]; then
  echo "export HISTFILESIZE=65536" >> ~/.bashrc
fi
if [[ -z $(grep "export HISTSIZE=" ~/.bashrc) ]]; then
  echo "export HISTSIZE=65536" >> ~/.bashrc
fi
source ~/.bashrc

eval "$(ssh-agent -s)"

# Try ED25519 first, fall back to RSA if not supported
KEY_FILE=""
if [[ ! -f ~/.ssh/id_ed25519_github ]]; then
  if ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f ~/.ssh/id_ed25519_github 2>/dev/null; then
    KEY_FILE="~/.ssh/id_ed25519_github"
    ssh-add ~/.ssh/id_ed25519_github
  elif [[ ! -f ~/.ssh/id_rsa_github ]]; then
    echo "ED25519 not supported, falling back to RSA"
    ssh-keygen -t rsa -b 4096 -C "$GIT_EMAIL" -f ~/.ssh/id_rsa_github
    KEY_FILE="~/.ssh/id_rsa_github"
    ssh-add ~/.ssh/id_rsa_github
  fi
elif [[ ! -f ~/.ssh/id_rsa_github ]]; then
  KEY_FILE="~/.ssh/id_ed25519_github"
  ssh-add ~/.ssh/id_ed25519_github
else
  KEY_FILE="~/.ssh/id_rsa_github"
  ssh-add ~/.ssh/id_rsa_github
fi

# Determine which key to use for GitHub
if [[ -f ~/.ssh/id_ed25519_github.pub ]]; then
  SSH_PUBLICKEY=$(cat ~/.ssh/id_ed25519_github.pub)
  SSH_KEY_TYPE="ED25519"
elif [[ -f ~/.ssh/id_rsa_github.pub ]]; then
  SSH_PUBLICKEY=$(cat ~/.ssh/id_rsa_github.pub)
  SSH_KEY_TYPE="RSA"
else
  echo "No SSH key found!"
  exit 1
fi

curl -L \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GIT_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/user/keys \
  --data @<(cat <<EOF
  {
    "title":"SSH Key: $HOSTNAME",
    "key":"$SSH_PUBLICKEY"
  }
EOF
)

touch ~/.ssh/config
mkdir -p ~/.ssh/config.d
if [[ -z $(grep "Include config.d/github" ~/.ssh/config) ]]; then
  echo "Include config.d/github" >> ~/.ssh/config;
  cat << EOF > ~/.ssh/config.d/github
Host *
        AddKeysToAgent yes
        #UseKeychain yes
        IdentityFile ~/.ssh/id_ed25519_github
        IdentityFile ~/.ssh/id_rsa_github

Host github.com
        Hostname ssh.github.com
        Port 443
        User git
EOF
fi






