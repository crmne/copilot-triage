# Reply evaluations

Run the offline control checks:

```sh
bundle exec ruby eval/run.rb --replay
```

This runs the real assessment pipeline against fixture GitHub data and supplied
model responses, including some deliberately unhelpful historical replies. It
checks suppression, positive replies, evidence lookup, and duplicate decisions.
It spends no model credits and cannot write to GitHub. The reported model calls
are simulated in replay mode; replay time is not a model-latency benchmark.

Measure fresh model behavior with a Copilot token in `COPILOT_GITHUB_TOKEN`:

```sh
bundle exec ruby eval/run.rb --live --model gpt-5.6-luna --output luna-eval.json
```

The live option consumes Copilot credits but still uses fixture GitHub evidence
and dry-run publishing. Compare another model by changing `--model`. Use
`--case verified-released-fix` to narrow a run. The runner returns a nonzero exit
status when an expected outcome, required content, or call budget fails.

Alternatively, manually dispatch the **Evaluate replies** Actions workflow. It
uses the repository's `COPILOT_GITHUB_TOKEN` secret and prints the full results
in the run log. Its GitHub permissions are read-only; it never posts to issues.
The optional `case` input narrows the run, and each case has at most two model
calls. Nothing schedules live evaluations automatically.

The corpus includes both expected silence and expected help: the ZapFast #20
stop request, a useful initial recap, suppressed follow-up recaps, repeated CPU
updates, an already answered question, a clear feature
request, an essential missing error, documented policy, a technical answer,
release evidence, a new regression without a question mark, and a confirmed
duplicate. Release and documentation details are synthetic fixtures, not claims
about actual ZapFast releases.

Results include unnecessary replies, missed helpful replies, model calls, input
bytes, wall time, and each actual reply. Per-case token counts appear when the
CLI reports usage. Review the replies as well as the pass count: keyword checks
cannot establish factual accuracy or whether a question was necessary. Do not
optimize only for silence. Keep positive cases when adding negative regressions.
