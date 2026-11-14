// mainframe-boot: one universal restore link.
//
//   windows:  irm <link> | iex
//   linux:    curl -fsSL <link> | bash
//
// the link itself routes by caller, because one static file cannot be both
// powershell and bash. User-Agent is the signal:
//   - powershell on windows  -> boot.ps1 (the windows restore, prompts quick/full)
//   - curl/wget              -> boot-remote.sh (the linux restore, prompts quick/full)
//   - powershell elsewhere   -> a tiny wrapper that fetches boot-remote.sh and runs it in bash
//   - browser / anything else -> a plain page with both commands
//
// no secrets, no state, no logging. the scripts themselves live in the
// mainframe repo; this worker only redirects to them.
const REPO = "FahadBinHussain/mainframe";
const PS1 = `https://raw.githubusercontent.com/${REPO}/main/boot.ps1`;
const SH = `https://raw.githubusercontent.com/${REPO}/main/boot-remote.sh`;

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><title>mainframe restore</title></head>
<body>
<h1>mainframe restore</h1>
<p>one link, any machine. paste the line for your OS:</p>
<h2>windows (powershell)</h2>
<pre><code>irm SHORTLINK | iex</code></pre>
<h2>linux (bash)</h2>
<pre><code>curl -fsSL SHORTLINK | bash</code></pre>
<p>both ask quick or full before downloading anything. full = everything,
quick = machine state only, no package installs.</p>
</body></html>`;

function psWrapper() {
  return `$ErrorActionPreference = 'Stop'
$t = Join-Path ([IO.Path]::GetTempPath()) 'boot-remote.sh'
Invoke-RestMethod -Uri '${SH}' -OutFile $t
bash $t
`;
}

export default {
  async fetch(request) {
    const ua = request.headers.get("user-agent") || "";
    const isWindows = /windows/i.test(ua);
    const isPS = /powershell/i.test(ua);
    const isFetcher = /^(curl|wget)\//i.test(ua);

    if (isPS && isWindows) return Response.redirect(PS1, 302);
    if (isFetcher) return Response.redirect(SH, 302);
    if (isPS) {
      return new Response(psWrapper(), {
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }
    const url = new URL(request.url);
    const page = PAGE.replaceAll("SHORTLINK", url.href);
    return new Response(page, {
      headers: { "content-type": "text/html; charset=utf-8" },
    });
  },
};
