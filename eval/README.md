# Reply evaluations

`TriageEvaluation` in `app/evals` uses RubyLLM's evaluation runner. Its YAML dataset
contains the same 23 control cases, with inputs separate from expected outcomes.
The RSpec suite declares `evaluates TriageEvaluation`, so each case also appears
as an ordinary example with the same assertions and failure messages.

Run the offline control checks:

```sh
bundle exec rake ruby_llm:eval
```

This runs the real tools and publisher against fixture GitHub data and supplied
tool calls/decisions. It checks positive replies, silence, evidence validation,
and guarded duplicate decisions. Conversational judgment belongs to the model,
so replay cannot establish that the model follows those policies.
It spends no model credits and cannot write to GitHub. The reported model calls
are simulated in replay mode; replay time is not a model-latency benchmark.

The [README](../README.md#evaluations) publishes the latest live results for
the default model, other Copilot models, and local models through RubyLLM.
We rerun them before each release and when we consider a new default model.

Measure fresh model behavior with a Copilot token in `COPILOT_GITHUB_TOKEN`:

```sh
EVAL_LIVE=true TRIAGE_MODEL=gpt-5.6-luna EVAL_OUTPUT=tmp/luna bundle exec rake ruby_llm:eval
```

Measure a model from another provider through RubyLLM with its key in
`TRIAGE_API_KEY`:

```sh
EVAL_LIVE=true TRIAGE_ENGINE=rubyllm TRIAGE_PROVIDER=anthropic TRIAGE_MODEL=claude-haiku-4-5 bundle exec rake ruby_llm:eval
```

Set `TRIAGE_API_BASE` for an OpenAI-compatible or local endpoint.

`EVAL_LIVE=true` consumes model credits but still uses fixture GitHub evidence
and dry-run publishing. Compare another model with `TRIAGE_MODEL`, or compare
`TRIAGE_REASONING_EFFORT=none` and `TRIAGE_REASONING_EFFORT=low`. Use
`bundle exec rake "ruby_llm:eval[TriageEvaluation,verified-released-fix]"` to narrow a run. The runner returns a nonzero exit
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

The task saves `tmp/evaluations/TriageEvaluation.json`. Set `EVAL_OUTPUT` to keep
runs in separate directories and `EVAL_REPETITIONS` to measure variation. Each
trial includes its reference, actual action, reply, tool trace, model calls,
input bytes, wall time, and any assertion failure. Per-case token counts appear
when the engine reports usage. The `mode` field distinguishes offline replay
from fresh model output. Review the replies as well as the pass count: keyword checks
cannot establish factual accuracy or whether a question was necessary. Do not
optimize only for silence. Keep positive cases when adding negative regressions.

The development bundle uses RubyLLM's `main` branch for the evaluation API.
The published action continues to install its pinned RubyLLM release.
