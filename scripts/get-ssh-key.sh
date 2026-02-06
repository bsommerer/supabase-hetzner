#!/bin/bash
# =============================================================================
# SSH Key Helper
# =============================================================================
# Prüft ob ein SSH Key existiert, erstellt einen falls nicht,
# und gibt den Public Key aus.
# =============================================================================

set -euo pipefail

# Farben
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ -f ~/.ssh/id_ed25519.pub ]; then
    echo -e "${GREEN}SSH Key existiert bereits (ed25519):${NC}"
    cat ~/.ssh/id_ed25519.pub
elif [ -f ~/.ssh/id_rsa.pub ]; then
    echo -e "${GREEN}SSH Key existiert bereits (RSA):${NC}"
    cat ~/.ssh/id_rsa.pub
else
    echo -e "${YELLOW}Kein SSH Key gefunden. Erstelle neuen ed25519 Key...${NC}"
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "supabase-hetzner"
    echo ""
    echo -e "${GREEN}Neuer SSH Key erstellt:${NC}"
    cat ~/.ssh/id_ed25519.pub
fi

echo ""
echo -e "${YELLOW}Kopiere den Key oben in terraform.tfvars unter 'ssh_public_key'${NC}"
