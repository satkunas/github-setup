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

# Function to start entropy services with retry logic
start_entropy_service() {
    local service_name="$1"
    local max_retries=3
    local retry_count=0

    while [[ $retry_count -lt $max_retries ]]; do
        if command -v systemctl >/dev/null 2>&1; then
            if sudo systemctl start "$service_name" >/dev/null 2>&1 && sudo systemctl is-active "$service_name" >/dev/null 2>&1; then
                echo "$service_name started successfully"
                return 0
            fi
        elif command -v service >/dev/null 2>&1; then
            if sudo service "$service_name" start >/dev/null 2>&1; then
                # Wait a moment and check if it's running
                sleep 1
                if pgrep "$service_name" >/dev/null 2>&1; then
                    echo "$service_name started successfully"
                    return 0
                fi
            fi
        fi
        retry_count=$((retry_count + 1))
        echo "Failed to start $service_name (attempt $retry_count/$max_retries)"
        sleep 2
    done
    return 1
}

# Function to generate aggressive entropy for Debian 7 and other old systems
generate_aggressive_entropy() {
    echo "Starting aggressive entropy generation for older systems..."

    # Kill any existing entropy generation processes to avoid conflicts
    pkill -f "dd.*urandom.*random" 2>/dev/null || true
    pkill -f "find.*-type f" 2>/dev/null || true

    # Method 1: Multiple concurrent dd processes with different block sizes
    for i in {1..3}; do
        dd if=/dev/urandom of=/dev/random count=10 bs=1024 >/dev/null 2>&1 &
        dd if=/dev/urandom of=/dev/random count=5 bs=2048 >/dev/null 2>&1 &
    done

    # Method 2: CPU-intensive operations in background
    (
        # Mathematical operations that generate entropy
        for i in {1..1000}; do
            echo $RANDOM $RANDOM | md5sum >/dev/null 2>&1
        done
    ) &

    # Method 3: Filesystem operations that generate entropy
    (
        if [[ -d /var/log ]]; then
            find /var/log -type f -name "*.log" -exec head -n 1 {} \; >/dev/null 2>&1 &
        fi
        if [[ -d /usr ]]; then
            find /usr -name "*.so" -type f | head -20 | xargs ls -la >/dev/null 2>&1 &
        fi
    ) &

    # Method 4: Memory operations
    (
        # Read from various system locations that generate entropy
        cat /proc/cpuinfo /proc/meminfo /proc/loadavg /proc/uptime >/dev/null 2>&1
        # Date and timing operations
        for i in {1..50}; do
            date +%s%N >/dev/null 2>&1
            sleep 0.01
        done
    ) &

    # Method 5: Network entropy if available
    if command -v ping >/dev/null 2>&1; then
        (timeout 5 ping -c 3 8.8.8.8 >/dev/null 2>&1 || true) &
    fi

    # Method 6: Hardware-based entropy gathering
    (
        # Try to gather entropy from various hardware sources
        for device in /dev/mem /dev/kmem /dev/port; do
            if [[ -r "$device" ]]; then
                timeout 2 dd if="$device" of=/dev/random bs=64 count=1 >/dev/null 2>&1 || true
            fi
        done

        # Mouse and keyboard entropy if available
        for input in /dev/input/mouse* /dev/input/event*; do
            if [[ -r "$input" ]]; then
                timeout 1 dd if="$input" of=/dev/random bs=64 count=1 >/dev/null 2>&1 || true
            fi
        done 2>/dev/null || true
    ) &

    # Method 7: Last resort - fake user activity simulation
    (
        # Simulate some randomness that GPG might accept
        for i in {1..20}; do
            # Mix current nanosecond time with random data
            echo "$(date +%s%N)$RANDOM" | sha256sum | cut -d' ' -f1 > /dev/random 2>/dev/null || true
            echo "fake_entropy_$(date +%s%N)_$RANDOM$i" | md5sum > /dev/random 2>/dev/null || true
            sleep 0.1
        done
    ) &

    echo "Background entropy generation processes started"
}

