# Threat model & hardening checklist

## What we protect

| Asset | Where it lives | Blast radius if stolen |
|---|---|---|
| claude.ai login (full-scope OAuth session) | `/home/agent/.claude` on the agent PVC | Someone else uses your subscription and can open Remote Control sessions. Revoke by signing out all sessions on claude.ai. |
| GitHub write access | 1h installation token in Secret `agents/git-token` | Push branches / open PRs on the repos in the minter's list for ≤1h. They can't merge to protected `main`. |
| GitHub App private key | Secret `agent-credentials/github-app` | Mint tokens for every repo the App is installed on. **Highest value.** Keep the install list minimal. |
| Provider API keys (optional gateway) | Secret `llm-gateway/litellm` | Billed usage. Set provider-side spend limits. |
| Source code | Agent PVC, GitHub | Confidentiality of your repos |

## Threats and controls

### T1. Prompt injection from repo content, issues or web pages makes the agent exfiltrate data or run malicious commands
* **Egress allowlist** (Cilium FQDN). The agent can only reach Anthropic, GitHub,
  and the mirrors you add. This is the control that actually stops exfiltration.
  Permission deny rules are guardrails, not a boundary: an agent with a shell
  can always find another way to run `curl`.
* **Residual risk:** `github.com` is allowed, so a hijacked agent could push
  secrets it can read into a branch. Mitigations: the token only reaches the
  listed repos, turn on GitHub **secret scanning push protection**, and keep
  the agent's readable secrets to the minimum (the claude.ai login is
  unavoidably readable by the same uid).
* `managed-settings.json`: bypass-permissions mode is disabled, sensitive paths
  are denied, `git push` asks for confirmation (you approve it from the phone),
  and repos can't add their own hooks, permission rules or MCP servers.
* Use **worktree spawn mode**, so each remote session works in its own git worktree.

### T2. Agent-executed code escapes the container
* PSA `restricted`, non-root, no capabilities, seccomp, read-only rootfs.
* **gVisor/Kata RuntimeClass** (`runtimeClassName` in the StatefulSet). This is
  strongly recommended, because the agent runs arbitrary build and test code by design.
* No ServiceAccount token, so a container escape doesn't hand over the Kubernetes API.
* Dedicated node pool with a taint for agents, if your cluster allows it.

### T3. Supply chain: a compromised dependency (the LiteLLM 1.82.7/1.82.8 case)
* [x] Claude Code binary verified against Anthropic's **GPG-signed manifest** with
      a pinned key fingerprint. No `curl | bash`, no npm lifecycle scripts.
* [x] Base images pinned by `@sha256` digest. Dependabot bumps them via PR with a **7-day cooldown**.
* [x] GitHub Actions pinned to full commit SHAs. Tags can be moved, and that is how
      the Trivy action compromise propagated. `persist-credentials: false`, least-privilege `permissions`.
* [x] Images signed keyless with cosign (GitHub OIDC). Kyverno only admits
      images signed by *this* workflow on `main`.
* [x] SBOM (SPDX) attached as a signed attestation, and a Grype scan gates the push.
* [x] No runtime package installs (`pip install`, `npx -y …`) in long-running
      components. Agents that need packages go through **your own registry
      mirror/proxy** with a quarantine/cooldown policy, never straight to PyPI/npm.
* [x] Gateway is optional. If you run one, it has no SA token, no cloud
      metadata access, egress only to providers, and the image is mirrored and pinned.
* [ ] Consider an in-cluster egress proxy log (Cilium Hubble or Tetragon) with an
      alert on *any* policy drop from `agents` or `llm-gateway`. Under these
      policies, drops are almost always worth looking at.

### T4. Someone else steers your agents
* Remote Control is tied to your claude.ai account. Turn on **Require trusted
  devices** (passkey/biometric re-auth every 18h), and use a hardware key or
  passkey for your Anthropic and Google accounts.
* Cluster access (`pods/exec`) only through an OIDC group with MFA, and audit
  logging on the API server for `pods/exec`.
* No Ingress, NodePort or LoadBalancer for agents. Everything is outbound.

### T5. Credential theft at rest
* Use an encrypted StorageClass for the agent PVCs, and enable Kubernetes
  Secret encryption at rest (KMS provider).
* Consider External Secrets Operator + a vault for the GitHub App key, so it is
  never stored as a plain Secret in etcd.

## Governance

* **Audit:** every tool call goes to stdout as JSON
  (`"audit":"claude-tool"`), plus token-mint events and Kubernetes audit logs
  for exec. Ship them to Loki or Elastic and keep them immutable.
* **Usage and cost:** the Claude Code OTel metrics (tokens, sessions, tool
  decisions, lines changed) go to your collector. Prompt contents are *not*
  exported unless you set `OTEL_LOG_USER_PROMPTS=1`.
* **Change control:** Claude Code version, base image, policies and allowlists
  all live in git and change only via reviewed PRs, so the history is your change log.
* **Kill switches:**
  * scale to 0: `kubectl -n agents scale sts claude-agent --replicas=0`
  * revoke the login: claude.ai → sign out all sessions
  * revoke repo access: suspend the GitHub App installation
  * cut the network: `kubectl -n agents delete cnp claude-agent-egress` (default-deny remains)

## Terms-of-service reminders

* Use your subscription login only with the official `claude` binary, for yourself.
  Don't proxy it to other tools or people.
* Remote Control won't work behind a gateway or with `setup-token` tokens. That's by design, not a bug to work around.
* For Google (Antigravity / Gemini CLI): a consumer login on a remote server is
  a grey zone with documented account suspensions. Prefer a Gemini API key.
