# ZapFast reply audit, 16 September 2026

Reviewed all 26 Copilot Triage issue comments available at the time, across 21
issues, plus the discussion list (one discussion, no bot replies). Twenty-four
comments used a recap followed by a suggested check; two were direct questions.
This is a qualitative review of the posted replies, not a model benchmark.

The attribution footers on those 26 replies report 146,595 input tokens and
1,782 output tokens: averages of 5,638 input and 69 output, with 98.8% of tokens
on input. None reports a response-cache hit. These totals cover runs that posted
comments, not all assessment runs, and do not establish provider-cache discounts
or billed cost. Issue #20 alone accounts for five replies, 28,201 input tokens,
and 418 output tokens.

The 40 successful runs returned by the workflow's latest-runs endpoint include
22 issue events (median 26 seconds), 17 issue-comment events (median 27 seconds),
and one discussion event (25 seconds), measured from `run_started_at` to
`updated_at`. Skipped assessments are included, so these are not inference-time
benchmarks. The [run answering the stop request](https://github.com/crmne/zapfast/actions/runs/35114447397)
took 51 seconds in its job, including the intentional 30-second comment delay.

| Example | What went wrong | Useful behavior |
| --- | --- | --- |
| [#20: measured patched build](https://github.com/crmne/zapfast/issues/20#issuecomment-5699770597) | Asked for focused/unfocused measurements the preceding comment already supplied. | Keep the measurements for the maintainer; no reply. |
| [#20: startup improvement](https://github.com/crmne/zapfast/issues/20#issuecomment-5699880606) | Repeated the update and invented another test. | No reply without a specific unresolved question that blocks investigation. |
| [#20: request to disable the bot](https://github.com/crmne/zapfast/issues/20#issuecomment-5699914061) | Posted almost the same CPU summary in response to a complaint about spam. | Stop replying. |
| [#17: all images fail](https://github.com/crmne/zapfast/issues/17#issuecomment-5697200980) | Asked whether all chats and image types were affected; the report already said all attachments in all chats. | Label silently, or provide a verified fix or workaround if available. |
| [#31: receipt mismatch](https://github.com/crmne/zapfast/issues/31#issuecomment-5699705885) | Asked the reporter to compare the official client after they had described that comparison. | No reply. |
| [#18: community section](https://github.com/crmne/zapfast/issues/18#issuecomment-5697229718), [#22: multiple accounts](https://github.com/crmne/zapfast/issues/22#issuecomment-5697484413) | Suggested inspecting protocol internals for already clear feature requests. | Leave the product decision to the maintainer; explain documented policy only when it directly answers the request. |
| [#34: NixOS packaging](https://github.com/crmne/zapfast/issues/34#issuecomment-5699918058) | Restated the request and suggested searching for a package elsewhere. | Label silently unless there is a verified existing package to point to. |
| [#36: unread filtering](https://github.com/crmne/zapfast/issues/36#issuecomment-5700007769) | Added a documentation link, but still just restated the request and suggested inspecting the implementation. | A citation does not make a recap useful; stay silent without an actual answer. |
| [#26: image error](https://github.com/crmne/zapfast/issues/26#issuecomment-5699098098) | Requested the redacted error text, which was only in an image the bot could not read. | This is a useful clarification to preserve. |

The [live workflow](https://github.com/crmne/zapfast/blob/main/.github/workflows/issue-assessment.yml)
was pinned to `10fdd4aaa1b20ac434b9d6352bca2738cf4e80f0` (v0.3.0).
That predates related-issue comparisons and duplicate closure. The
[project policy](https://github.com/crmne/zapfast/blob/main/.github/triage.yml)
also explicitly requested an initial assessment and a next check. The shared
prompt still allowed report-based assessments. Exact-text deduplication missed
rephrased repeats, and the latest-human-comment check allowed another reply after
every human update.

## Changes implemented locally in Copilot Triage

- Preserve one useful initial recap of a long or scattered newly opened issue.
  Short clear requests may need only labels; no forced next check or question.
- Limit subsequent report-only generated comments to one necessary clarification
  question. Suppress follow-up recaps while still applying valid labels.
- Suppress the observed stock recaps and generic next-check wording in sourced
  answers too; a valid citation does not make an unhelpful reply worth posting.
- Keep configured policy replies, sourced answers and workarounds, useful issue
  links, and duplicate closure under `duplicates: close`.
- Require explicit release evidence before claiming a fix in a named version.
  Include changelogs and contribution policy in the example source catalog.
- Persist questions, replies, processed updates, and stop requests across runs.
  Support `/triage`, `/triage mute`, and maintainer-only `/triage unmute`.
  Recover older public conversation state after cache eviction or missed events.
- Skip bot comments, ordinary maintainer comments, and acknowledgements before
  checkout. Check conversation eligibility before restoring or installing the CLI.
  Assess new questions, pending answers, and substantive new evidence, including
  versions, errors, measurements, and reproduction steps without a question mark.
- Offer bounded read-only documentation, release-note, and resolved-issue lookups,
  with at most two prompt invocations. Cache evidence and revalidate cited remote
  records before posting; a closed issue is not itself proof of a released fix.
- Shortlist relevant source paths and issues, send bounded source excerpts,
  cache the pinned CLI, and reduce the configurable comment debounce to 10 seconds.
- Record per-run decisions, model calls, prompt bytes, evidence reads, elapsed
  time, and available token counts. Add both helpful-reply and silence evaluations.
- Suppress replies with strongly overlapping wording, as well as exact repeats,
  before both previews and publishing. Preserve different versions, commands,
  source links, and issue numbers.

## Adoption and remaining limits

The changes are local to Copilot Triage. ZapFast's workflow and live issues were
not changed. To adopt them, publish the action changes and update ZapFast's pinned
SHA and project policy together. Allow one useful initial recap, remove the mandatory next-check text
and the old instruction to leave all duplicate handling to the maintainer. Set
`duplicates: close` to enable closure of confirmed duplicates under the existing
safeguards. Preview representative reports before enabling posting with the new
version, including #20 (silence) and #26 (a necessary question).

Prompts include the latest five comments plus compact question state. Recovery
reads up to 500 older comments without sending that history to the model. State
uses Actions cache, which can be evicted; completed silent assessments cannot be
reconstructed from public comments. Automatic selective follow-ups pause if
history remains incomplete; `/triage` explicitly requests reassessment.

Stop detection and evidence eligibility are bounded English-language wording
checks, and reply similarity does not establish semantic equivalence. Remote
lookups cover the latest 20 releases and 30 recently updated closed issues, not
the entire project history. Necessary versus unnecessary questions and the
accuracy of source-based claims still depend on model judgment. Offline replay
checks the controls and positive reply paths, not fresh model quality or latency.
The live evaluation runner needs a dedicated Copilot token; it was not run during
this implementation. No measured model-quality or speed improvement is claimed.
