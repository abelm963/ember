#!/bin/bash
# Installs atvloadly on Hearth (Ubuntu Server). atvloadly signs Ember.ipa with a free Apple ID,
# installs it on the Apple TV over the home network, and re-signs it before the 7 days run out.
#
# Run on Hearth:   sudo bash install-atvloadly.sh
# Then open:       http://<Hearth's address>:5533   (for example http://192.168.1.20:5533)
#
# To remove it later:  cd /opt/atvloadly && sudo docker compose down && sudo rm -rf /opt/atvloadly /etc/atvloadly

set -e
[ "$(id -u)" = 0 ] || { echo "Run with sudo: sudo bash $0"; exit 1; }

say() { printf '\n\033[33m== %s ==\033[0m\n' "$1"; }

say "Bonjour (avahi), so atvloadly can find the Apple TV"
apt-get update -qq
apt-get install -y -qq avahi-daemon
systemctl enable --now avahi-daemon

if ! command -v docker >/dev/null 2>&1; then
  say "Docker"
  apt-get install -y -qq docker.io docker-compose-v2
  systemctl enable --now docker
fi
docker compose version >/dev/null 2>&1 || apt-get install -y -qq docker-compose-v2

say "atvloadly"
mkdir -p /opt/atvloadly /etc/atvloadly
cat > /opt/atvloadly/docker-compose.yml <<'EOF'
services:
  atvloadly:
    container_name: atvloadly
    hostname: atvloadly
    # Pinned so an update can't break installs unexpectedly. Newer releases:
    # https://hub.docker.com/r/bitxeno/atvloadly/tags
    image: bitxeno/atvloadly:v0.7.4
    # Ubuntu's AppArmor profile for Docker blocks the D-Bus calls atvloadly makes to avahi, and
    # without them it never finds the Apple TV.
    security_opt:
      - seccomp:unconfined
      - apparmor:unconfined
    volumes:
      - /etc/atvloadly:/data
      - /var/run/dbus:/var/run/dbus
      - /var/run/avahi-daemon:/var/run/avahi-daemon
    ports:
      - 5533:80/tcp
    ulimits:
      core: 0
    restart: unless-stopped
EOF
cd /opt/atvloadly
docker compose pull
docker compose up -d

ip="$(hostname -I | awk '{print $1}')"
say "Done"
echo "Open http://$ip:5533 in a browser on your home network."
echo "atvloadly has no password of its own: don't expose port 5533 to the internet."
