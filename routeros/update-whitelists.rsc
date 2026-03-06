# Script MikroTik RouterOS v7 - Mise à jour des whitelists depuis GitHub
# Modifiez BASE_URL pour pointer vers le lien "raw" de votre branche (ex: main)

:local repoUrl "https://raw.githubusercontent.com/glouker/netfeeds-sync/main/lists"

:local targets {
    "plex"={"url"="$repoUrl/plex.txt"; "list"="plex"; "comment"="auto:plex"; "min"=1};
    "cloudflare-v4"={"url"="$repoUrl/cloudflare-v4.txt"; "list"="cloudflare"; "comment"="auto:cloudflare-v4"; "min"=10};
    "cloudflare-v6"={"url"="$repoUrl/cloudflare-v6.txt"; "list"="cloudflare"; "comment"="auto:cloudflare-v6"; "min"=5}
}

:foreach k,v in=$targets do={
    :local url ($v->"url")
    :local listName ($v->"list")
    :local listComment ($v->"comment")
    :local minEntries ($v->"min")
    :local fileName "temp_$k.txt"

    :log info "Telechargement de $url"
    :local dlStatus 0
    :do {
        /tool fetch url=$url mode=https dst-path=$fileName
        :set dlStatus 1
    } on-error={
        :log error "Echec du telechargement de $url. On passe a la suite."
    }

    :if ($dlStatus = 1) do={
        # Petite pause pour s'assurer que le fichier est bien ecrit sur le disque
        :delay 2s
        :local fileData [/file get $fileName contents]
        /file remove $fileName

        :if ([:len $fileData] > 0) do={
            # Decoupage du contenu en lignes
            :local ipArray [:toarray ""]
            :local line ""
            :for i from=0 to=([:len $fileData] - 1) do={
                :local char [:pick $fileData $i]
                :if ($char = "\n" || $char = "\r") do={
                    :if ([:len $line] > 0) do={
                        :set ipArray ($ipArray, $line)
                        :set line ""
                    }
                } else={
                    :set line ($line . $char)
                }
            }
            :if ([:len $line] > 0) do={
                :set ipArray ($ipArray, $line)
            }

            :local currentCount [:len $ipArray]
            :if ($currentCount >= $minEntries) do={
                :log info "Validation reussie: $currentCount IPs (min $minEntries) trouvees pour $k"

                # 1. Suppression des IPs obsoletes
                :local existingIpv4 [/ip firewall address-list find where comment=$listComment and list=$listName]
                :foreach id in=$existingIpv4 do={
                    :local currentIp [/ip firewall address-list get $id address]
                    :local found false
                    :foreach newIp in=$ipArray do={
                        :if ($currentIp = $newIp) do={ :set found true }
                    }
                    :if (!$found) do={
                        :log info "Suppression de l'IPv4 obsolète $currentIp ($listComment)"
                        /ip firewall address-list remove $id
                    }
                }

                :local existingIpv6 [/ipv6 firewall address-list find where comment=$listComment and list=$listName]
                :foreach id in=$existingIpv6 do={
                    :local currentIp [/ipv6 firewall address-list get $id address]
                    :local found false
                    :foreach newIp in=$ipArray do={
                        :if ($currentIp = $newIp) do={ :set found true }
                    }
                    :if (!$found) do={
                        :log info "Suppression de l'IPv6 obsolète $currentIp ($listComment)"
                        /ipv6 firewall address-list remove $id
                    }
                }

                # 2. Ajout des nouvelles IPs
                :foreach newIp in=$ipArray do={
                    :local isIpv6 ([:find $newIp ":"] > -1)
                    
                    :if ($isIpv6) do={
                        :if ([:len [/ipv6 firewall address-list find address=$newIp list=$listName comment=$listComment]] = 0) do={
                            :log info "Ajout de la nouvelle IPv6 $newIp ($listComment)"
                            :do {
                                /ipv6 firewall address-list add address=$newIp list=$listName comment=$listComment
                            } on-error={ :log warning "Echec lors de l'ajout de l'IPv6 $newIp" }
                        }
                    } else={
                        :if ([:len [/ip firewall address-list find address=$newIp list=$listName comment=$listComment]] = 0) do={
                            :log info "Ajout de la nouvelle IPv4 $newIp ($listComment)"
                            :do {
                                /ip firewall address-list add address=$newIp list=$listName comment=$listComment
                            } on-error={ :log warning "Echec lors de l'ajout de l'IPv4 $newIp" }
                        }
                    }
                }

                :log info "Mise a jour terminee pour $k."
            } else={
                :log error "Validation en echec pour $k: recu $currentCount IPs, minimum requis $minEntries. Annulation pour prevenir tout blocage."
            }
        } else={
            :log error "Le fichier telecharge est vide pour $k. Annulation des changements !"
        }
    }
}
