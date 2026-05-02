# SSH Zugang & Recovery

## Quelle der Wahrheit

Alle Server-SSH-Keys werden in `terraform/terraform.tfvars` unter
`ssh_public_keys` gepflegt — eine Zeile pro Gerät.

```hcl
ssh_public_keys = [
  "ssh-ed25519 AAAA...mac macbook",
  "ssh-ed25519 AAAA...lin thinkpad",
  "ssh-ed25519 AAAA...yk  yubikey-recovery",
]
```

- **Neuer Server:** Cloud-init schreibt die Liste beim First-Boot in
  `~ubuntu/.ssh/authorized_keys`.
- **Laufender Server:** `./scripts/sync-keys.sh` pusht die aktuelle
  Liste atomar (mit `.bak`). Lockout-Schutz ist eingebaut: das Script
  bricht ab, wenn der lokale Key nicht in der Liste steht.

## Neuen Key hinzufügen

1. Public Key auf dem neuen Gerät erzeugen (`ssh-keygen -t ed25519`).
2. In `terraform.tfvars` an `ssh_public_keys` anhängen, committen.
3. `./scripts/sync-keys.sh` ausführen.

## Recovery: ich komme nicht mehr per SSH rein

Funktioniert, solange **mindestens ein Key in der Hetzner-Console**
registriert ist (siehe `hcloud ssh-key list`). Damit kommt man immer
in den Rescue-Mode rein und kann `authorized_keys` reparieren.

```bash
export HCLOUD_TOKEN=...

# 1. Rescue mit registriertem Key aktivieren
hcloud server enable-rescue supabase-dev --type linux64 --ssh-key macbook-bs
hcloud server reboot supabase-dev

# 2. Alten Hostkey aus known_hosts entfernen, warten bis SSH offen
SERVER_IP=$(hcloud server ip supabase-dev)
ssh-keygen -R "$SERVER_IP"
until ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        root@"$SERVER_IP" 'echo READY' 2>/dev/null | grep -q READY; do
    sleep 5
done

# 3. Disk mounten, Key ergänzen, unmounten
ssh root@"$SERVER_IP" bash <<'EOF'
set -e
mount /dev/sda1 /mnt
mkdir -p /mnt/home/ubuntu/.ssh
echo 'ssh-ed25519 AAAA... new-key' >> /mnt/home/ubuntu/.ssh/authorized_keys
UBID=$(stat -c %u /mnt/home/ubuntu)
UBGID=$(stat -c %g /mnt/home/ubuntu)
chown -R $UBID:$UBGID /mnt/home/ubuntu/.ssh
chmod 700 /mnt/home/ubuntu/.ssh
chmod 600 /mnt/home/ubuntu/.ssh/authorized_keys
sync && umount /mnt
EOF

# 4. Zurück in den normalen Boot
hcloud server disable-rescue supabase-dev
hcloud server reboot supabase-dev
ssh-keygen -R "$SERVER_IP"
```

Nach dem Recovery: den temporär ergänzten Key auch in
`terraform.tfvars` aufnehmen und `sync-keys.sh` laufen lassen, damit
die Drift weggeht.

## Wichtig

- **Mindestens ein Hetzner-Cloud-SSH-Key bleibt immer registriert**
  (`hcloud ssh-key list`), das ist der Notausgang. Aktuell:
  `macbook-bs` (Fingerprint `ec:90:0c:...`).
- Cloud-init läuft nur beim First-Boot — `tfvars` ändern allein reicht
  für laufende Server **nicht**. Immer `sync-keys.sh` hinterher.
- Backup `~/.ssh/authorized_keys.bak` auf dem Server bleibt vom
  letzten Sync stehen — manueller Rollback möglich.
