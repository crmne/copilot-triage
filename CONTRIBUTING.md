# Contributing

This project exists because GitHub Agentic Workflows was too much machinery for
our issue triage. Keep the replacement small. Every extra model call, trigger,
and dependency needs to earn its place through better replies to reporters.
Discuss those changes in an issue first.

Run the offline tests:

```sh
bundle install
npm install --global @github/copilot@1.0.83
bundle exec rubocop
bundle exec rspec
bundle exec ruby eval/run.rb --replay
```

The CLI integration test talks to a local fake model and consumes no credits.
It skips if Copilot CLI is absent. Add a regression test for behavior changes.
Include example public replies when changing response policy.

The runtime uses Ruby's standard library. Keep GitHub mutations in the script.
Models can request bounded, read-only evidence through the validated JSON
interface. Keep CLI execution, arbitrary URLs, and write tools unavailable to the
model. Do not run contributor code to assess a report. Keep both positive and
negative reply examples in the evaluation corpus; silence alone is not success.

Use a short commit subject that says what changes. Keep changes focused and
do not include generated attribution footers.
