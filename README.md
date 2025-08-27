# cpanel-pmg-sync
synchronization of pmg-cpanel domains created as main, parking and addon with routing configured to local on the cpanel server.

This script was based on the initial script of https://github.com/JrZavaschi/cpanel-to-pmg-domains-sync

The initial script only created/removed the relay on the PMG server for the main domains.

In my case, I have more than one cPanel server, and I need to create the transport path to the correct cPanel server. While editing the initial script, other issues arose, such as domains that only have a website hosted on cPanel, but the email server is internal to the company or using GSuite/365. So, I needed to filter only the domains configured as local routing, discarding the remote routing. Another issue was filtering additional domains created by customers within their cPanel accounts, which cPanel treats as parking domains or add-on domains.

Initially, I used the grep, cut, tr, and sort commands to filter the JSON content. But the command line was getting too large, so they suggested using the jq command to filter the JSON responses, and it worked much better. To improve the use of jq, I used Gemini to see better search examples with jq.

At the end I added a routine to email our support what was added or removed.

## Configuration

The settings are simple:

PMG_IP="xxx.xxx.xxx.xxx" #IP or host

PMG_USER="user@pmg" # user@pmg

PMG_PASSWORD="password-user-pmg"

CPANEL_HOST="host-cpanel" #only host cpanel server

RECIPIENT_EMAIL="support@support.com"

DATA=`/bin/date '+%Y-%m-%d %T'`

LOG_FILE="/var/log/pmg_sync.log"

# Contribution

<form action="https://www.paypal.com/donate" method="post" target="_top">
<input type="hidden" name="business" value="V6K8R2N7VQ4BW" />
<input type="hidden" name="no_recurring" value="0" />
<input type="hidden" name="currency_code" value="BRL" />
<input type="image" src="https://www.paypalobjects.com/en_US/i/btn/btn_donate_SM.gif" border="0" name="submit" title="PayPal - The safer, easier way to pay online!" alt="Donate with PayPal button" />
<img alt="" border="0" src="https://www.paypal.com/en_BR/i/scr/pixel.gif" width="1" height="1" />
</form>

