#!/usr/bin/env bash
# Suppression des applications tierces non nécessaires au projet 7.
# Usage : sudo bash cleanup_apps.sh          -> simulation (rien n'est modifié)
#         sudo bash cleanup_apps.sh --apply  -> suppression réelle
set -uo pipefail
APPLY=0; [[ "${1:-}" == "--apply" ]] && APPLY=1
[[ $EUID -eq 0 ]] || { echo "À lancer avec sudo"; exit 1; }

SERVICES=(wazuh-dashboard wazuh-indexer wazuh-manager filebeat ollama postgresql valkey)
PKGS=(wazuh-manager wazuh-indexer wazuh-dashboard filebeat
      postgresql-server postgresql postgresql-private-libs valkey
      metasploit-framework
      nodejs nodejs-npm nodejs-docs nodejs-full-i18n nodejs-libs)
DIRS=(/var/ossec /etc/wazuh-indexer /var/lib/wazuh-indexer /var/log/wazuh-indexer /usr/share/wazuh-indexer
      /etc/wazuh-dashboard /usr/share/wazuh-dashboard /var/log/wazuh-dashboard
      /etc/filebeat /var/lib/filebeat /var/log/filebeat /usr/share/filebeat
      /var/lib/pgsql /var/lib/valkey /etc/valkey /var/log/valkey
      /opt/metasploit-framework
      /usr/local/lib/ollama /usr/share/ollama)
FILES=(/usr/local/bin/ollama /etc/systemd/system/ollama.service
       /etc/yum.repos.d/wazuh.repo /etc/yum.repos.d/metasploit-framework.repo)
FW_PORTS=(1514/tcp 1515/tcp 443/tcp 8889/tcp)   # Wazuh + 8889 (inutilisé)

run() { echo "+ $*"; [[ $APPLY -eq 1 ]] && "$@"; return 0; }

echo "=== Mode : $([[ $APPLY -eq 1 ]] && echo SUPPRESSION RÉELLE || echo SIMULATION) ==="

echo "--- 1. Arrêt et désactivation des services"
for s in "${SERVICES[@]}"; do
  systemctl list-unit-files "$s.service" >/dev/null 2>&1 && run systemctl disable --now "$s.service"
done

echo "--- 2. Paquets RPM (transaction dnf)"
INSTALLED=(); for p in "${PKGS[@]}"; do rpm -q "$p" >/dev/null 2>&1 && INSTALLED+=("$p"); done
if [[ ${#INSTALLED[@]} -gt 0 ]]; then
  if [[ $APPLY -eq 1 ]]; then dnf remove -y "${INSTALLED[@]}"
  else dnf remove --assumeno "${INSTALLED[@]}" 2>&1 | sed -n '/^Removing/,/^Transaction Summary/p;/Paquet\|Suppression\|Résumé/p' | head -60; fi
fi

echo "--- 3. Données, binaires et dépôts restants"
for d in "${DIRS[@]}" "${FILES[@]}"; do [[ -e "$d" ]] && { du -sh "$d" 2>/dev/null; run rm -rf -- "$d"; }; done

echo "--- 4. Utilisateurs/groupes système"
for u in ollama wazuh-indexer wazuh-dashboard wazuh; do id "$u" >/dev/null 2>&1 && run userdel "$u"; done
for g in ollama wazuh; do getent group "$g" >/dev/null && run groupdel "$g"; done

echo "--- 5. Ports firewalld liés à Wazuh (zone public, permanent)"
for p in "${FW_PORTS[@]}"; do
  firewall-cmd --zone=public --query-port="$p" --permanent >/dev/null 2>&1 && run firewall-cmd --zone=public --remove-port="$p" --permanent
done
run firewall-cmd --reload

echo "--- 6. systemd"
run systemctl daemon-reload; run systemctl reset-failed

echo "=== Terminé ($([[ $APPLY -eq 1 ]] && echo appliqué || echo simulation seulement)) ==="
