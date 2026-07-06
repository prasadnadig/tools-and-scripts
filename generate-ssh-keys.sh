#!/usr/bin/env bash

set -euo pipefail

usage() {
        cat <<'EOF'
Usage:
        gen-ssh-keys.sh [options] <key-name-1> [key-name-2 ...]

Note:
        This script is intended to be run interactively.
        By default, ssh-keygen will prompt for a passphrase during key generation.
        Use --no-passwd to generate keys with an empty passphrase.

Options:
        --prefix <value>      Prefix for filenames (default: output of whoami)
        --out-dir <path>      Directory to write keys to (default: ~/.ssh)
        --type <key-type>     SSH key type for ssh-keygen -t (default: rsa)
        --bits <size>         Key size for ssh-keygen -b (default: 2048)
        --no-passwd           Generate keys with an empty passphrase
        -h, --help            Show this help message

Example:
        gen-ssh-keys.sh --prefix cloud --out-dir ~/.ssh --type rsa --bits 2048 service1 service2
EOF
}

prefix="$(whoami)"
out_dir="$HOME/.ssh"
ssh_key_type="rsa"
key_bits="2048"
no_passwd="false"

key_names=()
generated_files=()

while [[ $# -gt 0 ]]; do
        case "$1" in
                --prefix)
                        [[ $# -ge 2 ]] || { echo "ERROR: --prefix requires a value"; exit 1; }
                        prefix="$2"
                        shift 2
                        ;;
                --out-dir)
                        [[ $# -ge 2 ]] || { echo "ERROR: --out-dir requires a value"; exit 1; }
                        out_dir="$2"
                        shift 2
                        ;;
                --type)
                        [[ $# -ge 2 ]] || { echo "ERROR: --type requires a value"; exit 1; }
                        ssh_key_type="$2"
                        shift 2
                        ;;
                --bits)
                        [[ $# -ge 2 ]] || { echo "ERROR: --bits requires a value"; exit 1; }
                        key_bits="$2"
                        shift 2
                        ;;
                --no-passwd)
                        no_passwd="true"
                        shift
                        ;;
                -h|--help)
                        usage
                        exit 0
                        ;;
                --)
                        shift
                        while [[ $# -gt 0 ]]; do
                                key_names+=("$1")
                                shift
                        done
                        ;;
                -*)
                        echo "ERROR: Unknown option: $1"
                        usage
                        exit 1
                        ;;
                *)
                        key_names+=("$1")
                        shift
                        ;;
        esac
done

if [[ ${#key_names[@]} -eq 0 ]]; then
        echo "ERROR: Provide at least one key name."
        usage
        exit 1
fi

if [[ ! "$key_bits" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --bits must be a positive integer."
        exit 1
fi

mkdir -p "$out_dir"
chmod 700 "$out_dir"

date_stamp="$(date +%Y-%m-%d)"

for key_name in "${key_names[@]}"; do
        filename_core="${prefix}-${key_name}-${date_stamp}"
        key_path="${out_dir}/${filename_core}"

        if [[ -e "$key_path" || -e "${key_path}.pub" ]]; then
                echo "Skipping ${filename_core}: key file already exists at ${key_path}"
                continue
        fi

        if [[ "$no_passwd" == "true" ]]; then
                ssh-keygen -t "$ssh_key_type" -b "$key_bits" -N "" -C "$filename_core" -f "$key_path"
        else
                ssh-keygen -t "$ssh_key_type" -b "$key_bits" -C "$filename_core" -f "$key_path"
        fi

        # Enforce secure key permissions explicitly.
        chmod 600 "$key_path"
        chmod 644 "${key_path}.pub"

        generated_files+=("$key_path")
        generated_files+=("${key_path}.pub")

        echo "Generated: ${key_path} and ${key_path}.pub"
done

if [[ ${#generated_files[@]} -gt 0 ]]; then
        echo "Keys generated in ${out_dir}"
        echo "Generated key files:"
        for generated_file in "${generated_files[@]}"; do
                echo "  ${generated_file}"
        done
else
        echo "No new key files were generated."
fi
