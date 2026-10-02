# Copilot Triage

**A maintainer's copilot for GitHub: it triages issues, discussions, and pull
requests, and keeps a board of what actually needs you.**

https://github.com/user-attachments/assets/a1513045-5e28-4868-9347-e163439088d3

[Download the video](https://github.com/crmne/copilot-triage/releases/download/v0.8.0/copilot-triage-launch-board-1080p60.mp4)

Open source maintenance is mostly reading. Copilot Triage reads for you. When
someone opens an issue, starts a discussion, sends a pull request, or comments,
an agent investigates with read-only tools and decides what helps:

- **Issues.** Labels, and one useful reply or none: an answer from your docs, a
  released fix, a duplicate, one essential question, or a recap of a long
  report. Silence is a valid decision; most follow-ups need no reply.
- **Discussions.** Questions get answered from your docs. A discussion that is
  really a bug report or feature request moves to an issue.
- **Pull requests.** Requests a Copilot code review when a change deserves one,
  reads Copilot's verdict when it arrives, checks your contribution policy
  (screenshots, an issue first, scope), and explains or closes changes your
  documented scope rules out.
- **Closing.** Closes what is plainly finished, each time with a comment that
  says why: duplicates, issues a release fixed, issues the reporter says are
  resolved, and requests your documented scope rules out. Merging and every
  judgment call stay with you.
- **Your board.** Every issue and pull request lands on a GitHub project board
  sorted by what it needs from you: Sign off, Decide, Do, or nothing because
  it is someone else's move. Each card has a priority and a one-line next
  step, your review is requested on the pull requests that need it, and urgent
  issues are assigned to you. Triage builds the board itself on an empty
  project.

So you can turn off GitHub's email for everything and open the board instead.

It runs on your **Copilot** allowance by default, or on **your own API key**
through [RubyLLM](https://rubyllm.com): a company key, OpenRouter, a cloud
provider, or any OpenAI-compatible endpoint. We [measure models](#evaluations)
before recommending them, and publish the results.

Built for [RubyLLM](https://github.com/crmne/ruby_llm) and
[Spotifast](https://github.com/crmne/spotifast), reusable in your repositories.

## Why this exists

We used [GitHub Agentic Workflows](https://github.com/github/gh-aw) to triage
RubyLLM and Spotifast. In RubyLLM alone, the
[compiled workflow](https://github.com/crmne/ruby_llm/blob/d04b4eeb341d76440bee9a029f150b7598e5cfcc/.github/workflows/issue-assessment.lock.yml)
was **2,035 lines of YAML**: tool gateways, agent jobs, a separate threat
detector, safe-output jobs, failure-reporting machinery. Then it started
[opening issues about its own failures](https://github.com/crmne/ruby_llm/issues/922)
and [commenting about its detector failing](https://github.com/crmne/ruby_llm/issues/913).
The bot became another thing to maintain, and another source of email.

So we removed the platform and kept the job: one agent, a
[system prompt](lib/triage.agent.md), and
[small read-only tools](lib/triage_tools.rb). The agent chooses what to search,
reads evidence, and decides whether to help. Ruby validates its structured
decision and publishes it. No classifier calls, no keyword gates, no failure
tickets: problems go to the job summary.

## Quick start

1. **Token.** Add a `COPILOT_GITHUB_TOKEN` repository secret: a fine-grained
   token with **Copilot Requests** and an available Copilot allowance (see
   [Copilot authentication](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference#copilot-login-options)).
   To request Copilot reviews of pull requests, also give it **Pull requests:
   Read and write** on the repository. Using your own API key instead? See
   [Models and cost](#models-and-cost).
2. **Policy.** Save [examples/triage.yml](examples/triage.yml) as
   `.github/triage.yml` on your default branch and adapt the labels, replies,
   source paths, and instructions to your project.
3. **Workflow.** Add `.github/workflows/triage.yml`:

```yaml
name: Triage
on:
  issues:
    types: [opened, reopened, closed]
  issue_comment:
    types: [created]
  discussion:
    types: [created]
  discussion_comment:
    types: [created]
  pull_request_target:
    types: [opened, reopened, ready_for_review, synchronize, closed]
  pull_request_review:
    types: [submitted]

permissions:
  contents: read
  issues: write
  discussions: write
  pull-requests: write

concurrency:
  group: >-
    triage-${{ github.event.discussion && 'discussion' || 'issue' }}-${{ github.event.issue.number || github.event.discussion.number || github.event.pull_request.number }}-${{ github.event.discussion && (github.event.comment.parent_id || github.event.comment.id) || 'report' }}
  cancel-in-progress: false

jobs:
  triage:
    if: github.event.sender.type != 'Bot' || github.event_name == 'issues' || github.event_name == 'pull_request_review'
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: crmne/copilot-triage@v0
        with:
          copilot-token: ${{ secrets.COPILOT_GITHUB_TOKEN }}
```

That's it. To add the board, see [The board](#the-board).

The action checks out your **default branch** (never contributor code),
restores small conversation state, installs Copilot CLI, and runs the
assessment on GitHub's Ubuntu runners. The `v0` tag follows tested releases;
pin a commit SHA if you need an immutable version. `main` is development work.

## Models and cost

### Copilot (default)

The default model is `gpt-5.6-luna` at low reasoning effort, billed to the
token's Copilot allowance. A typical assessment reads 10,000 to 60,000 input
tokens over a few model turns, around a cent or less at
[GitHub's listed price](https://docs.github.com/en/copilot/reference/copilot-billing/models-and-pricing).
Change it with the `model` input.

### Your own API key

Set `engine: rubyllm` to run a [RubyLLM](https://rubyllm.com) agent with the same
system prompt, tools, evidence budget, and decision checks:

```yaml
      - uses: crmne/copilot-triage@v0
        with:
          engine: rubyllm
          provider: openrouter
          model: openai/gpt-oss-120b
          api-key: ${{ secrets.OPENROUTER_API_KEY }}
```

`provider` is any RubyLLM provider slug, such as `openai`, `anthropic`,
`gemini`, `openrouter`, `mistral`, `deepseek`, `xai`, `bedrock`, `azure`, or
`ollama`, and `model` is that provider's model ID. For a server that speaks the
OpenAI API, use `provider: openai` with `api-base` set to its URL; its models
need not be in RubyLLM's registry. Replies show the run's cost when RubyLLM
knows the model's price. The action installs the `ruby_llm` gem only for this
engine, cached between runs.

**About free models:** free and small models vary widely at tool calling and
judgment, and the small local ones we tried fail most of our cases (see below).
Free tiers also have tight rate limits, and some free providers log or train on
prompts. Issue text from private repositories goes to whichever provider you
choose, so use one whose data terms you accept. Measure a model before you
rely on it.

### Evaluations

An [evaluation corpus](eval/README.md) of real and synthetic reports checks
both help and silence: stop requests, thank-yous, already answered questions,
documented answers, released fixes, duplicates, recaps. A case passes only with
the expected outcome, the required content, and within its call budget. Every
change runs it offline; before each release, and before changing the default
model, we run it live against real models and publish the results here.

Latest results, measured on October 1, 2026 with Copilot CLI 1.0.83 and
RubyLLM 2.0.0. Copilot models ran two rounds of the 15 cases, local models one.
Costs use GitHub's list prices without cache discounts.

| Model | Engine | Passed | Unneeded replies | Missed help | Input tokens per case | Cost per assessment |
| --- | --- | --- | --- | --- | --- | --- |
| GPT-5.6 Luna (default) | Copilot | 29/30 (97%) | 0 | 1 | 18,591 | $0.0039 |
| GPT-6 Luna | Copilot | 23/30 (77%) | 3 | 2 | 21,847 | $0.0023 |
| Claude Haiku 4.5 | Copilot | 19/30 (63%) | 1 | 10 | 16,750 | $0.0228 |
| gpt-oss 20B (local, Ollama) | RubyLLM | 6/15 (40%) | 2 | 1 | not reported | free (your hardware) |
| Qwen3 8B (local, Ollama) | RubyLLM | 5/15 (33%) | 2 | 4 | not reported | free (your hardware) |
| GPT-5 mini | Copilot | 8/30 (27%) | 9 | 0 | 23,518 | $0.0087 |
| Gemini 3.6 Flash | Copilot | 0/15: every case hit the 90-second limit | | | | |

The default stays GPT-5.6 Luna: GPT-6 Luna costs less per assessment but misses
more help and replies when it should not. Claude Haiku stays silent when the
docs have an answer, GPT-5 mini replies to almost everything, and the small
local models fail most cases even with the same tools and limits. Gemini 3.6
Flash never finished within Copilot CLI's 90-second limit.

Run it yourself against any model, with Copilot or through RubyLLM:

```sh
bundle exec ruby eval/run.rb --live --model gpt-5.6-luna
TRIAGE_API_KEY=... bundle exec ruby eval/run.rb --live --engine rubyllm --provider openrouter --model openai/gpt-oss-120b
```

## Issues

On a newly opened issue, the agent may write one concise recap when a report is
long or scattered: the problem, relevant environment, and key evidence. A short,
clear request needs only labels. After that, replies must add new help:

> Forwarding is already available: right-click the message or picture, choose Forward, then select the destination chat.

> Does restarting the app pick up the system theme?

Replies stay short, normally under 60 words, with no headings or status chatter.
Facts learned through tools carry citations to evidence the agent actually read,
and Ruby renders the links. A released-fix claim needs release notes, not code
on `main` or a closed issue. Map documentation files to your public site:

```yaml
documentation:
  docs/*.md: https://example.com/guides/%{name}/
```

Every comment ends with a footer naming the model, the tokens used, and a link
to the run, added by Ruby. Successful assessments get a 🎉 reaction. When a
maintainer or bot spoke last, the agent does not reply again.

### Duplicates and related issues

The agent searches open and closed issues and must read a candidate in full
before proposing a relationship.

```yaml
duplicates: suggest # or close, or 'off'
```

`suggest` posts the link and keeps the report open:

> See also #325. That issue covers the mini player's taskbar entry; this request concerns the separate Milkdrop window.

`close` also closes clear duplicates with GitHub's native duplicate reason, but
only against an older issue, never a reopened or maintainer-authored one, and
never after a maintainer has joined the conversation. Both reports are fetched
again before anything changes.

### Closing finished issues

```yaml
closing: suggest # or auto
```

The agent proposes closing an issue for one of three reasons, always with a
comment that explains it:

- **Fixed:** a published release fixed it, citing the release notes that name
  the fix. A fix on `main` that no release contains is not enough.
- **Resolved:** the reporter says it is solved, in their latest comment.
- **Out of scope:** your documented scope rules out the request itself, citing
  the document.

`suggest` posts the comment and puts the issue in **Sign off** on your board.
`auto` also closes it, as completed or, for out of scope, as not planned, but
never an issue a maintainer opened, joined, or reopened; those go to **Sign
off** instead.

### Follow-ups and commands

Every eligible human comment reaches the agent, which decides whether a reply
helps. `followups: off` limits triage to explicit commands and manual runs.
Bot comments and ordinary maintainer comments are skipped before any work.

- `/triage` or `/triage reassess` asks for a fresh assessment.
- `/triage mute` stops the bot in that conversation; a natural-language "please
  stop" works too, without a public apology.
- `/triage unmute` (maintainers only) turns it back on.

Comment runs wait 10 seconds (`debounce-seconds`, 0 to 60) so a burst of
comments is assessed once. A comment that arrives during an assessment
invalidates it; the next run sees the whole conversation.

### Error reports from bots

Issues opened by bots are skipped unless you list them:

```yaml
report_bots:
  - honeybadger[bot]
```

Error reports are assessed for the maintainer using the exception and
backtrace, which works in private repositories too.

## Discussions

Discussions can stay a place for questions and community. The agent answers
questions your docs establish, in the thread they were asked in.

When a new discussion is really a reproducible bug report or a concrete feature
request that no issue tracks yet, it moves to an issue. GitHub has no API to
convert a discussion, so the action creates the issue itself: same title, the
original text under a "Moved from" line that mentions the author (which
subscribes them), and the agent's labels. It replies in the discussion with the
link and closes it as outdated. The new issue is opened by the workflow's bot,
so the author cannot edit it. Questions, ideas still being explored, anything
already tracked, and anything the agent is unsure about stay put. To never
move discussions:

```yaml
discussions:
  move_to_issues: false
```

## Pull requests

```yaml
pull_requests:
  reviews: copilot      # or off
  out_of_scope: suggest # or close
```

With this in your policy, pull requests are assessed when they open, reopen,
become ready for review, or get a comment. The agent sees the changed files and
reads patches on demand; it never checks out or runs contributor code, which is
what makes `pull_request_target` safe here.

- **Reviews.** When a change touches behavior, public API, security, data
  handling, or non-trivial logic, the action requests a review from Copilot.
  Documentation, typos, generated files, lone dependency bumps, and pull
  requests still waiting on a process step are skipped. GitHub bills a Copilot
  review to whoever requests it: the `review-token` input, or `copilot-token`.
  After a new push, a fresh review of the new commit is requested without
  calling the model, once per commit. Drafts wait until they are ready. How
  thorough Copilot's review is, and what it costs, is a setting in GitHub:
  Lite costs less than the default.
- **Your own pull requests** are not assessed and never cost a model call: the
  board places them from their checks, conflicts, and reviews.
- **Policy.** Replies only when the author needs something: a requirement from
  your contribution policy, one essential question, or a scope explanation. It
  does not summarize changes or review code line by line.
- **Out of scope.** Only when your documented scope rules out the change itself,
  never for a missing process step, code quality, or tests, and always with a
  cited explanation. `suggest` stops at the explanation; `close` also closes the
  pull request, never one opened by a maintainer.

## The board

A GitHub project board of everything that needs you, across every repository
that uses it, public and private. Each column names what an item needs from
you, so you can clear **Sign off** in minutes on your phone and save **Do** for
focus time:

| Column | What it asks of you | What lands there |
| --- | --- | --- |
| **Sign off** | Say yes to a prepared result | Pull requests ready to merge, and closures triage proposes but may not make itself |
| **Decide** | Use your judgment | Feature requests, scope and design calls, answers only you can give |
| **Do** | Use your hands | A confirmed bug, a pull request worth reading closely, your own unfinished work, a failing default branch |
| **Their move** | Nothing | A contributor, reporter, reviewer, or upstream has the next step, or checks are still running |
| **Not now** | Nothing until you choose | Accepted but not scheduled, your own notes and roadmap; yours to set |
| **Done** | Nothing | Closed or merged, archived after a week |

Finished work moves to **Done** the moment it closes or merges, so you can see
what got done this week, and is archived after `archive_after_days` there (7 by
default; 30 keeps a month). Archived cards stay searchable in the project, and
a reopened issue or pull request comes back onto the board. Each card also gets a
**Priority** (Urgent, High, Normal) and a **Next step** written for you, such as
"Reproduce from the Windows backtrace; likely the path join in loader.rb".

### Set it up

1. Create an empty project for your account or organization, for example with
   `gh project create --owner your-name --title "Maintainer board"`. Keep it
   private unless you want the public to see your process; labels and replies
   stay the public signal on each issue.
2. Create a classic personal access token with the `project` scope, plus `repo`
   for private repositories and for requesting your review on pull requests
   (fine-grained tokens cannot reach user-owned projects yet). Save it as a
   `TRIAGE_PROJECT_TOKEN` secret.
3. Add the board to your policy:

```yaml
board:
  project: https://github.com/users/your-name/projects/1
  maintainer: your-name   # requests your review and assigns urgent issues
  archive_after_days: 7   # optional: how long finished work stays in Done
```

4. Pass the token to the triage step with `project-token:
   ${{ secrets.TRIAGE_PROJECT_TOKEN }}`, and add a daily sweep as
   `.github/workflows/board.yml`. The sweep uses no model:

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
  pull-requests: write # requests your review
  actions: write       # sends fork pull requests to triage

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
          triage-workflow: triage.yml
          dry-run: ${{ inputs.dry_run || false }}
```

Run it once by hand with `dry_run` turned off. It builds the board on the empty
project: the six columns in order with their colors, the Priority and Next step
fields, an **All repositories** board view, and a board view for each
repository once it has cards. Every sweep keeps that shape, archives finished
work, and fixes nothing that is already right. A column of your own survives.
Columns of earlier versions are renamed in place, so their cards stay put:
Approve becomes Sign off, Answer or decide becomes Decide, Fix becomes Do,
Waiting on others becomes Their move, and Backlog becomes Not now. Review is
retired, and its cards are placed again.

### How cards move

On each assessment, the agent picks the item's next move, a priority, and the
next step. An issue moves to **Their move** only when that run asked the
reporter something, and a closed one goes to **Done**. Priority only rises.
Urgent issues are assigned to `maintainer`, the one notification GitHub sends
you.

Pull requests follow GitHub's facts on their latest commit, without a model.
Drafts, failing checks, conflicts, and requested changes are the author's move
(**Do** for your own), and an approved, green, mergeable pull request goes to
**Sign off**. A decisive review from another review bot, such as CodeRabbit,
counts too: requested changes go back to the author, and an approval of a ready
pull request goes to **Sign off**. Copilot's **Approval recommended** goes to
**Sign off**, **Changes recommended** to **Their move**, and a pull request
whose review or checks are still running waits, including right after a new
push. **Needs a closer look** is the agent's call, because it means two things:
when Copilot only says a change is broad or risky, the pull request is ready
for you (**Sign off**, or **Do** when it deserves a close read); when Copilot
names something still wrong, it goes back to its author. Triage runs when
Copilot posts its review on a same-repository pull request; for forks, whose
review runs get no secrets, the sweep sends the pull request to the workflow
named by `triage-workflow`, once per review. That workflow needs a
`workflow_dispatch` trigger with `kind`, `number`, and `dry_run` inputs, as in
[Preview a report](#preview-a-report).

While a pull request sits in **Sign off** or **Do**, your review is requested
by the workflow, so GitHub's review-requested list is your queue; it is
withdrawn when the card moves on. Issues are not assigned to you outside urgent
ones, since being assigned subscribes you to every comment.

The sweep also places issues by GitHub facts: new ones go to **Decide**, or
**Do** when labeled `bug`; to **Their move** when a maintainer spoke last; and
your own untouched issues to **Not now**. An issue with an open pull request
that would close it follows that pull request's card. A card in **Their move**
comes back when the reporter answers. Cards in **Not now** or a column of your
own stay where you put them. While the default branch fails its checks, an
urgent card in **Do** says so, because every pull request inherits the failure;
it is archived once the branch passes.

### Labels

Labels stay public and simple: the types in your policy, such as `bug`,
`enhancement`, `documentation`, and `question`, on issues and pull requests
alike. Triage creates any of them a repository lacks. Priority, next steps, and
columns stay private on the board.

## Preview a report

Add manual inputs to the workflow:

```yaml
  workflow_dispatch:
    inputs:
      kind:
        type: choice
        options: [issue, discussion, pull_request]
        default: issue
      number:
        description: Issue, discussion, or pull request number
        required: true
```

and these inputs to the action step:

```yaml
          kind: ${{ inputs.kind || (github.event.discussion && 'discussion' || (github.event.pull_request || github.event.issue.pull_request) && 'pull_request' || 'issue') }}
          number: ${{ inputs.number || github.event.issue.number || github.event.discussion.number || github.event.pull_request.number }}
          dry-run: ${{ github.event_name == 'workflow_dispatch' }}
```

Add `|| inputs.number` to the concurrency group's number expression. A manual
run shows its decision in the job summary without changing anything, including
for closed reports. Previews spend model tokens.

To assess existing reports after installing, dispatch the same workflow for
each open issue and pull request with `dry_run` off. Add `quiet: true` to the
action step to sort them onto the board without comments, labels, closures, or
Copilot reviews, so nobody is pinged about an old thread.

## Configuration

Action inputs:

| Input | Default | Purpose |
| --- | --- | --- |
| `copilot-token` | | Copilot Requests token for the `copilot` engine |
| `github-token` | `github.token` | Reads reports, publishes labels and comments |
| `config` | `.github/triage.yml` | Policy file on the default branch |
| `engine` | `copilot` | `copilot` or `rubyllm` |
| `model` | `gpt-5.6-luna` | Model ID; for `rubyllm`, as the provider names it |
| `reasoning-effort` | `low` | Copilot reasoning effort, `none` or `low`; `default` for models without it, such as Claude Haiku |
| `provider`, `api-key`, `api-base` | | Provider, key, and optional endpoint for `rubyllm` |
| `review-token` | `copilot-token` | Token that requests Copilot reviews, billed to its owner |
| `project-token` | | Classic token with the `project` scope, for the board |
| `triage-workflow` | `triage.yml` | For the sweep, the triage workflow to run on fork pull requests Copilot asks a human to look at |
| `mode` | `triage` | `triage`, or `sweep` for the board |
| `kind`, `number` | from the event | What to assess, for manual runs |
| `dry-run` | `false` | Show the decision without changing GitHub |
| `debounce-seconds` | `10` | Wait for nearby comments, 0 to 60 |

Policy keys in `.github/triage.yml`: `labels` (at most two per issue),
`replies` (optional reply templates), `sources` (globs the agent may read),
`documentation` (links to your site), `instructions` (your project's policy),
`duplicates`, `closing`, `followups`, `report_bots`, `discussions`,
`pull_requests`, and `board`. See [examples/triage.yml](examples/triage.yml).

## Safety

- **No code execution.** The model has no shell, no file writes, no arbitrary
  URLs, and no GitHub write tools. It gets five tools:

  | Tool | Returns |
  | --- | --- |
  | `search_repository` | Up to ten literal matches in your configured sources |
  | `search_issues` | Up to five same-repository issue search results |
  | `list_releases` | Five published releases with short notes |
  | `read_evidence` | A paged file, issue, release, or pull request patch, up to 6 KB |
  | `submit_decision` | A schema-checked proposal; no GitHub mutation |

- **Ruby publishes.** Labels, comments, closures, moves, reviews, and board
  changes happen in Ruby after validating the decision, re-reading the report,
  and re-checking cited evidence. A report that changed during assessment is
  left alone.
- **Untrusted input.** Report text, comments, code, and links are evidence,
  never instructions. Comments cannot contain mentions, HTML, raw URLs, or
  Markdown links written by the model.
- **Tokens stay out of the model.** The GitHub, project, review, and API tokens
  are removed from the Copilot CLI environment and redacted from logs. Copilot
  runs with isolated settings and repository instructions disabled.
- **Bounded.** At most 12 evidence calls, 90 seconds (Copilot) or 20 turns and
  120 seconds (RubyLLM). The agent reads the whole conversation, up to the
  latest 100 comments, because long threads are where it helps most. Only a
  single text over 30 KB, such as a pasted log, is shortened around a visible
  marker, and a starting prompt over 200 KB (about 50,000 tokens) is left for a
  maintainer.

## Failures

Model failures and invalid decisions appear in the job summary and leave the
report unchanged. They never become issues, comments, or apologies. A Copilot
session that ends without calling a single tool, which happens when many runs
start at once, changed nothing, so it is tried again after 20 and then 40
seconds; the failure message includes the model's final text. GitHub
write failures fail the job without marking the assessment complete, so it is
retried. A failed board update or review request fails the job after the reply
is published, so it never causes a repeated reply. Exhausted Copilot credits
need a reset or a budget; the action never changes billing settings.

Conversation state (mute, processed updates, prior replies, review history)
lives in a small Actions cache. If it is evicted, up to 500 older comments are
recovered; an unchanged issue may then be assessed again.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md). Tests use fake GitHub and model
responses; the Copilot CLI integration test uses a local fake provider and
spends no credits.

```sh
bundle install
bundle exec rubocop
bundle exec rspec
bundle exec ruby eval/run.rb --replay
```

This independent project uses GitHub Copilot CLI and RubyLLM and is not an
official GitHub product. MIT licensed.
