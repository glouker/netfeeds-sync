#!/bin/bash
set -e

# S'assurer que le dossier lists existe
mkdir -p lists

function update_list() {
    local url=$1
    local output_file=$2
    local etag_file="${output_file}.etag"
    local temp_file="${output_file}.tmp"

    echo "Téléchargement de $url..."

    local curl_opts="-s -L"
    if [ -f "$etag_file" ]; then
        curl_opts="$curl_opts --etag-compare $etag_file"
    fi
    curl_opts="$curl_opts --etag-save $etag_file"

    HTTP_CODE=$(curl $curl_opts -w "%{http_code}" -o "$temp_file" "$url")

    if [ "$HTTP_CODE" -eq 200 ]; then
        if [ -s "$temp_file" ]; then
            # Normalisation : supprime les lignes vides, trie et dedoublonne
            grep -v '^[[:space:]]*$' "$temp_file" | sort -V | uniq > "$output_file"
            echo "Fichier $output_file mis à jour."
        else
            echo "Avertissement : Le fichier téléchargé est vide."
        fi
    elif [ "$HTTP_CODE" -eq 304 ]; then
        echo "Fichier non modifié (304 Not Modified)."
    else
        echo "Erreur lors du téléchargement (HTTP $HTTP_CODE)."
        exit 1
    fi

    rm -f "$temp_file"
}

# Mise à jour des listes
update_list "https://s3-eu-west-1.amazonaws.com/plex-sidekiq-servers-list/sidekiqIPs.txt" "lists/plex.txt"
update_list "https://www.cloudflare.com/ips-v4" "lists/cloudflare-v4.txt"
update_list "https://www.cloudflare.com/ips-v6" "lists/cloudflare-v6.txt"
