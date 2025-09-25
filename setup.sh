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

# Consolidated GPG version detection function
get_gpg_version() {
    local version=$(gpg --version 2>/dev/null | head -n1 | sed 's/gpg (GnuPG) //' || echo "1.4.0")
    local major=$(echo $version | cut -d. -f1)
    local minor=$(echo $version | cut -d. -f2)

    # Handle empty or invalid version numbers
    if [[ -z "$major" ]] || [[ "$major" == "gpg" ]]; then
        major=1
        minor=4
    fi

    # Return version components
    echo "$major.$minor"
}

# Function to generate GPG configuration based on version
generate_gpg_config() {
    local gpg_ver=$(get_gpg_version)
    local major=$(echo $gpg_ver | cut -d. -f1)
    local minor=$(echo $gpg_ver | cut -d. -f2)

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
    if [[ $major -eq 1 ]]; then
        # GPG 1.4.x - omit passphrase entirely, will use empty passphrase by default
        # Don't add any passphrase line - just a no-op
        true
    elif [[ $major -eq 2 && $minor -eq 0 ]]; then
        # GPG 2.0.x - supports %no-ask-passphrase
        cat >>~/.gnupg/conf <<EOF
%no-ask-passphrase
%no-protection
EOF
    else
        # For GPG 2.1.x+, use empty passphrase
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


    # Detect GPG version for proper command selection
    local gpg_ver=$(get_gpg_version)
    local major=$(echo $gpg_ver | cut -d. -f1)
    local minor=$(echo $gpg_ver | cut -d. -f2)

    local success=false

    # Set environment variables for low entropy systems
    export GNUPGHOME=~/.gnupg

    # Use reasonable timeout for GPG generation
    local timeout_duration=300  # 5 minutes timeout

    # Version-specific command execution
    if [[ $major -eq 1 ]]; then
        # GPG 1.4.x - NO --batch support, try basic --gen-key first
        local gpg_flags="--gen-key"
        # Install expect if needed for GPG 1.4.12 automation
        install_package "expect"

        # GPG 1.4.12 requires expect for full automation
        if command -v expect >/dev/null 2>&1; then
            if timeout $timeout_duration expect -c "
                spawn gpg --gen-key
                expect {
                    \"Your selection?\" { send \"1\r\"; exp_continue }
                    \"What keysize do you want?\" { send \"2048\r\"; exp_continue }
                    \"Key is valid for?\" { send \"0\r\"; exp_continue }
                    \"Is this correct?\" { send \"y\r\"; exp_continue }
                    \"Real name:\" { send \"$GIT_NAME\r\"; exp_continue }
                    \"Email address:\" { send \"$GIT_EMAIL\r\"; exp_continue }
                    \"Comment:\" { send \"\r\"; exp_continue }
                    \"Change (N)ame\" { send \"O\r\"; exp_continue }
                    \"You need a Passphrase\" { send \"\r\"; exp_continue }
                    \"Enter passphrase:\" { send \"\r\"; exp_continue }
                    \"Repeat passphrase:\" { send \"\r\"; exp_continue }
                    eof
                }
            " >/dev/null 2>&1; then
                success=true
            else
                local exit_code=$?
                if [[ $exit_code -eq 124 ]]; then
                    generate_entropy
                    sleep 3
                fi
            fi
        else
            echo "ERROR: expect package required for GPG 1.4.12 automation but not available"
        fi
    elif [[ $major -eq 2 && $minor -eq 0 ]]; then
        # GPG 2.0.x - supports --batch, requires pubring/secring
        local gpg_flags="--batch --gen-key"
        if timeout $timeout_duration gpg $gpg_flags "$HOME/.gnupg/conf" >/dev/null 2>&1; then
            success=true
        else
            local exit_code=$?
            if [[ $exit_code -eq 124 ]]; then
                generate_entropy
                sleep 3
            fi
        fi
    else
        # GPG 2.1.x+ - try multiple commands in order of preference
        local commands=("--batch --full-generate-key" "--batch --full-gen-key" "--batch --gen-key")
        for cmd in "${commands[@]}"; do
            if timeout $timeout_duration gpg $cmd "$HOME/.gnupg/conf" >/dev/null 2>&1; then
                success=true
                break
            else
                local exit_code=$?
                if [[ $exit_code -eq 124 ]]; then
                    generate_entropy
                    sleep 3
                fi
            fi
        done
    fi


    if [[ "$success" != "true" ]]; then
        echo "ERROR: GPG key generation failed"
        exit 1
    fi
}

