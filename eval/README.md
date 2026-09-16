# Reply evaluations

Run the offline control checks:

```sh
bundle exec ruby eval/run.rb --replay
```

This runs the real tools and publisher against fixture GitHub data and supplied
tool calls/decisions. It checks positive replies, silence, evidence validation,
and guarded duplicate decisions. Conversational judgment belongs to the model,
so replay cannot establish that the model follows those policies.
It spends no model credits and cannot write to GitHub. The reported model calls
are simulated in replay mode; replay time is not a model-latency benchmark.

Measure fresh model behavior with a Copilot token in `COPILOT_GITHUB_TOKEN`:

```sh
bundle exec ruby eval/run.rb --live --model gpt-5.6-luna --output luna-eval.json
```

The live option consumes Copilot credits but still uses fixture GitHub evidence
and dry-run publishing. Compare another model by changing `--model`, or compare
`--reasoning-effort none` and `--reasoning-effort low`. Use
`--case verified-released-fix` to narrow a run. The runner returns a nonzero exit
status when an expected outcome, required content, or call budget fails.

Alternatively, manually dispatch the **Evaluate replies** Actions workflow. It
uses the repository's `COPILOT_GITHUB_TOKEN` secret and prints the full results
in the run log. Its GitHub permissions are read-only; it never posts to issues.
The optional `case` input narrows the run. Each case runs one native Copilot
session; the agent chooses its tool calls. Nothing schedules live evaluations automatically.

Missing or invalid decisions fail the action without posting or marking the
conversation complete. Live tests have also observed intermittent CLI sessions
ending without a submitted decision, sometimes with `No response was returned`.
This remains an unresolved runtime limitation, not intentional silence. Preview
and evaluation diagnostics include final text, submitted decisions, tool calls,
and runtime errors, but not hidden reasoning or persisted session transcripts.

Use **Preview real report** to assess an existing Zapfast, Spotifast, or RubyLLM
issue or discussion with the action's development checkout. It reads the target
repository's policy and evidence, but cannot publish: dry-run mode is mandatory
and the workflow token has read-only permissions. Results stay in the run log
and summary; no artifacts or conversation state are saved. This is a manual
reassessment, not a simulation of a newly opened issue or comment event.

The corpus includes both expected silence and expected help: the ZapFast #20
stop request, Zapfast #46's already-implemented forwarding, a useful initial recap, follow-up recaps, repeated CPU
updates, an already answered question, a clear feature
request, an essential missing error, documented policy, a technical answer,
release evidence, a new regression without a question mark, and a confirmed
duplicate, including a closed canonical request inspired by Spotifast #500.
Release and documentation details are synthetic fixtures, not claims
about actual ZapFast releases.

The new-regression case requires assessment, not a manufactured question: either
a necessary clarification or silence is allowed. Cases with a clear answer,
required missing error, useful initial summary, or duplicate still require help.

Results include unnecessary replies, missed helpful replies, model calls, input
bytes, wall time, and each actual reply. Per-case token counts appear when the
CLI reports usage. Review the replies as well as the pass count: keyword checks
cannot establish factual accuracy or whether a question was necessary. Do not
optimize only for silence. Keep positive cases when adding negative regressions.
