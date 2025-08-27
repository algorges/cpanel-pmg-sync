#!/bin/bash
#original script - https://github.com/JrZavaschi/cpanel-to-pmg-domains-sync

# Proxmox Mail Gateway Credentials
PMG_IP="xxx.xxx.xxx.xxx"
PMG_USER="user@pmg" # user@pmg
PMG_PASSWORD="password-user-pmg"
CPANEL_HOST="host-cpanel" 
RECIPIENT_EMAIL="support@support.com"
DATA=`/bin/date '+%Y-%m-%d %T'`
LOG_FILE="/var/log/pmg_sync.log"

# Function to log messages to the console (standard output).
# Output will be discarded when the script is run from crontab with >/dev/null.
log() {
    echo "[$(date '+%Y-%m-%d %T')] $1"
}

# 1. Get authentication ticket
log "Getting authentication ticket from PMG..."
AUTH_RESPONSE=$(curl -s -k -X POST \
    --data-urlencode "username=$PMG_USER" \
    --data-urlencode "password=$PMG_PASSWORD" \
    "https://$PMG_IP:8006/api2/json/access/ticket")

# Check authentication
if ! echo "$AUTH_RESPONSE" | grep -q '"data":'; then
    log "ERROR: Authentication failed. Check credentials."
    exit 1
fi

# Extract ticket and CSRF token
TICKET=$(echo "$AUTH_RESPONSE" | grep -o '"ticket":"[^"]*' | cut -d'"' -f4)
CSRF_TOKEN=$(echo "$AUTH_RESPONSE" | grep -o '"CSRFPreventionToken":"[^"]*' | cut -d'"' -f4)

if [ -z "$TICKET" ]; then
    log "ERROR: Failed to get authentication ticket"
    exit 1
fi

# 2. Get cPanel domain list, add domain anda parked domain with only local MX records, exclude remote MX records and subdomains
log "Fetching domains from cPanel..."
ADDPARK_CPANEL=$(comm -12 <(for USER in $(whmapi1 listaccts --output=json | jq -r '.data.acct[].user'); do uapi --user=$USER --output=json DomainInfo list_domains | jq -r '.result.data.parked_domains[]?, .result.data.addon_domains[]?'; done | sort -u) <(sort /etc/localdomains))
PRIMARYDOMAINS_CPANEL=$(comm -12 <(whmapi1 listaccts --output=json | jq -r '.data.acct[].domain' | sort -u) <(sort /etc/localdomains))
DOMAINS_CPANEL=$(echo -e "$PRIMARYDOMAINS_CPANEL\n$ADDPARK_CPANEL" | sort -u)

if [ -z "$DOMAINS_CPANEL" ]; then
    log "No domains found in cPanel."
fi

# 3. Get PMG domain list
log "Fetching domains from PMG..."
RESPONSE_DOMAINS_PMG=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
    -X GET \
    "https://$PMG_IP:8006/api2/json/config/transport")

# Extract domains from PMG response, only use transport to $CPANEL_HOST
DOMAINS_PMG=$(echo "$RESPONSE_DOMAINS_PMG"| jq --arg cpanelhost "$CPANEL_HOST" -r '.data[] | select(.host == $cpanelhost) | .domain')

if [ -z "$DOMAINS_PMG" ]; then
    log "No domains found in PMG."
    DOMAINS_PMG=""
fi

# Variables to store new/removed domains
NEW_DOMAINS=""
REMOVED_DOMAINS=""

