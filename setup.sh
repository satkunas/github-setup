#!/usr/bin/env bash
#set -x

# Cleanup function to kill background processes
cleanup() {
    # Kill any background processes from this script
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
read -e -p "GIT fine-grained PAT: " -i $GIT_TOKEN GIT_TOKEN

install_package() {
    local package="$1"
    if command -v apt-get >/dev/null; then
        if ! dpkg -l | grep -q "^ii  $package "; then
            echo "Installing $package..."
            sudo apt-get update -qq && sudo apt-get install -y "$package"
        fi
    elif command -v yum >/dev/null; then
        if ! rpm -q "$package" >/dev/null 2>&1; then
            echo "Installing $package..."
            sudo yum install -y "$package"
        fi
    else
        echo "Warning: No supported package manager found. Please install $package manually."
    fi
}

# Install GPG
if command -v apt-get >/dev/null; then
    if ! command -v gpg >/dev/null 2>&1; then
        if ! dpkg -l | grep -q "^ii  gnupg "; then
            echo "Installing gnupg..."
            sudo apt-get update -qq && sudo apt-get install -y gnupg >/dev/null 2>&1
        fi
        if ! command -v gpg >/dev/null 2>&1; then
            install_package "gpg"
        fi
    fi
else
    install_package "gpg"
fi
install_package "git"

# Basic entropy improvement
improve_entropy() {
    if [[ -w /dev/random ]] && [[ -r /dev/urandom ]]; then
        dd if=/dev/urandom of=/dev/random count=1 bs=1024 >/dev/null 2>&1 || true
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

# Check if GPG version supports batch generation
is_gpg_supported() {
    local gpg_ver=$(get_gpg_version)
    local major=$(echo $gpg_ver | cut -d. -f1)

    if [[ $major -ge 2 ]]; then
        return 0
    else
        return 1
    fi
}

# Detect existing GPG key
get_existing_gpg_key() {
    # Try to get existing key ID
    local key_id=$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec:/ {print $5; exit}')
    if [[ -n "$key_id" && "$key_id" =~ ^[A-F0-9]{8,16}$ ]]; then
        echo "$key_id"
        return 0
    fi
    return 1
}

# Detect existing SSH key
get_existing_ssh_key() {
    # Check for common SSH key files
    local key_files=("~/.ssh/id_ed25519.pub" "~/.ssh/id_rsa.pub" "~/.ssh/id_ed25519_github.pub" "~/.ssh/id_rsa_github.pub")

    for key_file in "${key_files[@]}"; do
        local expanded_path=$(eval echo $key_file)
        if [[ -f "$expanded_path" ]]; then
            # Get first 20 characters after the key type
            local key_preview=$(head -n1 "$expanded_path" 2>/dev/null | awk '{print $1 " " substr($2,1,20) "..."}')
            echo "$key_preview"
            return 0
        fi
    done
    return 1
}

# Generate hostname identifier for key naming
get_hostname_identifier() {
    local hostname=$(hostname 2>/dev/null || echo "localhost")
    local username=$(whoami 2>/dev/null || echo "$USER")

    # If hostname is localhost, try to get IP address
    if [[ "$hostname" == "localhost" ]]; then
        # Try to get primary interface IP
        local ip_addr=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' || echo "127.0.0.1")
        hostname="$ip_addr"
    fi

    echo "$username@$hostname"
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

}

# Generate GPG key with version-appropriate command and fallback
generate_gpg_key() {
    improve_entropy
    prepare_gpg_environment


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
                    improve_entropy
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
                improve_entropy
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
                    improve_entropy
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

# 4-Step Setup Flow
echo "=== GitHub Setup ==="
echo

# Check GPG version and show warning if unsupported
GENERATE_GPG=false
UPLOAD_GPG=false
if is_gpg_supported; then
    # GPG 2.0+ - supported
    echo "GPG version $(get_gpg_version) detected - batch key generation supported."
else
    # GPG < 2.0 - unsupported
    echo "GPG version $(get_gpg_version) detected. Batch key generation not supported."
    echo "GPG key generation will be skipped."
fi
echo

# Step 1: GPG Generation Prompt
if is_gpg_supported; then
    existing_gpg=$(get_existing_gpg_key)
    if [[ $? -eq 0 ]]; then
        # Existing GPG key found
        read -p "GPG generate [$existing_gpg]? (Y/[n]): " -n 1 -r gpg_gen_choice
        echo
        if [[ $gpg_gen_choice =~ ^[Yy]$ ]]; then
            GENERATE_GPG=true
        fi
    else
        # No existing GPG key
        read -p "GPG generate? ([Y]/n): " -n 1 -r gpg_gen_choice
        echo
        if [[ -z $gpg_gen_choice || $gpg_gen_choice =~ ^[Yy]$ ]]; then
            GENERATE_GPG=true
        fi
    fi
fi

# Step 2: GPG API Upload Prompt (if GPG generation chosen or existing key)
if [[ $GENERATE_GPG == true ]] || (is_gpg_supported && get_existing_gpg_key >/dev/null 2>&1); then
    read -p "Upload GPG key to GitHub? (Y/n): " -n 1 -r gpg_upload_choice
    echo
    if [[ -z $gpg_upload_choice || $gpg_upload_choice =~ ^[Yy]$ ]]; then
        UPLOAD_GPG=true
    fi
fi

# Step 3: SSH Generation Prompt
GENERATE_SSH=false
existing_ssh=$(get_existing_ssh_key)
if [[ $? -eq 0 ]]; then
    # Existing SSH key found
    read -p "SSH generate [$existing_ssh]? (Y/[n]): " -n 1 -r ssh_gen_choice
    echo
    if [[ $ssh_gen_choice =~ ^[Yy]$ ]]; then
        GENERATE_SSH=true
    fi
else
    # No existing SSH key
    read -p "SSH generate? ([Y]/n): " -n 1 -r ssh_gen_choice
    echo
    if [[ -z $ssh_gen_choice || $ssh_gen_choice =~ ^[Yy]$ ]]; then
        GENERATE_SSH=true
    fi
fi

# Step 4: SSH API Upload Prompt (if SSH generation chosen or existing key)
UPLOAD_SSH=false
if [[ $GENERATE_SSH == true ]] || get_existing_ssh_key >/dev/null 2>&1; then
    read -p "Upload SSH key to GitHub? (Y/n): " -n 1 -r ssh_upload_choice
    echo
    if [[ -z $ssh_upload_choice || $ssh_upload_choice =~ ^[Yy]$ ]]; then
        UPLOAD_SSH=true
    fi
fi

echo "=== Setup Summary ==="
echo "GPG Generate: $GENERATE_GPG"
echo "GPG Upload: $UPLOAD_GPG"
echo "SSH Generate: $GENERATE_SSH"
echo "SSH Upload: $UPLOAD_SSH"
echo

# Execute GPG Generation
if [[ $GENERATE_GPG == true ]]; then
    echo "Generating GPG key..."
    generate_gpg_key
fi

# Execute GPG Upload
if [[ $UPLOAD_GPG == true ]]; then
    echo "Uploading GPG key to GitHub..."

    # Extract GPG key ID
    GPG_SIGNINGKEY=$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '/^sec:/ {print $5; exit}')

    if [[ -z "$GPG_SIGNINGKEY" ]]; then
        echo "ERROR: No GPG key found for upload"
    else
        echo "Found GPG key: $GPG_SIGNINGKEY"

        # Prompt for custom name
        default_name="GPG Key: $(get_hostname_identifier)"
        read -e -p "GPG key name: " -i "$default_name" gpg_key_name

        GPG_PUBLICKEY=$(gpg --armor --export $GPG_SIGNINGKEY)
        GPG_PUBLICKEY_ESCAPED=${GPG_PUBLICKEY//$'\n'/\\n}

        # Upload to GitHub
        GPG_UPLOAD_RESPONSE=$(curl -L -s \
          -X POST \
          -H "Accept: application/vnd.github+json" \
          -H "Authorization: Bearer $GIT_TOKEN" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          https://api.github.com/user/gpg_keys \
          --data @<(cat <<EOF
          {
            "name":"$gpg_key_name",
            "armored_public_key":"$GPG_PUBLICKEY_ESCAPED"
          }
EOF
        ))

        if echo "$GPG_UPLOAD_RESPONSE" | grep -q "Resource not accessible"; then
            echo "WARNING: GPG key upload failed. Your GitHub token needs the 'write:gpg_keys' scope."
        elif echo "$GPG_UPLOAD_RESPONSE" | grep -q '"id"'; then
            echo "GPG key successfully uploaded to GitHub."
        else
            echo "GPG key upload status unclear."
        fi
    fi
fi

# Configure Git (optional)
CONFIGURE_GIT=false
if [[ $GENERATE_GPG == true && -n "$GPG_SIGNINGKEY" ]]; then
    read -p "Configure Git with GPG signing? (Y/n): " -n 1 -r git_config_choice
    echo
    if [[ -z $git_config_choice || $git_config_choice =~ ^[Yy]$ ]]; then
        CONFIGURE_GIT=true
    fi
fi

if [[ $CONFIGURE_GIT == true ]]; then
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
fi

# Execute SSH Generation
if [[ $GENERATE_SSH == true ]]; then
    echo "Generating SSH key..."
    eval "$(ssh-agent -s)"

    # Generate SSH key (ED25519 preferred)
    if ssh-keygen -t ed25519 -C "$GIT_EMAIL" -f ~/.ssh/id_ed25519_github -N "" 2>/dev/null; then
        ssh-add ~/.ssh/id_ed25519_github
        echo "ED25519 key generated"
    elif ssh-keygen -t rsa -b 4096 -C "$GIT_EMAIL" -f ~/.ssh/id_rsa_github -N ""; then
        ssh-add ~/.ssh/id_rsa_github
        echo "RSA key generated"
    else
        echo "ERROR: SSH key generation failed"
    fi
fi

# Execute SSH Upload
if [[ $UPLOAD_SSH == true ]]; then
    echo "Uploading SSH key to GitHub..."

    # Find SSH public key (check same files as detection function)
    key_files=("~/.ssh/id_ed25519_github.pub" "~/.ssh/id_rsa_github.pub" "~/.ssh/id_ed25519.pub" "~/.ssh/id_rsa.pub")
    SSH_PUBLICKEY=""

    for key_file in "${key_files[@]}"; do
        expanded_path=$(eval echo $key_file)
        if [[ -f "$expanded_path" ]]; then
            SSH_PUBLICKEY=$(cat "$expanded_path")
            break
        fi
    done

    if [[ -z "$SSH_PUBLICKEY" ]]; then
        echo "ERROR: No SSH public key found for upload"
    fi

    if [[ -n "$SSH_PUBLICKEY" ]]; then
        # Prompt for custom name
        default_name="SSH Key: $(get_hostname_identifier)"
        read -e -p "SSH key name: " -i "$default_name" ssh_key_name

        # Upload to GitHub
        SSH_UPLOAD_RESPONSE=$(curl -L -s \
          -X POST \
          -H "Accept: application/vnd.github+json" \
          -H "Authorization: Bearer $GIT_TOKEN" \
          -H "X-GitHub-Api-Version: 2022-11-28" \
          https://api.github.com/user/keys \
          --data @<(cat <<EOF
          {
            "title":"$ssh_key_name",
            "key":"$SSH_PUBLICKEY"
          }
EOF
        ))

        if echo "$SSH_UPLOAD_RESPONSE" | grep -q "Resource not accessible"; then
            echo "WARNING: SSH key upload failed. Your GitHub token needs the 'write:public_key' scope."
        elif echo "$SSH_UPLOAD_RESPONSE" | grep -q '"id"'; then
            echo "SSH key successfully uploaded to GitHub."
        else
            echo "SSH key upload status unclear."
        fi
    fi
fi

# Configure SSH
if [[ $GENERATE_SSH == true ]]; then
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
fi

echo "=== Setup Complete ==="






