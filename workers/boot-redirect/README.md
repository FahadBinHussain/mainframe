# mainframe-boot

the universal restore link. one short link, any machine:

```
windows:  irm <link> | iex
linux:    curl -fsSL <link> | bash
```

the worker routes by User-Agent (see `worker.js`): powershell on windows
gets `boot.ps1`, curl/wget gets `boot-remote.sh`, powershell elsewhere gets
a wrapper that runs the linux script in bash, browsers get a page with both
commands. both scripts ask quick or full before downloading anything.

## deploy

```bash
# from this dir, with a cloudflare api token (vault: dash.cloudflare.com, [API Tokens])
npx -y wrangler deploy
```

or the api directly (no npm):

```bash
CF=$(cat /tmp/cf-token.txt)
ACCT=<account id from GET /client/v4/accounts>
curl -X PUT "https://api.cloudflare.com/client/v4/accounts/$ACCT/workers/scripts/mainframe-boot" \
  -H "Authorization: Bearer $CF" \
  -F 'metadata={"main_module":"worker.js"};type=application/json' \
  -F 'worker.js=@worker.js;type=application/javascript+module'
curl -X PATCH "https://api.cloudflare.com/client/v4/accounts/$ACCT/workers/scripts/mainframe-boot/subdomain" \
  -H "Authorization: Bearer $CF" -H 'Content-Type: application/json' \
  -d '{"enabled":true}'
```

live at `https://mainframe-boot.fahadbinhussain001.workers.dev`.
the short link points here (create with `https://da.gd/shorten?url=<worker url>`).

## verify routing

```bash
W=https://mainframe-boot.fahadbinhussain001.workers.dev
curl -sI -A "Mozilla/5.0 (Windows NT 10.0) WindowsPowerShell/5.1" $W | grep -i location
curl -sI -A "curl/8.5.0" $W | grep -i location
curl -s -A "Mozilla/5.0" $W | head -3
```
