# Copilot Triage

**You shouldn't need 2,000 lines of generated YAML to label an issue.**

Copilot Triage is a small alternative to **GitHub Agentic Workflows** for issues
and discussions, built for [RubyLLM](https://github.com/crmne/ruby_llm) and
[Spotifast](https://github.com/crmne/spotifast). A small Ruby program, a cheap model,
and cached answers. Read the report, help the person, get out of the way.

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

One prompt chooses labels and whether a reply would help. A technical
question or possible duplicate can use one more prompt with the relevant evidence.
Ruby validates the result and calls GitHub's API. That's the whole approach.

```ruby
item, labels = read_report
decision = assess(item, labels)
publish(item, labels, decision)
```

- **Use the Copilot subscription you already pay for.** The default is
  `gpt-5.6-luna`. Change the model if you want. Keep one billing account.
- **Spend tokens on the report.** One prompt for triage, one optional prompt for
  a technical answer or duplicate comparison. The model can request bounded
  documentation, release, and resolved-issue searches through its JSON decision.
  Ruby performs those reads; there is no open-ended agent loop.
- **Reuse the answer.** An identical validated prompt comes from cache with
  zero model calls. New comments and changed source material are considered.
- **Give people useful replies.** A missing detail gets one short question.
  A long new issue can get one concise recap. Follow-ups bring supported answers,
  workarounds, released fixes, policies, or useful issue links, not more recaps.
  Short clear requests can be labeled silently.
- **Keep the bot's problems out of your issues.** Model failures go in the job
  summary. They don't become a new ticket or a string of failure comments.
- **Read the code yourself.** [Assessment](lib/assessment.rb) and
  [issue comparison](lib/related_issues.rb), using the
  standard library. Your repository keeps a small policy file and calls a
  shared action. Fix it once, reuse it everywhere.

Here is what we replaced in RubyLLM:

| | Our GitHub Agentic Workflows setup | Copilot Triage |
| --- | --- | --- |
| Workflow | 2,035 generated YAML lines plus a Markdown definition | A small caller and shared Ruby code |
| Model work | Sonnet 5 assessment plus Haiku 4.5 detection | Luna triage plus one optional evidence prompt |
| GitHub access | Agent tools behind a gateway, followed by safe-output jobs | Ruby validates the decision and makes the API calls |
| Reassessment | Agent-driven investigation | Cached responses when the prompt is unchanged |
| Model failures | Bot-created issues and detector comments | Job summary |

Those are differences in scope and machinery, not a claim of identical answer
quality. This supplies five recent comments, remembered questions, and bounded
evidence excerpts or one candidate issue. Uncertain answers stay with a maintainer. We have not yet
benchmarked live answer quality or end-to-end cost against the old workflow.

**Issue triage can be this simple.**

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
      - uses: crmne/copilot-triage@v0.5.0
        with:
          copilot-token: ${{ secrets.COPILOT_GITHUB_TOKEN }}
```

The action checks out your repository's **default branch**, restores cached
responses, installs Copilot CLI, and runs the assessment. Commit the configuration
to that branch before enabling the workflow. It requires the Ruby, Node.js,
GitHub CLI, Git, and `timeout` commands provided by GitHub's Ubuntu runners.
There is no runtime gem dependency or provider API key.

Pin the action to a full commit SHA for an immutable version. Update that
reference to adopt a release; the implementation stays in this repository.
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
Uncached prompts still consume Copilot credits.

## Replies

On a newly opened issue, one concise initial recap is welcome when it saves the
maintainer a long read: the problem, relevant environment, and key evidence.
A short, already clear request may need only labels. A recap does not need an
invented next check or a question to justify posting it.

After that, replies must add new help, not summarize each comment. One essential
missing fact can get one direct question, without an introductory summary.
Ruby permits report-only summaries only on the first assessment of an opened
issue; other generated report-only comments must be a single question. It also
suppresses common recap and generic next-check wording in sourced answers.
Answers, workarounds, and project policies use configured replies or supplied docs
and source. A claim that something was fixed in a particular release requires
explicit release documentation; code on the default branch does not establish it.
Include your changelog in `sources` when it records published fixes. Technical
answers use the supplied docs or source,
with a short example when useful and verified links placed inside the reply.
The answer stays under 60 words and at most three sentences, with no headings,
tables, em dashes, or generic status summaries.

For example, a reply might be:

> Does restarting the app pick up the system theme?
>
> _Generated by [Copilot Triage](https://github.com/marketplace/actions/copilot-triage) using `gpt-5.6-luna`; 6200 input / 80 output tokens this run; [view run](https://github.com/crmne/copilot-triage/actions)._

The figures above are illustrative. Every posted comment includes this compact
footer, added by Ruby, with the model, measured input/output tokens, and a link
to the exact run attempt. Counts cover fresh calls in that run, including
provider-cached input. Cache-only runs say **0 new model tokens**; missing CLI
usage is reported as unavailable. The footer links the Marketplace listing so
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
Git revision read. Models choose source paths from a catalog and cannot invent
links. Source files outside the checkout are excluded.

Each run reads the current report and its latest five comments. A discussion
comment event reads that thread's parent and latest five replies, including
threads older than the latest top-level comments. Answers stay in that thread.
Technical answers can select at most two source files, up to 48 KB combined.
Files are selected from eight ranked paths with short documentation hints, with at most 6 KB of relevant text
per file sent to the answer prompt. Long excerpts are marked as incomplete.
Uncertain answers and product decisions stay with the maintainer. This bounds
the work; it does not reproduce a full repository
investigation or guarantee the same answer as a larger agent.

The action suppresses ordinary replies when a maintainer or bot commented most
recently. A manual assessment may add a new related-issue link after a bot reply.
It checks the report again before publishing and skips if it changed. Successful
assessments get a bot 🎉 reaction. PRs are outside its scope; GitHub's built-in
Copilot code review is a separate product.

### Related issues and duplicates

The bot can connect an issue or discussion to an existing open issue. It gets a
compact catalog of titles first, then reads one candidate's body and latest five
comments in the optional second call. A title match alone cannot close anything.
There are still at most two model calls, with no agent search loop.

Choose the behavior in `.github/triage.yml`:

```yaml
duplicates: suggest
```

- `suggest` (default): post a useful issue link and keep the report open.
- `close`: also close clear duplicates with GitHub's native duplicate reason.
- `'off'`: do not fetch other issues or compare reports. Keep the quotes in YAML.

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

Issue duplicates close only against an older open issue, preventing reciprocal
closures. Discussions can close in favor of an open issue. Maintainer-authored
reports, reopened issues, and reports with a maintainer among the recent comments
are linked without automatic closure. A previous bot duplicate comment also
prevents another automatic closure. Both reports are fetched again before any
changes; changed or closed candidates invalidate the assessment.

The script ranks up to 100 recently created open issues in the same repository
and supplies at most eight titles, capped at 160 characters and 2 KB combined.
Duplicate closure still compares one full candidate. It does not search PRs,
other repositories, or other discussions. Older issues outside that catalog
are not duplicate candidates.
These bounds keep duplicate detection useful without making triage an agent loop.

### Evidence requests

The first decision can request up to two scoped, read-only searches in `lookup`:

```json
{"lookup":[{"tool":"releases","query":"Windows inline images"}]}
```

`docs` searches configured source files and returns at most two excerpts.
`releases` ranks the latest 20 release records; `resolved_issues` ranks the latest
30 updated closed issues. Each returns at most two records with bounded bodies.
These requests share the single optional evidence call; they cannot be combined
with a duplicate comparison or extended into another round of searches.
If a search is inconclusive, the final call may ask one essential missing-information
question instead of claiming an answer. Factual answers cite only supplied evidence. Release and resolved-issue records
are fetched again before publishing; changes invalidate the answer. A closed
issue is not proof that a fix shipped, and prereleases must not be described as
stable releases.

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

New reports are assessed. Follow-ups use `followups: selective` by default:
new questions, answers to pending clarifications, and substantive new evidence
are eligible. New versions, platforms, measurements, errors, regression reports,
and reproduction steps can qualify without a question mark. Repeated updates
and simple acknowledgements need no model call. The evidence check uses bounded
text patterns, so use `/triage` when it misses a useful update, or set
`followups: all` to assess every eligible human comment. `followups: off` leaves
only explicit reassessment commands and manual runs.

Bot comments, ordinary maintainer comments, and unmistakable acknowledgements
are skipped before checkout or CLI installation. A second preflight checks live
conversation state before installing or restoring Copilot. Anyone can request
reassessment with `/triage` or `/triage reassess`. These commands still respect
closed reports and a muted conversation.

Comment runs wait 10 seconds before reading GitHub; set the action input
`debounce-seconds` between 0 and 60 to change this. If a newer comment exists,
the older event is skipped without calling Copilot. Concurrency keeps one run
active per issue or discussion thread and replaces older pending runs in that
conversation. Separate discussion threads are assessed independently. A comment
arriving during inference invalidates that answer; the next run assesses the
updated conversation.
Active runs are allowed to finish so publishing cannot be interrupted halfway.

A qualifying human comment usually changes the prompt and costs a model call.
Processed events are remembered; manual reassessment bypasses that check. Cache
hits help repeated assessments of unchanged input. Reassessment does not mean
another public reply: the same response rules apply, and an exact reply already
present in the recent conversation is not posted again. Ruby also suppresses
replies with strongly overlapping wording, ignoring attribution changes while
keeping different versions, commands, source links, and issue numbers distinct.
This is a wording check, not a guarantee of semantic deduplication.

An explicit request to stop Copilot or the triage bot, or `/triage mute`, mutes
that issue or discussion thread without a public acknowledgement. Only a
maintainer can use `/triage unmute`. Questions, previous replies, pending
clarifications, maintainer participation, processed updates, and mute state are
saved between runs. Previews do not change this state.

State is restored from Actions cache. If evicted, or if comments were missed
between runs, the script recovers public bot questions and stop/unmute requests
from up to 500 older comments without sending that history to the model.
Automatic selective follow-ups pause when that bound leaves history incomplete;
`/triage` requests an explicit reassessment. Completion of a silent assessment
cannot be reconstructed after cache eviction, so it may be assessed again.

Existing issues and discussions are not automatically backfilled when you
install or upgrade the action. Use a manual preview for older reports. If a
run posts nothing, its job summary distinguishes skipped input or invalid model
output from a valid decision to stay silent.

## Cost and caching

The default model is `gpt-5.6-luna` with `reasoning-effort: low`; set `model` to
change it. `reasoning-effort: none` is available for comparison, but live checks
found it missed useful initial summaries and duplicate comparisons. These are
small fixture evaluations, not a general model benchmark. The first prompt
is limited to 24 KB and the answer or comparison prompt to 64 KB. Long runs of
repeated NUL bytes in pasted logs become a compact count; surrounding messages
remain intact.
Other oversized input is left for a maintainer rather than silently truncated. Copilot adds its own system
context, so billed input exceeds the text supplied by the script.

Validated responses are cached through GitHub Actions. The key includes the
complete prompt, model, reasoning effort, and script version. An unchanged prompt costs **zero
model calls**. New report text, recent comments, policy, or models change the key.
Answer keys include source contents, so documentation changes refresh the answer
while source selection can still be reused. Comparison keys include both reports
and their recent comments; the first prompt also includes the open-issue catalog.
A changed catalog may require a new selection call. Cached output is validated again.

Response and conversation-state caches are scoped to the issue or discussion
thread. Reusable evidence has a separate cache: source excerpts are keyed by
content, while remote catalogs expire after five minutes and cited records are
revalidated. The pinned CLI installation is also cached. Eligible runs fetch
the report again. GitHub may evict cache entries, causing a fresh call. A new
bot reply also changes the next assessment's input. Stable policy and sources
precede report text to help provider prompt caching; Copilot determines any
provider-side discount.

There are at most two prompt invocations, each with a 90-second timeout and no
workflow retry loop. The CLI may retry service requests internally. Its minimum
session limit is 30 AI credits; this is a soft fallback limit, not an expected
price, and an in-flight response can exceed it. Actual usage JSON appears in
the job summary when available.

Each assessment also emits a `Triage metrics` JSON record with its outcome,
skip reason, model calls, cache hits, input bytes, evidence catalog reads, elapsed
time, and token counts when available. An early event-only skip is logged before
assessment setup. Use [the evaluation runner](eval/README.md) to compare actual
reply quality, unnecessary replies, missed helpful replies, cost, and latency
across models. Offline replay is part of CI; fresh-model evaluations consume credits.

## Failures and permissions

Copilot failures and invalid output appear in the job summary and leave the
report unchanged. They do not create failure issues or comments. GitHub write
failures fail the job without marking the assessment complete. The action does
not change your billing settings; exhausted credits require a reset or budget.

The model has no CLI tools, MCP servers, GitHub write token, or repository custom
instructions. It can request only the scoped evidence reads described above,
which Ruby validates and executes. It runs with isolated settings. The script controls labels and
comments, and only closes duplicates when you opt in with `duplicates: close`.
It never modifies code. Keep secrets out of report text and the configured
source files, which are sent to Copilot.

The CLI is pinned to `1.0.83`. An empty custom-agent tool list still retains
skill and SQL tools in that version, so they are excluded explicitly. The
offline integration test verifies that the actual model request has zero tools.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md). Tests use fake GitHub/model responses;
the CLI integration test uses a local fake provider and spends no credits.

The first release is a preview. This independent project uses GitHub Copilot CLI
and is not an official GitHub product.

MIT licensed. Built for [RubyLLM](https://github.com/crmne/ruby_llm) and
[Spotifast](https://github.com/crmne/spotifast), reusable in your repositories.
