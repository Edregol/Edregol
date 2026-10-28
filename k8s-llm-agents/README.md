# Remote-controlled coding agents on Kubernetes

A reference design for running Claude Code (and optionally other agent CLIs) in
hardened pods that you steer from your phone or browser, that can clone and push
code, and that are built so a compromised dependency has as little to steal as possible.

> Status: a reference design. The YAML, JSON and shell files pass syntax checks,
> but nothing here has been schema-validated (kubeconform) or applied to a live
> cluster yet. Run it in a test cluster first.

---

## 1. The constraints that decide the design

These come from the vendors' current docs and terms. They matter more than any
of the YAML.

### 1.1 Claude subscription + Remote Control ⇒ no LLM gateway on that path

Per the official [Remote Control docs](https://code.claude.com/docs/en/remote-control):

* Remote Control needs a **claude.ai subscription login** (Pro/Max/Team/Enterprise).
  API keys are not supported.
* Tokens from `claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN` **cannot** start
  Remote Control. You need a full `claude auth login` session.
* Remote Control is **disabled when `ANTHROPIC_BASE_URL` points anywhere other
  than `api.anthropic.com`**, which includes LiteLLM or any other gateway.
* It makes **outbound HTTPS only** and never opens inbound ports. That's good for
  security: you don't need an Ingress, a LoadBalancer or a VPN to steer the pods.

So you can't have "subscription + remote control + LiteLLM in the middle".
This design puts Claude Code pods **directly on `api.anthropic.com`** and moves
governance to the places that still work there:

| Governance need | Where it lives |
|---|---|
| Which hosts the agent can reach | Cilium FQDN egress policy (`deploy/agents/egress-policy.yaml`) |
| What the agent may do (tools, files, bypass mode) | `managed-settings.json` baked into the image (users and repos can't override it) |
| Audit trail of every tool call | Managed `PreToolUse` hook → stdout → your cluster log pipeline |
| Usage and cost metrics | Claude Code OpenTelemetry (`CLAUDE_CODE_ENABLE_TELEMETRY`) → your collector |
| Who may steer a session | Your claude.ai account + **Trusted Devices** (turn on "Require trusted devices") |
| Which repos the agent can touch | Short-lived, repo-scoped GitHub App tokens (§4) |

### 1.2 Subscription terms

* Anthropic's [Feb 2026 policy](https://winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/):
  Free/Pro/Max OAuth tokens may be used **only by Claude Code / Claude apps**,
  not by third-party tools or the Agent SDK. Running the official `claude`
  binary in your own pod, for yourself, is Claude Code. Putting your
  subscription token behind LiteLLM so *other* tools can use it is the
  prohibited case.
* A subscription is for **one person**. Don't hand these sessions to teammates.
  For a team, use Team/Enterprise seats or API keys.
* All pods share **one usage limit**. Ten parallel agents run out of quota ten
  times faster.
* **Antigravity**: `agy` has a headless mode, but Google's position on running a
  consumer login on a remote server is unclear. Forum replies from Google staff
  [conflict](https://discuss.ai.google.dev/t/is-orchestrating-the-official-antigravity-cli-from-a-local-multi-agent-coding-application-allowed/181088.md),
  and early-2026 ban waves hit people who reused Antigravity OAuth. My
  recommendation is to run the Google path on a **Gemini API key** (billed per
  token, works through a gateway) rather than your Google AI subscription, or
  accept the account risk knowingly.

Check both vendors' current terms before you rely on any of this. They have
changed several times this year.

### 1.3 Where a gateway still makes sense

A gateway is useful for **API-key traffic**: a Gemini API key, an Anthropic
Console key for CI agents, local models. It gives you per-agent virtual keys,
budgets and request logs. It's optional, and §5 covers how to run one without
repeating the LiteLLM incident.

---

## 2. Architecture

```
                 you (phone / browser)
                         │  claude.ai/code, Claude app (Trusted Devices)
                         ▼
                ┌──────────────────┐
                │ api.anthropic.com │◄──── outbound HTTPS only (no Ingress)
                └──────────────────┘
                         ▲
 ┌───────────────────────┼──────── namespace: agents (PSA restricted) ────────┐
 │  StatefulSet claude-agent-N                                                 │
 │   ├─ init: git-clone   (token from Secret, repo-scoped, 1h TTL)             │
 │   └─ claude remote-control --spawn worktree   (inside tmux)                 │
 │        • non-root, read-only rootfs, no caps, seccomp, no SA token          │
 │        • managed-settings.json: deny secrets, no bypass mode, audit hook    │
 │        • PVC /home/agent: login state + workspace                           │
 │  CiliumNetworkPolicy: egress only to an FQDN allowlist                     │
 └──────────────────────────────────────────────────────────────────────────────┘
 ┌──────── namespace: agent-credentials (agents cannot read this) ─────────────┐
 │  CronJob git-token-minter: GitHub App private key → installation token       │
 │  (scoped to listed repos, contents+PR write) → Secret in `agents` every 30m  │
 └──────────────────────────────────────────────────────────────────────────────┘
 ┌──────── namespace: llm-gateway (optional, API-key traffic only) ────────────┐
 │  Envoy AI Gateway or LiteLLM, pinned by digest, egress only to providers    │
 └──────────────────────────────────────────────────────────────────────────────┘
 Cluster-wide: Kyverno. Images must be pinned by digest and signed by your CI;
 no privileged pods.
```

Remote control for agents without a native remote feature (Gemini CLI, `agy`):
use `kubectl exec -it … -- tmux attach`, with the kube-apiserver behind OIDC and
an RBAC role that allows only `pods/exec` in the `agents` namespace. You still
need no inbound exposure. Avoid web terminals such as ttyd; they're an extra
internet-facing shell.

---

## 3. Layout

```
k8s-llm-agents/
├── images/
│   ├── claude-agent/          Claude Code image: GPG-verified binary, non-root
│   │   ├── Dockerfile
│   │   ├── managed-settings.json
│   │   ├── audit-hook.sh
│   │   └── entrypoint.sh
│   └── git-token-minter/      mints GitHub App installation tokens
├── deploy/
│   ├── base/                  namespaces (PSA restricted), default-deny
│   ├── agents/                StatefulSet, egress allowlist, exec-only RBAC
│   ├── git-credentials/       token minter CronJob + narrow RBAC
│   ├── gateway/               optional hardened LiteLLM
│   └── policies/              Kyverno: digest pinning, signatures, pod hardening
├── SECURITY.md                threat model + supply-chain checklist
└── ../.github/workflows/build-claude-agent.yml   build, SBOM, scan, sign
```

---

## 4. Code checkout without long-lived secrets in the agent

Don't give an agent a personal access token or SSH key. Instead:

1. Create a **GitHub App** with only `Contents: read/write`, `Pull requests:
   read/write` and `Metadata: read`. Install it on **only** the repos the agents
   may touch.
2. Keep the App private key in the `agent-credentials` namespace. The agent pods
   can't read that namespace.
3. A CronJob mints an **installation token** every 30 minutes, scoped down to
   the repo list in its ConfigMap. Tokens expire after 1 hour. It writes the token
   into Secret `agents/git-token`.
4. The agent's git credential helper reads that mounted file, so it always has
   a fresh token and never sees the key.
5. Add a **branch protection / ruleset** on `main`: require a PR and review. The
   agent can push branches and open PRs, but it can't merge to `main` itself.

If a pod is compromised, the attacker gets at most a one-hour token for a few
repos, and still can't reach `main`.

---

## 5. Optional gateway, without repeating the LiteLLM incident

On 2026-03-24, LiteLLM **1.82.7 and 1.82.8** on PyPI shipped a credential
stealer. 1.82.8 used a `.pth` file that runs on *every* Python start. The
attackers got in with hijacked publishing credentials, reportedly via the
compromised Trivy action in LiteLLM's CI, and the payload went after SSH keys,
cloud credentials and **Kubernetes secrets**
([NetSPI](https://www.netspi.com/blog/executive-blog/ai-ml-pentesting/litellm-supply-chain-compromise/),
[Comet](https://www.comet.com/site/blog/litellm-supply-chain-attack/)).

What would have contained it:

* **Never `pip install` at deploy time.** Use a container image pinned by
  `@sha256:` digest, mirrored into your own registry after a scan, and only
  promoted after a soak period (for example 7 days). Both bad versions were
  pulled within hours.
* **No Kubernetes API token** in the gateway pod (`automountServiceAccountToken:
  false`). The stealer had nothing to take.
* **Egress allowlist** to the provider APIs only. Exfiltration to the attacker's
  domain would have been dropped and logged.
* **Only the credentials it needs**: provider keys, nothing else. No cloud
  instance-metadata access (block `169.254.169.254`).
* Consider **Envoy AI Gateway** (Go, Envoy/CNCF, much smaller dependency tree)
  if all you need is routing, keys and rate limits. LiteLLM is fine with the
  controls above, but it's a large Python app with hundreds of transitive deps.

`deploy/gateway/` contains a LiteLLM deployment with all of these controls.

---

## 6. Rollout

```bash
# 0. Prereqs: Cilium (for FQDN egress), Kyverno, a registry you control, and
#    a storage class. gVisor/Kata are optional but recommended (see StatefulSet).

# 1. Set images/claude-agent/CLAUDE_VERSION to the current stable release, merge to
#    main; CI (.github/workflows/build-claude-agent.yml) builds, scans and signs.
#    Put the printed digests into deploy/*/kustomization.yaml.

# 2. Base, policies, credentials
kubectl apply -k deploy/base
kubectl apply -k deploy/policies        # start in Audit mode, switch to Enforce later
kubectl -n agent-credentials create secret generic github-app \
  --from-literal=app-id=123456 --from-literal=installation-id=7890123 \
  --from-file=private-key.pem=./my-app.private-key.pem
kubectl apply -k deploy/git-credentials
kubectl -n agent-credentials create job --from=cronjob/git-token-minter mint-now

# 3. Agents
kubectl apply -k deploy/agents

# 4. One-time interactive login + workspace trust (per agent)
kubectl -n agents exec -it claude-agent-0 -- tmux attach -t rc
#    → the first run asks to trust the workspace (answer y). Then:
#    Ctrl-b d, and in a fresh shell:
kubectl -n agents exec -it claude-agent-0 -- claude auth login
#    open the printed URL, paste the code back. The login lives on the PVC.

# 5. Turn on "Require trusted devices" in claude.ai account settings.
# 6. Steer from claude.ai/code or the Claude app. Sessions show up named claude-agent-0-…
```

Kill switch: `kubectl -n agents scale sts claude-agent --replicas=0`. To revoke
the login, sign out of all sessions in claude.ai account settings. To revoke
repo access, suspend the GitHub App installation.

See [SECURITY.md](SECURITY.md) for the threat model and the full checklist.
