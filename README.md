# Copilot Triage

**You shouldn't need 2,000 lines of generated YAML to label an issue.**

Copilot Triage is a small alternative to **GitHub Agentic Workflows** for issues
and discussions, built for [RubyLLM](https://github.com/crmne/ruby_llm) and
[Spotifast](https://github.com/crmne/spotifast). A small Ruby program, a cheap model,
a system prompt, and scoped tools. Read the report, help the person, get out of the way.

https://github.com/user-attachments/assets/7fbd2ac8-33e7-49d3-a3f2-0d1ce509a3d6

[Download the video](https://github.com/crmne/copilot-triage/releases/download/v0.6.2/copilot-triage-launch-1080p60.mp4)

## Why this exists

We used [GitHub Agentic Workflows](https://github.com/github/gh-aw) to triage
[RubyLLM](https://github.com/crmne/ruby_llm) and
[Spotifast](https://github.com/crmne/spotifast) issues and discussions. In
RubyLLM alone, the [compiled workflow](https://github.com/crmne/ruby_llm/blob/d04b4eeb341d76440bee9a029f150b7598e5cfcc/.github/workflows/issue-assessment.lock.yml)
was **2,035 lines of YAML**. Tool gateways. Agent jobs. A separate threat detector.
Safe-output jobs. Failure-reporting machinery.

Our [recorded runs](https://github.com/crmne/ruby_llm/actions/runs/33890389416)
used Sonnet 5 to assess reports and Haiku 4.5 to inspect the output. Both consumed
Copilot credits. Then the workflow started
[opening issues about its own failures](https://github.com/crmne/ruby_llm/issues/922)
and [posting comments about its detector failing](https://github.com/crmne/ruby_llm/issues/913).
The bot became another thing to maintain. And another source of email.

That is a ridiculous amount of machinery for this job.

GitHub Agentic Workflows is a general agent platform. We needed a bot for
issues and discussions.
So we removed the platform and kept the job.

## Small on purpose

One agent, a [system prompt](lib/triage.agent.md), and
[small read-only tools](lib/triage_tools.rb). Copilot chooses what to search,
reads evidence, and decides whether to help. There are no separate classifier,
answer, or duplicate-comparison model calls, and no keyword-based conversation
gates. Ruby validates and publishes the agent's structured decision.

- Use your existing Copilot subscription. The default model remains `gpt-5.6-luna`.
- Let the agent investigate with repository search, issue search, releases, and
  paged evidence reads. Results are bounded; the model can refine its own query.
- Keep replies useful: answers, essential questions, policy, released fixes,
  duplicates, and one helpful initial recap. Do not recap every follow-up.
- Keep failures in job summaries, never new failure tickets or bot apologies.
- Keep the runtime small. With Copilot, it is Ruby's standard library and
  Copilot owns the agent loop; with [another provider](#other-model-providers),
  a [RubyLLM](https://rubyllm.com) agent runs the same tools. Neither is
  another orchestration framework.

Unit tests cover boundaries and publishing. Offline tool integration tests use
the real Copilot CLI with a fake provider; they do not establish model quality.
The [evaluation corpus](eval/README.md) covers both required help and silence.

## Use it

1. Add a `COPILOT_GITHUB_TOKEN` repository secret. Use a fine-grained token with
   **Copilot Requests** permission and an available Copilot allowance. See
   [Copilot authentication](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#copilot-login-options).
2. Save [examples/triage.yml](examples/triage.yml) as `.github/triage.yml` and
   adapt the labels, replies, source paths, and policy to your project.
3. Add `.github/workflows/triage.yml`:

```yaml
name: Triage
on:
  issues:
    types: [opened, reopened]
  issue_comment:
    types: [created]
  discussion:
    types: [created]
  discussion_comment:
    types: [created]

permissions:
  contents: read
  issues: write
  discussions: write

concurrency:
  group: >-
    triage-${{ github.event.discussion && 'discussion' || 'issue' }}-${{ github.event.issue.number || github.event.discussion.number }}-${{ github.event.discussion && (github.event.comment.parent_id || github.event.comment.id) || 'report' }}
  cancel-in-progress: false

jobs:
  triage:
    if: (github.event.sender.type != 'Bot' || github.event_name == 'issues') && !github.event.issue.pull_request
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: crmne/copilot-triage@v0
        with:
          copilot-token: ${{ secrets.COPILOT_GITHUB_TOKEN }}
```

The action checks out your repository's **default branch**, restores conversation
state, installs Copilot CLI, and runs the assessment. Commit the configuration
to that branch before enabling the workflow. It requires the Ruby, Node.js,
GitHub CLI, Git, and `timeout` commands provided by GitHub's Ubuntu runners.
With the default Copilot engine there is no runtime gem dependency or
provider API key.

The `v0` tag tracks tested v0 releases, so consuming repositories update
automatically. Use a full commit SHA instead when you need an immutable version.
The `main` branch contains development work, not just released versions.
Keep project-specific policy in your repository.

### Preview a report

Add manual inputs to the workflow's `on` section:

```yaml
  workflow_dispatch:
    inputs:
      kind:
        type: choice
        options: [issue, discussion]
        default: issue
      number:
        description: Issue or discussion number
        required: true
```

Then add these inputs alongside `copilot-token` on the action step:

```yaml
          kind: ${{ inputs.kind || (github.event.discussion && 'discussion' || 'issue') }}
          number: ${{ inputs.number || github.event.issue.number || github.event.discussion.number }}
          dry-run: ${{ github.event_name == 'workflow_dispatch' }}
```

Also add `|| inputs.number` to the concurrency group's number expression and
`inputs.kind ||` before its kind expression. A manual run shows its decision
in the job summary without changing GitHub. It can preview closed reports.
Previews consume Copilot credits.

## Replies

On a newly opened issue, one concise initial recap is welcome when it saves the
maintainer a long read: the problem, relevant environment, and key evidence.
A short, already clear request may need only labels. A recap does not need an
invented next check or a question to justify posting it.

After that, replies must add new help, not summarize each comment. One essential
missing fact can get one direct question, without an introductory summary.
The agent decides whether a recap, question, answer, or silence is appropriate.
These are prompt policies, not regular expressions that classify human wording.
A feature request may already be implemented; the agent should check rather than
automatically assume that it needs development. For example:

> Forwarding is already available: right-click the message or picture, choose Forward, then select the destination chat.

Answers should be concise, normally under 60 words. Learned facts use citations
to evidence the agent actually read. A released-fix claim needs release evidence,
not just code on the default branch or a closed issue.

For example, a reply might be:

> Does restarting the app pick up the system theme?
>
> _Generated by [Copilot Triage](https://github.com/marketplace/actions/copilot-triage) using `gpt-5.6-luna`; 6200 input / 80 output tokens this run; [view run](https://github.com/crmne/copilot-triage/actions)._

The figures above are illustrative. Every posted comment includes this compact
footer, added by Ruby, with the model, measured input/output tokens, and a link
to the exact run attempt. Counts cover fresh calls in that run, including
provider-cached input. Missing CLI usage is reported as unavailable. The footer links the Marketplace listing so
readers can reuse the action. It does not spend model tokens to write itself.

Or, when the configured documentation establishes it:

> Define `execute` on your tool class. See [the guide](https://rubyllm.com/tools/).

Map documentation files to your public site in the policy:

```yaml
documentation:
  docs/*.md: https://example.com/guides/%{name}/
```

`%{name}` is the filename without its extension. The maintainer supplies this
mapping; the action does not crawl the site. Other citations link to the exact
Git revision read. Only references read through tools can become citations; the wrapper supplies
links. Source files outside the checkout are excluded.

Each run reads the current report and its latest five comments. A discussion
comment event reads that thread's parent and latest five replies, including
threads older than the latest top-level comments. Answers stay in that thread.
The model can inspect configured sources on demand, with up to 6 KB of text per
read and explicit pagination. Search results are previews, not citation evidence.
Tools never receive an entire repository dump.

The action suppresses ordinary replies when a maintainer or bot commented most
recently. It checks the report again before publishing and skips if it changed. Successful
assessments get a bot 🎉 reaction. Triage does not assess PRs; GitHub's built-in
Copilot code review is a separate product. The optional
[project board](#project-board) sweep does place PRs on the board.

### Related issues and duplicates

The agent can search this repository's open and closed issues and read candidates
it selects. A duplicate proposal requires reading the full candidate; a search
title or incomplete preview cannot authorize closure.

Choose the behavior in `.github/triage.yml`:

```yaml
duplicates: suggest
```

- `suggest` (default): post a useful issue link and keep the report open.
- `close`: also close clear duplicates with GitHub's native duplicate reason.
- `'off'`: do not propose duplicate/related-issue actions. Keep the quotes in YAML.

For a clear duplicate with closure enabled:

> Duplicate of #42. Both reports describe the selected theme resetting after a restart.

For related reports with different requirements:

> See also #325. That issue covers the Winamp mini player's taskbar entry; this request concerns the separate Milkdrop window.

The script supplies the issue link and adds the usual attribution footer. The
model cannot invent a target or close an arbitrary report. Closure requires a
full comparison that identifies the same specific problem or feature. Different
components, platforms, and requirements remain separate unless the evidence
establishes a duplicate. Model judgments can still be wrong; use `suggest` when
you want to review every closure yourself.

Issue duplicates close only against an older issue, preventing reciprocal
closures. Open and closed issues can be targets; a closed issue alone does not
prove that a fix shipped. Discussions can close in favor of an issue. Maintainer-authored
reports, reopened issues, and reports with a maintainer among the recent comments
are linked without automatic closure. Both reports are fetched again before any
changes; changed candidates invalidate the assessment.

### Tools

The agent has four retrieval tools and a structured decision tool:

| Tool | What it returns |
| --- | --- |
| `search_repository` | Up to ten literal matches with paths, lines, and nearby byte offsets; an empty query lists files |
| `search_issues` | Up to five same-repository GitHub search results with short body previews |
| `list_releases` | Five published releases with version, prerelease status, and short notes |
| `read_evidence` | A paged file, issue with recent comments, or release; up to 6 KB of content |
| `submit_decision` | A schema-validated proposal for labels, a reply, a related issue, or mute; no GitHub mutation |

Tool results are at most 8 KB of serialized JSON, with explicit continuation
offsets/pages rather than hidden truncation. Files must match configured source
patterns, resolve inside the checkout, and be no larger than 1 MB. No shell,
arbitrary URLs, other repositories, or contributor code execution is exposed.
The agent can make up to 12 evidence calls; submission remains available after
that budget. Remote reads time out after 15 seconds.

Search uses literal text or GitHub's issue search, not our own relevance ranker.
The agent chooses search terms and can try again. Read results carry references;
the wrapper checks cited content again before publishing.

Copilot CLI's JSON output is an event stream, not schema-constrained final
generation. The agent therefore submits typed arguments through
`submit_decision`; final assistant prose is never used as a decision.
This is validated tool output, not a claim of provider-native strict structured
generation. Invalid tool arguments produce an error the agent can correct.

### Reports from Honeybadger

Private repositories work too. Allow the reporting bot in your policy:

```yaml
report_bots:
  - honeybadger[bot]
```

The workflow above admits bot-created issue events; the script checks the
author against this list before calling the model. Other bots remain excluded,
and bot comments never trigger a conversation loop. Error reports are assessed
for the maintainer using the supplied exception and backtrace. Configure the
source files it may read; keep credentials and customer data out of that input.

### Follow-up comments

Every eligible human update reaches the agent. `followups: selective` and the
legacy `all` setting both let the agent decide whether a reply helps.
`followups: off` leaves only explicit reassessment commands and manual runs.
There are no regexes deciding whether a comment contains a question, an error,
new evidence, or an acknowledgement.

Bot comments and ordinary maintainer comments are skipped before checkout or
CLI installation. Anyone can request reassessment with `/triage` or
`/triage reassess`; these commands still respect closed reports and mute state.

Comment runs wait 10 seconds before reading GitHub; set the action input
`debounce-seconds` between 0 and 60 to change this. If a newer comment exists,
the older event is skipped without calling Copilot. Concurrency keeps one run
active per issue or discussion thread and replaces older pending runs in that
conversation. Separate discussion threads are assessed independently. A comment
arriving during inference invalidates that answer; the next run assesses the
updated conversation.
Active runs are allowed to finish so publishing cannot be interrupted halfway.

Human updates can consume model calls even when the agent correctly stays silent.
Already-processed events are skipped; explicit reassessment bypasses that check.
Exact duplicate replies are blocked by code; the agent handles semantic repetition.

`/triage mute` takes effect without inference. The agent recognizes natural-language
stop requests and records a mute decision without a public acknowledgement. Only
a maintainer can use `/triage unmute`. Mute state, processed event fingerprints,
prior replies, and maintainer participation persist in a small Actions cache.
Previews do not change this state.

When state is evicted or comments were missed, up to 500 older comments can be
recovered. Unseen history is supplied to the agent, not interpreted with regexes.
Incomplete or oversized history pauses automatic follow-ups; `/triage` requests
reassessment but does not bypass the context-size limit. Silent completion cannot
be recovered after cache eviction, so an unchanged issue may be assessed again.

Existing issues and discussions are not automatically backfilled when you
install or upgrade the action. Use a manual preview for older reports. If a
run posts nothing, its job summary distinguishes skipped input or invalid model
output from a valid decision to stay silent.

## Other model providers

Copilot is the default because it uses an allowance you may already pay for.
To pay for tokens another way, switch to the `rubyllm` engine: a
[RubyLLM](https://rubyllm.com) agent with the same system prompt, tools,
evidence budget, and decision checks. Use a company API key, OpenRouter, a
cloud provider, or any OpenAI-compatible endpoint:

```yaml
      - uses: crmne/copilot-triage@v0
        with:
          engine: rubyllm
          provider: openrouter
          model: openai/gpt-oss-120b
          api-key: ${{ secrets.OPENROUTER_API_KEY }}
```

`provider` is a RubyLLM provider slug, such as `openai`, `anthropic`, `gemini`,
`openrouter`, `mistral`, `deepseek`, `xai`, or `ollama`, and `model` is the ID
that provider uses. For a server that speaks the OpenAI API, set
`provider: openai` and `api-base` to its URL; models it serves do not need to
be in RubyLLM's registry. A local model works the same way on a self-hosted
runner, for example `provider: ollama` with `api-base: http://localhost:11434/v1`.

The action installs the `ruby_llm` gem only for this engine, cached between
runs. The agent gets 20 model turns, 120 seconds, and 4,000 output tokens per
turn, and stops as soon as it submits a decision. Replies show the run's cost
when RubyLLM knows the model's price.

Choose a model by measuring it. The [evaluation runner](eval/README.md) runs
the same cases against any provider:

```sh
TRIAGE_API_KEY=... bundle exec ruby eval/run.rb --live --engine rubyllm \
  --provider openrouter --model openai/gpt-oss-120b
```

Small and free models vary widely in tool calling and judgment, so check that
a model passes before relying on it. Free tiers also have tight rate limits,
and some free providers log or train on prompts. Issue text from private
repositories, including error reports, goes to that provider; use a provider
whose data terms you accept.

## Project board

Optionally, triage can keep a GitHub project board of what needs you, across
every repository that uses it, public and private. The columns say whose move
it is:

| Column | Meaning |
| --- | --- |
| **Needs me** | Your decision, answer, review, or fix |
| **Waiting on them** | Triage or you asked the reporter something |
| **Blocked** | Yours to set; triage never moves cards out of it |
| **Ready to merge** | A PR is mergeable, green, and approved (or yours) |
| **Backlog** | Valid, nobody has to act now; yours to set |
| **In progress** | A PR is linked, or a draft PR is being worked on |
| **Done** | Closed; use the project's built-in workflow |

Each card can also carry a **Priority** (Urgent, High, Normal) and a one-line
**Next step** written for you by the agent, such as "Reproduce from the Windows
backtrace; likely the path join in loader.rb". The board is the summary: sort
**Needs me** by priority and you know what to do next.

### Set it up

1. Create a project owned by your account or organization, for example
   `https://github.com/users/crmne/projects/3`. Keep it private unless you want
   the public to see your workflow; triage's labels and replies stay the
   public signal on each issue.
2. Give its **Status** field the column options above. Add a single-select
   **Priority** field with Urgent, High, and Normal, and a text field named
   **Next step**. Both are optional; triage skips fields the project lacks.
   Enable the project's built-in workflows that set Done when an issue or PR
   is closed or merged.
3. Create a classic personal access token with the `project` scope, plus
   `repo` if private repositories use the board. Fine-grained tokens cannot
   access user-owned projects yet. Save it as a `TRIAGE_PROJECT_TOKEN`
   repository secret (or an organization secret).
4. Add the board to `.github/triage.yml`:

```yaml
board:
  project: https://github.com/users/crmne/projects/3
  assign_urgent_to: crmne # optional
  columns:                # optional: rename to match existing options
    needs_maintainer: Needs me
```

Column keys are `needs_maintainer`, `waiting_on_reporter`, `blocked`,
`ready_to_merge`, `backlog`, `in_progress`, and `done`.

5. Pass the token to the triage step:

```yaml
      - uses: crmne/copilot-triage@v0
        with:
          copilot-token: ${{ secrets.COPILOT_GITHUB_TOKEN }}
          project-token: ${{ secrets.TRIAGE_PROJECT_TOKEN }}
```

6. Add a daily sweep as `.github/workflows/board.yml`:

```yaml
name: Board
on:
  schedule:
    - cron: '17 6 * * *'
  workflow_dispatch:
    inputs:
      dry_run:
        type: boolean
        default: true

permissions:
  contents: read

concurrency:
  group: board
  cancel-in-progress: false

jobs:
  sweep:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: crmne/copilot-triage@v0
        with:
          mode: sweep
          project-token: ${{ secrets.TRIAGE_PROJECT_TOKEN }}
          dry-run: ${{ inputs.dry_run || false }}
```

Run it once manually with `dry_run` to see what it would place. The first real
run adds existing open issues and PRs, at most 100 changes per run.

### How cards move

On each assessed issue event, the agent decides whose move it is, a priority,
and the next step, as part of the decision it already submits. The card moves
to **Waiting on them** only when that run posted a reply asking the reporter
something; otherwise "waiting on the reporter" leaves the column unchanged.
Priority only rises, never falls. With `assign_urgent_to`, an urgent issue
nobody is assigned to is assigned to that person, which notifies them; GitHub
sends no notification for board changes. Discussions cannot be project items,
so they stay off the board.

The sweep uses no model and spends no Copilot credits. It applies moves that
follow from GitHub facts:

- New issues go to **Needs me**, or **Waiting on them** when a maintainer spoke
  last. Your own untouched issues go to **Backlog**.
- A card in **Waiting on them** returns to **Needs me** when the reporter
  commented after it moved.
- An issue with an open linked PR moves to **In progress**.
- PRs go to **Ready to merge**, **Needs me** (a contributor PR to review),
  **Waiting on them** (changes requested, failing checks, or conflicts), or
  **In progress** (drafts and your own unfinished PRs).

**Your moves win.** Triage and the sweep only move cards out of no column,
**Needs me**, **Waiting on them**, **Ready to merge**, and **Done** (for
reopened issues). **Backlog**, **Blocked**, **In progress**, and any column of
your own are your decisions and stay put; only PR cards leave **In progress**
when their facts change. Board failures fail the job and appear in its summary,
after any reply was published, so they never cause a repeated reply. The model
never receives the project token.

## Cost and caching

The model remains `gpt-5.6-luna` with `reasoning-effort: low`. Each assessment uses
one native Copilot session, which may contain multiple model/tool turns. The
initial task, system prompt, and tool definitions are bounded to 24 KB (26 KB
with a project board, covering its guidance); tool
results are bounded separately. Repeated NUL padding in logs is compacted without
discarding surrounding evidence. Other oversized input is left for a maintainer.

There is one 90-second CLI timeout and no wrapper retry loop. Copilot may retry
internally. Its 30-AI-credit session limit is a soft fallback ceiling, not an
expected price; an in-flight response may exceed it.

Only conversation state and the pinned CLI installation are cached. Isolated
model answers and local excerpts are no longer cached. State is small, disposable,
and scoped to each issue/discussion thread. This is not yet native session resume:
a new assessment starts a fresh Copilot session. Provider prompt caching is
separate and any discount depends on Copilot.

Metrics include model turns, initial prompt bytes, evidence tool calls/result
bytes, wall time, outcome, and tokens when Copilot reports them. Model input also
includes Copilot's own system context and previous tool turns. Use the
[evaluation runner](eval/README.md) to measure help, unwanted replies, tokens,
and latency together. Offline replay verifies plumbing, not fresh model judgment.

## Failures and permissions

Copilot failures and invalid output appear in the job summary and leave the
report unchanged. They do not create failure issues or comments. GitHub write
failures fail the job without marking the assessment complete. The action does
not change your billing settings; exhausted credits require a reset or budget.

The model has no shell, general filesystem tools, arbitrary network access, or
GitHub write tools. Its only MCP server is the scoped tool server above. The
GitHub credential is available to that server, not the model's environment.
Copilot runs with isolated settings and repository instructions disabled.
The wrapper controls labels/comments and closes duplicates only with explicit
configuration and the safeguards above. It never edits project code.

The optional project token is passed only to the Ruby code that writes the
board and is removed from the Copilot CLI environment.

The CLI is pinned to `1.0.83`. Skill and SQL tools are excluded explicitly.
The offline integration test verifies the actual provider request exposes only
the five triage tools, and exercises native search, query refinement, reads, and
structured decision submission.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md). Tests use fake GitHub/model responses;
the CLI integration test uses a local fake provider and spends no credits.

The first release is a preview. This independent project uses GitHub Copilot CLI
and is not an official GitHub product.

MIT licensed. Built for [RubyLLM](https://github.com/crmne/ruby_llm) and
[Spotifast](https://github.com/crmne/spotifast), reusable in your repositories.
