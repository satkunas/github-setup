#!/usr/bin/env bash
#set -x

# Cleanup function to kill background processes
cleanup() {
    # Kill entropy generation processes
    pkill -f "dd.*urandom.*random" 2>/dev/null || true
    pkill -f "sha256sum" 2>/dev/null || true
    pkill -f "md5sum" 2>/dev/null || true

    # Kill entropy services we might have started
    sudo pkill rngd 2>/dev/null || true
    sudo pkill haveged 2>/dev/null || true

    # Kill any other background processes from this script
    jobs -p | xargs -r kill 2>/dev/null || true
}

# Set up trap handlers for cleanup
trap cleanup EXIT
trap cleanup INT
trap cleanup TERM
trap cleanup HUP
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

# Simple entropy threshold
get_entropy_threshold() {
    echo "200"  # Fixed low threshold since we proceed anyway
}


# Simplified entropy generation function
generate_entropy() {

    # Kill any existing entropy generation processes to avoid conflicts
    cleanup

    # Method 1: Basic dd processes for immediate entropy
    dd if=/dev/urandom of=/dev/random count=5 bs=1024 >/dev/null 2>&1 &

    # Method 2: System information entropy
    (
        cat /proc/cpuinfo /proc/meminfo /proc/loadavg /proc/uptime >/dev/null 2>&1
        for i in {1..20}; do
            echo "$(date +%s%N)$RANDOM" | sha256sum | cut -d' ' -f1 > /dev/random 2>/dev/null || true
            sleep 0.1
        done
    ) &

    # Method 3: Hardware sources if available
    for hwrng in /dev/hwrng /dev/hw_random; do
        if [[ -r "$hwrng" ]]; then
            timeout 3 dd if="$hwrng" of=/dev/random bs=512 count=5 >/dev/null 2>&1 &
        fi
    done 2>/dev/null || true

}


# Simple entropy improvement function
improve_entropy() {
    # Start basic entropy generation
    generate_entropy

    # Install common entropy tools
    install_package "haveged" 2>/dev/null || true
    install_package "rng-tools" 2>/dev/null || true

    # Start services if available
    if command -v haveged >/dev/null 2>&1; then
        sudo systemctl start haveged 2>/dev/null || sudo service haveged start 2>/dev/null || true
    fi
    if command -v rngd >/dev/null 2>&1; then
        sudo rngd -r /dev/urandom -o /dev/random -t 1 >/dev/null 2>&1 &
    fi

    # Brief wait for entropy to improve
    sleep 5
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

    # Use standard key size
    local key_length=2048

    cat >~/.gnupg/conf <<EOF
%echo GPG generating...
Key-Type: RSA
Key-Length: $key_length
Subkey-Type: RSA
Subkey-Length: $key_length
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
# Function to prepare GPG environment
prepare_gpg_environment() {
    # Ensure GPG directory has correct permissions
    chmod 700 ~/.gnupg 2>/dev/null || true

    # Remove any existing gpg.conf that might conflict
    rm -f ~/.gnupg/gpg.conf 2>/dev/null || true

    # Create minimal gpg.conf only if needed
    local version=$(gpg --version 2>/dev/null | head -n1 | sed 's/gpg (GnuPG) //' || echo "1.4.0")
    local major=$(echo $version | cut -d. -f1)

    # Skip gpg.conf creation for GPG 1.x - not needed and can cause issues
    # if [[ $major -eq 1 ]]; then
    #     cat > ~/.gnupg/gpg.conf <<EOF
    # # Minimal GPG 1.x configuration
    # cert-digest-algo SHA256
    # EOF
    # fi
}

# Generate GPG key with version-appropriate command and fallback
generate_gpg_key() {
    # Improve entropy before generation if using older systems
    improve_entropy

    # Prepare GPG environment
    prepare_gpg_environment

    # Keep entropy generation running during GPG generation
    local entropy_pid=""
    local os_version=""
    if [[ -f /etc/debian_version ]]; then
        os_version=$(cat /etc/debian_version | cut -d. -f1)
    fi


    local commands=("$(get_gpg_command)" "--full-generate-key" "--full-gen-key" "--gen-key")
    local success=false

    for cmd in "${commands[@]}"; do


        # Set environment variables for low entropy systems
        export GNUPGHOME=~/.gnupg

        # Use reasonable timeout for GPG generation
        local timeout_duration=300  # 5 minutes timeout

        # Use appropriate flags for GPG version
        local gpg_flags="$cmd --batch $HOME/.gnupg/conf"

        if timeout $timeout_duration gpg $gpg_flags >/dev/null 2>&1; then
            success=true
            break
        else
            local exit_code=$?

            if [[ $exit_code -eq 124 ]]; then
                # For timeout, try regenerating entropy before next attempt
                generate_entropy
                sleep 3
            fi
        fi
    done


    if [[ "$success" != "true" ]]; then
        echo "ERROR: GPG key generation failed"
        exit 1
    fi
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






