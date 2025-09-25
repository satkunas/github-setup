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
# Try 'gnupg' first (more common on older systems), fall back to 'gpg'
if command -v apt-get >/dev/null; then
    if ! command -v gpg >/dev/null 2>&1; then
        if ! dpkg -l | grep -q "^ii  gnupg "; then
            echo "Installing gnupg..."
            sudo apt-get update -qq && sudo apt-get install -y gnupg >/dev/null 2>&1
        fi
        # If gnupg didn't provide gpg command, try installing gpg package
        if ! command -v gpg >/dev/null 2>&1; then
            install_package "gpg"
        fi
    fi
else
    install_package "gpg"
fi
install_package "git"

# Function to check available entropy
check_entropy() {
    if [[ -r /proc/sys/kernel/random/entropy_avail ]]; then
        cat /proc/sys/kernel/random/entropy_avail
    else
        echo "1000"  # assume sufficient entropy if can't check
    fi
}

# Function to get appropriate entropy threshold based on OS and kernel version
get_entropy_threshold() {
    local kernel_version=$(uname -r | cut -d. -f1-2)
    local major=$(echo $kernel_version | cut -d. -f1)
    local minor=$(echo $kernel_version | cut -d. -f2)

    # Detect OS version for older systems that struggle with entropy
    local os_version=""
    if [[ -f /etc/debian_version ]]; then
        os_version=$(cat /etc/debian_version | cut -d. -f1)
    elif [[ -f /etc/redhat-release ]]; then
        os_version=$(grep -o '[0-9]\+' /etc/redhat-release | head -1)
    fi

    # Use much lower thresholds for older OS versions that struggle with entropy
    if [[ -n "$os_version" && "$os_version" -le 7 ]]; then
        echo "300"  # Very low threshold for old OS versions (Debian 7, RHEL 7, etc.)
    elif [[ $major -lt 4 ]]; then
        echo "400"  # Low threshold for very old kernels
    elif [[ $major -eq 4 ]] || [[ $major -eq 5 && $minor -lt 10 ]]; then
        echo "500"  # Medium threshold for older kernels
    else
        echo "200"  # Use 200 as threshold for modern kernels (5.10+)
    fi
}

# Function to improve entropy for older systems
improve_entropy_for_old_systems() {
    local version=$(gpg --version 2>/dev/null | head -n1 | sed 's/gpg (GnuPG) //' || echo "1.4.0")
    local gpg_major=$(echo $version | cut -d. -f1)
    local gpg_minor=$(echo $version | cut -d. -f2)

    # Handle empty or invalid version numbers
    if [[ -z "$gpg_major" ]] || [[ "$gpg_major" == "gpg" ]]; then
        gpg_major=1
        gpg_minor=4
    fi

    # Check if we're on an older OS that struggles with entropy
    local os_version=""
    if [[ -f /etc/debian_version ]]; then
        os_version=$(cat /etc/debian_version | cut -d. -f1)
    elif [[ -f /etc/redhat-release ]]; then
        os_version=$(grep -o '[0-9]\+' /etc/redhat-release | head -1)
    fi

    # Improve entropy for older GPG versions OR older OS versions
    local should_improve=false
    if [[ $gpg_major -lt 2 ]] || [[ $gpg_major -eq 2 && $gpg_minor -eq 0 ]]; then
        should_improve=true  # Older GPG versions need entropy
    elif [[ -n "$os_version" && "$os_version" -le 7 ]]; then
        should_improve=true  # Older OS versions struggle with entropy
    fi

    if [[ "$should_improve" == "true" ]]; then
        local entropy=$(check_entropy)
        local threshold=$(get_entropy_threshold)
        if [[ $entropy -lt $threshold ]]; then
            echo "Low entropy ($entropy) detected for older GPG version. Improving entropy..."

            # Try multiple entropy improvement methods
            # Install haveged for better entropy generation
            install_package "haveged"
            if command -v haveged >/dev/null 2>&1; then
                sudo service haveged start >/dev/null 2>&1 || sudo systemctl start haveged >/dev/null 2>&1 || true
            else
                echo "haveged not available, trying rng-tools..."
            fi

            # Also install rng-tools as backup (more likely to be available on older systems)
            install_package "rng-tools"
            if command -v rngd >/dev/null 2>&1; then
                sudo rngd -r /dev/urandom >/dev/null 2>&1 &
            else
                echo "rng-tools not available, using manual entropy generation..."
            fi

            # Generate some entropy manually
            echo "Generating additional entropy..."
            dd if=/dev/urandom of=/dev/random count=1 bs=4096 >/dev/null 2>&1 &

            # Wait for entropy to build up, tracking if it stops increasing
            local previous_entropy=0
            local stagnant_count=0
            # Be more patient with older systems - allow more time for entropy to build
            local max_stagnant=10
            if [[ -n "$os_version" && "$os_version" -le 7 ]]; then
                max_stagnant=15  # Even more patience for very old systems
            fi

            while true; do
                local current_entropy=$(check_entropy)
                echo "Current entropy: $current_entropy/$threshold"

                if [[ $current_entropy -gt $threshold ]]; then
                    echo "Sufficient entropy achieved: $current_entropy"
                    break
                fi

                # Check if entropy has increased
                if [[ $current_entropy -le $previous_entropy ]]; then
                    stagnant_count=$((stagnant_count + 1))
                    if [[ $stagnant_count -ge $max_stagnant ]]; then
                        echo "Warning: Entropy appears to have stopped increasing (current: $current_entropy)"
                        echo "Continuing with GPG generation despite low entropy..."
                        break
                    fi
                else
                    stagnant_count=0  # Reset counter when entropy increases
                fi

                previous_entropy=$current_entropy
                sleep 2
            done
        fi
    fi
}

# Function to get GPG version and determine appropriate command
get_gpg_command() {
    local version=$(gpg --version 2>/dev/null | head -n1 | sed 's/gpg (GnuPG) //' || echo "1.4.0")
    local major=$(echo $version | cut -d. -f1)
    local minor=$(echo $version | cut -d. -f2)
    local patch=$(echo $version | cut -d. -f3)

    # Handle empty or invalid version numbers
    if [[ -z "$major" ]] || [[ "$major" == "gpg" ]]; then
        # Very old GPG or parsing failed, assume 1.4
        echo "--gen-key"
        return
    fi

    # Version comparison logic
    if [[ $major -lt 2 ]]; then
        # GPG 1.x - very common on Debian 7
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
    local version=$(gpg --version 2>/dev/null | head -n1 | sed 's/gpg (GnuPG) //' || echo "1.4.0")
    local major=$(echo $version | cut -d. -f1)
    local minor=$(echo $version | cut -d. -f2)

    # Handle empty or invalid version numbers
    if [[ -z "$major" ]] || [[ "$major" == "gpg" ]]; then
        major=1
        minor=4
    fi

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
EOF

    # Handle passphrase configuration based on GPG version
    if [[ $major -lt 2 ]] || [[ $major -eq 2 && $minor -eq 0 ]]; then
        # For older GPG versions (1.x and 2.0.x), use %no-ask-passphrase
        cat >>~/.gnupg/conf <<EOF
%no-ask-passphrase
%no-protection
EOF
    else
        # For newer GPG versions, use empty passphrase
        cat >>~/.gnupg/conf <<EOF
Passphrase:
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
    # Improve entropy before generation if using older systems
    improve_entropy_for_old_systems

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