# 4. Add domains that are in cPanel but not in PMG
log "Syncing domains: adding new ones..."
for domain in $DOMAINS_CPANEL; do
    if ! echo "$DOMAINS_PMG" | grep -q "^$domain$"; then
        log "Adding domain: $domain"

	#Add the domain to the PMG relay domains list
        RESPONSE_RELAY=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
            -X POST \
            -H "Content-Type: application/json" \
            -d "{\"domain\":\"$domain\"}" \
            "https://$PMG_IP:8006/api2/json/config/domains")

        if echo "$RESPONSE_RELAY" | grep -q '"data":'; then
            log "SUCCESS: Relay domain $domain added."
	    NEW_DOMAINS+="$domain\n"
        elif echo "$RESPONSE_RELAY" | grep -q 'already exists'; then
            log "NOTICE: Relay domain $domain already exists"
        else
            log "ERROR adding relay domain $domain: $RESPONSE_RELAY"
        fi

	# Add the transport to route emails to the cPanel server
        RESPONSE_TRANSPORT=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
            -X POST \
            -H "Content-Type: application/json" \
	    --data '{"domain": "'"$domain"'", "host": "'"$CPANEL_HOST"'", "port": 25, "comment": "Adicionado '"$DATA"'", "protocol": "smtp", "use_mx": false}' \
            "https://$PMG_IP:8006/api2/json/config/transport")
	
        if echo "$RESPONSE_TRANSPORT" | grep -q '"data":'; then
            log "SUCCESS: Transport for $domain added."
        elif echo "$RESPONSE_TRANSPORT" | grep -q 'already exists'; then
            log "NOTICE: Transport for $domain already exists"
        else
            log "ERROR adding transport for $domain: $RESPONSE_TRANSPORT"
        fi
    else
        log "Domain $domain already exists in PMG. Skipping."
    fi
done

# 5. Remove domains that are in PMG but not in cPanel
log "Syncing domains: removing obsolete..."
for domain in $DOMAINS_PMG; do
    if ! echo "$DOMAINS_CPANEL" | grep -q "^$domain$"; then
        log "Removing domain: $domain"

	#Delete the domain from the PMG relay list
        RESPONSE_DELETE_RELAY=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
            -X DELETE \
            "https://$PMG_IP:8006/api2/json/config/domains/$domain")

        if echo "$RESPONSE_DELETE_RELAY" | grep -q '"data":'; then
            log "SUCCESS: Relay domain $domain removed."
	    REMOVED_DOMAINS+="$domain\n"
        else
            log "ERROR removing $domain: $RESPONSE_DELETE_RELAY"
        fi

	#Delete the transport entry for the domain
        RESPONSE_DELETE_TRANSPORT=$(curl -s -k -b "PMGAuthCookie=$TICKET" -H "CSRFPreventionToken: $CSRF_TOKEN" \
           -X DELETE \
           "https://$PMG_IP:8006/api2/json/config/transport/$domain")

        if echo "$RESPONSE_DELETE_TRANSPORT" | grep -q '"data":'; then
            log "SUCCESS: Transport for $domain removed."
        else
            log "ERROR removing $domain: $RESPONSE_DELETE_TRANSPORT"
        fi

    else
        log "Domain $domain still exists in cPanel. Keeping."
    fi
done

log "Sync complete."

# 6. Send email notification and log changes
if [ -n "$NEW_DOMAINS" ] || [ -n "$REMOVED_DOMAINS" ]; then
    EMAIL_BODY=$(cat <<EOF
Synchronization report between $CPANEL_HOST and PMG.

---
Newly Added Domains:
EOF
    )
    if [ -z "$NEW_DOMAINS" ]; then
        EMAIL_BODY+="No domains were added.\n"
    else
        EMAIL_BODY+="$NEW_DOMAINS"
    fi
    EMAIL_BODY+="
---
Removed Domains:
"
    if [ -z "$REMOVED_DOMAINS" ]; then
        EMAIL_BODY+="No domains were removed.\n"
    else
        EMAIL_BODY+="$REMOVED_DOMAINS"
    fi
    EMAIL_BODY+="
---
Synchronization completed on $DATA
"

    # Send email
    (
        echo "From: root@$CPANEL_HOST"
        echo "To: $RECIPIENT_EMAIL"
        echo "Subject: PMG Sync Report for $CPANEL_HOST - $DATA"
        echo "MIME-Version: 1.0"
        echo "Content-Type: text/plain; charset=\"UTF-8\""
        echo ""
        echo "$EMAIL_BODY"
    ) | /usr/sbin/sendmail -t -i

    # Log changes
    echo "---" >> "$LOG_FILE"
    echo "PMG Synchronization Report for $CPANEL_HOST - $DATA" >> "$LOG_FILE"
    echo -e "$EMAIL_BODY" >> "$LOG_FILE"
    echo "---" >> "$LOG_FILE"

else
    log "No changes found. Sync report email not sent."
    echo "[$(date '+%Y-%m-%d %T')] No changes found in this sync cycle." >> "$LOG_FILE"
fi