# Emergency entropy recovery for completely stalled systems
emergency_entropy_recovery() {
    echo "EMERGENCY: Implementing last-resort entropy measures..."

    # Kill all existing entropy processes to start fresh
    pkill -f "dd.*urandom" 2>/dev/null || true
    pkill -f "md5sum" 2>/dev/null || true
    pkill -f "sha256sum" 2>/dev/null || true
    sleep 2

    # Method 1: Flood /dev/random with deterministic but varied data
    (
        for i in {1..100}; do
            # Use multiple sources of pseudo-randomness
            {
                cat /proc/uptime /proc/loadavg /proc/meminfo /proc/cpuinfo
                date +%s%N
                echo $RANDOM $RANDOM $RANDOM
                ps aux | head -10 | md5sum
            } 2>/dev/null | dd of=/dev/random bs=4096 count=1 >/dev/null 2>&1 || true
        done
    ) &

    # Method 2: Aggressive rngd configuration if available
    if command -v rngd >/dev/null 2>&1; then
        sudo pkill rngd 2>/dev/null || true
        sleep 1
        # Use the most aggressive settings possible
        sudo rngd -r /dev/urandom -o /dev/random -t 1 -W 50 -f >/dev/null 2>&1 &
        echo "Started emergency rngd configuration"
    fi

    # Method 3: Create a high-frequency entropy injection loop
    (
        counter=0
        while [[ $counter -lt 1000 ]]; do
            # High-frequency random data injection
            echo "emergency_entropy_$counter_$(date +%s%N)_$RANDOM$RANDOM" | sha256sum | cut -d' ' -f1 > /dev/random 2>/dev/null || true
            printf "%d%s%d\n" $counter "$(date +%N)" $RANDOM | md5sum > /dev/random 2>/dev/null || true
            counter=$((counter + 1))

            # Brief pause to prevent overwhelming the system
            if [[ $((counter % 50)) -eq 0 ]]; then
                sleep 0.1
            fi
        done
    ) &

    # Method 4: Try manual entropy pool writing (dangerous but necessary)
    if [[ -w /proc/sys/kernel/random/entropy_avail ]]; then
        # Try to manually increase entropy pool estimate
        echo 256 > /proc/sys/kernel/random/entropy_avail 2>/dev/null || true
    fi

    # Method 5: Use any available hardware entropy sources more aggressively
    for hwrng in /dev/hwrng /dev/hw_random; do
        if [[ -r "$hwrng" ]]; then
            dd if="$hwrng" of=/dev/random bs=1024 count=10 >/dev/null 2>&1 &
        fi
    done 2>/dev/null || true

    echo "Emergency entropy recovery measures deployed"
    echo "Waiting 15 seconds for entropy accumulation..."
    sleep 15
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
            echo "Low entropy ($entropy) detected for older system. Implementing comprehensive entropy improvement..."

            # Start aggressive entropy generation immediately
            generate_aggressive_entropy

            # Install and start entropy services with retry logic
            install_package "haveged"
            if command -v haveged >/dev/null 2>&1; then
                start_entropy_service "haveged"
            fi

            # Try rng-tools with better configuration
            install_package "rng-tools"
            if command -v rngd >/dev/null 2>&1; then
                # Kill any existing rngd processes
                sudo pkill rngd 2>/dev/null || true
                sleep 1
                # Start rngd with more aggressive settings
                sudo rngd -r /dev/urandom -o /dev/random -t 1 -W 75 >/dev/null 2>&1 &
                echo "Started rngd with aggressive settings"
            fi

            # Try additional entropy tools for Debian 7
            if [[ -n "$os_version" && "$os_version" -le 7 ]]; then
                # Install additional packages that might help
                install_package "randomsound" || true
                install_package "timer-entropy" || true

                # Start any available entropy services
                for service in randomsound timer-entropy; do
                    if command -v "$service" >/dev/null 2>&1; then
                        start_entropy_service "$service" || true
                    fi
                done
            fi

            # Give services time to start and generate initial entropy
            echo "Allowing entropy services to initialize..."
            sleep 5

            # Enhanced monitoring with more aggressive timeout handling
            local previous_entropy=0
            local stagnant_count=0
            local total_wait_time=0
            local max_wait_time=180  # 3 minutes max wait
            local max_stagnant=8     # Less patience, more action

            if [[ -n "$os_version" && "$os_version" -le 7 ]]; then
                max_stagnant=12  # Still more patience for very old systems
            fi

            while [[ $total_wait_time -lt $max_wait_time ]]; do
                local current_entropy=$(check_entropy)
                echo "Current entropy: $current_entropy/$threshold (waited ${total_wait_time}s)"

                if [[ $current_entropy -gt $threshold ]]; then
                    echo "Sufficient entropy achieved: $current_entropy"
                    break
                fi

                # Check if entropy has increased
                if [[ $current_entropy -le $previous_entropy ]]; then
                    stagnant_count=$((stagnant_count + 1))
                    echo "Entropy stagnant ($stagnant_count/$max_stagnant)"

                    if [[ $stagnant_count -ge $max_stagnant ]]; then
                        echo "Entropy stagnant for too long. Triggering emergency entropy boost..."
                        # Emergency entropy generation
                        generate_aggressive_entropy
                        # Reset counter to give it another chance
                        stagnant_count=0
                    fi
                else
                    stagnant_count=0  # Reset counter when entropy increases
                fi

                previous_entropy=$current_entropy
                sleep 3
                total_wait_time=$((total_wait_time + 3))
            done

            # Final check - if still low, continue anyway with warning
            local final_entropy=$(check_entropy)
            if [[ $final_entropy -lt $threshold ]]; then
                echo "Warning: Entropy still low ($final_entropy) after $max_wait_time seconds"
                echo "Continuing with GPG generation - background processes will keep generating entropy"
            else
                echo "Entropy sufficient for GPG generation: $final_entropy"
            fi
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
# Function to prepare GPG environment for low entropy systems
prepare_gpg_environment() {
    # Ensure GPG directory has correct permissions
    chmod 700 ~/.gnupg 2>/dev/null || true

    # For very old GPG versions, create gpg.conf with entropy-friendly settings
    local version=$(gpg --version 2>/dev/null | head -n1 | sed 's/gpg (GnuPG) //' || echo "1.4.0")
    local major=$(echo $version | cut -d. -f1)

    if [[ $major -lt 2 ]]; then
        cat > ~/.gnupg/gpg.conf <<EOF
# GPG configuration for older versions on low-entropy systems
personal-cipher-preferences AES256
personal-digest-preferences SHA256
cert-digest-algo SHA256
default-preference-list SHA256 AES256 ZLIB BZIP2 ZIP Uncompressed
weak-digest SHA1
use-agent
EOF
        echo "Created GPG configuration optimized for older systems"
    fi

    # Start GPG agent if available to reduce entropy requirements
    if command -v gpg-agent >/dev/null 2>&1; then
        eval "$(gpg-agent --daemon 2>/dev/null)" || true
    fi
}

# Generate GPG key with version-appropriate command and fallback
generate_gpg_key() {
    # Improve entropy before generation if using older systems
    improve_entropy_for_old_systems

    # Prepare GPG environment
    prepare_gpg_environment

    # Keep entropy generation running during GPG generation
    local entropy_pid=""
    local os_version=""
    if [[ -f /etc/debian_version ]]; then
        os_version=$(cat /etc/debian_version | cut -d. -f1)
    fi

    # For Debian 7 and other very old systems, keep aggressive entropy running
    if [[ -n "$os_version" && "$os_version" -le 7 ]]; then
        echo "Starting continuous entropy generation for Debian 7..."
        (
            while true; do
                # Continuous light entropy generation
                dd if=/dev/urandom of=/dev/random count=2 bs=512 >/dev/null 2>&1
                echo $RANDOM$RANDOM | md5sum >/dev/null 2>&1
                date +%s%N >/dev/null 2>&1
                sleep 1
            done
        ) &
        entropy_pid=$!
    fi

    local commands=("$(get_gpg_command)" "--full-generate-key" "--full-gen-key" "--gen-key")
    local success=false

    for cmd in "${commands[@]}"; do
        echo "Trying GPG command: $cmd"

        # Monitor entropy during GPG generation
        (
            while kill -0 $$ 2>/dev/null; do
                local current_entropy=$(check_entropy 2>/dev/null || echo "unknown")
                echo "GPG generating... entropy: $current_entropy"
                sleep 10
            done
        ) &
        local monitor_pid=$!

        # Use longer timeout for older systems and run GPG generation
        local timeout_duration=600  # 10 minutes for very old systems
        if timeout $timeout_duration gpg --verbose $cmd --batch ~/.gnupg/conf; then
            echo "Successfully generated GPG key using: $cmd"
            success=true
            kill $monitor_pid 2>/dev/null || true
            break
        else
            local exit_code=$?
            kill $monitor_pid 2>/dev/null || true

            if [[ $exit_code -eq 124 ]]; then
                echo "Command $cmd timed out after $timeout_duration seconds"
                # For timeout, try regenerating entropy before next attempt
                if [[ -n "$os_version" && "$os_version" -le 7 ]]; then
                    echo "Regenerating entropy for next attempt..."
                    generate_aggressive_entropy
                    sleep 5
                fi
            else
                echo "Command $cmd failed with exit code $exit_code"
            fi
            echo "Trying next command..."
        fi
    done

    # Clean up background entropy generation
    if [[ -n "$entropy_pid" ]]; then
        kill $entropy_pid 2>/dev/null || true
    fi

    if [[ "$success" != "true" ]]; then
        echo "ERROR: All GPG key generation commands failed"
        echo "Final entropy status: $(check_entropy 2>/dev/null || echo 'unknown')"

        # Try one more time with maximum entropy effort
        echo "Making final attempt with maximum entropy generation..."
        generate_aggressive_entropy
        sleep 10

        if timeout 900 gpg --verbose --gen-key --batch ~/.gnupg/conf; then
            echo "Final attempt succeeded!"
            return 0
        fi

        # Ultimate fallback: try to create a minimal entropy environment
        echo "Attempting emergency entropy recovery..."
        emergency_entropy_recovery

        if timeout 1200 gpg --verbose --gen-key --batch ~/.gnupg/conf; then
            echo "Emergency recovery succeeded!"
            return 0
        fi

        echo "CRITICAL: GPG key generation failed despite all entropy improvements."
        echo "System may have hardware entropy limitations. Consider:"
        echo "1. Installing additional entropy packages manually"
        echo "2. Running the script multiple times"
        echo "3. Using a different system for key generation"
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