generate_gpg_key

# Extract GPG key ID - robust cross-version approach
extract_gpg_key_id() {
    local key_id=""

    # Method 1: Machine-readable format (most reliable across ALL versions)
    key_id=$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec:/ {print $5; exit}')
    if [[ -n "$key_id" && "$key_id" =~ ^[A-F0-9]{8,16}$ ]]; then
        echo "$key_id"
        return 0
    fi

    # Method 2: Human-readable with long format (fallback)
    key_id=$(gpg --list-secret-keys --keyid-format=long 2>/dev/null | sed -n 's/^sec.*\/\([A-F0-9]\{16\}\).*/\1/p' | head -n1)
    if [[ -n "$key_id" && "$key_id" =~ ^[A-F0-9]{16}$ ]]; then
        echo "$key_id"
        return 0
    fi

    # Method 3: Basic parsing (final fallback)
    key_id=$(gpg --list-secret-keys 2>/dev/null | sed -n 's/^sec.*\/\([A-F0-9]\{8,16\}\).*/\1/p' | head -n1)
    if [[ -n "$key_id" && "$key_id" =~ ^[A-F0-9]{8,16}$ ]]; then
        echo "$key_id"
        return 0
    fi

    return 1
}

GPG_SIGNINGKEY=$(extract_gpg_key_id)

# Verify key extraction succeeded
if [[ -z "$GPG_SIGNINGKEY" ]]; then
    echo "ERROR: Failed to extract GPG key ID. GPG key generation may have failed."
    echo "Please run 'gpg --list-secret-keys' to verify key exists."
    exit 1
fi

echo "GPG key ID extracted: $GPG_SIGNINGKEY"
GPG_PUBLICKEY=$(gpg --armor --export $GPG_SIGNINGKEY)

# Verify public key export succeeded
if [[ -z "$GPG_PUBLICKEY" ]]; then
    echo "ERROR: Failed to export GPG public key for key ID: $GPG_SIGNINGKEY"
    exit 1
fi

GPG_PUBLICKEY_ESCAPED=${GPG_PUBLICKEY//$'\n'/\\n}

# Upload GPG key to GitHub
GPG_UPLOAD_RESPONSE=$(curl -L -s \
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
))

if echo "$GPG_UPLOAD_RESPONSE" | grep -q "Resource not accessible"; then
    echo "WARNING: GPG key upload failed. Your GitHub token needs the 'write:gpg_keys' scope."
    echo "Please update your token permissions at: https://github.com/settings/tokens"
elif echo "$GPG_UPLOAD_RESPONSE" | grep -q "key is already in use"; then
    echo "GPG key already exists on GitHub - skipping upload."
elif echo "$GPG_UPLOAD_RESPONSE" | grep -q '"id"'; then
    echo "GPG key successfully uploaded to GitHub."
else
    echo "GPG key upload status unclear. Response: $GPG_UPLOAD_RESPONSE"
fi

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
  if ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f ~/.ssh/id_ed25519_github -N "" 2>/dev/null; then
    KEY_FILE="~/.ssh/id_ed25519_github"
    ssh-add ~/.ssh/id_ed25519_github
  elif [[ ! -f ~/.ssh/id_rsa_github ]]; then
        ssh-keygen -t rsa -b 4096 -C "$GIT_EMAIL" -f ~/.ssh/id_rsa_github -N ""
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

# Upload SSH key to GitHub
SSH_UPLOAD_RESPONSE=$(curl -L -s \
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
))

if echo "$SSH_UPLOAD_RESPONSE" | grep -q "Resource not accessible"; then
    echo "WARNING: SSH key upload failed. Your GitHub token needs the 'write:public_key' scope."
    echo "Please update your token permissions at: https://github.com/settings/tokens"
elif echo "$SSH_UPLOAD_RESPONSE" | grep -q "key is already in use"; then
    echo "SSH key already exists on GitHub - skipping upload."
elif echo "$SSH_UPLOAD_RESPONSE" | grep -q '"id"'; then
    echo "SSH key successfully uploaded to GitHub."
else
    echo "SSH key upload status unclear. Response: $SSH_UPLOAD_RESPONSE"
fi

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






